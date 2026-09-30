# Moves money between two accounts, locking both rows with SELECT ... FOR UPDATE.
#
# With `ordered: false` rows are locked in argument order. A transfer A -> B and
# a transfer B -> A running at the same time each lock their first row and then
# wait forever for the other's: a deadlock. Postgres detects it (after
# deadlock_timeout, 1s by default), aborts one of the transactions, and Rails
# raises ActiveRecord::Deadlocked in that thread.
#
# With `ordered: true` (the default) every transfer locks the lower id first, so
# the two transfers queue on the same row instead of crossing.
class Transfer
  def self.call(from_id:, to_id:, amount_cents:, ordered: true, think_time: 0)
    raise ArgumentError, "can't transfer to the same account" if from_id == to_id

    lock_order = ordered ? [ from_id, to_id ].sort : [ from_id, to_id ]

    Account.transaction do
      locked = lock_order.index_with do |id|
        Account.lock.find(id).tap { sleep(think_time) } # hold the first lock while the other side takes its own
      end
      from, to = locked.values_at(from_id, to_id)

      next :insufficient_funds if from.balance_cents < amount_cents

      from.update!(balance_cents: from.balance_cents - amount_cents)
      to.update!(balance_cents: to.balance_cents + amount_cents)
      LedgerEntry.insert_all!([
        { account_id: from.id, amount_cents: -amount_cents, created_at: Time.current },
        { account_id: to.id, amount_cents: amount_cents, created_at: Time.current }
      ])
      :ok
    end
  end
end
