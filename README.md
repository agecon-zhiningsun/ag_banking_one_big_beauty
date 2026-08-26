# AG Banking: One Big Beauty

Standalone research repository for measuring local bank market power with a BLP-style differentiated-products demand system and linking the static estimates to a dynamic bank problem.

## What is already here

- A reproducible synthetic baseline with bank-market-year observations.
- BLP/logit market-power calculations: demand derivatives, multi-product ownership, implied markups, marginal costs, Lerner indices, and HHI.
- A Bellman equation for dynamic branching, deposit pricing, lending, and exit.
- A field-level checklist for replacing the synthetic panel with empirical data.

The current numbers are **method-validation results from simulated data**, not estimates about actual banks. See `results/blp_market_power_summary.csv` after running the pipeline.

## Quick start

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python src/run_blp_market_power.py
```

The script writes:

- `data/processed/synthetic_bank_market_panel.csv`
- `results/blp_product_results.csv`
- `results/blp_market_power_summary.csv`

## Empirical workflow

1. Construct bank × local-market × year deposit products and an outside-option share.
2. Estimate demand, preferably with instruments for endogenous deposit prices/rates.
3. Form the demand Jacobian and ownership matrix in each market-year.
4. Recover markups from banks' multiproduct first-order conditions.
5. Use recovered profits and transition estimates in the dynamic model.

Model notation and identification are in [docs/model.md](docs/model.md); required inputs and proposed sources are in [docs/data_requirements.md](docs/data_requirements.md).

