//+------------------------------------------------------------------+
//|                 Dual-Donchian Channel Breakout strategy.mq5      |
//|                 Copyright 2026, Karma Rathore                    |
//|                 Version 17.0 (LIVE)                              |
//+------------------------------------------------------------------+
#property copyright "Karma Rathore"
#property link      "https://www.mql5.com"
#property version   "17.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input group "=== Strategy Settings ==="
input string     InpSetName        = "Set2-NQ";  
input ENUM_TIMEFRAMES InpTimeFrame    = PERIOD_CURRENT;
input int        InpEntryPeriod    = 130;
input int        InpExitPeriod     = 90;
input double     InpATRStopMult    = 3.0;        
input int        InpATRPeriod      = 20;

input group "=== D1 Volatility Entry Filter ==="
input bool       InpUseD1VolFilter  = true;
input int        InpD1VolPeriod     = 90;        
input double     InpD1VolMinRatio   = 0.7;       
input double     InpD1VolMaxRatio   = 1.5;       

input group "=== Regime Filter (Hurst) ==="
input bool       InpUseHurstFilter = true;
input int        InpHurstPeriod    = 100;
input double     InpHurstThreshold = 0.55;

input group "=== Time Filter (Server Time) ==="
input bool       InpUseTimeFilter  = true;
input int        InpStartHour      = 7;
input int        InpEndHour        = 9;

input group "=== Risk Management ==="
input int        InpMaxTradesPerDay = 1;
input double     InpRiskMoney       = 25.0; // Pegged to base risk
input int        InpMagicNum        = 30001;

input group "=== Global Mutex Lock (Cross-Asset Cap) ==="
input bool       InpUseGlobalMutex  = true;
input int        InpMaxGlobalTrades = 3;
input ulong      InpMagicRangeStart = 30000;
input ulong      InpMagicRangeEnd   = 30100;

input group "=== Swap & Weekend Protection ==="
input bool       UseSwapFilter       = true;
input bool       BlockSaturdayEntries= true;
input bool       BlockSundayEntries  = true;
input bool       AutoDetectTriple    = true;
input ENUM_DAY_OF_WEEK ManualSwapDay = WEDNESDAY;
input bool       BlockFridayEntries  = true;
input bool       ForceCloseFriday    = true;
input int        FridayCloseHour     = 20;
input int        SwapCloseHour       = 21;

input group "=== Trade Management (BE & Targets) ==="
input bool       InpUseFixedRR       = false;
input double     InpFixedRR_Target   = 2.0;
input bool       UseBreakEven        = true;
input double     BE_Trigger_R        = 1.0;
input double     BE_Offset_Pips      = 2.0;

input group "=== Trade Management (Trailing Stop) ==="
input bool       InpUseTrailingStop  = true;
input double     InpTrail_Activation = 1.0;
input double     InpTrail_Distance_R = 1.0;
input double     InpTrail_Step_R     = 0.2;

input group "=== Visuals & Telemetry ==="
input bool       InpShowVisuals      = true;
input bool       InpShowDashboard    = true;

//--- Global Objects & Caches
CTrade           trade;

int              handleATR, handleD1VolATR;
double           g_lastD1VolRatio;   
datetime         lastBarTime;
ENUM_TIMEFRAMES  WorkTF;
double           g_pipUnit;
ENUM_DAY_OF_WEEK g_tripleSwapDay;

int              g_currentDayOfYear  = -1;

// Raw Points for HUD
double           g_rawM5AtrPts       = 0;

struct TradeCache {
   ulong    posID;
   double   initialRisk;
   datetime lastModifyAttempt;
};
TradeCache g_tradeCache[];

double g_UpperEntry = 0, g_LowerEntry = 0;
double g_UpperExit  = 0, g_LowerExit  = 0;
double g_prevClose  = 0, g_currentATR = 0;
double g_cachedHurst = 0.5;

//+------------------------------------------------------------------+
int OnInit()
{
   g_UpperEntry = 0; 
   g_LowerEntry = 0;
   g_UpperExit  = 0; 
   g_LowerExit  = 0;
   g_prevClose  = 0; 
   g_currentATR = 0;
   g_cachedHurst = 0.5;
   g_currentDayOfYear = -1;
   g_rawM5AtrPts = 0;
   lastBarTime = 0;
   ArrayFree(g_tradeCache);

   WorkTF = (InpTimeFrame == PERIOD_CURRENT) ? _Period : InpTimeFrame;
   
   handleATR = iATR(_Symbol, WorkTF, InpATRPeriod);
   handleD1VolATR = iATR(_Symbol, PERIOD_D1, InpD1VolPeriod);
   
   if(handleATR == INVALID_HANDLE || handleD1VolATR == INVALID_HANDLE) return(INIT_FAILED);

   // Pre-Loader: Defends against iBarShift fragmentation
   datetime temp[1];
   CopyTime(_Symbol, PERIOD_D1, 0, 200, temp); 
   CopyTime(_Symbol, WorkTF, 0, InpEntryPeriod + InpExitPeriod + 50, temp); 

   g_lastD1VolRatio   = 999.0; // Toxic Initialize          
   
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(10);
   trade.LogLevel(LOG_LEVEL_NO); 
   
   g_pipUnit       = GetPipUnit();
   g_tripleSwapDay = GetTripleSwapDay();
   
   // --- BROKER METADATA TELEMETRY FOR PROP FIRMS ---
   Print("==================================================");
   Print("=== BROKER CONTRACT SPECS (", _Symbol, ") ===");
   Print("Contract Size: ", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE));
   Print("Tick Value:    ", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE));
   Print("Tick Size:     ", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));
   Print("Point:         ", SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   Print("Digits:        ", SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   Print("==================================================");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   IndicatorRelease(handleATR); IndicatorRelease(handleD1VolATR);
   ObjectsDeleteAll(0, "Donchian_"); ArrayFree(g_tradeCache); Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_currentDayOfYear) {
      g_currentDayOfYear = dt.day_of_year;
      g_lastD1VolRatio   = 999.0; // Reset daily armor
   }

   if(PositionsTotal() > 0) {
      if(UseBreakEven)         ManageBreakEven();
      if(InpUseTrailingStop)   ManageTrailingStop();
      
      static datetime lastMinute = 0;
      datetime currentMinute = TimeCurrent() / 60;
      if(currentMinute != lastMinute) {
         lastMinute = currentMinute;
         if(UseSwapFilter) {
            if(ForceCloseFriday && dt.day_of_week == FRIDAY && dt.hour >= FridayCloseHour) CloseAllPositions("Weekend");
            if(dt.day_of_week == g_tripleSwapDay && dt.hour >= SwapCloseHour) CloseAllPositions("Swap");
         }
      }
   }

   datetime currentTime = iTime(_Symbol, WorkTF, 0);
   bool isNewBar = (currentTime != lastBarTime);
   if(isNewBar) lastBarTime = currentTime;

   // HUD Telemetry Frame Rate: 1 Second Max
   static datetime lastHUDTime = 0;
   if(InpShowDashboard && TimeCurrent() != lastHUDTime && !MQLInfoInteger(MQL_OPTIMIZATION)) {
      lastHUDTime = TimeCurrent();
      UpdateDashboard();
   }

   // --- THROTTLED CONTINUOUS RETRY DATA FETCHING ---
   if(isNewBar || g_lastD1VolRatio == 999.0) {
      
      static datetime lastDataRetry = 0;
      if(TimeCurrent() != lastDataRetry) { // 1-Second Max Throttle for Local Cache
         lastDataRetry = TimeCurrent();

         // Volatility Ratio
         if(InpUseD1VolFilter) {
            double d1VolBuf[1];
            if(CopyBuffer(handleD1VolATR, 0, 1, 1, d1VolBuf) > 0 && d1VolBuf[0] > 0) {
               double yHigh = iHigh(_Symbol, PERIOD_D1, 1);
               double yLow  = iLow(_Symbol, PERIOD_D1, 1);
               if(yHigh > 0 && yLow > 0 && yHigh > yLow) {
                  g_lastD1VolRatio = (yHigh - yLow) / d1VolBuf[0];
               }
            } else g_lastD1VolRatio = 999.0;
         } else g_lastD1VolRatio = 1.0;
      }
   }

   // --- STRUCTURAL NEW BAR MATH ---
   if(isNewBar) 
   {
      if(InpUseHurstFilter) g_cachedHurst = GetHurstExponent(InpHurstPeriod); 

      double atrBuf[1]; 
      if(CopyBuffer(handleATR, 0, 1, 1, atrBuf) > 0) {
         g_currentATR = atrBuf[0];
         g_rawM5AtrPts = g_currentATR / _Point;
      }

      int idxUpperEntry = iHighest(_Symbol, WorkTF, MODE_HIGH, InpEntryPeriod, 2);
      int idxLowerEntry = iLowest (_Symbol, WorkTF, MODE_LOW,  InpEntryPeriod, 2);
      int idxUpperExit  = iHighest(_Symbol, WorkTF, MODE_HIGH, InpExitPeriod,  2);
      int idxLowerExit  = iLowest (_Symbol, WorkTF, MODE_LOW,  InpExitPeriod,  2);
      
      if(idxUpperEntry >= 2 && idxLowerEntry >= 2 && idxUpperExit >= 2 && idxLowerExit >= 2) {
         g_UpperEntry = iHigh(_Symbol, WorkTF, idxUpperEntry);
         g_LowerEntry = iLow (_Symbol, WorkTF, idxLowerEntry);
         g_UpperExit  = iHigh(_Symbol, WorkTF, idxUpperExit);
         g_LowerExit  = iLow (_Symbol, WorkTF, idxLowerExit);
         g_prevClose  = iClose(_Symbol, WorkTF, 1);
      } else {
         return; 
      }
      
      if(InpShowVisuals && g_UpperEntry > 0) {
         DrawLevel("Donchian_UpperEntry", g_UpperEntry, clrDodgerBlue, STYLE_SOLID);
         DrawLevel("Donchian_LowerEntry", g_LowerEntry, clrCrimson,    STYLE_SOLID);
         DrawLevel("Donchian_UpperExit",  g_UpperExit,  clrSilver,     STYLE_DASHDOT);
         DrawLevel("Donchian_LowerExit",  g_LowerExit,  clrSilver,     STYLE_DASHDOT);
         ChartRedraw(0);
      }
   }

   // --- EXECUTION GATE: The Signal State Machine ---
   bool hasOpenPos = false;
   double liveBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double liveAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) { 
         hasOpenPos = true; 
         
         // TICK-TOUCH EXIT: Instant structural bailout (No waiting for bar close)
         if(g_LowerExit > 0 && g_UpperExit > 0) {
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY  && liveBid < g_LowerExit) {
               trade.PositionClose(ticket);
               hasOpenPos = false; // Update state immediately
            }
            if(type == POSITION_TYPE_SELL && liveAsk > g_UpperExit) {
               trade.PositionClose(ticket);
               hasOpenPos = false; // Update state immediately
            }
         }
      }
   }

   static datetime lastExecutionBar = 0;

   // 1. Check if we already processed this bar, and if the structure is ready
   if(currentTime != lastExecutionBar && !hasOpenPos && g_currentATR > 0 && g_UpperEntry > 0)
   {
      // 2. Validate the Bar-Close Signal (Strictly ignores wicks)
      bool isBuySignal  = (g_prevClose > g_UpperEntry);
      bool isSellSignal = (g_prevClose < g_LowerEntry);
      
      // If there is no confirmed breakout, mark bar as processed and exit to save CPU
      if(!isBuySignal && !isSellSignal) {
         lastExecutionBar = currentTime;
         return;
      }

      // 3. Data Starvation Retry (DO NOT lock the bar here! We must keep retrying)
      if(InpUseD1VolFilter && g_lastD1VolRatio == 999.0) return; 

      // 4. Lock the Bar (Data is here, we make our one-and-only decision for this candle)
      lastExecutionBar = currentTime;

      // 5. Final Filter Checks (Stateless Mutex Implementation)
      if(GetLocalTradesToday() >= InpMaxTradesPerDay) return;
      if(InpUseGlobalMutex && GetGlobalTradesToday() >= InpMaxGlobalTrades) return;
      if(InpUseTimeFilter  && !IsSessionOpen()) return;
      if(InpUseHurstFilter && g_cachedHurst < InpHurstThreshold) return;
      if(InpUseD1VolFilter && (g_lastD1VolRatio < InpD1VolMinRatio || g_lastD1VolRatio > InpD1VolMaxRatio)) return; 

      if(UseSwapFilter && ((BlockSaturdayEntries && dt.day_of_week == SATURDAY) || 
                           (BlockSundayEntries && dt.day_of_week == SUNDAY) || 
                           (BlockFridayEntries  &&  dt.day_of_week == FRIDAY) || 
                           (dt.day_of_week == g_tripleSwapDay && dt.hour >= SwapCloseHour - 2))) return;

      // 6. Execute exactly once
      double slDist = InpATRStopMult * g_currentATR; // Using static ATR multiplier
      double minSL = 50 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(slDist < minSL) slDist = minSL;
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      double buyTP  = InpUseFixedRR ? ask + (slDist * InpFixedRR_Target) : 0;
      double sellTP = InpUseFixedRR ? bid - (slDist * InpFixedRR_Target) : 0;
      
      double lotSize = CalculateLotSize(slDist);
      
      if(isBuySignal) {
         trade.Buy(lotSize, _Symbol, 0, ask - slDist, buyTP, "Donchian Channel V17.0");
      }
      else if(isSellSignal) {
         trade.Sell(lotSize, _Symbol, 0, bid + slDist, sellTP, "Donchian Channel V17.0");
      }
   }
}

//+------------------------------------------------------------------+
//| ORB-AESTHETIC HUD (v17.0 - LIVE)                                 |
//+------------------------------------------------------------------+
void UpdateDashboard() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   string status = "🟢 HUNTING";
   bool isToxic = false;
   
   // Status Cascades
   if(GetLocalTradesToday() >= InpMaxTradesPerDay) status = "🔴 BLOCKED (Local Max Hits)";
   else if(InpUseGlobalMutex && GetGlobalTradesToday() >= InpMaxGlobalTrades) status = "🔴 BLOCKED (Global Max Hits)";
   else if(UseSwapFilter && ((BlockSaturdayEntries && dt.day_of_week == SATURDAY) || 
                             (BlockSundayEntries && dt.day_of_week == SUNDAY) || 
                             (BlockFridayEntries && dt.day_of_week == FRIDAY) || 
                             (dt.day_of_week == g_tripleSwapDay && dt.hour >= SwapCloseHour - 2))) {
      status = "🔴 BLOCKED (Weekend/Swap Guard)";
   }
   else if(InpUseTimeFilter && !IsSessionOpen()) status = "🟡 SLEEPING (Out of Session)";
   else if(InpUseHurstFilter && g_cachedHurst < InpHurstThreshold) status = "🟡 CHOP (Hurst < Limit)";
   else if(InpUseD1VolFilter && g_lastD1VolRatio == 999.0) {
      status = "🟠 SYNCING DATA CACHE...";
      isToxic = true;
   }
   else if(InpUseD1VolFilter && (g_lastD1VolRatio < InpD1VolMinRatio || g_lastD1VolRatio > InpD1VolMaxRatio)) status = "🔴 BLOCKED (Toxic Volatility)";

   // Bar Timer Calculation
   int periodSeconds = PeriodSeconds(WorkTF);
   datetime nextBarTime = iTime(_Symbol, WorkTF, 0) + periodSeconds;
   int secondsLeft = (int)(nextBarTime - TimeCurrent());
   int mLeft = secondsLeft / 60;
   int sLeft = secondsLeft % 60;
   string timerStr = StringFormat("%02d:%02d", mLeft, sLeft);

   // Live Spread
   int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   // Filter Labels
   string hurstLabel = (g_cachedHurst >= InpHurstThreshold) ? "✅ (Pass)" : "❌ (Chop)";
   string volLabel   = "";

   if(isToxic) {
      volLabel = "⚠️ AWAITING CACHE";
   } else {
      bool volPass = (g_lastD1VolRatio >= InpD1VolMinRatio && g_lastD1VolRatio <= InpD1VolMaxRatio);
      volLabel = DoubleToString(g_lastD1VolRatio, 2) + "x " + (volPass ? "✅ (Pass)" : "❌ (Block)");
   }

   // Build Output
   string hud = "================================\n";
   hud += "🔥 DUAL-DONCHIAN v17.0 (LIVE) [" + InpSetName + "]\n";
   hud += "================================\n";
   hud += "Time   : " + TimeToString(TimeCurrent(), TIME_SECONDS) + " | " + EnumToString(WorkTF) + " (" + timerStr + ")\n";
   hud += "Symbol : " + _Symbol + " / Magic " + IntegerToString(InpMagicNum) + "\n";
   hud += "Status : " + status + "\n";
   hud += "Spread : " + IntegerToString(currentSpread) + " Points\n";
   hud += "M5 ATR : " + DoubleToString(g_rawM5AtrPts, 0) + " pts\n";
   if(InpUseHurstFilter)    hud += "Hurst  : " + DoubleToString(g_cachedHurst, 3) + " " + hurstLabel + "\n";
   if(InpUseD1VolFilter)    hud += "D1 Vol : " + volLabel + "\n";
   hud += "Mutex  : L: " + IntegerToString(GetLocalTradesToday()) + "/" + IntegerToString(InpMaxTradesPerDay) + " | G: " + IntegerToString(GetGlobalTradesToday()) + "/" + IntegerToString(InpMaxGlobalTrades) + "\n";
   hud += "Risk   : $" + DoubleToString(InpRiskMoney, 2) + "\n";
   hud += "================================";

   Comment(hud);
}

//+------------------------------------------------------------------+
double GetInitialRisk(ulong posIdentifier, int &outCacheIdx)
{
   int size = ArraySize(g_tradeCache);
   for(int i = 0; i < size; i++) {
      if(g_tradeCache[i].posID == posIdentifier) {
         outCacheIdx = i;
         return g_tradeCache[i].initialRisk;
      }
   }

   double risk = 0;
   if(HistorySelectByPosition(posIdentifier)) {
      for(int i = 0; i < HistoryDealsTotal(); i++) {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
            ulong orderTicket = HistoryDealGetInteger(dealTicket, DEAL_ORDER);
            if(HistoryOrderSelect(orderTicket)) {
               double openPrice = HistoryOrderGetDouble(orderTicket, ORDER_PRICE_OPEN);
               double slPrice   = HistoryOrderGetDouble(orderTicket, ORDER_SL);
               if(slPrice > 0 && openPrice > 0) risk = MathAbs(openPrice - slPrice);
            }
         }
      }
   }
   
   if(risk <= _Point * 10) {
      if(g_currentATR > 0) risk = g_currentATR * InpATRStopMult;
      if(risk <= 0) risk = 50 * _Point; 
   }
   
   if(size > 200) { ArrayFree(g_tradeCache); size = 0; }
   
   ArrayResize(g_tradeCache, size + 1);
   g_tradeCache[size].posID             = posIdentifier;
   g_tradeCache[size].initialRisk       = risk;
   g_tradeCache[size].lastModifyAttempt = 0;
   
   outCacheIdx = size;
   return risk;
}

//+------------------------------------------------------------------+
void ManageTrailingStop() {
   int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long stLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopDistance = stLevel * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      
      int cacheIdx = -1;
      double initialRisk = GetInitialRisk(ticket, cacheIdx);
      if(initialRisk <= 0) continue;
      
      if(cacheIdx >= 0 && TimeCurrent() - g_tradeCache[cacheIdx].lastModifyAttempt < 3) continue;
      
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double current   = PositionGetDouble(POSITION_PRICE_CURRENT);
      long   type      = PositionGetInteger(POSITION_TYPE);
      
      if(type == POSITION_TYPE_BUY) {
         double newSL = currentSL; bool modify = false;
         if((current - entry) / initialRisk >= InpTrail_Activation) {
            double pTrail = current - (InpTrail_Distance_R * initialRisk);
            if(pTrail > newSL) { newSL = pTrail; modify = true; }
         }
         if(modify && NormalizeDouble(newSL, dig) != NormalizeDouble(currentSL, dig) && MathAbs(current - newSL) > stopDistance) {
            if(cacheIdx >= 0) g_tradeCache[cacheIdx].lastModifyAttempt = TimeCurrent();
            trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL) {
         double newSL = currentSL; bool modify = false;
         if((entry - current) / initialRisk >= InpTrail_Activation) {
            double pTrail = current + (InpTrail_Distance_R * initialRisk);
            if(pTrail < newSL || newSL == 0) { newSL = pTrail; modify = true; }
         }
         if(modify && NormalizeDouble(newSL, dig) != NormalizeDouble(currentSL, dig) && MathAbs(current - newSL) > stopDistance) {
            if(cacheIdx >= 0) g_tradeCache[cacheIdx].lastModifyAttempt = TimeCurrent();
            trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

void ManageBreakEven() {
   int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long stLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopDistance = stLevel * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      
      int cacheIdx = -1;
      double initialRisk = GetInitialRisk(ticket, cacheIdx);
      if(initialRisk <= 0) continue;
      
      if(cacheIdx >= 0 && TimeCurrent() - g_tradeCache[cacheIdx].lastModifyAttempt < 3) continue;
      
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double current   = PositionGetDouble(POSITION_PRICE_CURRENT);
      long   type      = PositionGetInteger(POSITION_TYPE);
      
      if(type == POSITION_TYPE_BUY) {
         double newSL = currentSL; bool modify = false;
         if((current - entry) / initialRisk >= BE_Trigger_R) {
            double pBE = entry + (BE_Offset_Pips * g_pipUnit);
            if(pBE > newSL) { newSL = pBE; modify = true; }
         }
         if(modify && NormalizeDouble(newSL, dig) != NormalizeDouble(currentSL, dig) && MathAbs(current - newSL) > stopDistance) {
            if(cacheIdx >= 0) g_tradeCache[cacheIdx].lastModifyAttempt = TimeCurrent();
            trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL) {
         double newSL = currentSL; bool modify = false;
         if((entry - current) / initialRisk >= BE_Trigger_R) {
            double pBE = entry - (BE_Offset_Pips * g_pipUnit);
            if(pBE < newSL || newSL == 0) { newSL = pBE; modify = true; }
         }
         if(modify && NormalizeDouble(newSL, dig) != NormalizeDouble(currentSL, dig) && MathAbs(current - newSL) > stopDistance) {
            if(cacheIdx >= 0) g_tradeCache[cacheIdx].lastModifyAttempt = TimeCurrent();
            trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UTILITIES                                                        |
//+------------------------------------------------------------------+
void DrawLevel(string name, double price, color clr, ENUM_LINE_STYLE style) {
   if(price <= 0) return;
   if(ObjectFind(0, name) < 0) {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr); ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);   ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false); ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
}

double GetPipUnit() {
   string sym = _Symbol;
   if(StringFind(sym, "JPY") >= 0) return 0.01;
   if(StringFind(sym, "GC") >= 0 || StringFind(sym, "MGC") >= 0 || StringFind(sym, "GOLD") >= 0 || StringFind(sym, "XAU") >= 0) return (SymbolInfoDouble(_Symbol, SYMBOL_POINT) == 0.1) ? 0.1 : 0.10; 
   if(StringFind(sym, "BTC") >= 0 || StringFind(sym, "NAS") >= 0 || StringFind(sym, "US100") >= 0 || StringFind(sym, "USTEC") >= 0 || StringFind(sym, "US30") >= 0 || StringFind(sym, "DJ30") >= 0) return 1.0;
   return 0.0001;
}

double GetHurstExponent(int period) {
   if(period <= 1) return 0.5; 
   double prices[]; 
   ArrayResize(prices, period); 
   
   if(CopyClose(_Symbol, WorkTF, 1, period, prices) < period) return 0.5;
   
   double mean = 0; 
   for(int i = 0; i < period; i++) mean += prices[i]; 
   mean /= period;
   
   double devSum = 0, cumDev = 0, maxCumDev = -DBL_MAX, minCumDev = DBL_MAX;
   for(int i = 0; i < period; i++) {
      double diff = prices[i] - mean; 
      devSum += diff * diff; 
      cumDev += diff;
      if(cumDev > maxCumDev) maxCumDev = cumDev; 
      if(cumDev < minCumDev) minCumDev = cumDev;
   }
   
   double stdDev = MathSqrt(devSum / period); 
   if(stdDev == 0) return 0.5;
   
   double RS = (maxCumDev - minCumDev) / stdDev; 
   if(RS <= 0) RS = 1e-5; 
   
   return MathLog(RS) / MathLog(period);
}

ENUM_DAY_OF_WEEK GetTripleSwapDay() { return AutoDetectTriple ? (ENUM_DAY_OF_WEEK)SymbolInfoInteger(_Symbol, SYMBOL_SWAP_ROLLOVER3DAYS) : ManualSwapDay; }

void CloseAllPositions(string reason) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) trade.PositionClose(ticket);
   }
}

bool IsSessionOpen() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return (InpStartHour < InpEndHour) ? (dt.hour >= InpStartHour && dt.hour < InpEndHour) : (dt.hour >= InpStartHour || dt.hour < InpEndHour);
}

//--- THE UPDATED CONTRACT-SIZE LOT CALCULATION ---
double CalculateLotSize(double slDist) {
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double volumeStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(contractSize <= 0 || slDist <= 0) return minLot;
   if(volumeStep <= 0) volumeStep = 0.01;

   // Monetary loss per 1 lot
   double riskPerLot = slDist * contractSize;
   if (riskPerLot <= 0) return minLot;

   double lots = InpRiskMoney / riskPerLot;

   // Normalize to broker volume step
   lots = MathFloor(lots / volumeStep) * volumeStep;
   
   return MathMax(minLot, MathMin(maxLot, lots));
}

int GetLocalTradesToday() {
   int localCount = 0;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   
   if(HistorySelect(dayStart, TimeCurrent())) {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0) {
            if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
               ulong magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
               string sym  = HistoryDealGetString(ticket, DEAL_SYMBOL);
               
               // Strict filter for THIS specific EA and THIS specific asset
               if(magic == InpMagicNum && sym == _Symbol) {
                  localCount++;
               }
            }
         }
      }
   }
   return localCount;
}

int GetGlobalTradesToday() {
   int globalCount = 0;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   
   if(HistorySelect(dayStart, TimeCurrent())) {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0) {
            if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
               ulong magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
               if(magic >= InpMagicRangeStart && magic <= InpMagicRangeEnd) {
                  globalCount++;
               }
            }
         }
      }
   }
   return globalCount;
}
//+------------------------------------------------------------------+