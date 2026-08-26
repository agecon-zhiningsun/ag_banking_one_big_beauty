# Model and estimation notes

## 1. BLP-style deposit demand

For bank product \(j\) in local market \(m\) and year \(t\), depositor \(i\)'s utility is

\[
u_{ijmt}=x_{jmt}'\beta-\alpha p_{jmt}+\xi_{jmt}+\mu_{ijmt}+\varepsilon_{ijmt},
\]

where \(p\) is a price-like deposit measure (for example, fees minus the deposit rate), \(x\) contains branch access and bank characteristics, \(\xi\) is unobserved quality, and \(\mu\) permits random coefficients. The repository baseline sets \(\mu=0\), giving simple logit shares

\[
s_{jmt}=\frac{\exp(\delta_{jmt})}{1+\sum_k\exp(\delta_{kmt})}.
\]

For logit demand, the price derivative is

\[
\frac{\partial s_j}{\partial p_k}=-\alpha s_j(\mathbf{1}\{j=k\}-s_k).
\]

Let \(\Omega_{jk}=1\) if products \(j\) and \(k\) have the same owner. Define \(\Delta=-\Omega\odot(\partial s/\partial p)'\). The multiproduct pricing first-order conditions imply

\[
p-mc=\Delta^{-1}s.
\]

The code reports implied markups, marginal costs, and Lerner indices. In an empirical application, estimate \((\alpha,\beta)\) using excluded cost or rival-characteristic instruments; do not treat the calibrated synthetic \(\alpha\) as an estimate.

## 2. Dynamic bank problem (Bellman equation)

Let the state be \(z_{jmt}=(b_{jmt},d_{jmt},\ell_{jmt},k_{jt},a_{jt},q_{mt})\): branches, deposits, loans, capital, bank productivity, and local demand conditions. A bank chooses deposit price \(p^d\), loan price \(p^\ell\), branch investment \(I\), and exit \(e\). A useful recursive formulation is

\[
V_j(z_t)=\max_{p^d_j,p^\ell_j,I_j,e_j}
\left\{\pi_j(z_t,p^d_j,p^\ell_j)-C_I(I_j)-e_j C_E
+\beta\,\mathbb E\left[V_j(z_{t+1})\mid z_t,p^d_j,p^\ell_j,I_j,e_j\right]\right\},
\]

subject to

\[
d_{jmt}=M_{mt}s_{jmt}(p^d_t,x_t,\xi_t),\qquad
b_{jm,t+1}=(1-\delta_b)b_{jmt}+I_{jmt},
\]

\[
k_{j,t+1}=k_{jt}+\pi_{jt}-\text{dividends}_{jt},\qquad
k_{jt}\geq \kappa\,\text{RWA}_{jt},
\]

plus balance-sheet feasibility. One profit mapping is

\[
\pi_{jt}=r^\ell_{jt}\ell_{jt}-r^d_{jt}d_{jt}-C(d_{jt},\ell_{jt},b_{jt},a_{jt})-\text{losses}_{jt}.
\]

The static BLP estimates identify deposit-demand substitution and implied deposit-side margins. The dynamic layer additionally requires transition processes, investment/adjustment costs, loan demand, credit losses, and regulatory constraints. Estimation could use two-step CCP methods, simulated method of moments, or a nested fixed point, depending on the counterfactual.

## 3. Main identification risks

- Deposit rates or fees correlate with unobserved bank quality.
- Market size and the outside option determine levels of inferred demand.
- Branches and product availability are endogenous entry/investment choices.
- Bank × market observations must be aggregated consistently across mergers.
- Deposit and loan margins should not be conflated without balance-sheet costs.

