# db-locking-lab

A hands-on Rails + PostgreSQL lab about **concurrent writes to the same row**: what
goes wrong without a lock, and what each fix (pessimistic, optimistic, atomic update,
lock ordering) costs. Every claim here is backed by a spec that runs real threads
against a real database, plus a rake task that races the strategies side by side.

## Why this exists

The bug this lab reproduces never shows up in development and never shows up in a
normal test suite:

```ruby
account = Account.find(id)
if account.balance_cents >= amount
  account.update!(balance_cents: account.balance_cents - amount)
end
```

Each line is correct. The problem is the gap between the `find` and the `update!`.
Two requests that read the same balance both pass the check, and both write
`balance - amount`. The second write silently replaces the first: a **lost update**.
Money is spent twice, stock is sold twice, a like counter drops increments.

Wrapping it in `transaction do ... end` doesn't fix it. Under Postgres' default
isolation level (READ COMMITTED), a transaction makes your writes atomic. It doesn't
stop anyone else from reading the row you're about to change.

## The lab

One `Account` with a balance, and a `LedgerEntry` for every movement (including the
opening deposit). That gives a simple invariant to check after every race:

```ruby
account.balance_cents == account.ledger_entries.sum(:amount_cents)
```

A lost update breaks it: the ledger records every debit, but the balance only reflects
the last write.

The same withdrawal is implemented four ways in [app/services/withdrawal/](app/services/withdrawal/),
all with the same interface. Each takes a `think_time:` pause between reading the
balance and writing it, standing in for real work done in that window (a fraud check,
a call to a payment gateway). This makes the race window wide enough to hit on every run.

```
$ bin/rails locking:withdrawals

20 threads each withdraw 10 from a balance of 100 at the same instant,
pausing 50ms between reading the balance and writing it.
A correct strategy lets 10 through and ends at 0, with the balance matching the ledger.

strategy       ok   no $  conflict  attempts  balance  ledger  consistent  time (ms)
--------------------------------------------------------------------------------------
naive          20      0         0        20       90    -100          NO        117
pessimistic    10     10         0        20        0       0         yes        699
optimistic      3      0        17        57       70      70         yes        230
atomic         10     10         0        20        0       0         yes        105
```

The knobs are env vars: `THREADS`, `BALANCE`, `AMOUNT`, `THINK_MS`, `MAX_ATTEMPTS`.

### 1. Naive: read, decide in Ruby, write back ([naive.rb](app/services/withdrawal/naive.rb))

All 20 threads read `100` before any of them writes, so all 20 pass the funds check.
Each one writes `90`. The ledger shows 20 debits (−100 overall) while the balance
dropped by 10 once. The `CHECK (balance_cents >= 0)` constraint doesn't catch it,
because the balance never goes negative. It's just wrong.

### 2. Pessimistic: `SELECT ... FOR UPDATE` ([pessimistic.rb](app/services/withdrawal/pessimistic.rb))

```ruby
Account.transaction do
  account = Account.lock.find(id) # or account.with_lock { ... }
  # ...
end
```

The second thread blocks on the `SELECT` until the first commits, then reads the
balance the first one wrote. It's correct at any level of contention, and the code
reads like the naive version.

**The cost:** anything you do while holding the lock runs one request at a time for
that row. Ten withdrawals of 50ms each took ~700ms. Put an HTTP call inside a
`with_lock` and the throughput for that row is one request per call's latency.
Requests queue on the row and hold a DB connection while they wait.

### 3. Optimistic: `lock_version` ([optimistic.rb](app/services/withdrawal/optimistic.rb))

Add a `lock_version` column and Active Record turns every `update!` into:

```sql
UPDATE accounts SET balance_cents = 90, lock_version = 1
WHERE id = 1 AND lock_version = 0
```

If someone wrote in between, zero rows match and it raises `ActiveRecord::StaleObjectError`.
Nothing blocks. The only correct response is to **re-read and re-decide**, because the
funds check you made on the stale copy no longer means anything.

**The cost:** under contention most of the work is wasted. All 20 threads read the same
`lock_version` and only one wins per round. With `MAX_ATTEMPTS=3`, 17 of them gave up
with `:conflict` even though there was money left: 57 attempts for 3 withdrawals.
The result is never *wrong*, but it can fail requests that should have gone through.
The spec [optimistic_spec.rb](spec/services/withdrawal/optimistic_spec.rb) shows that
`max_attempts = successful_writes + 1` is always enough, and why.

### 4. Atomic update ([atomic.rb](app/services/withdrawal/atomic.rb))

Often the best answer is to not read at all:

```sql
UPDATE accounts SET balance_cents = balance_cents - 10
WHERE id = 1 AND balance_cents >= 10
```

An `UPDATE` takes the row lock itself. A concurrent `UPDATE` waits, and then Postgres
**re-evaluates the WHERE against the newly committed row**, so the funds check always
sees the latest balance. The database serializes only the statement, not the 50ms of
work around it. It's as fast as the naive version and as correct as the pessimistic one.

It only works when the decision fits in SQL. "Balance is at least X" does. "Ask the
fraud service using the current balance" doesn't.

## Deadlocks: the price of pessimistic locking ([transfer.rb](app/services/transfer.rb))

A transfer locks two rows. Alice → Bob locks Alice then Bob. Bob → Alice, running at the
same moment, locks Bob then Alice. Each ends up holding the row the other is waiting for.

```
$ bin/rails locking:deadlock

== Lock the source account first (ordered: false)
   thread 0: ActiveRecord::Deadlocked (PG::TRDeadlockDetected: ERROR:  deadlock detected)
   thread 1: :ok
   took 1504ms, balances alice=110 bob=90

== Lock the lower id first (ordered: true)
   thread 0: :ok
   thread 1: :ok
   took 843ms, balances alice=110 bob=90
```

Postgres detects the cycle after `deadlock_timeout` (1s), aborts one transaction, and
Rails raises `ActiveRecord::Deadlocked` there. The ledger stays consistent because the
aborted transaction rolled back as a unit. The fix is to **always lock in the same
order** (here, by id). Then the second transfer queues behind the first instead of
crossing it.

## Choosing one

| | Naive | Pessimistic | Optimistic | Atomic update |
|---|---|---|---|---|
| Correct under concurrency | No | Yes | Yes | Yes |
| What contention costs | Wrong data | Waiting (serialized) | Retries, then failures | Waiting on one statement |
| Holds a lock during app work | – | Yes | No | No |
| Deadlock risk | – | Yes, across rows | No | Low (single statement) |
| Decision can be arbitrary Ruby | Yes | Yes | Yes | Only what fits in SQL |
| Needs a retry loop | – | No (maybe for deadlocks) | Yes | No |

My rules of thumb:

- **Counters and balances with a simple rule** (likes, stock, "balance ≥ amount"):
  atomic update first: `update_counters` for plain counters, `update_all` with a guard
  in the WHERE when there's a rule.
- **High contention with a complex decision on a short critical section**:
  pessimistic. Keep slow work (HTTP, email) outside the lock. When locking several
  rows, lock them in a fixed order.
- **Low contention with long "think time"**, especially human think time (two admins
  editing the same record in a form): optimistic. Nobody holds a lock while someone is
  looking at a form. A conflict means "someone changed this, review it", not a retry.
- **Never** read-modify-write a shared value without one of the above.

## Gotchas found while building this

- **Transactional tests hide every one of these bugs.** With
  `use_transactional_tests`, Rails shares one connection across all threads in a test.
  There's no real concurrency, so no race, no row lock, no deadlock, and a broken
  implementation passes. The threaded specs are tagged `concurrency: true`, which turns
  transactional tests off and truncates afterwards ([spec/support/concurrency.rb](spec/support/concurrency.rb)).
- **Optimistic locking only protects code that goes through it.** `update_all` and raw
  SQL ignore `lock_version` and overwrite freely. [atomic.rb](app/services/withdrawal/atomic.rb)
  bumps `lock_version` by hand so optimistic writers elsewhere still notice the change.
- **`update_columns` on a stale record fails silently.** In Rails 8.1 it adds
  `AND lock_version = ?` to the WHERE, but when that matches nothing it returns `false`
  instead of raising, and it doesn't bump the version. Nobody checks that return value.
  See [account_spec.rb](spec/models/account_spec.rb).
- **Adding `lock_version` changes every existing `save`** on that model. Code that used
  to overwrite now raises `StaleObjectError`, so it needs a plan for handling that error.
- **The pool must fit the threads.** Each racing thread holds its own connection, so
  `max_connections` is raised to 25 in dev/test ([config/database.yml](config/database.yml)).
- **Why Postgres and not SQLite:** SQLite has no `SELECT ... FOR UPDATE` and serializes
  every write to the whole database. The races and row-level locks in this lab can't
  happen there, so it would prove nothing.

## Running it

| | Version |
|---|---|
| Ruby | 3.3.5 |
| Rails | 8.1.4 |
| PostgreSQL | 17 |

```sh
bundle install
bin/rails db:prepare

bundle exec rspec               # 23 examples, ~6s (the deadlock specs wait for deadlock_timeout)
bin/rails locking:withdrawals   # the comparison table above
bin/rails locking:deadlock      # opposite transfers, unordered vs ordered
```

The race harness is [lib/race.rb](lib/race.rb). It starts N threads, has each one check
out its own connection, and releases them all at once with a latch, so they hit the
database together instead of one after the other as threads get scheduled.
