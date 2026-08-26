# Data requirements

## Minimum viable BLP panel

One row per bank × local market × year:

| Field | Definition | Why needed |
|---|---|---|
| `market_id`, `year` | County/MSA/commuting-zone and period | Choice market |
| `bank_id`, `owner_id` | Product and ultimate parent | Multiproduct ownership |
| `deposits` | Deposits in the local market | Inside share |
| `market_size` | Potential deposit dollars or households | Outside share |
| `deposit_rate` and/or `fees` | Depositor return/cost | Endogenous price |
| `branches` | Local branch count/access | Observed quality |
| bank controls | size, capital, digital access, services | Demand and cost controls |
| cost shifters | funding costs, wages, rents, regulation exposure | Supply/instruments |
| rival characteristics | competing branch networks and predetermined traits | Candidate BLP instruments |

Enforce positive inside shares and `sum(deposits) < market_size` within every market-year. Preserve merger histories so `owner_id` reflects ownership in that year.

## Dynamic extension

Add branch openings/closures, entry/exit, loans by geography, interest income/expense, charge-offs, securities, wholesale funding, equity capital, risk-weighted assets, dividends, merger events, and local economic states. These variables identify profits, state transitions, adjustment costs, and constraints in the Bellman problem.

## Candidate U.S. sources

- FDIC Summary of Deposits: branch deposits, locations, ownership.
- FFIEC Call Reports / Federal Reserve NIC: bank balance sheets and organizational history.
- RateWatch or another rate vendor: bank-product deposit rates and fees.
- Census / BEA / BLS: households, income, employment, wages, and market controls.
- HMDA or Call Reports: lending outcomes, with geographic limitations documented.

## Construction decisions to freeze before estimation

1. Geographic market definition and annual observation date.
2. Market-size denominator and outside option.
3. Price convention: higher `price` must lower utility.
4. Treatment of online banks and zero-branch products.
5. Parent-bank consolidation and merger-year rules.
6. Instrument set and the exclusion argument for every instrument.

