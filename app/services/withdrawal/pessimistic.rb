module Withdrawal
  # SELECT ... FOR UPDATE: lock the row before reading it.
  #
  # A second request blocks on the SELECT until the first commits, then reads the
  # balance the first one wrote. Correct under any contention, but everything
  # done while holding the lock (the think_time here) is serialized per account.
  class Pessimistic
    def self.call(account_id:, amount_cents:, think_time: 0)
      status = Account.transaction do
        account = Account.lock.find(account_id) # same as Account.find(id).lock!, minus one query

        if account.balance_cents < amount_cents
          :insufficient_funds
        else
          sleep(think_time)
          account.update!(balance_cents: account.balance_cents - amount_cents)
          account.ledger_entries.create!(amount_cents: -amount_cents)
          :ok
        end
      end

      Result.new(status: status, attempts: 1)
    end
  end
end
