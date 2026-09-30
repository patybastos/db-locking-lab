# 20 withdrawals of 10 against a balance of 100 fired at the same instant.
# A correct strategy lets exactly 10 through and ends at 0, with the balance
# matching the ledger.
module WithdrawalRace
  BALANCE = 100
  AMOUNT = 10
  THREADS = 20
  POSSIBLE = BALANCE / AMOUNT

  def race_withdrawals(strategy, think_time: 0.05, **options)
    account = Account.open!(owner: "Ada", balance_cents: BALANCE)

    outcome = Race.run(threads: THREADS) do
      strategy.call(account_id: account.id, amount_cents: AMOUNT, think_time: think_time, **options)
    end
    raise outcome.values.find { |v| v.is_a?(Exception) } if outcome.values.any?(Exception)

    [ account.reload, outcome.values, outcome.elapsed ]
  end
end

RSpec.configure do |config|
  config.include WithdrawalRace, concurrency: true
end
