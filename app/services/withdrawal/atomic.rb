module Withdrawal
  # Let the database do the check and the write in one statement:
  #
  #   UPDATE accounts SET balance_cents = balance_cents - 10, ...
  #   WHERE id = 1 AND balance_cents >= 10
  #
  # An UPDATE takes the row lock itself. A concurrent UPDATE on the same row waits,
  # then Postgres re-evaluates the WHERE against the committed row, so the funds
  # check always sees the latest balance. No read-modify-write, no retry loop.
  # It only works when the decision fits in a WHERE clause.
  class Atomic
    def self.call(account_id:, amount_cents:, think_time: 0)
      sleep(think_time) # nothing to hold across it: there's no read to go stale

      withdrawn = Account.transaction do
        rows = Account.where(id: account_id, balance_cents: amount_cents..)
          .update_all([ "balance_cents = balance_cents - ?, lock_version = lock_version + 1, updated_at = ?", amount_cents, Time.current ])
        # Bumping lock_version by hand keeps optimistic writers elsewhere honest:
        # update_all skips Active Record's locking, so without it they'd never notice.

        LedgerEntry.create!(account_id: account_id, amount_cents: -amount_cents) if rows == 1
        rows == 1
      end

      Result.new(status: withdrawn ? :ok : :insufficient_funds, attempts: 1)
    end
  end
end
