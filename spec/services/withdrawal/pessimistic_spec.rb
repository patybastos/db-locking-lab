require "rails_helper"

RSpec.describe Withdrawal::Pessimistic, concurrency: true do
  it "lets exactly as many withdrawals through as the balance allows" do
    account, results, _elapsed = race_withdrawals(described_class)

    expect(results.count(&:ok?)).to eq(WithdrawalRace::POSSIBLE)
    expect(results.count(&:insufficient_funds?)).to eq(WithdrawalRace::THREADS - WithdrawalRace::POSSIBLE)
    expect(account.balance_cents).to eq(0)
    expect(account).to be_consistent
  end

  it "serializes the work done while holding the lock" do
    _account, _results, elapsed = race_withdrawals(described_class, think_time: 0.05)

    # 10 successful withdrawals each held the row for 50ms, one after the other.
    expect(elapsed).to be >= WithdrawalRace::POSSIBLE * 0.05
  end
end
