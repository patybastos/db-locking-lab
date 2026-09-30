class LedgerEntry < ApplicationRecord
  belongs_to :account

  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
end
