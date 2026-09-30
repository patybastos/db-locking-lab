class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :owner, null: false
      t.integer :balance_cents, null: false, default: 0
      # The presence of this column is what turns on optimistic locking in Active Record.
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_check_constraint :accounts, "balance_cents >= 0", name: "accounts_balance_non_negative"
  end
end
