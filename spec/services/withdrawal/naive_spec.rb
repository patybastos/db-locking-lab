require "rails_helper"

RSpec.describe Withdrawal::Naive do
  it "works when requests arrive one at a time" do
    account = Account.open!(owner: "Ada", balance_cents: 100)

    11.times { described_class.call(account_id: account.id, amount_cents: 10) }

    expect(account.reload.balance_cents).to eq(0)
    expect(account).to be_consistent
  end

  context "under concurrency", concurrency: true do
    it "loses updates: more withdrawals succeed than the balance allows" do
      account, results, _elapsed = race_withdrawals(described_class)

      # Every thread read 100 before any of them wrote, so all of them passed the check.
      expect(results.count(&:ok?)).to be > WithdrawalRace::POSSIBLE
      # Each wrote "100 - 10": the balance only dropped once, the ledger recorded every debit.
      expect(account.balance_cents).to be > 0
      expect(account.ledger_balance_cents).to be < 0
      expect(account).not_to be_consistent
    end
  end
end
