namespace :locking do
  desc "Race concurrent withdrawals against one account with each locking strategy"
  task withdrawals: :environment do
    threads = Integer(ENV.fetch("THREADS", 20))
    balance = Integer(ENV.fetch("BALANCE", 100))
    amount = Integer(ENV.fetch("AMOUNT", 10))
    think_time = Float(ENV.fetch("THINK_MS", 50)) / 1000
    max_attempts = Integer(ENV.fetch("MAX_ATTEMPTS", 3))
    possible = balance / amount

    Rails.application.eager_load! # don't autoload constants from inside the threads

    puts "#{threads} threads each withdraw #{amount} from a balance of #{balance} at the same instant,"
    puts "pausing #{(think_time * 1000).round}ms between reading the balance and writing it."
    puts "A correct strategy lets #{possible} through and ends at 0, with the balance matching the ledger."
    puts
    printf("%-12s %4s %6s %9s %9s %8s %7s %11s %10s\n",
      "strategy", "ok", "no $", "conflict", "attempts", "balance", "ledger", "consistent", "time (ms)")
    puts "-" * 86

    Withdrawal::STRATEGIES.each_key do |name|
      strategy = Withdrawal.strategy(name)
      options = name == :optimistic ? { max_attempts: max_attempts } : {}
      account = Account.open!(owner: "lab-#{name}", balance_cents: balance)

      outcome = Race.run(threads: threads) do
        strategy.call(account_id: account.id, amount_cents: amount, think_time: think_time, **options)
      end
      errors, results = outcome.values.partition { |value| value.is_a?(Exception) }
      errors.each { |error| warn "  #{name}: #{error.class}: #{error.message}" }

      account.reload
      printf("%-12s %4d %6d %9d %9d %8d %7d %11s %10.0f\n",
        name,
        results.count(&:ok?),
        results.count(&:insufficient_funds?),
        results.count(&:conflict?),
        results.sum(&:attempts),
        account.balance_cents,
        account.ledger_balance_cents,
        account.consistent? ? "yes" : "NO",
        outcome.elapsed * 1000)
    ensure
      account&.destroy
    end

    puts
    puts "naive:       every thread read #{balance} before anyone wrote. All passed the funds check, and each"
    puts "             wrote #{balance} - #{amount}: the ledger shows every debit, the balance only one."
    puts "pessimistic: correct, but the #{(think_time * 1000).round}ms of work runs once per withdrawal, one after the other."
    puts "optimistic:  never wrong, but threads that keep losing give up with :conflict (MAX_ATTEMPTS=#{max_attempts})."
    puts "atomic:      the check lives in the UPDATE's WHERE, so the database serializes only the statement."
  end

  desc "Run two opposite transfers at once, locking rows in argument order vs. by id"
  task deadlock: :environment do
    Rails.application.eager_load!

    alice = Account.open!(owner: "lab-alice", balance_cents: 100)
    bob = Account.open!(owner: "lab-bob", balance_cents: 100)

    [ false, true ].each do |ordered|
      puts ordered ? "== Lock the lower id first (ordered: true)" : "== Lock the source account first (ordered: false)"
      puts "   thread 0: alice -> bob    thread 1: bob -> alice    (each holds its first lock 200ms)"

      outcome = Race.run(threads: 2) do |i|
        from, to = i.zero? ? [ alice, bob ] : [ bob, alice ]
        Transfer.call(from_id: from.id, to_id: to.id, amount_cents: 10, ordered: ordered, think_time: 0.2)
      end

      outcome.values.each_with_index do |value, i|
        puts "   thread #{i}: #{value.is_a?(Exception) ? "#{value.class} (#{value.message.lines.first.strip})" : value.inspect}"
      end
      printf("   took %.0fms, balances alice=%d bob=%d\n\n", outcome.elapsed * 1000, alice.reload.balance_cents, bob.reload.balance_cents)
    end

    puts "Unordered, each transaction waits on the row the other holds. Postgres notices after"
    puts "deadlock_timeout (1s), aborts one and the other commits. Ordered, the second transfer"
    puts "just queues behind the first on alice's row: no cycle, nothing aborted."
  ensure
    [ alice, bob ].compact.each(&:destroy)
  end
end
