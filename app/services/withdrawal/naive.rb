module Withdrawal
  # Read, decide in Ruby, write back the computed value. No lock.
  #
  # Two requests that read the same balance both pass the funds check and both
  # write `balance - amount`: the second write overwrites the first (lost update).
  # The transaction doesn't help: under READ COMMITTED it only makes the write
  # and the ledger entry atomic, it doesn't stop anyone else reading the old balance.
  class Naive
    def self.call(account_id:, amount_cents:, think_time: 0)
      account = Account.find(account_id)
      return Result.new(status: :insufficient_funds, attempts: 1) if account.balance_cents < amount_cents

      sleep(think_time)

      Account.transaction do
        # Writes the value computed in Ruby, exactly what `update!` does on a table
        # without lock_version. update_all goes around Active Record locking (so does
        # raw SQL), standing in for code written before lock_version was added.
        Account.where(id: account.id).update_all(balance_cents: account.balance_cents - amount_cents)
        account.ledger_entries.create!(amount_cents: -amount_cents)
      end

      Result.new(status: :ok, attempts: 1)
    end
  end
end
