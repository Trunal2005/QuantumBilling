defmodule QuantumBilling.EWayBills do
  @moduledoc """
  E-way bills: raising, cancelling and Part-B updates.

  "Active" and "Cancelled" are stored; "Expired" is derived from `valid_until`.
  Deleting moves a bill to the Bin and does not cancel it on the portal.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.EWayBillNotifier
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Notifications
  alias QuantumBilling.Paging
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Settings

  # Allowlisted sort columns; `value` lives on the invoice.
  @sortable %{
    ewb_no: {:bill, :ewb_number},
    issued_on: {:bill, :ewb_date},
    value: {:invoice, :grand_total}
  }

  @statuses ["Active", "Expired", "Cancelled"]

  # Rule 138(9): a bill may be cancelled within twenty-four hours of generation.
  @cancellation_window_hours 24
  # Rule 138(10): validity may be extended within eight hours before or after expiry.
  @extension_window_hours 8
  @extension_window_seconds 8 * 3600
  # Indian Standard Time (UTC+5:30) offset.
  @ist_offset_seconds 19_800

  @default_per_page 10
  @max_per_page 200

  @doc """
  Raises an e-way bill against an invoice.

  Returns `{:ok, bill}` or `{:error, :gst_only | :already_issued | :cancelled | changeset | portal_reason}`;
  `:gst_only` for a VAT business or invoice.
  """
  def generate_e_way_bill(%Invoice{} = invoice, params \\ %{}) do
    with :ok <- QuantumBilling.Tax.ensure_gst(invoice),
         :ok <- ensure_issuable(invoice),
         {:ok, attrs} <- NICClient.generate_ewb(invoice, params) do
      now = now_ist()

      # Mark any prior expired active bills for this invoice as "Expired".
      from(b in EWayBill,
        where: b.invoice_id == ^invoice.id and b.status == "Active" and b.valid_until < ^now
      )
      |> Repo.update_all(set: [status: "Expired"])

      attrs =
        attrs
        |> Map.put(:invoice_id, invoice.id)
        |> Map.put(:status, "Active")
        |> put_custom_fields(params)

      %EWayBill{}
      |> EWayBill.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, bill} ->
          bill = preload_bill(bill)

          Audit.log_event(:generate_e_way_bill, "EWayBill", bill.id,
            details: %{
              ewb_number: bill.ewb_number,
              invoice_id: invoice.id,
              invoice_number: invoice.invoice_number,
              distance_km: bill.distance_km,
              vehicle_number: bill.vehicle_number
            }
          )

          # The bill already exists on the portal, so the result is not matched.
          _ = EWayBillNotifier.notify_generated(bill)

          if Settings.get_organization().notify_ewb_generated != false do
            Notifications.notify(%{
              kind: "e_way_bill",
              title:
                if(EWayBill.demo?(bill),
                  do: "Demo e-way bill #{bill.ewb_number} created (not filed)",
                  else: "E-Way Bill #{bill.ewb_number} generated"
                ),
              body: "#{invoice.invoice_number} · #{bill.vehicle_number || "no vehicle recorded"}",
              path: "/invoices/#{invoice.id}",
              dedupe_key: "ewb_generated:#{bill.id}"
            })
          end

          broadcast_change(bill)
          Webhooks.publish("e_way_bill.generated", bill.id)
          {:ok, bill}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # The form's custom fields go to the bill's own changeset, which validates them.
  defp put_custom_fields(attrs, params) do
    case Map.get(params, "custom_fields", Map.get(params, :custom_fields)) do
      values when is_map(values) -> Map.put(attrs, :custom_fields, values)
      _none -> attrs
    end
  end

  @doc """
  Cancels a bill under Rule 138(9): within 24 hours, with a reason.

  Returns `{:ok, bill}` or `{:error, :already_cancelled | :window_closed | changeset}`.
  """
  def cancel_e_way_bill(%EWayBill{} = bill, params \\ %{}) do
    with :ok <- ensure_cancellable(bill),
         {:ok, _portal} <- NICClient.cancel_ewb(bill, params) do
      bill
      |> EWayBill.cancel_changeset(params)
      |> Repo.update()
      |> case do
        {:ok, cancelled} ->
          cancelled = preload_bill(cancelled)

          Audit.log_event(:cancel_e_way_bill, "EWayBill", cancelled.id,
            details: %{
              ewb_number: cancelled.ewb_number,
              reason: cancelled.cancellation_reason
            }
          )

          # Always sent: a cancelled bill on a moving consignment must be known.
          Notifications.notify(%{
            kind: "e_way_bill",
            severity: "warning",
            title: "E-Way Bill #{cancelled.ewb_number} cancelled",
            body: cancelled.cancellation_reason,
            path: "/invoices/#{cancelled.invoice_id}",
            dedupe_key: "ewb_cancelled:#{cancelled.id}"
          })

          broadcast_change(cancelled)
          Webhooks.publish("e_way_bill.cancelled", cancelled.id)
          {:ok, cancelled}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Records a Part-B update (a new vehicle) and moves the bill to it.

  Cancelled and expired bills cannot be updated.
  """
  def update_part_b(%EWayBill{} = bill, params) do
    with :ok <- ensure_updatable(bill),
         {:ok, _portal} <- NICClient.update_part_b(bill, params) do
      attrs = Map.put(stringify(params), "e_way_bill_id", bill.id)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:first_leg, fn _repo, _changes -> ensure_first_leg(bill) end)
      |> Ecto.Multi.insert(:part_b, PartBUpdate.changeset(%PartBUpdate{}, attrs))
      |> Ecto.Multi.update(:bill, fn %{part_b: part_b} ->
        Ecto.Changeset.change(bill, %{
          vehicle_number: part_b.vehicle_number,
          mode_of_transport: part_b.mode_of_transport
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{bill: updated, part_b: part_b}} ->
          updated = preload_bill(updated, force: true)

          Audit.log_event(:update_e_way_bill_part_b, "EWayBill", updated.id,
            details: %{
              ewb_number: updated.ewb_number,
              vehicle_number: part_b.vehicle_number,
              mode_of_transport: part_b.mode_of_transport,
              place: part_b.place
            }
          )

          broadcast_change(updated)
          {:ok, updated}

        {:error, _step, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Extends the validity of an e-way bill under Rule 138(10).

  Allowed within 8 hours before or after expiry time. Updates validity and adds
  a Part-B transit leg if vehicle or mode changed.
  """
  def extend_validity(%EWayBill{} = bill, params \\ %{}) do
    params = stringify(params)

    with :ok <- ensure_extendable(bill),
         {:ok, portal_resp} <- NICClient.extend_validity(bill, params) do
      new_valid_until =
        case portal_resp do
          %{"valid_until" => %NaiveDateTime{} = dt} ->
            dt

          %{"validUntil" => str} when is_binary(str) ->
            parse_portal_datetime(str) || calculate_extended_validity(bill, params)

          _ ->
            calculate_extended_validity(bill, params)
        end

      remaining_km =
        case Integer.parse(to_string(Map.get(params, "remaining_distance", bill.distance_km))) do
          {km, ""} -> km
          _ -> bill.distance_km
        end

      new_vehicle = presence(Map.get(params, "vehicle_number")) || bill.vehicle_number
      new_mode = presence(Map.get(params, "mode_of_transport")) || bill.mode_of_transport || "Road"
      place = presence(Map.get(params, "from_place")) || "In Transit"
      reason = Map.get(params, "reason") || "Extension"

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.update(:bill, fn _changes ->
          Ecto.Changeset.change(bill, %{
            valid_until: new_valid_until,
            distance_km: remaining_km,
            vehicle_number: new_vehicle,
            mode_of_transport: new_mode,
            status: "Active"
          })
        end)

      multi =
        if new_vehicle != bill.vehicle_number or new_mode != bill.mode_of_transport do
          multi
          |> Ecto.Multi.run(:first_leg, fn _repo, _changes -> ensure_first_leg(bill) end)
          |> Ecto.Multi.insert(:part_b, fn _changes ->
            PartBUpdate.changeset(%PartBUpdate{}, %{
              "e_way_bill_id" => bill.id,
              "vehicle_number" => new_vehicle,
              "mode_of_transport" => new_mode,
              "place" => place,
              "reason" => reason,
              "updated_on" => DateTime.utc_now() |> DateTime.truncate(:second)
            })
          end)
        else
          multi
        end

      multi
      |> Repo.transaction()
      |> case do
        {:ok, %{bill: updated}} ->
          updated = preload_bill(updated, force: true)

          Audit.log_event(:extend_e_way_bill_validity, "EWayBill", updated.id,
            details: %{
              ewb_number: updated.ewb_number,
              valid_until: updated.valid_until,
              reason: reason,
              remarks: Map.get(params, "remarks")
            }
          )

          Notifications.notify(%{
            kind: "e_way_bill",
            title: "E-Way Bill #{updated.ewb_number} validity extended",
            body: "Valid until #{Calendar.strftime(updated.valid_until, "%d/%m/%Y %H:%M")}",
            path: "/invoices/#{updated.invoice_id}",
            dedupe_key: "ewb_extended:#{updated.id}:#{NaiveDateTime.to_date(updated.valid_until)}"
          })

          broadcast_change(updated)
          Webhooks.publish("e_way_bill.extended", updated.id)
          {:ok, updated}

        {:error, _step, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc "One non-binned bill with its invoice and history, or `nil` (also for bad ids)."
  def get_e_way_bill(id), do: fetch_by_id(EWayBill.kept(), id)

  @doc "One non-binned bill. Raises if missing."
  def get_e_way_bill!(id) do
    EWayBill.kept()
    |> Repo.get!(id)
    |> preload_bill()
  end

  @doc "One binned bill, or `nil` (also for bad ids)."
  def get_deleted_e_way_bill(id), do: fetch_by_id(EWayBill.binned(), id)

  defp fetch_by_id(query, id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> query |> Repo.get(int_id) |> preload_bill()
      _not_an_id -> nil
    end
  end

  @doc "Binned bills, most recently deleted first; `limit:` bounds the rows."
  def list_deleted_e_way_bills(opts \\ []) do
    from(b in EWayBill.binned(), order_by: [desc: b.deleted_at, desc: b.id], preload: [:invoice])
    |> Paging.bounded(opts)
    |> Repo.all()
  end

  @doc "How many bills are in the Bin."
  def count_deleted_e_way_bills, do: Repo.aggregate(EWayBill.binned(), :count)

  @doc """
  Moves a bill to the Bin. An Active bill stays active on the portal.

  `opts` may carry `:user_id` for the audit entry.
  """
  def delete_e_way_bill(bill, opts \\ [])

  def delete_e_way_bill(%EWayBill{deleted_at: %DateTime{}} = bill, _opts), do: {:ok, bill}

  def delete_e_way_bill(%EWayBill{} = bill, opts) do
    bill
    |> EWayBill.bin_changeset()
    |> Repo.update()
    |> announce(:bin_e_way_bill, opts)
  end

  @doc "Restores a bill. Returns `{:error, :invoice_has_live_bill}` if a newer live bill exists."
  def restore_e_way_bill(%EWayBill{} = bill, opts \\ []) do
    bill
    |> EWayBill.restore_changeset()
    |> Repo.update()
    |> case do
      {:error, %Ecto.Changeset{}} -> {:error, :invoice_has_live_bill}
      result -> result
    end
    |> announce(:restore_e_way_bill, opts)
  end

  @doc "Deletes a binned bill and its Part-B history. Returns `{:error, :not_in_bin}` otherwise."
  def purge_e_way_bill(bill, opts \\ [])

  def purge_e_way_bill(%EWayBill{deleted_at: nil}, _opts), do: {:error, :not_in_bin}

  def purge_e_way_bill(%EWayBill{} = bill, opts) do
    bill
    |> Repo.delete()
    |> announce(:purge_e_way_bill, opts)
  end

  defp announce({:ok, %EWayBill{} = bill} = result, action, opts) do
    Audit.log_event(action, "EWayBill", bill.id,
      user_id: Keyword.get(opts, :user_id),
      details: %{ewb_number: bill.ewb_number, invoice_id: bill.invoice_id, status: bill.status}
    )

    broadcast_change(bill)
    result
  end

  defp announce(result, _action, _opts), do: result

  @doc """
  The live (not cancelled, not expired, not binned) bill for an invoice, or `nil`.
  """
  def live_bill_for_invoice(invoice_id) do
    now = now_ist()

    EWayBill.kept()
    |> where(
      [b],
      b.invoice_id == ^invoice_id and b.status == "Active" and
        (is_nil(b.valid_until) or b.valid_until >= ^now)
    )
    |> Repo.one()
    |> preload_bill()
  end

  @doc "Every e-way bill, newest first. Unbounded; the page uses `page/1`."
  def list_e_way_bills do
    base_query()
    |> order_by([bill: b], desc: b.ewb_date, desc: b.id)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  One page of e-way bills, filtered and sorted in the database.

  Options: `:search`, `:status`, `:sort_field`, `:sort_dir`, `:page`, `:per_page`.
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    sort_field = Keyword.get(opts, :sort_field, :issued_on)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    query =
      base_query()
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))

    # `:keyset` pages newest-created first below `:before_id`, for the API.
    result =
      if Keyword.get(opts, :keyset, false) do
        Paging.keyset(query, Keyword.get(opts, :before_id), per_page)
      else
        Paging.page(query, &order(&1, sort_field, sort_dir),
          page: Keyword.get(opts, :page, 1),
          per_page: per_page
        )
      end

    # `records: true` returns the bills themselves (used by the API).
    if Keyword.get(opts, :records, false),
      do: result,
      else: %{result | rows: Enum.map(result.rows, &to_row/1)}
  end

  @doc "Every bill matching the list filters, for CSV export. Ignores `:page`."
  def export_rows(opts \\ []) do
    base_query()
    |> search_where(Keyword.get(opts, :search))
    |> status_where(Keyword.get(opts, :status))
    |> order(Keyword.get(opts, :sort_field, :issued_on), Keyword.get(opts, :sort_dir, :desc))
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  @doc "The statuses the list page may filter on, the catch-all first."
  def status_options, do: ["All Status" | @statuses]

  @doc "How long after generation a bill may still be cancelled, in hours."
  def cancellation_window_hours, do: @cancellation_window_hours

  @doc "How long before or after expiry a bill's validity may be extended, in hours (Rule 138(10))."
  def extension_window_hours, do: @extension_window_hours

  @doc """
  Whether this bill is still inside its Rule 138(9) cancellation window.
  """
  def cancellable?(%EWayBill{} = bill), do: ensure_cancellable(bill) == :ok

  @doc """
  Whether this bill is eligible for Rule 138(10) validity extension.

  Extension is allowed within 8 hours before or 8 hours after the expiry time,
  for bills that have not been cancelled.
  """
  def extendable?(%EWayBill{status: "Cancelled"}), do: false
  def extendable?(%EWayBill{valid_until: nil}), do: false

  def extendable?(%EWayBill{valid_until: valid_until}) do
    now = now_ist()
    diff = NaiveDateTime.diff(now, valid_until, :second)
    diff >= -@extension_window_seconds and diff <= @extension_window_seconds
  end

  @doc """
  A bill's status. "Expired" is derived from `valid_until` compared with Indian Standard Time.
  """
  def status(%EWayBill{status: "Cancelled"}), do: "Cancelled"
  def status(%EWayBill{status: "Expired"}), do: "Expired"
  def status(%EWayBill{valid_until: nil}), do: "Active"

  def status(%EWayBill{valid_until: valid_until}) do
    if NaiveDateTime.compare(valid_until, now_ist()) == :lt,
      do: "Expired",
      else: "Active"
  end

  defp ensure_issuable(%Invoice{status: "Cancelled"}), do: {:error, :cancelled}

  defp ensure_issuable(%Invoice{id: id}) do
    now = now_ist()

    active_exists =
      EWayBill.kept()
      |> where(
        [b],
        b.invoice_id == ^id and b.status == "Active" and
          (is_nil(b.valid_until) or b.valid_until >= ^now)
      )
      |> Repo.exists?()

    if active_exists, do: {:error, :already_issued}, else: :ok
  end

  defp ensure_extendable(%EWayBill{status: "Cancelled"}), do: {:error, :already_cancelled}
  defp ensure_extendable(%EWayBill{valid_until: nil}), do: {:error, :no_validity}

  defp ensure_extendable(%EWayBill{valid_until: valid_until}) do
    now = now_ist()
    diff = NaiveDateTime.diff(now, valid_until, :second)

    cond do
      diff < -@extension_window_seconds ->
        {:error, :too_early}

      diff > @extension_window_seconds ->
        {:error, :window_closed}

      true ->
        :ok
    end
  end

  defp ensure_cancellable(%EWayBill{status: "Cancelled"}), do: {:error, :already_cancelled}

  defp ensure_cancellable(%EWayBill{inserted_at: nil}), do: :ok

  defp ensure_cancellable(%EWayBill{inserted_at: generated_at}) do
    hours = DateTime.diff(DateTime.utc_now(), generated_at, :second) / 3600

    if hours <= @cancellation_window_hours, do: :ok, else: {:error, :window_closed}
  end

  defp ensure_updatable(%EWayBill{} = bill) do
    case status(bill) do
      "Active" -> :ok
      "Cancelled" -> {:error, :already_cancelled}
      "Expired" -> {:error, :expired}
    end
  end

  defp preload_bill(bill, opts \\ [])

  defp preload_bill(nil, _opts), do: nil

  defp preload_bill(%EWayBill{} = bill, opts) do
    Repo.preload(
      bill,
      [
        invoice: :items,
        part_b_updates: from(p in PartBUpdate, order_by: [asc: p.updated_on, asc: p.id])
      ],
      opts
    )
  end

  # Keeps the original vehicle as the first Part-B leg.
  defp ensure_first_leg(%EWayBill{} = bill) do
    recorded? = Repo.exists?(from p in PartBUpdate, where: p.e_way_bill_id == ^bill.id)

    if recorded? do
      {:ok, :already_recorded}
    else
      Repo.insert(
        PartBUpdate.changeset(%PartBUpdate{}, %{
          "e_way_bill_id" => bill.id,
          "vehicle_number" => bill.vehicle_number,
          "mode_of_transport" => bill.mode_of_transport,
          "updated_on" => bill.inserted_at
        })
      )
    end
  end

  @doc "A bill by id on the same terms as `page/1`: neither it nor its invoice is binned."
  def get_listed_e_way_bill(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.one(from [bill: b] in base_query(), where: b.id == ^id)
      _not_an_id -> nil
    end
  end

  defp base_query do
    from b in EWayBill.kept(),
      as: :bill,
      join: i in assoc(b, :invoice),
      as: :invoice,
      where: is_nil(i.deleted_at),
      preload: [invoice: i]
  end

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"

    where(
      query,
      [bill: b, invoice: i],
      ilike(b.ewb_number, ^pattern) or ilike(i.invoice_number, ^pattern) or
        ilike(i.client_name, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query

  defp status_where(query, "Cancelled"), do: where(query, [bill: b], b.status == "Cancelled")

  defp status_where(query, "Expired") do
    now = now_ist()

    where(
      query,
      [bill: b],
      b.status == "Expired" or (b.status != "Cancelled" and b.valid_until < ^now)
    )
  end

  defp status_where(query, "Active") do
    now = now_ist()

    where(
      query,
      [bill: b],
      b.status == "Active" and (is_nil(b.valid_until) or b.valid_until >= ^now)
    )
  end

  defp status_where(query, _unknown), do: query

  defp order(query, field, direction) do
    {binding, column} = Map.get(@sortable, field, {:bill, :ewb_date})
    direction = if direction == :asc, do: :asc, else: :desc

    # The id breaks ties so paging is stable.
    case binding do
      :bill ->
        order_by(query, [bill: b], [{^direction, field(b, ^column)}, {^direction, b.id}])

      :invoice ->
        order_by(query, [bill: b, invoice: i], [
          {^direction, field(i, ^column)},
          {^direction, b.id}
        ])
    end
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp now_ist do
    NaiveDateTime.add(NaiveDateTime.utc_now(), @ist_offset_seconds, :second)
  end

  defp stringify(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp to_row(%EWayBill{invoice: %Invoice{} = invoice} = bill) do
    %{
      id: bill.id,
      invoice_id: invoice.id,
      ewb_no: bill.ewb_number,
      portal_mode: bill.portal_mode,
      document_no: invoice.invoice_number,
      issued_on: bill.ewb_date,
      valid_until: bill.valid_until,
      to_party: invoice.client_name,
      from_place: invoice.company_state || "—",
      to_place: invoice.client_state || invoice.place_of_supply || "—",
      value: invoice.grand_total,
      distance_km: bill.distance_km,
      vehicle_number: bill.vehicle_number,
      transporter_name: bill.transporter_name,
      mode_of_transport: bill.mode_of_transport,
      status: status(bill),
      cancellable: cancellable?(bill),
      extendable: extendable?(bill),
      custom_fields: bill.custom_fields || %{}
    }
  end

  @doc """
  Subscribes the caller to e-way bill changes.
  """
  def subscribe, do: Events.subscribe(Events.e_way_bills_topic())

  @doc """
  Announces an e-way bill change to every listening page.
  """
  def broadcast_change(e_way_bill, event \\ :e_way_bill_changed) do
    Events.broadcast(Events.e_way_bills_topic(), {event, e_way_bill})
  end
end
