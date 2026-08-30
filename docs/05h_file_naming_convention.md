# File naming convention

Every project-created file begins with the stage and sequence letter of the
script that creates it. The prefix makes the pipeline order visible without
opening a file.

| Prefix | Folder | Purpose |
|---|---|---|
| `01a_` | `code/01_download/` | Download policy-exposure source data |
| `02a_`–`02b_` | `code/02_clean/` | Clean historical and annual FSA payments |
| `03a_`–`03d_` | `code/03_construct/` | Construct dynamic, market-power, payment-retention, and OBBBA panels |
| `04a_`–`04j_` | `code/04_analysis/` | Estimate BLP/reduced-form models and solve policy counterfactuals |
| `05a_` onward | `code/05_documentation/`, `docs/` | Documentation and report artifacts |

Generated datasets in the external Dropbox data store use the producing
script's prefix. Tracked results use both a prefixed folder and a prefixed
filename, for example
`output/tables/04h_balance_sheet_channels/04h_default_risk_scenarios.csv`.

Official raw downloads retain the original USDA, BEA, FDIC, FRED, or ERS
filename. Those names are source identifiers and must not be changed. Inputs
created by the upstream `ag_lending_competition` pipeline also retain their
established names unless this repository regenerates them.
