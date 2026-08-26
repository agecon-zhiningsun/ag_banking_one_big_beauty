"""Reproducible BLP/logit market-power baseline using synthetic bank data."""

from pathlib import Path

import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
ALPHA = 1.35  # calibrated price sensitivity; replace with an IV/BLP estimate


def simulate_panel(seed: int = 2026) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    rows = []
    owners = {"Bank_A_1": "Bank_A", "Bank_A_2": "Bank_A", "Bank_B": "Bank_B", "Bank_C": "Bank_C"}
    for year in (2022, 2023, 2024):
        for market in ("north", "south", "west"):
            quality = rng.normal(0, 0.18, len(owners))
            price = rng.uniform(1.50, 2.50, len(owners))
            branches = rng.integers(2, 13, len(owners))
            delta = -0.35 + 0.09 * branches - ALPHA * price + quality
            exp_delta = np.exp(delta)
            shares = exp_delta / (1 + exp_delta.sum())
            for idx, product in enumerate(owners):
                rows.append({
                    "market_id": market,
                    "year": year,
                    "product_id": product,
                    "owner_id": owners[product],
                    "price": price[idx],
                    "branches": branches[idx],
                    "share": shares[idx],
                })
    return pd.DataFrame(rows)


def recover_market_power(group: pd.DataFrame) -> pd.DataFrame:
    group = group.copy().reset_index(drop=True)
    shares = group["share"].to_numpy()
    derivative = -ALPHA * (np.diag(shares) - np.outer(shares, shares))
    ownership = (group["owner_id"].to_numpy()[:, None] == group["owner_id"].to_numpy()[None, :]).astype(float)
    delta = -(ownership * derivative.T)
    markups = np.linalg.solve(delta, shares)
    group["markup"] = markups
    group["marginal_cost"] = group["price"] - markups
    group["lerner_index"] = markups / group["price"]
    group["outside_share"] = 1 - shares.sum()
    group["hhi"] = 10_000 * np.square(shares).sum()
    return group


def main() -> None:
    panel = simulate_panel()
    recovered = []
    for (market_id, year), group in panel.groupby(["market_id", "year"], sort=False):
        market_results = recover_market_power(group.drop(columns=["market_id", "year"]))
        market_results.insert(0, "year", year)
        market_results.insert(0, "market_id", market_id)
        recovered.append(market_results)
    results = pd.concat(recovered, ignore_index=True)
    summary = pd.DataFrame({
        "statistic": ["mean_markup", "median_markup", "mean_lerner_index", "mean_hhi", "mean_outside_share", "observations"],
        "value": [results.markup.mean(), results.markup.median(), results.lerner_index.mean(), results.hhi.mean(), results.outside_share.mean(), len(results)],
    })
    (ROOT / "data" / "processed").mkdir(parents=True, exist_ok=True)
    (ROOT / "results").mkdir(parents=True, exist_ok=True)
    panel.to_csv(ROOT / "data" / "processed" / "synthetic_bank_market_panel.csv", index=False)
    results.to_csv(ROOT / "results" / "blp_product_results.csv", index=False)
    summary.to_csv(ROOT / "results" / "blp_market_power_summary.csv", index=False)
    print(summary.to_string(index=False))


if __name__ == "__main__":
    main()
