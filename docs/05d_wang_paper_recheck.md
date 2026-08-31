# Recheck against Wang, Whited, Wu, and Xiao

Reference: Yifei Wang, Toni M. Whited, Yufeng Wu, and Kairong Xiao, *Bank Market Power and Monetary Policy Transmission: Evidence from a Structural Estimation*, SSRN 3049665, May 19, 2020.

## What the reference study does

Wang et al. estimate a dynamic banking model with imperfect deposit and loan competition, capital and reserve regulation, costly non-reservable borrowing, long-term loans, defaults, and endogenous bank equity. Their sample combines quarterly Call Reports with annual FDIC Summary of Deposits for 1994–2017.

Estimation is sequential:

1. Estimate national annual loan and deposit demand using BLP/Nevo methods.
2. Plug demand into the dynamic bank problem.
3. Estimate seven cost/friction parameters by simulated minimum distance using ten moments.
4. Remove one friction at a time in counterfactuals.

Their Table 5 attributes 35.91% of loan sensitivity to the federal-funds rate to deposit market power, 27.65% to capital regulation, 7.88% to reserve regulation, and -23.39% to loan market power. Their central nonlinear result is a reversal below a federal-funds-rate threshold near 0.9%: further easing can reduce lending because deposit margins and bank capital are compressed.

## Mapping to this repository

| Wang et al. | Agricultural-bank update |
|---|---|
| All commercial-bank loans | Agricultural-production loans, plus total loans as a benchmark |
| Cash/bonds and nonbank credit outside options | FCS, USDA/FSA credit, trade credit, captive finance and no borrowing |
| Aggregate federal-funds and default states | Federal-funds rate, farm income/commodity state, agricultural charge-offs and policy-support state |
| Representative large/small banks | Agricultural versus non-agricultural banks, with size heterogeneity retained where possible |
| 1994–2017 | 1994–2025, with a post-2025 policy extension |
| Generic monetary-policy counterfactuals | Joint monetary-policy, farm-downturn and One Big Beautiful Bill counterfactuals |

## Recheck findings

### Data

- The project correctly uses each year as a national market, consistent with Wang et al.'s main specification.
- The latest panel requires all four Call Report quarters before forming a bank-year product.
- Outside-option construction is decisive. Agricultural credit requires explicit FCS and government-credit components rather than treating all nonbank borrowing as homogeneous.
- Bank identity must follow charter and merger histories. `CERT` is used for firm and inference clustering, but parent-level robustness remains necessary.

### BLP

- The cleaned primary specification now follows Wang et al. directly, using salary and premises cost shifters as excluded instruments.
- Deposits retain random rate heterogeneity; the two loan markets use homogeneous rate sensitivity, as in Wang et al.
- The all-rival-characteristics differentiation-instrument specification is retained as robustness rather than treated as the maintained model.
- The final primary median margins are 0.161 percentage points for deposits, 1.009 percentage points for total loans, and 1.560 percentage points for agricultural-production loans.
- Total agricultural loans are not assigned a BLP markup because Call Reports lack a matching total-agricultural-loan interest-income rate.
- Required next checks include first-stage reporting, parent-level clustering, national-versus-local deposit demand, alternative outside-option construction, and weak-identification-robust inference.

### Bellman model

- The state/action logic follows Wang et al.: banks set loan and deposit rates, manage securities and wholesale funding, satisfy reserve/capital constraints, absorb defaults, and evolve equity.
- Expected competitor rates are iterated to a fixed point, following the paper's low-dimensional Krusell–Smith approximation.
- The current code solves a discretized dynamic problem and reports a Bellman residual, feasibility and equilibrium gap.
- A two-stage agricultural-bank SMD estimator is now implemented in `04k_estimate_wang_smd_bellman.R`. It uses 11 moments, seven parameters, clustered-bank bootstrap weighting, numerical Jacobians, and sandwich inference; every objective evaluation resolves the Bellman and pricing equilibrium.
- The completed estimate is numerically converged but empirically rejected by the overidentifying moment fit. It must not be used as a policy result. The largest misses are ROA, leverage, loan/deposit, payout, and noninterest cost.
- The cleaned audit rejects the old perfect-competition output because demand slopes were multiplied by 100. A correct comparison must constrain the loan rate to risk-adjusted marginal cost and re-solve.
- The proposed risk-only/franchise decomposition is not identified until an agricultural-franchise adjustment cost is added and estimated.
- Before publication-quality counterfactuals, respecify the accounting/profit block, add parameter-recovery tests, and pass a preregistered moment-fit gate; the present counterfactual files are explicitly tagged as rejected diagnostics.

## Recommended empirical sequence

1. Stabilize and validate the BLP demand system.
2. Estimate agricultural default and farm-income transition processes.
3. Implement SMD moments patterned on Wang et al. Table 4, augmented with agricultural-bank/FCS moments.
4. Validate baseline fit before any policy experiment.
5. Run friction-removal experiments and policy counterfactuals with uncertainty bands.
