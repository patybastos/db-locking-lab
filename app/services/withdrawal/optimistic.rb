module Withdrawal
  # Read without locking, write with UPDATE ... WHERE lock_version = <what I read>.
  #
  # If someone else wrote in between, zero rows match and Active Record raises
  # StaleObjectError. The only correct reaction is to re-read and re-decide: the
  # funds check made on the stale copy means nothing. No one waits on a lock,
  # but under contention most attempts are wasted, and after `max_attempts` the
  # request gives up with :conflict even if there was money to withdraw.
  class Optimistic
    def self.call(account_id:, amount_cents:, think_time: 0, max_attempts: 3)
      1.upto(max_attempts) do |attempt|
        account = Account.find(account_id)
        return Result.new(status: :insufficient_funds, attempts: attempt) if account.balance_cents < amount_cents

        sleep(think_time)

        Account.transaction do
          account.update!(balance_cents: account.balance_cents - amount_cents)
          account.ledger_entries.create!(amount_cents: -amount_cents)
        end

        return Result.new(status: :ok, attempts: attempt)
      rescue ActiveRecord::StaleObjectError
        next
      end

      Result.new(status: :conflict, attempts: max_attempts)
    end
  end
end
