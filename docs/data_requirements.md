# Data requirements and file map

## Core BLP panel

The construction script expects annual bank observations for 1994–2025. Each year is a national demand market.

| Component | Required fields or concepts | External location |
|---|---|---|
| Call Reports | `cert`, report date, deposits, total loans, agricultural loans, assets, equity, income/expense items, employees | `pipeline_cache/nc1177/fdic/` |
| FDIC Summary of Deposits | bank certificate, year, branch count and deposit geography | `pipeline_cache/nc1177/sod/branch_year/` |
| Market-power cost inputs | loan/deposit rates, funding costs and operating-cost shifters | `pipeline_cache/nc1177/market_power/` |
| ERS agricultural credit | lender-sector agricultural credit totals used for market size/outside option | `raw/ers/` and `pipeline_cache/nc1177/market_power/` |
| Final BLP panel | prices, inside/outside shares, characteristics, bank type and instruments | `processed/nc1177/bank_year_market_power_inputs_1994_2025.parquet` |

The estimation requires positive shares, a valid outside share for every year, positive balances, economically valid rates, and stable bank identifiers. `agricultural_bank` must be consistently defined before sample splitting.

## BLP instruments and characteristics

The maintained random-coefficient specification uses:

- product price: agricultural-production loan rate or deposit rate;
- observed quality/cost controls including branch access and employees per branch;
- bank-type interactions;
- same-type Gandhi–Houde differentiation instruments; and
- year clustering and annual national market identifiers.

Instrument validity, market-size construction, missing-rate treatment and merger/charter continuity must be frozen before final estimation.

## Dynamic-bank inputs

The dynamic construction additionally needs annual balance sheets, BLP-implied margins, interest income and expense, charge-offs, the federal-funds rate, USDA ERS farm income, capital ratios, deposits, wholesale funding, securities, loan maturity, regulatory requirements and taxes.

The final model panel is written to `processed/nc1177/dynamic_bank_model/bank_year_dynamic_model_inputs_1994_2025.parquet`.

Large source and processed files stay in Dropbox and are never committed to Git.

