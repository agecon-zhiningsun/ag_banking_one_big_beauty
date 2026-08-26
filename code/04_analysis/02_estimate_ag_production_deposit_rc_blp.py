"""Full random-coefficient BLP with same-type Gandhi-Houde instruments.

Main study period: 1994-2025. Raw and processed data remain outside Git.
"""
from __future__ import annotations

import pickle
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pyblp


ROOT = Path(__file__).resolve().parents[2]
config_text = (ROOT / "config" / "data_paths.R").read_text(encoding="utf-8")
match = re.search(r'data_root\s*<-\s*["\']([^"\']+)', config_text)
if not match:
    raise RuntimeError("Could not read data_root from config/data_paths.R")
DATA_ROOT = Path(match.group(1))
INPUT = DATA_ROOT / "processed" / "nc1177" / "bank_year_market_power_inputs_1994_2025.parquet"
TABLE_ROOT = ROOT / "output" / "tables" / "blp_market_power"
DATA_OUT = DATA_ROOT / "processed" / "nc1177" / "blp_market_power"
TABLE_ROOT.mkdir(parents=True, exist_ok=True)
DATA_OUT.mkdir(parents=True, exist_ok=True)

pyblp.options.verbose = True
pyblp.options.digits = 6


def prepare(market: str) -> pd.DataFrame:
    d = pd.read_parquet(INPUT)
    d = d.loc[d["year"].between(1994, 2025) & d["agricultural_bank"].isin([0, 1])].copy()
    if market == "ag_production":
        d["prices"] = d["ag_production_loan_rate"]
        d["shares"] = d["ag_production_share"]
        positive_balance = d["lnag"] > 0
    elif market == "deposits":
        d["prices"] = d["deposit_rate"]
        d["shares"] = d["deposit_share"]
        positive_balance = d["dep"] > 0
    else:
        raise ValueError(market)

    required = ["prices", "shares", "log_branches", "log_employees_per_branch"]
    finite = np.logical_and.reduce([np.isfinite(d[c]) for c in required])
    d = d.loc[positive_balance & finite & (d["prices"] > 0) &
              (d["prices"] <= 0.50) & (d["shares"] > 0)].copy()
    d["market_ids"] = d["year"].astype(int)
    d["clustering_ids"] = d["year"].astype(int)
    d["firm_ids"] = d["cert"].astype(str)
    d["type_market_ids"] = (d["year"].astype(str) + "_" +
                             d["agricultural_bank"].astype(int).astype(str))
    d["ag_rate"] = d["prices"] * d["agricultural_bank"]

    # Products that are filtered out become part of the estimation outside option.
    inside = d.groupby("market_ids")["shares"].transform("sum")
    if (inside >= 1).any():
        raise RuntimeError(f"Invalid {market} inside share")

    # Gandhi-Houde quadratic differentiation instruments, calculated as if each
    # year x bank-type cell were its own rival set. Estimation markets remain years.
    gh_data = d.copy()
    gh_data["market_ids"] = gh_data["type_market_ids"]
    gh_formulation = pyblp.Formulation("0 + log_branches + log_employees_per_branch")
    gh = pyblp.build_differentiation_instruments(
        gh_formulation, gh_data, version="quadratic", interact=False
    )
    ag = d["agricultural_bank"].to_numpy(dtype=float)[:, None]
    nonag = 1.0 - ag
    excluded_full = np.column_stack([
        gh * ag,
        gh * nonag,
    ])
    # With year and bank fixed effects, the first two quadratic GH columns in
    # each type block are exact linear combinations of included characteristics.
    # Retain the non-collinear differentiation columns and all cost shifters.
    excluded = excluded_full[:, [2, 3, 6, 7]]
    for column, values in enumerate(excluded.T):
        d[f"demand_instruments{column}"] = values
    return d


def estimate(market: str) -> None:
    d = prepare(market)
    table_root = TABLE_ROOT
    data_out = DATA_OUT
    table_root.mkdir(parents=True, exist_ok=True)
    data_out.mkdir(parents=True, exist_ok=True)
    # Mean coefficients and heterogeneity can differ by bank type. The derivative
    # with respect to prices includes the ag-rate interaction for ag-bank products.
    x1 = pyblp.Formulation(
        "0 + prices + ag_rate + log_branches + log_employees_per_branch",
        absorb="C(cert) + C(year)",
    )
    x2 = pyblp.Formulation("0 + prices + ag_rate")
    integration = pyblp.Integration("halton", size=20, specification_options={"seed": 20260816})
    problem = pyblp.Problem((x1, x2), d, integration=integration)

    # A diagonal starting value lets the data estimate separate rate heterogeneity
    # without imposing the sign of either mean demand slope.
    sigma0 = np.diag([5.0, 5.0])
    optimization = pyblp.Optimization("l-bfgs-b", {"gtol": 1e-5, "maxiter": 500})
    iteration = pyblp.Iteration("squarem", {"atol": 1e-12})
    cache_path = data_out / f"{market}_problem_results.pkl"
    if cache_path.exists():
        with cache_path.open("rb") as stream:
            results = pickle.load(stream)
    else:
        results = problem.solve(
            sigma=sigma0,
            optimization=optimization,
            iteration=iteration,
            method="2s",
            se_type="clustered",
        )
        with cache_path.open("wb") as stream:
            pickle.dump(results, stream)

    jacobians = results.compute_demand_jacobians(name="prices")
    own_derivative = np.empty(len(d))
    cursor = 0
    for _, group in d.groupby("market_ids", sort=True):
        count = len(group)
        matrix = jacobians[cursor:cursor + count, :count]
        own_derivative[cursor:cursor + count] = np.diag(matrix)
        cursor += count
    d["own_rate_derivative"] = own_derivative
    d["economically_valid_slope"] = (
        own_derivative > 0 if market == "deposits" else own_derivative < 0
    )
    if market == "deposits":
        raw_margin = d["shares"] / own_derivative
    else:
        raw_margin = -d["shares"] / own_derivative
    # The maintained reporting rule is based on the implied economic object:
    # retain finite, nonnegative markups/markdowns. Demand estimation itself
    # continues to use every product; this rule only defines the observations
    # used for margin summaries and downstream margin regressions.
    d["structural_margin"] = np.where(
        np.isfinite(raw_margin) & (raw_margin >= 0), raw_margin, np.nan
    )
    d["retained_nonnegative_margin"] = d["structural_margin"].notna()

    beta = dict(zip(results.beta_labels, np.ravel(results.beta)))
    beta_se = dict(zip(results.beta_labels, np.ravel(results.beta_se)))
    nonag_alpha = float(beta["prices"])
    ag_alpha = float(beta["prices"] + beta["ag_rate"])
    # pyblp does not expose the concentrated beta covariance block separately.
    # Report a conservative upper bound for the SE of beta_price + beta_ag by
    # adding their marginal SEs (the Cauchy-Schwarz worst case).
    ag_se_upper_bound = float(beta_se["prices"] + beta_se["ag_rate"])

    rows = []
    for bank_type, group in d.groupby("agricultural_bank"):
        alpha = ag_alpha if bank_type == 1 else nonag_alpha
        alpha_se = ag_se_upper_bound if bank_type == 1 else beta_se["prices"]
        margin = group["structural_margin"]
        rows.append({
            "market": market,
            "bank_type": "ag_banks" if bank_type == 1 else "nonag_banks",
            "observations": len(group),
            "banks": group["cert"].nunique(),
            "mean_rate_coefficient": alpha,
            "mean_rate_coefficient_se": alpha_se,
            "ag_interaction_coefficient": float(beta["ag_rate"]),
            "ag_interaction_se": float(beta_se["ag_rate"]),
            "random_rate_sd_price": float(results.sigma[0, 0]),
            "random_rate_sd_ag_interaction": float(results.sigma[1, 1]),
            "valid_margin_observations": int(margin.notna().sum()),
            "excluded_negative_or_undefined_margins": int(margin.isna().sum()),
            "mean_structural_margin": float(margin.mean()),
            "median_structural_margin": float(margin.median()),
            "gmm_objective": float(results.objective),
            "converged": bool(results.converged),
        })
    pooled_margin = d["structural_margin"]
    pooled_alpha = float(np.average(
        np.where(d["agricultural_bank"].to_numpy() == 1, ag_alpha, nonag_alpha)
    ))
    rows.append({
        "market": market,
        "bank_type": "all_banks_pooled",
        "observations": len(d),
        "banks": d["cert"].nunique(),
        "mean_rate_coefficient": pooled_alpha,
        "mean_rate_coefficient_se": np.nan,
        "ag_interaction_coefficient": float(beta["ag_rate"]),
        "ag_interaction_se": float(beta_se["ag_rate"]),
        "random_rate_sd_price": float(results.sigma[0, 0]),
        "random_rate_sd_ag_interaction": float(results.sigma[1, 1]),
        "valid_margin_observations": int(pooled_margin.notna().sum()),
        "excluded_negative_or_undefined_margins": int(pooled_margin.isna().sum()),
        "mean_structural_margin": float(pooled_margin.mean()),
        "median_structural_margin": float(pooled_margin.median()),
        "gmm_objective": float(results.objective),
        "converged": bool(results.converged),
    })
    output_name = f"{market}_summary.csv"
    pd.DataFrame(rows).to_csv(table_root / output_name, index=False)
    d[["cert", "year", "bank_name", "agricultural_bank", "shares", "prices",
       "own_rate_derivative", "economically_valid_slope",
       "retained_nonnegative_margin", "structural_margin"]].to_parquet(
           data_out / f"{market}_bank_year.parquet", index=False
       )


if __name__ == "__main__":
    requested = sys.argv[1:] or ["ag_production", "deposits"]
    for requested_market in requested:
        estimate(requested_market)


