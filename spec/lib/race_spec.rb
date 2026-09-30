require "rails_helper"

RSpec.describe Race, concurrency: true do
  it "runs every thread on its own database connection" do
    outcome = Race.run(threads: 5) { ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()") }

    expect(outcome.values.uniq.size).to eq(5)
  end

  it "releases the threads together" do
    outcome = Race.run(threads: 5) { sleep 0.2 }

    expect(outcome.elapsed).to be < 0.5 # one after the other would take 1s
  end

  it "returns exceptions instead of raising them" do
    outcome = Race.run(threads: 2) { |i| i.zero? ? :ok : raise("boom") }

    expect(outcome.values.first).to eq(:ok)
    expect(outcome.values.last).to be_a(RuntimeError)
  end
end
