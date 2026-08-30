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
5. Run `code/04_analysis/03_wang_full_dynamic_bank_model.R`.
6. Run `code/04_analysis/10_prepare_dynamic_counterfactuals.R`.

## Current BLP results

The cleaned final BLP estimates cover 1994–2025 and are empirical outputs synchronized from the Dropbox `ag-lending-competition` project.

| Market | Primary instruments | Observations | Banks | Median margin |
|---|---|---:|---:|---:|
| Deposits | Wang supply costs | 245,553 | 14,984 | 0.001613 |
| Total loans | Wang supply costs | 244,893 | 14,936 | 0.010090 |
| Agricultural production loans | Wang supply costs | 99,028 | 7,248 | 0.015604 |

The primary specification follows Wang et al. and instruments loan rates with salary expense/assets and premises expense/assets. The all-rival-characteristics specification is retained as robustness. See `output/tables/blp_final/final_blp_summary.csv` for all six specifications. Rates and margins are decimals; for example, `0.015604` is about 1.5604 percentage points.

## Dynamic model status

The repository includes the Wang-style balance-sheet Bellman implementation, transition tables, parameters, diagnostics, and policy output. The cleaned audit in `output/tables/dynamic_counterfactuals/counterfactual_readiness.csv` is binding: the earlier competitive output is invalid because it scaled demand slopes incorrectly, and the risk/franchise counterfactual is not identified until an agricultural-franchise adjustment cost is estimated. Existing policy results remain illustrative rather than publication-ready estimates.

See `docs/model.md` for the Bellman equation and `docs/data_requirements.md` for the complete input map.

## Research extensions

- `docs/wang_paper_recheck.md` compares this implementation with Wang, Whited, Wu, and Xiao.
- `docs/one_big_beautiful_bill_design.md` maps the 2025 law into estimable agricultural-credit shocks and counterfactuals.
