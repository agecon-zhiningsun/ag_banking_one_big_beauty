# AG Banking: One Big Beauty

This repository collects the structural pieces of the agricultural-banking project in one compact, reproducible package: BLP market-power estimation, dynamic-bank inputs, and a Wang-style Bellman model.

Its layout follows the Dropbox reference repository `/ag-lending-competition`:

- `code/01_download/`: data acquisition (documented here; source scripts remain in the parent project);
- `code/02_clean/`: source cleaning (documented here; source scripts remain in the parent project);
- `code/03_construct/`: BLP panels and dynamic-model inputs;
- `code/04_analysis/`: BLP estimation and the Bellman model;
- `output/tables/`: small, Git-tracked empirical results;
- `output/figures/`: Git-tracked figures;
- `docs/`: model and data documentation; and
- `config/`: collaborator-specific external data path.

## Data storage

Large datasets stay outside Git. On the primary machine they live at:

`C:/Users/zhini/Dropbox/ag lending data`

Copy `config/data_paths_example.R` to `config/data_paths.R` and set `data_root`. The local file is ignored by Git. The repository intentionally has no tracked `data/` directory.

Expected external layout:

- `raw/`: downloaded source files;
- `pipeline_cache/nc1177/`: cleaned inputs and rebuild intermediates; and
- `processed/nc1177/`: final estimation panels and detailed model output.

## Reproduction order

1. Run the upstream download and cleaning stages in `/ag-lending-competition` if the external data store is not already populated.
2. Run `code/03_construct/07_construct_market_power_panels.R`.
3. Run `code/04_analysis/09_estimate_final_blp.R`.
4. Run `code/03_construct/06_construct_dynamic_bank_model_inputs.R`.
5. Run `code/04_analysis/10_prepare_dynamic_counterfactuals.R`.

### OBBBA policy-exposure module

1. Run `code/01_download/01_download_policy_exposure_data.R`.
2. Run `code/02_clean/01_clean_historical_policy_payments.R`.
3. Run `code/03_construct/11_construct_payment_retention_panels.R`.
4. Run `code/04_analysis/11_estimate_payment_retention.R`.
5. Run `code/03_construct/12_construct_obbba_exposure.R`.
6. Run `code/04_analysis/12_simulate_obbba_arc_plc_payments.R`.
7. Run `code/04_analysis/13_prepare_obbba_bellman_counterfactuals.R`.
8. Run `code/04_analysis/14_run_identified_deposit_policy_counterfactual.R`.
9. Run `code/04_analysis/15_estimate_and_simulate_total_fsa_lending_channel.R`.
10. Run `code/04_analysis/16_estimate_obbba_balance_sheet_channels.R`.
11. Run `code/04_analysis/03_wang_full_dynamic_bank_model.R`.
12. Run `code/04_analysis/17_summarize_obbba_structural_results.R`.

This module keeps county-market and bank designs distinct. The county design
relates policy payments to total deposits across all branches in a county. The
bank design uses prior-year SOD deposit geography to construct service-area
exposure; it does not assign county payments to individual banks or assume that
all bank depositors are farmers. The first-pass fixed-effect estimates in
`output/tables/payment_retention/` are diagnostics, not causal estimates.
The FSA recipient files cover calendar disbursements from 2014 through 2025;
recipient names and addresses remain outside Git, and only county-program
aggregates enter the analytical panels. ARC/PLC, MFP, CFAP and BEA total
government payments are estimated separately. The OBBBA counterfactual uses
only the positive, statistically significant total-FSA coefficient. It reports
the simulated percentage increase in total FSA payments and applies the
estimated retention coefficient to the corresponding payment-to-deposit shock;
it does not use the insignificant program-family coefficients. OBBBA
payment/deposit scenarios are in `output/tables/obbba_simulation/`.
Bellman-ready bank shock inputs and the counterfactual registry are in
`output/tables/obbba_bellman/`. Historical service-area regressions estimate
funding, capital and pricing responses. Because historical payment targeting
prevents a credible default-risk estimate, the dynamic exercise reports zero,
10-percent and 25-percent charge-off-reduction calibrations instead of treating
the endogenous historical charge-off coefficient as causal.
The identified deposit-only comparison of no policy (A) with OBBBA under current
market power (B) is reported in
`output/tables/obbba_bellman/identified_deposit_policy_counterfactual.csv`.
The corresponding descriptive agricultural-lending reduced form and central
OBBBA simulation are in `output/tables/obbba_lending/`. This stage allows
payments to reduce borrowing demand rather than assuming that every additional
deposit dollar becomes a new farm loan.

## Current BLP results

The cleaned final BLP estimates cover 1994–2025 and are empirical outputs synchronized from the Dropbox `ag-lending-competition` project.

| Market | Primary instruments | Observations | Banks | Median margin |
|---|---|---:|---:|---:|
| Deposits | Wang supply costs | 245,553 | 14,984 | 0.001613 |
| Total loans | Wang supply costs | 244,893 | 14,936 | 0.010090 |
| Agricultural production loans | Wang supply costs | 99,028 | 7,248 | 0.015604 |

The primary specification follows Wang et al. and instruments loan rates with salary expense/assets and premises expense/assets. The all-rival-characteristics specification is retained as robustness. See `output/tables/blp_final/final_blp_summary.csv` for all six specifications. Rates and margins are decimals; for example, `0.015604` is about 1.5604 percentage points.

## Dynamic model status

The repository includes the Wang-style balance-sheet Bellman implementation,
transition tables, parameters, diagnostics, and policy output. The invalid old
competition shortcut that multiplied demand slopes has been removed. Competitive
lending now fixes the loan rate at risk-adjusted marginal cost; competitive
deposits use the avoided marginal wholesale-funding cost net of servicing and
reserve carry. OBBBA channel, competition and capital counterfactuals have been
run on a two-point bank-state grid. They are structural calibrations, not the
full Wang simulated-minimum-distance estimation, and the reported competitor-
rate equilibrium gaps remain material.

See `docs/model.md` for the Bellman equation and `docs/data_requirements.md` for the complete input map.

## Research extensions

- `docs/wang_paper_recheck.md` compares this implementation with Wang, Whited, Wu, and Xiao.
- `docs/one_big_beautiful_bill_design.md` maps the 2025 law into estimable agricultural-credit shocks and counterfactuals.
