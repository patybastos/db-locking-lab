require "rails_helper"

RSpec.describe Withdrawal::Optimistic, concurrency: true do
  it "never loses an update, even when it gives up" do
    account, results, _elapsed = race_withdrawals(described_class, max_attempts: 3)

    expect(results.count(&:ok?)).to be <= WithdrawalRace::POSSIBLE
    expect(account.balance_cents).to eq(WithdrawalRace::BALANCE - results.count(&:ok?) * WithdrawalRace::AMOUNT)
    expect(account).to be_consistent
  end

  it "wastes attempts under contention and turns some away with :conflict" do
    _account, results, _elapsed = race_withdrawals(described_class, max_attempts: 3)

    # All 20 read the same lock_version; each round only one of them can win.
    expect(results.count(&:conflict?)).to be > 0
    expect(results.map(&:attempts).max).to eq(3)
  end

  it "reaches the right answer when allowed enough retries" do
    # Every round at least one writer commits, and only 10 commits are possible,
    # so a thread can lose at most 10 times before it wins or sees no funds.
    account, results, _elapsed = race_withdrawals(described_class, max_attempts: WithdrawalRace::POSSIBLE + 1)

    expect(results.count(&:ok?)).to eq(WithdrawalRace::POSSIBLE)
    expect(results.count(&:conflict?)).to eq(0)
    expect(account.balance_cents).to eq(0)
    expect(account).to be_consistent
  end
end
