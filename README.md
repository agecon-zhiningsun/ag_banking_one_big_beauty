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
3. Install `code/04_analysis/requirements.txt`, then run `code/04_analysis/02_estimate_ag_production_deposit_rc_blp.py`.
4. Run `code/03_construct/06_construct_dynamic_bank_model_inputs.R`.
5. Run `code/04_analysis/03_wang_full_dynamic_bank_model.R`.

## Current BLP results

The tracked agricultural-production BLP estimates cover 1994–2025 and are empirical outputs copied from the reference project, not synthetic examples.

| Sample | Observations | Banks | Mean structural margin | Median structural margin | Converged |
|---|---:|---:|---:|---:|---|
| Non-agricultural banks | 53,805 | 5,626 | 0.02379 | 0.00823 | Yes |
| Agricultural banks | 45,223 | 3,114 | 0.02023 | 0.00887 | Yes |
| All banks pooled | 99,028 | 7,248 | 0.02213 | 0.00856 | Yes |

See `output/tables/blp_market_power/ag_production_summary.csv` for the full compact table. These are provisional structural estimates: the current Hansen test has `p = 0.0113`, and the weighting and parameter-covariance matrices are poorly conditioned. The repository therefore preserves the estimates while flagging instrument/specification refinement as required before causal interpretation.

## Dynamic model status

The repository includes the full Wang-style balance-sheet Bellman implementation and tracked diagnostics. The policy results remain labeled `illustrative_not_estimated`; the parameter table distinguishes initial SMD parameters, statutory/direct inputs, stress calibrations, and descriptive reduced-form quantities.

See `docs/model.md` for the Bellman equation and `docs/data_requirements.md` for the complete input map.

## Research extensions

- `docs/wang_paper_recheck.md` compares this implementation with Wang, Whited, Wu, and Xiao.
- `docs/one_big_beautiful_bill_design.md` maps the 2025 law into estimable agricultural-credit shocks and counterfactuals.
