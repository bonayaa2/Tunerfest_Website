//+------------------------------------------------------------------+
//| XauTrendPullback.mq5                                             |
//| Trend-pullback Expert Advisor for XAUUSD (MetaTrader 5).         |
//|                                                                  |
//| Buys pullbacks in an uptrend, sells pullbacks in a downtrend.    |
//| Fixed risk per trade, ATR-based stop and target, spread/session  |
//| filters, daily loss limit. Refuses to run on a REAL account      |
//| unless AllowLiveAccount = true.                                  |
//| No strategy wins every time. Test on demo first.                 |
//+------------------------------------------------------------------+
#property copyright "Paper-tested template - use at your own risk"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- safety
input bool   AllowLiveAccount   = false;   // Must be true to trade a REAL account
input long   MagicNumber        = 260111;  // Identifies this EA's trades

//--- risk
input double RiskPercent        = 0.5;     // % of balance risked per trade
input double MaxDailyLossPct    = 2.0;     // Stop for the day after losing this % 
input int    MaxTradesPerDay    = 5;       // 0 = unlimited

//--- strategy
input int    FastEMA            = 50;      // Fast EMA period
input int    SlowEMA            = 200;     // Slow (trend) EMA period
input int    RsiPeriod          = 14;
input double RsiBuyLevel        = 40.0;    // Buy when RSI climbs back above this in an uptrend
input double RsiSellLevel       = 60.0;    // Sell when RSI drops back below this in a downtrend
input int    AtrPeriod          = 14;
input double SlAtrMult          = 1.5;     // Stop-loss = ATR x this
input double TpAtrMult          = 1.5;     // Take-profit = ATR x this
input double BreakEvenAtrMult   = 1.0;     // Move stop to entry after this much profit (0 = off)

//--- filters
input int    MaxSpreadPoints    = 50;      // Skip entries when spread is wider (points)
input int    StartHour          = 8;       // Server-time hour trading starts
input int    EndHour            = 20;      // Server-time hour trading ends
input int    FridayCutoffHour   = 18;      // No new trades on Friday from this hour
input int    SlippagePoints     = 30;

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
int      hRsi  = INVALID_HANDLE, hAtr  = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !AllowLiveAccount)
   {
      Alert("XauTrendPullback: REAL account detected. Set AllowLiveAccount=true only after demo testing.");
      return INIT_FAILED;
   }
   if(StringFind(_Symbol, "XAU") < 0)
      Print("Warning: built for XAUUSD, attached to ", _Symbol);
   if(FastEMA >= SlowEMA || SlAtrMult <= 0 || TpAtrMult <= 0 || RiskPercent <= 0)
   {
      Print("Invalid inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFast = iMA(_Symbol, _Period, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRsi  = iRSI(_Symbol, _Period, RsiPeriod, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, _Period, AtrPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE)
   {
      Print("Failed to create indicators.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFast); IndicatorRelease(hSlow);
   IndicatorRelease(hRsi);  IndicatorRelease(hAtr);
}

//+------------------------------------------------------------------+
bool Buf(int handle, int count, double &out[])
{
   ArraySetAsSeries(out, true);
   return CopyBuffer(handle, 0, 0, count, out) == count;
}

//+------------------------------------------------------------------+
ulong OurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return t;
   }
   return 0;
}

//+------------------------------------------------------------------+
// Closed P&L today (this EA, this symbol) and number of entries today.
void TodayStats(double &pnl, int &entries)
{
   pnl = 0; entries = 0;
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(!HistorySelect(dayStart, TimeCurrent())) return;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      pnl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
           + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) entries++;
   }
}

//+------------------------------------------------------------------+
bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 5 && dt.hour >= FridayCutoffHour) return false;
   return dt.hour >= StartHour && dt.hour < EndHour;
}

//+------------------------------------------------------------------+
// Lot size so that hitting the stop loses RiskPercent of balance.
double LotsForRisk(double slDistance)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(tickSize <= 0 || tickValue <= 0 || step <= 0) return 0;

   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double lossPerLot = slDistance / tickSize * tickValue;
   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   if(lots < minLot) return 0;          // can't trade this small without over-risking
   return MathMin(lots, maxLot);
}

//+------------------------------------------------------------------+
void ManageBreakEven(ulong ticket, double atr)
{
   if(BreakEvenAtrMult <= 0 || !PositionSelectByTicket(ticket)) return;
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   long   type = PositionGetInteger(POSITION_TYPE);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trigger = BreakEvenAtrMult * atr;

   if(type == POSITION_TYPE_BUY && bid - open >= trigger && sl < open)
      trade.PositionModify(ticket, NormalizeDouble(open, _Digits), tp);
   else if(type == POSITION_TYPE_SELL && open - ask >= trigger && (sl > open || sl == 0))
      trade.PositionModify(ticket, NormalizeDouble(open, _Digits), tp);
}

//+------------------------------------------------------------------+
void OnTick()
{
   double atrBuf[];
   if(!Buf(hAtr, 2, atrBuf)) return;
   double atr = atrBuf[1];

   ulong ticket = OurPosition();
   if(ticket > 0) { ManageBreakEven(ticket, atr); return; }   // one trade at a time

   // Entries only once per new bar, on closed-bar signals.
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   double pnl; int entries;
   TodayStats(pnl, entries);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(pnl <= -balance * MaxDailyLossPct / 100.0) return;
   if(MaxTradesPerDay > 0 && entries >= MaxTradesPerDay) return;
   if(!InSession()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

   double fast[], slow[], rsi[];
   if(!Buf(hFast, 3, fast) || !Buf(hSlow, 3, slow) || !Buf(hRsi, 3, rsi)) return;
   double close1 = iClose(_Symbol, _Period, 1);

   bool buySignal  = fast[1] > slow[1] && close1 > slow[1] &&
                     rsi[2] < RsiBuyLevel && rsi[1] >= RsiBuyLevel;
   bool sellSignal = fast[1] < slow[1] && close1 < slow[1] &&
                     rsi[2] > RsiSellLevel && rsi[1] <= RsiSellLevel;
   if(!buySignal && !sellSignal) return;

   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double slDist = MathMax(atr * SlAtrMult, stopsLevel + 2 * _Point);
   double tpDist = MathMax(atr * TpAtrMult, stopsLevel + 2 * _Point);
   double lots = LotsForRisk(slDist);
   if(lots <= 0) { Print("Balance too small for minimum lot at this risk; skipping."); return; }

   if(buySignal)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      trade.Buy(lots, _Symbol, ask,
                NormalizeDouble(ask - slDist, _Digits),
                NormalizeDouble(ask + tpDist, _Digits), "XTP buy");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      trade.Sell(lots, _Symbol, bid,
                 NormalizeDouble(bid + slDist, _Digits),
                 NormalizeDouble(bid - tpDist, _Digits), "XTP sell");
   }
   if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
      Print("Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
