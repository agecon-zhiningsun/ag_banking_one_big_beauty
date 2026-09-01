# Structural model

## BLP demand and market power

Each year is a national product market. Bank `j`'s indirect utility is

\[
u_{ijt}=x_{jt}'\beta+\alpha_i r_{jt}+\xi_{jt}+\varepsilon_{ijt},
\qquad \alpha_i=\bar\alpha+\sigma_\alpha\nu_i.
\]

The cleaned final estimator covers deposits, total loans, and agricultural-production loans. The primary specification follows Wang et al.: salary expense/assets and premises expense/assets instrument rates, while log branches and log employees per branch enter demand with bank and year fixed effects. An all-rival-characteristics differentiation-instrument specification is retained as robustness. Random rate heterogeneity is used for deposits; loan demand uses homogeneous rate sensitivity, matching Wang et al.

For ownership matrix `Ω` and share Jacobian `J`, implied margins solve

\[
m_t=-(\Omega_t\odot J_t')^{-1}s_t.
\]

The compact final results are in `output/tables/04a_blp/04a_final_blp_summary.csv`. Detailed bank-year estimates remain in the external processed-data store. The primary median margins are 0.161 percentage points for deposits, 1.009 percentage points for total loans, and 1.560 percentage points for agricultural-production loans.

## Bellman equation

Let the bank state contain legacy loans, equity, aggregate funding and farm-income states, expected competitor rates, bank type, and other balance-sheet conditions:

\[
z_t=(L_t,E_t,f_t,q_t,r^L_{-j,t},r^D_{-j,t},a_j).
\]

Following equation (24) in Wang et al., the bank chooses its loan rate, deposit rate, government securities, non-reservable borrowing, reserves, and dividends. New loans and deposits follow estimated demand; reserves, securities and wholesale funding close the balance sheet. The recursive problem is

\[
V_j(z_t)=\max_{r^L_{jt},r^D_{jt},G_{jt},N_{jt},R_{jt},C_{j,t+1}}
\left\{C_{j,t+1}
+\frac{1}{1+\rho}\,
\mathbb E[V_j(z_{t+1})\mid z_t,\text{choices}_{jt}]\right\},
\]

subject to demand, balance-sheet feasibility, loan maturity/default, retained-earnings evolution, capital and reserve requirements, and nonnegative funding quantities. The aggregate farm state shifts agricultural loan demand and expected agricultural charge-offs.

A compact profit mapping is

\[
\pi_{jt}=r^L_{jt}L_{jt}+r^S_tS_{jt}
-r^D_{jt}Dep_{jt}-r^W_tW_{jt}
-C(L_{jt},Dep_{jt},a_j)-Loss_{jt}-Tax_{jt}.
\]

Expected competitor loan and deposit rates are iterated to a fixed point. The implementation reports the equilibrium gap, Bellman residual, feasibility share, balance-sheet error, and capital-constraint violations.

## Interpretation

The BLP table is an empirical model output. The current R dynamic program solves
a discretized Wang-style Bellman problem. `04k_estimate_wang_smd_bellman.R`
now implements two-stage SMD: each objective evaluation resolves the Bellman
problem and competitor-rate fixed point, the second stage uses a clustered-bank
bootstrap moment covariance matrix, and numerical derivatives feed sandwich
inference. The agricultural adaptation replaces market-to-book, which is not
observed for most private agricultural banks, with observed balance-sheet and
profitability moments. The loan state is total loans; the farm-policy shock
applies only to the agricultural-loan component.

The September 1, 2026 correction uses the updated total-loan BLP system for the
whole balance sheet and the agricultural-production-loan BLP system for the
farmer-facing component. Observed outstanding loans equal `L+B`; the legacy
state is therefore `(1-mu)` times the observed stock and stationary originations
are `mu` times the stock. Existing coupons follow Wang's present-value
cash-flow convention rather than being counted again as current originations.

The two-stage SMD estimate passes the declared economic moment-fit gate. The
strict relative Bellman residual is below `1e-8`; policy-scenario fixed-point
gaps are below `5e-4`; feasibility is 100 percent on a 360-state grid. BLP
spreads and historical credit sensitivity are validation/calibration moments,
while dividends, wholesale funding, deposits/assets, operating costs, leverage,
and loans/deposits identify the dynamic block.
