class Account < ApplicationRecord
  # accounts.lock_version exists, so every `save`/`update!` on an Account is
  # already optimistic: UPDATE ... WHERE id = ? AND lock_version = ?
  has_many :ledger_entries, dependent: :delete_all

  validates :owner, presence: true
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Opening deposit goes through the ledger too, so the invariant
  # `balance_cents == ledger_entries.sum(:amount_cents)` holds from the start.
  def self.open!(owner:, balance_cents:)
    transaction do
      create!(owner: owner, balance_cents: balance_cents).tap do |account|
        account.ledger_entries.create!(amount_cents: balance_cents)
      end
    end
  end

  def ledger_balance_cents
    ledger_entries.sum(:amount_cents)
  end

  def consistent?
    reload.balance_cents == ledger_balance_cents
  end
end
