# XauTrendPullback: MT5 Expert Advisor for XAUUSD

Buys dips in an uptrend and sells rallies in a downtrend. Each trade risks a fixed % of your balance.
The EA refuses to start on a real-money account unless you set `AllowLiveAccount = true`.

## Install
1. In MT5: **File → Open Data Folder → MQL5 → Experts**, and copy `XauTrendPullback.mq5` there.
2. Open it in MetaEditor (F4) and press **Compile** (F7). It should report 0 errors.
3. In MT5, open an **XAUUSD M15** chart and drag the EA from the Navigator onto it.
4. Turn on **Algo Trading** in the toolbar.

## Test before you trust it
1. **Strategy Tester** (Ctrl+R): XAUUSD, M15, "Every tick based on real ticks", at least 2 years of data.
   Look at the profit factor (above 1.3 is decent) and max drawdown, not just the win rate.
2. Run it on a **demo account** for at least 4–8 weeks.
3. Only then consider live trading, with money you can afford to lose.

## Rules
| Rule | Default |
|---|---|
| Trend | EMA 50 above EMA 200 = only buys; below = only sells |
| Entry | RSI(14) dips below 40 and crosses back above it (buy), or rises above 60 and crosses back below it (sell) |
| Stop / target | 1.5 × ATR each (1:1). Stop moves to entry once trade is +1 ATR |
| Risk | 0.5% of balance per trade, stop for the day at −2%, max 5 trades/day |
| Filters | Spread ≤ 50 points, 08:00–20:00 server time, no new trades late Friday |

## Win rate vs. profit
You can push the win rate to 90%+ by setting `TpAtrMult = 0.3` and `SlAtrMult = 3`, but then each loss
erases about 10 wins, which usually means losing money overall. Choose settings by profit factor and drawdown
in the Strategy Tester.
