#!/usr/bin/env python3
"""
Paper-trading scalper. Standard library only (Python 3.9+).

Goal: close each trade with at least `--target` dollars of profit AFTER fees and spread.
It does this by only selling once the bid is high enough to cover both fees + target.
Trades that don't get there are closed by a stop-loss or a max-hold timer, which is
where losses come from. Nothing here guarantees a profit.

PAPER MODE ONLY. No real orders are ever sent.

Feeds:
  --feed coinbase   live best bid/ask from Coinbase's public API (no account needed)
  --feed sim        offline random-walk market for testing
"""
import argparse, csv, json, math, os, random, sys, time, urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone


# ---------------------------------------------------------------- price feeds
class CoinbaseFeed:
    def __init__(self, product):
        self.url = f"https://api.exchange.coinbase.com/products/{product}/ticker"

    def quote(self):
        req = urllib.request.Request(self.url, headers={"User-Agent": "paper-scalper"})
        with urllib.request.urlopen(req, timeout=5) as r:
            d = json.load(r)
        return float(d["bid"]), float(d["ask"])


class SimFeed:
    """Random walk with a fixed spread. Has no edge built in, on purpose."""
    def __init__(self, start=100_000.0, vol=0.0004, spread_bps=1.0, seed=None):
        self.mid, self.vol, self.spread = start, vol, spread_bps / 10_000
        self.rng = random.Random(seed)

    def quote(self):
        self.mid *= math.exp(self.rng.gauss(0, self.vol))
        half = self.mid * self.spread / 2
        return self.mid - half, self.mid + half


# ---------------------------------------------------------------- paper broker
@dataclass
class Position:
    qty: float
    entry_price: float
    cost: float          # dollars spent incl. buy fee
    opened: float
    take_profit: float   # bid needed to net the target
    stop: float


class PaperBroker:
    def __init__(self, cash, fee):
        self.cash, self.fee = cash, fee

    def buy(self, usd, ask):
        fee = usd * self.fee
        qty = (usd - fee) / ask
        self.cash -= usd
        return qty, usd

    def sell(self, qty, bid):
        gross = qty * bid
        net = gross - gross * self.fee
        self.cash += net
        return net


# ---------------------------------------------------------------- the bot
class Scalper:
    def __init__(self, a, feed, log_path):
        self.a, self.feed = a, feed
        self.broker = PaperBroker(a.cash, a.fee)
        self.pos = None
        self.ema = None
        self.alpha = 2 / (a.ema + 1)
        self.trades = self.wins = 0
        self.pnl = 0.0
        self.log_path = log_path
        new = not os.path.exists(log_path)
        self.log = open(log_path, "a", newline="")
        self.w = csv.writer(self.log)
        if new:
            self.w.writerow(["time", "side", "price", "qty", "usd", "pnl", "reason"])

    def record(self, side, price, qty, usd, pnl="", reason=""):
        t = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.w.writerow([t, side, f"{price:.2f}", f"{qty:.8f}", f"{usd:.4f}",
                         pnl if pnl == "" else f"{pnl:.4f}", reason])
        self.log.flush()

    def should_stop(self):
        if os.path.exists(self.a.kill_file):
            return "kill file found"
        if self.pnl <= -abs(self.a.max_loss):
            return f"max loss hit ({self.pnl:.2f})"
        if self.a.max_trades and self.trades >= self.a.max_trades:
            return "max trades reached"
        return None

    def step(self, bid, ask, now):
        a = self.a
        mid = (bid + ask) / 2
        prev = self.ema
        self.ema = mid if prev is None else self.alpha * mid + (1 - self.alpha) * prev
        if prev is None:
            return

        if self.pos is None:
            # Entry: price pushing up through the EMA by a threshold (simple momentum).
            if mid > self.ema * (1 + a.entry_bps / 10_000) and self.broker.cash >= a.size:
                qty, cost = self.broker.buy(a.size, ask)
                # Bid at which selling everything nets `target` after the sell fee.
                tp = (cost + a.target) / (qty * (1 - a.fee))
                stop = ask * (1 - a.stop_pct / 100)
                self.pos = Position(qty, ask, cost, now, tp, stop)
                self.record("BUY", ask, qty, cost, reason=f"tp={tp:.2f} stop={stop:.2f}")
            return

        p = self.pos
        reason = None
        if bid >= p.take_profit:
            reason = "take-profit"
        elif bid <= p.stop:
            reason = "stop-loss"
        elif now - p.opened >= a.max_hold:
            reason = "max-hold"
        if reason:
            proceeds = self.broker.sell(p.qty, bid)
            pnl = proceeds - p.cost
            self.pnl += pnl
            self.trades += 1
            self.wins += pnl > 0
            self.record("SELL", bid, p.qty, proceeds, pnl, reason)
            print(f"  trade {self.trades:>4}: {reason:<11} pnl {pnl:+.4f}  total {self.pnl:+.4f}")
            self.pos = None

    def summary(self):
        wr = 100 * self.wins / self.trades if self.trades else 0
        print("\n=== summary (paper) ===")
        print(f"trades: {self.trades}   wins: {self.wins} ({wr:.0f}%)")
        print(f"net P&L after fees: {self.pnl:+.4f} USD")
        print(f"open position: {'yes' if self.pos else 'no'}")
        print(f"trade log: {self.log_path}")


def main():
    ap = argparse.ArgumentParser(description="Paper-trading scalper (no real orders).")
    ap.add_argument("--feed", choices=["coinbase", "sim"], default="sim")
    ap.add_argument("--product", default="BTC-USD")
    ap.add_argument("--cash", type=float, default=1000, help="paper starting cash")
    ap.add_argument("--size", type=float, default=100, help="USD per trade")
    ap.add_argument("--target", type=float, default=0.01, help="min net profit per winning trade, USD")
    ap.add_argument("--fee", type=float, default=0.001, help="fee per side, e.g. 0.001 = 0.1%%")
    ap.add_argument("--ema", type=int, default=20, help="EMA length in ticks")
    ap.add_argument("--entry-bps", type=float, default=2, help="entry threshold above EMA, basis points")
    ap.add_argument("--stop-pct", type=float, default=0.3, help="stop-loss, percent below entry")
    ap.add_argument("--max-hold", type=float, default=300, help="close after N seconds/ticks")
    ap.add_argument("--max-loss", type=float, default=5, help="stop the bot after losing this many USD")
    ap.add_argument("--max-trades", type=int, default=0, help="0 = unlimited")
    ap.add_argument("--interval", type=float, default=1.0, help="seconds between quotes (live feed)")
    ap.add_argument("--ticks", type=int, default=0, help="sim: number of ticks to run (0 = forever)")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--kill-file", default="STOP", help="create this file to stop the bot")
    ap.add_argument("--log", default="trades.csv")
    a = ap.parse_args()

    feed = CoinbaseFeed(a.product) if a.feed == "coinbase" else SimFeed(seed=a.seed)
    bot = Scalper(a, feed, a.log)
    print(f"PAPER MODE | feed={a.feed} size=${a.size} target=${a.target} fee={a.fee*100:.2f}%/side")

    tick = 0
    try:
        while True:
            why = bot.should_stop()
            if why:
                print(f"stopping: {why}")
                break
            try:
                bid, ask = feed.quote()
            except Exception as e:
                print(f"feed error: {e}; retrying")
                time.sleep(max(a.interval, 2))
                continue
            now = tick if a.feed == "sim" else time.time()
            bot.step(bid, ask, now)
            tick += 1
            if a.feed == "sim":
                if a.ticks and tick >= a.ticks:
                    break
            else:
                time.sleep(a.interval)
    except KeyboardInterrupt:
        print("\ninterrupted")
    if bot.pos:  # close out at last bid so the summary is honest
        bid, _ = feed.quote()
        bot.step(bid, bid, float("inf"))
    bot.summary()


if __name__ == "__main__":
    main()
