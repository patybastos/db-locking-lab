require "rails_helper"

RSpec.describe Withdrawal::Atomic, concurrency: true do
  it "lets exactly as many withdrawals through as the balance allows" do
    account, results, _elapsed = race_withdrawals(described_class)

    expect(results.count(&:ok?)).to eq(WithdrawalRace::POSSIBLE)
    expect(account.balance_cents).to eq(0)
    expect(account).to be_consistent
  end

  it "doesn't serialize work done outside the statement" do
    _account, _results, elapsed = race_withdrawals(described_class, think_time: 0.05)

    expect(elapsed).to be < WithdrawalRace::POSSIBLE * 0.05
  end

  it "bumps lock_version so optimistic writers notice the change" do
    account = Account.open!(owner: "Ada", balance_cents: 100)
    stale = Account.find(account.id)

    described_class.call(account_id: account.id, amount_cents: 10)

    expect { stale.update!(balance_cents: 0) }.to raise_error(ActiveRecord::StaleObjectError)
  end
end
