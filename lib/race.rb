# Runs a block in N threads and releases them at the same instant, so they hit
# the database together instead of one after the other as threads get scheduled.
#
#   Race.run(threads: 10) { |i| Withdrawal::Naive.call(...) }
#   # => [result_or_exception, ...] in thread order
#
# Each thread uses its own database connection, so the pool needs at least
# `threads` connections (see config/database.yml).
module Race
  Outcome = Data.define(:values, :elapsed)

  def self.run(threads:)
    ready = Concurrent::CountDownLatch.new(threads)
    start = Concurrent::CountDownLatch.new(1)

    workers = Array.new(threads) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.verify! # connect now, not on the first query after the start signal
          ready.count_down
          start.wait
          yield i
        rescue => error
          error
        end
      end
    end

    ready.wait
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    start.count_down
    values = workers.map(&:value)

    Outcome.new(values: values, elapsed: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
  end
end
