require "rails_helper"

RSpec.describe Account do
  describe ".open!" do
    it "records the opening deposit in the ledger" do
      account = Account.open!(owner: "Ada", balance_cents: 100)

      expect(account.ledger_entries.pluck(:amount_cents)).to eq([ 100 ])
      expect(account).to be_consistent
    end
  end

  describe "#consistent?" do
    it "is false when the balance drifts from the ledger" do
      account = Account.open!(owner: "Ada", balance_cents: 100)
      account.update!(balance_cents: 90) # money moved without a ledger entry

      expect(account).not_to be_consistent
    end
  end

  describe "optimistic locking (lock_version)" do
    it "rejects a write made from a stale copy" do
      account = Account.open!(owner: "Ada", balance_cents: 100)
      first = Account.find(account.id)
      second = Account.find(account.id)

      first.update!(balance_cents: 90)

      expect { second.update!(balance_cents: 80) }.to raise_error(ActiveRecord::StaleObjectError)
      expect(account.reload.balance_cents).to eq(90)
    end

    it "is ignored by update_all and raw SQL" do
      account = Account.open!(owner: "Ada", balance_cents: 100)
      stale = Account.find(account.id)

      account.update!(balance_cents: 90)
      Account.where(id: stale.id).update_all(balance_cents: stale.balance_cents - 20) # overwrites the 90

      expect(account.reload.balance_cents).to eq(80)
    end

    it "makes update_columns from a stale copy a silent no-op" do
      account = Account.open!(owner: "Ada", balance_cents: 100)
      stale = Account.find(account.id)

      account.update!(balance_cents: 90)

      # UPDATE ... WHERE id = ? AND lock_version = 0 matches nothing, and instead of
      # raising StaleObjectError it just returns false. Easy to miss.
      expect(stale.update_columns(balance_cents: 80)).to be(false)
      expect(account.reload.balance_cents).to eq(90)
    end
  end

  it "refuses a negative balance at the database level" do
    account = Account.open!(owner: "Ada", balance_cents: 100)

    expect { account.update_columns(balance_cents: -1) }.to raise_error(ActiveRecord::StatementInvalid, /accounts_balance_non_negative/)
  end
end
