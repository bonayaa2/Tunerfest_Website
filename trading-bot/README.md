# Paper scalper

A paper-trading bot that tries to close every trade with at least $0.01 profit (or any `--target`) after fees.
It never sends real orders.

## Run (needs Python 3.9+, nothing to install)

```bash
python3 bot.py --feed coinbase --product BTC-USD     # live prices, fake money
python3 bot.py --feed sim --ticks 20000 --seed 1     # offline simulation
```

Stop it with Ctrl+C or by creating a file named `STOP` in this folder. Every buy and sell is logged to `trades.csv`.

## How it trades
- **Buy:** when the price pushes `--entry-bps` above a short moving average.
- **Take profit:** sells as soon as the bid covers both fees plus `--target`.
- **Stop-loss:** sells if the price falls `--stop-pct` percent.
- **Max hold:** sells after `--max-hold` seconds.
- **Daily loss limit:** stops the bot once total losses reach `--max-loss` USD.

## Fees decide everything
Set `--fee` to your exchange's real taker fee. A $100 trade at 0.1% per side costs $0.20 in fees,
so the price has to rise about 0.21% just to net one cent. Small stop-losses cost more than the
wins earn, so a high win rate can still lose money overall.
