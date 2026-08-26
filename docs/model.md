# Structural model

## BLP demand and market power

Each year is a national product market. Bank `j`'s indirect utility is

\[
u_{ijt}=x_{jt}'\beta+\alpha_i r_{jt}+\xi_{jt}+\varepsilon_{ijt},
\qquad \alpha_i=\bar\alpha+\sigma_\alpha\nu_i.
\]

The maintained agricultural-production/deposit specification uses random coefficients and same-type Gandhi–Houde differentiation instruments. Bank type is agricultural versus non-agricultural. The estimation code performs the BLP contraction, IV/GMM estimation, share-derivative construction, and recovery of structural margins from the supply first-order conditions.

For ownership matrix `Ω` and share Jacobian `J`, implied margins solve

\[
m_t=-(\Omega_t\odot J_t')^{-1}s_t.
\]

The compact empirical results are in `output/tables/blp_market_power/`. Detailed bank-year estimates remain in the external processed-data store.

## Bellman equation

Let the bank state contain legacy loans, equity, aggregate funding and farm-income states, expected competitor rates, bank type, and other balance-sheet conditions:

\[
z_t=(L_t,E_t,f_t,q_t,r^L_{-j,t},r^D_{-j,t},a_j).
\]

The bank chooses its loan rate, deposit rate, and dividends. New loans and deposits follow estimated demand; reserves, securities and wholesale funding close the balance sheet. The recursive problem is

\[
V_j(z_t)=\max_{r^L_{jt},r^D_{jt},D_{jt}}
\left\{\pi_j(z_t,r^L_{jt},r^D_{jt},D_{jt})
+\frac{1}{1+\rho}\,
\mathbb E[V_j(z_{t+1})\mid z_t,r^L_{jt},r^D_{jt},D_{jt}]\right\},
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

The BLP table is an empirical model output. The downturn policy table is currently illustrative, not a final estimated counterfactual. That distinction is retained in every tracked output.

