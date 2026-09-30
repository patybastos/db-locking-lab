require "rails_helper"

RSpec.describe Transfer do
  let!(:alice) { Account.open!(owner: "Alice", balance_cents: 100) }
  let!(:bob) { Account.open!(owner: "Bob", balance_cents: 100) }

  it "moves money and records both sides in the ledger" do
    expect(described_class.call(from_id: alice.id, to_id: bob.id, amount_cents: 30)).to eq(:ok)

    expect(alice.reload.balance_cents).to eq(70)
    expect(bob.reload.balance_cents).to eq(130)
    expect([ alice, bob ]).to all(be_consistent)
  end

  it "refuses to overdraw" do
    expect(described_class.call(from_id: alice.id, to_id: bob.id, amount_cents: 101)).to eq(:insufficient_funds)

    expect(alice.reload.balance_cents).to eq(100)
  end

  context "two opposite transfers at the same time", concurrency: true do
    def race_opposite_transfers(ordered:)
      Race.run(threads: 2) do |i|
        from, to = i.zero? ? [ alice, bob ] : [ bob, alice ]
        described_class.call(from_id: from.id, to_id: to.id, amount_cents: 10, ordered: ordered, think_time: 0.2)
      end.values
    end

    it "deadlocks when each locks its source account first" do
      results = race_opposite_transfers(ordered: false)

      # Postgres aborted one transaction to break the cycle; the other went through.
      expect(results).to contain_exactly(:ok, an_instance_of(ActiveRecord::Deadlocked))
      expect(alice.reload.balance_cents + bob.reload.balance_cents).to eq(200)
      expect([ alice, bob ]).to all(be_consistent)
    end

    it "both succeed when every transfer locks the lower id first" do
      results = race_opposite_transfers(ordered: true)

      expect(results).to eq([ :ok, :ok ])
      expect(alice.reload.balance_cents).to eq(100)
      expect(bob.reload.balance_cents).to eq(100)
    end
  end
end
