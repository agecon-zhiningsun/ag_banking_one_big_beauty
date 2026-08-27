"""Full random-coefficient BLP with same-type Gandhi-Houde instruments.

Main study period: 1994-2025. Raw and processed data remain outside Git.
"""
from __future__ import annotations

import hashlib
import json
import pickle
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pyblp
from scipy.stats import chi2


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
CACHE_VERSION = "2026-08-26-gh-cross-characteristics-v3"


def prepare(market: str) -> pd.DataFrame:
    d = pd.read_parquet(INPUT)
    d = d.loc[d["year"].between(1994, 2025) & d["agricultural_bank"].isin([0, 1])].copy()
    if market == "ag_production":
        d["prices"] = d["ag_production_loan_rate"]
        d["shares"] = d["ag_production_share"]
        positive_balance = d["lnag"] > 0
    elif market == "total_loans":
        d["prices"] = d["loan_rate"]
        d["shares"] = d["loan_share"]
        positive_balance = d["lnlsgr"] > 0
    elif market == "deposits":
        d["prices"] = d["deposit_rate"]
        d["shares"] = d["deposit_share"]
        positive_balance = d["dep"] > 0
    else:
        raise ValueError(market)

    required = ["prices", "shares", "log_branches", "log_employees_per_branch"]
    finite = np.logical_and.reduce([np.isfinite(d[c]) for c in required])
    d = d.loc[positive_balance & finite & (d["quarters_observed"] == 4) &
              (d["prices"] > 0) &
              (d["prices"] <= 0.50) & (d["shares"] > 0)].copy()
    d["market_ids"] = d["year"].astype(int)
    # Demand shocks can be serially correlated within banks. Wang et al. cluster
    # their structural parameter estimates at the bank level, so use CERT rather
    # than the 32 year-markets as the clustering identifier.
    d["clustering_ids"] = d["cert"].astype(str)
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
        gh_formulation, gh_data, version="quadratic", interact=True
    )
    ag = d["agricultural_bank"].to_numpy(dtype=float)[:, None]
    nonag = 1.0 - ag
    # The first half of pyblp's columns summarize same-firm products and are
    # identically zero because each CERT offers one product per year. The second
    # half contains rival-product quadratic distances, including the requested
    # cross-characteristic term when interact=True. Keep separate blocks for
    # agricultural and non-agricultural banks. No cost shifters enter this
    # maintained GH-only specification.
    rival_gh = gh[:, gh.shape[1] // 2:]
    excluded = np.column_stack([rival_gh * ag, rival_gh * nonag])
    for column, values in enumerate(excluded.T):
        d[f"demand_instruments{column}"] = values
    return d


def estimate(market: str) -> None:
    d = prepare(market)
    table_root = TABLE_ROOT
    data_out = DATA_OUT
    table_root.mkdir(parents=True, exist_ok=True)
    data_out.mkdir(parents=True, exist_ok=True)
    # Mean coefficients and heterogeneity can differ by bank type. Write the
    # interaction symbolically so pyblp recognizes it as endogenous and does not
    # automatically add price times bank type to the instrument matrix.
    x1 = pyblp.Formulation(
        "0 + prices + I(prices * agricultural_bank) + log_branches + log_employees_per_branch",
        absorb="C(cert) + C(year)",
    )
    x2 = pyblp.Formulation("0 + prices + I(prices * agricultural_bank)")
    integration = pyblp.Integration("halton", size=20, specification_options={"seed": 20260816})
    problem = pyblp.Problem((x1, x2), d, integration=integration)

    fingerprint_columns = [
        "cert", "year", "prices", "ag_rate", "shares", "log_branches",
        "log_employees_per_branch", "agricultural_bank",
        *[c for c in d if c.startswith("demand_instruments")],
    ]
    hashed = pd.util.hash_pandas_object(
        d[fingerprint_columns], index=False
    ).to_numpy().tobytes()
    fingerprint = hashlib.sha256(CACHE_VERSION.encode() + hashed).hexdigest()

    # A diagonal starting value lets the data estimate separate rate heterogeneity
    # without imposing the sign of either mean demand slope.
    sigma0 = np.diag([5.0, 5.0])
    optimization = pyblp.Optimization("l-bfgs-b", {"gtol": 1e-5, "maxiter": 500})
    iteration = pyblp.Iteration("squarem", {"atol": 1e-12})
    cache_path = data_out / f"{market}_problem_results.pkl"
    metadata_path = data_out / f"{market}_problem_results.json"
    cache_valid = False
    if cache_path.exists() and metadata_path.exists():
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        cache_valid = metadata.get("fingerprint") == fingerprint
    if cache_valid:
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
        metadata_path.write_text(json.dumps({
            "cache_version": CACHE_VERSION,
            "fingerprint": fingerprint,
            "observations": len(d),
            "markets": int(d["year"].nunique()),
            "pyblp_version": pyblp.__version__,
        }, indent=2), encoding="utf-8")

    price_jacobians = results.compute_demand_jacobians(name="prices")
    own_derivative = np.empty(len(d))
    cursor = 0
    for _, group in d.groupby("market_ids", sort=True):
        count = len(group)
        price_matrix = price_jacobians[cursor:cursor + count, :count]
        own_derivative[cursor:cursor + count] = np.diag(price_matrix)
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
    interaction_label = next(
        label for label in results.beta_labels if "agricultural_bank" in label
    )
    nonag_alpha = float(beta["prices"])
    ag_alpha = float(beta["prices"] + beta[interaction_label])
    beta_covariance = (
        results.parameter_covariances[-len(results.beta_labels):,
                                      -len(results.beta_labels):] /
        results.problem.N
    )
    price_index = results.beta_labels.index("prices")
    ag_index = results.beta_labels.index(interaction_label)
    ag_se = float(np.sqrt(
        beta_covariance[price_index, price_index] +
        beta_covariance[ag_index, ag_index] +
        2 * beta_covariance[price_index, ag_index]
    ))

    rows = []
    hansen_statistic = float(results.run_hansen_test())
    hansen_df = int(results.problem.MD - results.parameters.size)
    hansen_p_value = float(chi2.sf(hansen_statistic, hansen_df)) if hansen_df > 0 else np.nan
    sigma_at_zero_boundary = bool(np.any(np.diag(results.sigma) <= 1e-8))
    weighting_matrix_condition_number = float(np.linalg.cond(results.W))
    parameter_covariance_condition_number = float(
        np.linalg.cond(results.parameter_covariances)
    )
    for bank_type, group in d.groupby("agricultural_bank"):
        alpha = ag_alpha if bank_type == 1 else nonag_alpha
        alpha_se = ag_se if bank_type == 1 else beta_se["prices"]
        margin = group["structural_margin"]
        rows.append({
            "market": market,
            "bank_type": "ag_banks" if bank_type == 1 else "nonag_banks",
            "observations": len(group),
            "banks": group["cert"].nunique(),
            "years": group["year"].nunique(),
            "simulation_draws_per_market": 20,
            "excluded_gh_instruments": len([c for c in d if c.startswith("demand_instruments")]),
            "mean_rate_coefficient": alpha,
            "mean_rate_coefficient_se": alpha_se,
            "ag_interaction_coefficient": float(beta[interaction_label]),
            "ag_interaction_se": float(beta_se[interaction_label]),
            "random_rate_sd_price": float(results.sigma[0, 0]),
            "random_rate_sd_ag_interaction": float(results.sigma[1, 1]),
            "valid_margin_observations": int(margin.notna().sum()),
            "excluded_negative_or_undefined_margins": int(margin.isna().sum()),
            "mean_structural_margin": float(margin.mean()),
            "median_structural_margin": float(margin.median()),
            "p10_structural_margin": float(margin.quantile(0.10)),
            "p90_structural_margin": float(margin.quantile(0.90)),
            "gmm_objective": float(np.asarray(results.objective).item()),
            "converged": bool(results.converged),
            "hansen_statistic": hansen_statistic,
            "hansen_df": hansen_df,
            "hansen_p_value": hansen_p_value,
            "sigma_at_zero_boundary": sigma_at_zero_boundary,
            "weighting_matrix_condition_number": weighting_matrix_condition_number,
            "parameter_covariance_condition_number": parameter_covariance_condition_number,
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
        "years": d["year"].nunique(),
        "simulation_draws_per_market": 20,
        "excluded_gh_instruments": len([c for c in d if c.startswith("demand_instruments")]),
        "mean_rate_coefficient": pooled_alpha,
        "mean_rate_coefficient_se": np.nan,
        "ag_interaction_coefficient": float(beta[interaction_label]),
        "ag_interaction_se": float(beta_se[interaction_label]),
        "random_rate_sd_price": float(results.sigma[0, 0]),
        "random_rate_sd_ag_interaction": float(results.sigma[1, 1]),
        "valid_margin_observations": int(pooled_margin.notna().sum()),
        "excluded_negative_or_undefined_margins": int(pooled_margin.isna().sum()),
        "mean_structural_margin": float(pooled_margin.mean()),
        "median_structural_margin": float(pooled_margin.median()),
        "p10_structural_margin": float(pooled_margin.quantile(0.10)),
        "p90_structural_margin": float(pooled_margin.quantile(0.90)),
        "gmm_objective": float(np.asarray(results.objective).item()),
        "converged": bool(results.converged),
        "hansen_statistic": hansen_statistic,
        "hansen_df": hansen_df,
        "hansen_p_value": hansen_p_value,
        "sigma_at_zero_boundary": sigma_at_zero_boundary,
        "weighting_matrix_condition_number": weighting_matrix_condition_number,
        "parameter_covariance_condition_number": parameter_covariance_condition_number,
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


