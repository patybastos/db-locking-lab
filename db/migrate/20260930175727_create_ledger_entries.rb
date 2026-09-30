class CreateLedgerEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :ledger_entries do |t|
      t.references :account, null: false, foreign_key: true
      # Signed: credits are positive, debits negative. An account is consistent
      # when its balance equals the sum of its entries.
      t.integer :amount_cents, null: false

      t.datetime :created_at, null: false
    end
  end
end
