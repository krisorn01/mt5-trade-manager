//+------------------------------------------------------------------+
//| TradeManagerEA.mq5                                               |
//| Copyright (c) 2026 Krisorn Intakorn                              |
//| Licensed under the MIT License (see LICENSE)                     |
//|                                                                  |
//| WHAT IT DOES                                                     |
//| - Trade management is the product: percent-risk lot sizing,      |
//|   breakeven, partial take-profit, ATR trailing stop, daily loss  |
//|   limit and spread filter, applied to every position this EA     |
//|   opens (matched by InpMagic + chart symbol).                    |
//| - The ENTRY RULE IS A DEMO: session-range breakout. The range is |
//|   built from InpRangeStartHour to InpRangeEndHour (server time); |
//|   one trade per day, long or short on the first closed-bar break.|
//|   It exists only so the EA can be back-tested end to end.        |
//|   Replace the entry logic with your own rule.                    |
//|                                                                  |
//| MANAGEMENT ORDER (every tick, for the open position)             |
//|   1. daily loss limit   (close + stop trading for the day)       |
//|   2. breakeven          (SL to open +/- offset once R >= trigger)|
//|   3. partial take-profit(close % of initial volume at R >= x)   |
//|   4. ATR trailing stop  (SL follows bid/ask once R >= start)     |
//| Time exit: all positions closed at/after InpCloseHour (new bar). |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Krisorn Intakorn"
#property version   "1.00"
#property description "Session-range breakout DEMO entry + trade management (percent-risk sizing, breakeven, partial TP, ATR trail, daily loss limit, spread filter)."

#include <Trade\Trade.mqh>

input group "Entry (demo rule: session-range breakout)"
input int    InpRangeStartHour = 7;     // server hour, range start (inclusive)
input int    InpRangeEndHour   = 9;     // server hour, range end (exclusive); trade window follows until InpCloseHour
input int    InpCloseHour      = 20;    // server hour: close all positions at/after this hour, no new trades
input double InpSL_ATR         = 1.5;   // stop distance in ATR multiples
input double InpTP_RR          = 2.0;   // take-profit = RR x stop distance (0 = no TP)
input int    InpATRPeriod      = 14;
input group "Risk"
input double InpRiskPercent    = 1.0;   // % of account balance risked per trade
input double InpMaxSpreadPts   = 300;   // skip entries when spread (points) above this (0 = off)
input double InpDailyLossPct   = 3.0;   // stop trading for the day when realised+floating loss >= this % of day-start balance (0 = off)
input group "Management"
input double InpBE_TriggerRR   = 1.0;   // move SL to breakeven when profit >= this x stop distance (0 = off)
input double InpBE_OffsetPts   = 20;    // breakeven offset in points (locks a little profit)
input double InpPartialRR      = 1.0;   // take partial at this x stop distance (0 = off)
input double InpPartialPct     = 50;    // % of initial volume to close at partial
input double InpTrail_ATR      = 2.0;   // trailing distance in ATR multiples (0 = off)
input double InpTrailStartRR   = 1.0;   // start trailing after profit >= this x stop distance
input group "General"
input long   InpMagic          = 240001;
input string InpComment        = "TM";

CTrade   trade;
int      g_atrHandle       = INVALID_HANDLE;
int      g_dayKey          = 0;
double   g_dayStartBalance = 0.0;
double   g_rangeHigh       = 0.0;
double   g_rangeLow        = DBL_MAX;
bool     g_rangeReady      = false;
bool     g_tradedToday     = false;
bool     g_dailyStopHit    = false;
datetime g_lastBarTime     = 0;
double   g_initStopDist    = 0.0;
double   g_initVolume      = 0.0;
bool     g_partialDone     = false;
bool     g_beDone          = false;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int DayKeyOf(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

int HourOf(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour;
}

void ResetDay(const int key, const double balance)
{
   g_dayKey          = key;
   g_dayStartBalance = balance;
   g_rangeHigh       = 0.0;
   g_rangeLow        = DBL_MAX;
   g_rangeReady      = false;
   g_tradedToday     = false;
   g_dailyStopHit    = false;
}

// Floor a volume to SYMBOL_VOLUME_STEP (no min/max clamp).
double NormalizeVolumeDown(const double vol)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;
   int digits = 0;
   double s = step;
   while(s < 1.0 - 1e-9 && digits < 8)
   {
      s *= 10.0;
      digits++;
   }
   double v = MathFloor(vol / step + 1e-9) * step;
   return NormalizeDouble(v, digits);
}

// Lot size so that hitting the stop loses InpRiskPercent of balance.
double RiskLots(const double stopDist)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || stopDist <= 0.0)
      return 0.0;
   double lossPerLot = stopDist / tickSize * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;
   double lots = NormalizeVolumeDown(riskMoney / lossPerLot);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lots > maxV)
      lots = maxV;
   if(lots < minV)
      lots = minV;
   return lots;
}

// Last closed bar ATR (bar 1).
bool GetATR1(double &atr)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1)
      return false;
   atr = buf[0];
   return (atr > 0.0);
}

// Find the open position with InpMagic on _Symbol (netting or hedging).
bool SelectOwnPosition(ulong &ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      ticket = t;
      return true;
   }
   ticket = 0;
   return false;
}

void CloseOwnPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(!trade.PositionClose(t))
         Print(__FUNCTION__, " ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Entry                                                            |
//+------------------------------------------------------------------+
void TryEntry()
{
   ulong ticket;
   if(SelectOwnPosition(ticket))
      return;

   if(InpMaxSpreadPts > 0.0 && (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPts)
      return;

   double close1 = iClose(_Symbol, _Period, 1);
   bool goLong  = (close1 > g_rangeHigh);
   bool goShort = (close1 < g_rangeLow);
   if(!goLong && !goShort)
      return;

   double atr;
   if(!GetATR1(atr))
   {
      Print(__FUNCTION__, " ATR read failed");
      return;
   }

   double stopDist = InpSL_ATR * atr;
   double minDist  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stopDist < minDist)
      stopDist = minDist;

   double lots = RiskLots(stopDist);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minV)
   {
      Print(__FUNCTION__, " skip entry: lots ", lots, " below min volume ", minV);
      return;
   }

   bool ok = false;
   if(goLong)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - stopDist, _Digits);
      double tp  = (InpTP_RR > 0.0) ? NormalizeDouble(ask + InpTP_RR * stopDist, _Digits) : 0.0;
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment);
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + stopDist, _Digits);
      double tp  = (InpTP_RR > 0.0) ? NormalizeDouble(bid - InpTP_RR * stopDist, _Digits) : 0.0;
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);
   }

   if(ok)
   {
      g_tradedToday  = true;
      g_initStopDist = stopDist;
      g_initVolume   = lots;
      g_partialDone  = false;
      g_beDone       = false;
   }
   else
   {
      Print(__FUNCTION__, " ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| New-bar logic: roll-over, range build, time exit, entry          |
//+------------------------------------------------------------------+
void OnNewBar()
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   int hour0 = HourOf(t0);
   int key0  = DayKeyOf(t0);

   // 1. Day roll-over
   if(key0 != g_dayKey)
      ResetDay(key0, AccountInfoDouble(ACCOUNT_BALANCE));

   // 2. Range build from closed bar 1
   datetime t1 = iTime(_Symbol, _Period, 1);
   if(t1 != 0)
   {
      int hour1 = HourOf(t1);
      if(hour1 >= InpRangeStartHour && hour1 < InpRangeEndHour)
      {
         double h1 = iHigh(_Symbol, _Period, 1);
         double l1 = iLow(_Symbol, _Period, 1);
         if(h1 > g_rangeHigh)
            g_rangeHigh = h1;
         if(l1 < g_rangeLow)
            g_rangeLow = l1;
      }
   }
   if(!g_rangeReady && g_rangeHigh > 0.0 && hour0 >= InpRangeEndHour)
      g_rangeReady = true;

   // 3. Time exit
   if(hour0 >= InpCloseHour)
      CloseOwnPositions();

   // 4. Entry (one trade per day)
   if(g_rangeReady && !g_tradedToday && !g_dailyStopHit && hour0 < InpCloseHour)
      TryEntry();
}

//+------------------------------------------------------------------+
//| Management (every tick): daily loss -> BE -> partial -> trail    |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   ulong ticket;
   if(!SelectOwnPosition(ticket))
      return;

   // 1. Daily loss limit
   if(InpDailyLossPct > 0.0)
   {
      double loss = g_dayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY);
      if(loss >= g_dayStartBalance * InpDailyLossPct / 100.0)
      {
         if(!g_dailyStopHit)
            Print(__FUNCTION__, " daily loss limit hit: loss ", loss, " day-start balance ", g_dayStartBalance);
         g_dailyStopHit = true;
         CloseOwnPositions();
         return;
      }
   }

   if(g_initStopDist <= 0.0)
      return;

   if(!SelectOwnPosition(ticket))
      return;

   bool   isLong = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL  = PositionGetDouble(POSITION_SL);
   double curTP  = PositionGetDouble(POSITION_TP);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitDist = isLong ? (bid - openP) : (openP - ask);
   double R = profitDist / g_initStopDist;

   bool modifiedThisTick = false;

   // 2. Breakeven
   if(InpBE_TriggerRR > 0.0 && !g_beDone && R >= InpBE_TriggerRR)
   {
      double offset = InpBE_OffsetPts * _Point;
      double newSL  = NormalizeDouble(isLong ? (openP + offset) : (openP - offset), _Digits);
      bool improves = (curSL == 0.0) || (isLong ? (newSL > curSL) : (newSL < curSL));
      if(improves)
      {
         if(!trade.PositionModify(ticket, newSL, curTP))
            Print(__FUNCTION__, " ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         modifiedThisTick = true;
      }
      g_beDone = true;
   }

   // 3. Partial take-profit
   if(InpPartialRR > 0.0 && !g_partialDone && R >= InpPartialRR)
   {
      double closeVol = NormalizeVolumeDown(g_initVolume * InpPartialPct / 100.0);
      double curVol   = PositionGetDouble(POSITION_VOLUME);
      double minV     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(closeVol >= minV && (curVol - closeVol) >= minV)
      {
         if(!trade.PositionClosePartial(ticket, closeVol))
            Print(__FUNCTION__, " ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      g_partialDone = true;
   }

   // 4. ATR trailing stop
   if(InpTrail_ATR > 0.0 && !modifiedThisTick && R >= InpTrailStartRR)
   {
      double atr;
      if(GetATR1(atr))
      {
         if(!PositionSelectByTicket(ticket))
            return;
         curSL = PositionGetDouble(POSITION_SL);
         curTP = PositionGetDouble(POSITION_TP);

         double trailDist = InpTrail_ATR * atr;
         double stopsDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         double cand = 0.0;
         bool   valid = false;
         if(isLong)
         {
            cand  = NormalizeDouble(bid - trailDist, _Digits);
            valid = (cand <= bid - stopsDist) && (curSL == 0.0 || cand >= curSL + _Point);
         }
         else
         {
            cand  = NormalizeDouble(ask + trailDist, _Digits);
            valid = (cand >= ask + stopsDist) && (curSL == 0.0 || cand <= curSL - _Point);
         }
         if(valid)
         {
            if(!trade.PositionModify(ticket, cand, curTP))
               Print(__FUNCTION__, " ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!(InpRangeStartHour < InpRangeEndHour && InpRangeEndHour < InpCloseHour))
   {
      Print("Invalid input: need InpRangeStartHour < InpRangeEndHour < InpCloseHour");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
   {
      Print("Invalid input: InpRiskPercent must be in (0,10]");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpPartialPct <= 0.0 || InpPartialPct >= 100.0)
   {
      Print("Invalid input: InpPartialPct must be in (0,100)");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("iATR handle creation failed, error ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetDay(0, AccountInfoDouble(ACCOUNT_BALANCE));
   g_lastBarTime = 0;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialisation                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 != 0 && t0 != g_lastBarTime)
   {
      g_lastBarTime = t0;
      OnNewBar();
   }
   ManageOpenPosition();
}
//+------------------------------------------------------------------+
