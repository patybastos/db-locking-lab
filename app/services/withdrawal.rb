# Four ways to take money out of an account. They share the same contract so the
# specs and `bin/rails locking:withdrawals` can race them against each other:
#
#   Withdrawal::Naive.call(account_id:, amount_cents:, think_time: 0) # => Withdrawal::Result
#
# `think_time` is a pause between reading the balance and writing the new one,
# standing in for real work done in that window (a fraud check, an HTTP call).
# It makes race windows wide enough to hit on every run.
module Withdrawal
  Result = Data.define(:status, :attempts) do
    def ok? = status == :ok
    def insufficient_funds? = status == :insufficient_funds
    def conflict? = status == :conflict
  end

  STRATEGIES = {
    naive: "Withdrawal::Naive",
    pessimistic: "Withdrawal::Pessimistic",
    optimistic: "Withdrawal::Optimistic",
    atomic: "Withdrawal::Atomic"
  }.freeze

  def self.strategy(name)
    STRATEGIES.fetch(name).constantize
  end
end
