# mt5-trade-manager

An MT5 Expert Advisor built around the position-management features that get requested most often, with a deliberately simple entry rule so the management code can be back-tested on real ticks.

**This is the management layer, not a signal.** The included entry (session-range breakout) is a demo and is not profitable as-is: on the included XAUUSD run it made 215 trades with profit factor 0.89. That is the point of publishing it: you bring the entry, this code handles risk and exits cleanly, and the tester journal shows zero rejected or invalid orders over 215 trades.

## What it manages

| Feature | Inputs | Behaviour |
|---|---|---|
| Percent-risk lot sizing | `InpRiskPercent` | Lots from balance × risk% ÷ (stop distance in ticks × tick value), normalised to the volume step, clamped to min/max |
| Initial stop and target | `InpSL_ATR`, `InpTP_RR`, `InpATRPeriod` | SL = ATR multiple (raised to the broker's stops level if needed), TP = R multiple of the stop (0 = none) |
| Breakeven | `InpBE_TriggerRR`, `InpBE_OffsetPts` | At the trigger R, SL moves to entry ± offset, only if that improves it |
| Partial take-profit | `InpPartialRR`, `InpPartialPct` | Closes a percentage of the initial volume once, respecting min volume on both the closed and the remaining part |
| ATR trailing stop | `InpTrail_ATR`, `InpTrailStartRR` | After the start R, SL follows price at an ATR distance and only ever tightens |
| Daily loss limit | `InpDailyLossPct` | Equity loss from the day-start balance ≥ limit → close position, no more entries today |
| Spread filter | `InpMaxSpreadPts` | No entry when spread is above the limit |
| Time exit | `InpCloseHour` | Flat at/after the close hour, no new trades |

Management order on every tick: daily loss → breakeven → partial → trailing. At most one modification per tick. Works on netting and hedging accounts (positions are matched by magic + symbol). Every failed trade call is printed with the broker return code and description.

## Demo entry rule

Range = high/low of `InpRangeStartHour`..`InpRangeEndHour` (server time). First closed bar after the range that closes above the range high → long, below the range low → short. One trade per day.

## Included backtest

XAUUSD.v M15, 2026-04-01 to 2026-10-27, InterStellar Financial server, every tick based on real ticks, deposit 10,000 USD, defaults (1% risk, SL 1.5 ATR, TP 2R, BE at 1R, 50% partial at 1R, trail 2 ATR from 1R, daily loss 3%, spread ≤ 300 pts).

| Metric | Value |
|---|---|
| Trades | 215 (362 deals, partial closes included) |
| Net profit | −843.10 |
| Profit factor | 0.89 |
| Win rate | 61.4% (average win 52.89, average loss −94.27) |
| Max balance drawdown | 14.5% |
| Invalid stops / invalid volume / rejected orders in the journal | 0 |

Files: `results/TradeManager_XAUUSDv_M15_2026.htm` and the tester's PNG charts.

## Build and run

Compile `MQL5/Experts/TradeManagerEA.mq5` in MetaEditor (0 errors, 0 warnings) or with `MetaEditor64.exe /compile:<file> /log:<log>`. Attach to one chart per symbol; set `InpMagic` differently per chart. For a headless tester run, use a `[Tester]` `.ini` with `terminal64.exe /config:file.ini`.

## Limitations

- One position per symbol by design. Pyramiding or grids are out of scope.
- The trailing stop can modify the position on consecutive ticks in fast markets; add a minimum step or a timer if your broker rate-limits modifications.
- Day boundaries use server time; set the hours for your broker's clock.
- Breakeven and partial state is kept in memory. If the terminal restarts with an open position, the EA treats it as already managed from the current SL (no second partial).

## License

MIT, see `LICENSE`.
