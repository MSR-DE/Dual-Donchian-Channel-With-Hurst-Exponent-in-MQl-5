# Dual Donchian Channel Breakout Strategy with Hurst Exponent Filter

An algorithmic trading system developed in MQL5, that dynamically adapts to market regimes. The strategy combines a Dual Donchian Channel breakout mechanism with a Hurst Exponent filter to distinguish between trending and mean-reverting market conditions.

## Strategy Architecture & Logic

Most breakout strategies suffer severe drawdowns during ranging markets. This system mitigates false breakouts by applying layered volatility and regime filters before taking entries.

1.  **Core Logic (Dual Donchian):** Uses a fast Donchian Channel for early breakout detection and a slow Donchian Channel for overarching trend confirmation.
2.  **Regime Filter (Hurst Exponent):** Measures the fractal dimension of the time series. Trades are only permitted when the Hurst Exponent ($H \ge 0.55$) indicates a persistent trend regime.
3.  **D1 Volatility Expansion:** A daily ATR expansion filter ensures the macro-environment has sufficient liquidity and volatility to sustain the intraday breakout.
4.  **Risk Management:** Implements ATR-based position sizing to normalize volatility risk across different asset classes, improving capital efficiency and ensuring uniform risk per trade.
5.  **Global Mutex Locking:** Cap limits on daily trades (both locally per-asset and globally across the portfolio) to prevent over-exposure during highly correlated market crashes.
6.  **Swap & Weekend Protection:** Automatically closes positions before toxic swap rollover periods (triple swap) and weekends to prevent gap risk.

## Performance Data (2019 – 2026)

The system was developed using manual Walk-Forward Analysis (WFA) on MT5 to prevent curve-fitting across 7 highly varied asset classes to ensure broad robustness.

### Backtest Results Summary

| Asset | Total Net Profit ($) | Profit Factor | Maximum Drawdown | Total Trades |
|-------|----------------------|---------------|------------------|--------------|
| **BTC** | 8,859.32 | 1.73 | 4.63% | 296 |
| **Gold** | 10,017.48 | 1.46 | 7.65% | 500 |
| **USDJPY** | 4,819.35 | 1.69 | 4.76% | 225 |
| **NQ** | 6,216.78 | 1.44 | 12.91% | 350 |
| **AUDJPY** | 2,966.47 | 1.35 | 10.97% | 275 |
| **DAX** | 3,878.59 | 1.31 | 13.74% | 194 |
| **SNP500** | 4,500.35 | 1.13 | 19.07% | 666 |

*Testing parameters used a fixed base risk. Full HTML reports and equity curve PNGs for every asset are categorized in the `Code/Results` directory.*

## Technology Stack
*   **MQL5:** Core execution logic, state management, HUD telemetry, and MetaTrader 5 broker API integration.

## Disclaimer
*This code is for educational and research purposes only. Do not deploy this algorithm on live capital without conducting your own rigorous forward testing.*
#
