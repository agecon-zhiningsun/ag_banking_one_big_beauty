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

- The latest code clusters by bank, not by 32 annual markets.
- It uses 20 simulation draws per market and same-type Gandhi–Houde quadratic differentiation instruments.
- It now records years, excluded instruments, margin quantiles, Hansen diagnostics, boundary status and matrix condition numbers.
- Current agricultural-production estimates converge, but the Hansen test rejects at conventional levels (`p = 0.0113`) and numerical conditioning is weak. The implied margins must remain provisional.
- Required next checks: rescale characteristics/instruments; reduce or regularize the instrument set; report first-stage relevance; compare national and local deposit markets; test parent-level clustering; vary simulation draws; and report weak-identification-robust intervals.

### Bellman model

- The state/action logic follows Wang et al.: banks set loan and deposit rates, manage securities and wholesale funding, satisfy reserve/capital constraints, absorb defaults, and evolve equity.
- Expected competitor rates are iterated to a fixed point, following the paper's low-dimensional Krusell–Smith approximation.
- The current code solves a discretized dynamic problem and reports a Bellman residual, feasibility and equilibrium gap.
- It does **not** yet reproduce the paper's full SMD estimator. Several parameters remain initial values, statutory inputs, descriptive estimates or policy-stress calibrations.
- Before publication-quality counterfactuals, implement the SMD objective, data/model moments, weighting matrix, standard errors, and parameter-recovery tests.

## Recommended empirical sequence

1. Stabilize and validate the BLP demand system.
2. Estimate agricultural default and farm-income transition processes.
3. Implement SMD moments patterned on Wang et al. Table 4, augmented with agricultural-bank/FCS moments.
4. Validate baseline fit before any policy experiment.
5. Run friction-removal experiments and policy counterfactuals with uncertainty bands.

