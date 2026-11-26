defmodule QuantumBilling.Repo.TenantMigrations.AllowEWayBillReissuanceOnExpiry do
  use Ecto.Migration

  @moduledoc """
  Updates `e_way_bills_one_live_bill_per_invoice_index` so that an invoice with an expired
  or cancelled e-way bill can have a new e-way bill issued.

  The index now enforces uniqueness only for live bills with `status = 'Active' AND deleted_at IS NULL`.
  """

  def up do
    drop_if_exists unique_index(:e_way_bills, [:invoice_id],
                     name: :e_way_bills_one_live_bill_per_invoice_index
                   )

    create unique_index(:e_way_bills, [:invoice_id],
             name: :e_way_bills_one_live_bill_per_invoice_index,
             where: "status = 'Active' AND deleted_at IS NULL"
           )
  end

  def down do
    drop_if_exists unique_index(:e_way_bills, [:invoice_id],
                     name: :e_way_bills_one_live_bill_per_invoice_index
                   )

    create unique_index(:e_way_bills, [:invoice_id],
             name: :e_way_bills_one_live_bill_per_invoice_index,
             where: "status <> 'Cancelled' AND deleted_at IS NULL"
           )
  end
end
