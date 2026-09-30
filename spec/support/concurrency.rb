# Specs tagged `concurrency: true` run threads against the real database.
#
# They can't use transactional tests: in that mode Rails wraps each example in
# a transaction on one connection and shares that connection with every thread
# (so they'd all see each other's uncommitted writes and queue on the same
# socket). No real concurrency, so no races, no row locks, no deadlocks, and
# the spec passes for the wrong reason. These examples commit for real and
# truncate afterwards instead.
RSpec.shared_context "real concurrency" do
  self.use_transactional_tests = false

  after do
    ActiveRecord::Base.connection.truncate_tables(*%w[ledger_entries accounts])
  end
end

RSpec.configure do |config|
  config.include_context "real concurrency", concurrency: true
end
