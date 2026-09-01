source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
})

# Full Wang-style balance-sheet Bellman problem adapted to agricultural credit.
# The implementation follows Wang et al. equations (10)-(26): banks choose loan
# and deposit rates and dividends; demand determines new loans and deposits;
# reserves, securities, and wholesale funding close the balance sheet; loans
# mature; defaults reduce profits; retained earnings evolve equity; and expected
# competitor rates are iterated to a fixed point. The additional aggregate farm
# state shifts agricultural loan demand and expected agricultural charge-offs.

input_path <- file.path(
  data_root, "processed", "nc1177", "dynamic_bank_model",
  "03a_bank_year_dynamic_model_inputs_1994_2025.parquet"
)
external_dir <- file.path(data_root, "processed", "nc1177", "dynamic_bank_model")
table_dir <- file.path("output", "tables", "04i_dynamic_model")
dir.create(external_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(input_path)) stop("Run code/03_construct/03a_construct_dynamic_bank_model_inputs.R first.")

x <- as.data.table(read_parquet(input_path))
x <- x[
  agricultural_bank %in% 0:1 & is.finite(funding_rate) &
    is.finite(net_chargeoff_rate) & is.finite(total_loan_ratio) &
    is.finite(ag_production_loan_ratio) &
    is.finite(blp_total_share) & is.finite(blp_total_rate) &
    is.finite(total_own_rate_derivative) &
    is.finite(capital_ratio) & is.finite(deposit_asset_ratio)
]

clip <- function(z, lo, hi) pmin(pmax(z, lo), hi)
qgrid <- function(z, p) unique(as.numeric(quantile(z[is.finite(z)], p, na.rm = TRUE)))
nearest <- function(z, grid) which.min(abs(grid - z))
linear_weights <- function(z, grid) {
  if (z <= grid[1L]) return(list(index = 1L, weight = 1))
  if (z >= grid[length(grid)]) return(list(index = length(grid), weight = 1))
  upper <- which(grid >= z)[1L]
  lower <- upper - 1L
  upper_weight <- (z - grid[lower]) / (grid[upper] - grid[lower])
  list(index = c(lower, upper), weight = c(1 - upper_weight, upper_weight))
}
bilinear_value <- function(value_matrix, l_value, e_value) {
  lw <- linear_weights(l_value, l_grid)
  ew <- linear_weights(e_value, e_grid)
  out <- 0
  for (i in seq_along(lw$index)) for (j in seq_along(ew$index)) {
    out <- out + lw$weight[i] * ew$weight[j] *
      value_matrix[lw$index[i], ew$index[j]]
  }
  out
}
stationary_vector <- function(P) {
  p <- rep(1 / nrow(P), nrow(P))
  for (iter in seq_len(10000L)) {
    updated <- drop(p %*% P)
    if (max(abs(updated - p)) < 1e-14) break
    p <- updated
  }
  p / sum(p)
}
safe_median <- function(z, fallback) {
  out <- median(z[is.finite(z)], na.rm = TRUE)
  if (is.finite(out)) out else fallback
}

# Empirical transition matrices, with Jeffreys smoothing.
transition_matrix <- function(dt, state_name, nstate) {
  tmp <- copy(dt)
  setorder(tmp, cert, year)
  tmp[, next_state__ := shift(get(state_name), type = "lead"), by = cert]
  counts <- tmp[!is.na(next_state__), .N, by = c(state_name, "next_state__")]
  setnames(counts, state_name, "state__")
  full <- merge(
    CJ(state__ = seq_len(nstate), next_state__ = seq_len(nstate)), counts,
    by = c("state__", "next_state__"), all.x = TRUE
  )
  full[is.na(N), N := 0]
  full[, probability := (N + 0.5) / sum(N + 0.5), by = state__]
  matrix(full$probability, nrow = nstate, byrow = TRUE)
}

# Discretized aggregate and bank states: f, delta, farm income, L, E.
f_grid <- qgrid(x$funding_rate, c(1 / 3, 2 / 3))
d_grid <- qgrid(x$net_chargeoff_rate, c(1 / 3, 2 / 3))
maturity_rate <- 1 / 3.5
# In Wang, L is the legacy balance that survives into the origination date;
# the observed outstanding book is L+B. At stationarity, L=(1-mu)*stock and
# B=mu*stock. Using the observed stock directly as L double counts originations.
l_grid <- qgrid(
  (1 - maturity_rate) * x$total_loan_ratio,
  c(.05, .25, .50, .75, .95)
)
e_grid <- sort(unique(c(qgrid(x$capital_ratio, c(.20, .50, .80)), .18, .25, .35)))
if (any(lengths(list(f_grid, d_grid, l_grid, e_grid)) < c(2, 2, 2, 2))) {
  stop("Insufficient support for the Wang state grids.")
}
x[, `:=`(
  f_state = vapply(funding_rate, nearest, integer(1), grid = f_grid),
  d_state = vapply(net_chargeoff_rate, nearest, integer(1), grid = d_grid),
  l_state = vapply((1 - maturity_rate) * total_loan_ratio,
                   nearest, integer(1), grid = l_grid),
  e_state = vapply(capital_ratio, nearest, integer(1), grid = e_grid)
)]
P_f <- transition_matrix(x, "f_state", length(f_grid))
P_d <- transition_matrix(x, "d_state", length(d_grid))
P_z <- transition_matrix(x, "farm_state", 3L)

states <- CJ(
  f_state = seq_along(f_grid), d_state = seq_along(d_grid),
  farm_state = 1:3, l_state = seq_along(l_grid), e_state = seq_along(e_grid)
)
states[, state_id := .I]
state_index <- array(NA_integer_, dim = c(length(f_grid), length(d_grid), 3L,
                                          length(l_grid), length(e_grid)))
for (i in seq_len(nrow(states))) {
  state_index[states$f_state[i], states$d_state[i], states$farm_state[i],
              states$l_state[i], states$e_state[i]] <- states$state_id[i]
}

# Demand slopes come from the final BLP demand systems. Wang permits random
# coefficients in deposit demand and uses homogeneous loan-rate sensitivity in
# the dynamic stage. We retain ten deposit draws and the empirical median loan
# semi-elasticity for each bank type.
demand_by_type <- x[
  blp_total_share > 0 & blp_ag_share > 0 & blp_deposit_share > 0 &
    total_own_rate_derivative < 0 & own_rate_derivative < 0 &
    deposit_own_rate_derivative > 0,
  .(
    alpha_l = median(-total_own_rate_derivative / blp_total_share, na.rm = TRUE),
    alpha_ag = median(-own_rate_derivative / blp_ag_share, na.rm = TRUE),
    alpha_d = median(deposit_own_rate_derivative / blp_deposit_share, na.rm = TRUE),
    loan_share = median(blp_total_share, na.rm = TRUE),
    ag_share = median(blp_ag_share, na.rm = TRUE),
    deposit_share = median(blp_deposit_share, na.rm = TRUE),
    loan_rate = weighted.mean(blp_total_rate, pmax(total_loan_ratio, 1e-8), na.rm = TRUE),
    ag_loan_rate = weighted.mean(blp_ag_rate, pmax(ag_production_loan_ratio, 1e-8), na.rm = TRUE),
    ag_markup = median(blp_ag_markup, na.rm = TRUE),
    deposit_rate = weighted.mean(deposit_rate, pmax(deposit_asset_ratio, 1e-8), na.rm = TRUE),
    loan_ratio = median(total_loan_ratio, na.rm = TRUE),
    ag_loan_ratio = median(ag_production_loan_ratio, na.rm = TRUE),
    deposit_ratio = median(deposit_asset_ratio, na.rm = TRUE)
  ), by = agricultural_bank
]
rate_pass_by_type <- x[
  is.finite(blp_total_rate) & is.finite(deposit_rate) &
    is.finite(funding_rate) & is.finite(net_chargeoff_rate),
  {
    loan_fit <- lm(blp_total_rate ~ funding_rate + net_chargeoff_rate)
    deposit_fit <- lm(deposit_rate ~ funding_rate)
    .(
      loan_funding_pass_through = clip(unname(coef(loan_fit)["funding_rate"]), 0, 1.5),
      loan_default_pass_through = clip(unname(coef(loan_fit)["net_chargeoff_rate"]), 0, 1.5),
      deposit_funding_pass_through = clip(unname(coef(deposit_fit)["funding_rate"]), 0, 1.5)
    )
  }, by = agricultural_bank
]
demand_by_type <- merge(demand_by_type, rate_pass_by_type,
                        by = "agricultural_bank", all.x = TRUE)

# Seven bank-side parameters correspond to Wang's second-stage objects. Initial
# values are data-disciplined and are written explicitly; a separate SMD block
# below assesses their moment fit rather than silently treating them as known.
initial_loan_service_cost <- max(
  safe_median(x$blp_total_rate, 0.06) -
    safe_median(x$funding_rate, 0.02) -
    safe_median(x$net_chargeoff_rate, 0.005) -
    safe_median(x$blp_total_markup, 0.01),
  0.0005
)
initial_noninterest_cost <- safe_median(x$net_noninterest_cost_asset_ratio, 0.015)
initial_deposit_service_cost <- max(
  (initial_noninterest_cost -
    (initial_loan_service_cost - safe_median(x$net_chargeoff_rate, 0.005)) *
      safe_median(x$total_loan_ratio, 0.60) - 0.0005) /
    safe_median(x$deposit_asset_ratio, 0.80),
  0.0005
)
theta <- list(
  discount_rate = 0.045,
  wholesale_cost = 0.010,
  deposit_service_cost = 0.001,
  loan_service_cost = initial_loan_service_cost,
  fixed_operating_cost = 0.0005,
  wealth_to_loan_market = 0.92,
  no_borrow_quality = 0
)
theta_initial <- theta
estimated_parameter_path <- file.path(
  "output", "tables", "04k_smd_estimation", "04k_wang_smd_parameter_estimates.csv"
)
smd_moment_path <- file.path(
  "output", "tables", "04k_smd_estimation", "04k_wang_smd_moment_fit.csv"
)
smd_valid <- FALSE
if (file.exists(estimated_parameter_path)) {
  estimated_theta <- fread(estimated_parameter_path)
  estimated_theta <- estimated_theta[
    parameter %in% setdiff(names(theta), "no_borrow_quality") & is.finite(estimate)
  ]
  for (parameter_name in estimated_theta$parameter) {
    theta[[parameter_name]] <- estimated_theta[parameter == parameter_name, estimate][1L]
  }
  if (file.exists(smd_moment_path)) {
    smd_fit <- fread(smd_moment_path)
    fit_tolerance <- c(
      dividend_book_equity = .02, mean_wholesale_deposit = .02,
      deposit_assets = .02, noninterest_cost_assets = .003,
      leverage = 1, loan_deposit = .05
    )
    targeted_fit <- smd_fit[moment %in% names(fit_tolerance)]
    smd_valid <- nrow(targeted_fit) == length(fit_tolerance) &&
      all(is.finite(targeted_fit$model - targeted_fit$data)) &&
      all(abs(targeted_fit$model - targeted_fit$data) <=
        fit_tolerance[targeted_fit$moment])
  }
}
# The outside good is already normalized in each BLP demand system. Reestimating
# a second baseline outside-good intercept changes the first-stage shares and
# double counts that normalization. Only policy changes to the government-credit
# outside option enter the counterfactual.
theta$no_borrow_quality <- 0
statutory <- list(tax_rate = 0.35, capital_requirement = 0.06,
                  reserve_requirement = 0.03, maturity_rate = maturity_rate,
                  equity_issuance_cost = 0,
                  structural_wholesale_share = 0.032,
                  # A 9% operating target plus endogenous precautionary equity
                  # reproduces the observed aggregate 10.7% capital ratio.
                  management_capital_target = 0.09)

# Farm-income mechanisms estimated from the bank panel. The demand regression is
# descriptive and conditions on bank and year-scale observables; the model uses
# conservative clipped slopes to avoid extrapolation outside observed support.
farm_demand_fit <- lm(
  log(pmax(ag_production_loan_ratio, 1e-6)) ~ farm_downturn_state +
    funding_rate + capital_ratio + factor(agricultural_bank), data = x
)
farm_default_fit <- lm(
  net_chargeoff_rate ~ farm_downturn_state + funding_rate +
    factor(agricultural_bank), data = x
)
farm_demand_reduced_form <- -unname(coef(farm_demand_fit)["farm_downturn_state"])
farm_default_reduced_form <- unname(coef(farm_default_fit)["farm_downturn_state"])
# The historical aggregate coefficients have the opposite sign from the stress
# mechanism and do not identify a causal farm-income shock. The maintained
# policy experiment is therefore an explicit central stress calibration: a
# one-state deterioration lowers agricultural loan demand utility by 0.10 log
# point and raises expected charge-offs by 50 basis points.
farm_demand_loading <- 0.10
farm_default_loading <- 0.005

logit_share <- function(own_utility, rival_utility, outside_utility, competitors) {
  exp_own <- exp(clip(own_utility, -40, 40))
  exp_rival <- exp(clip(rival_utility, -40, 40))
  exp_own / (exp(clip(outside_utility, -40, 40)) + exp_own + competitors * exp_rival)
}

solve_type <- function(bank_type, theta, regime = "current_power",
                       policy_shock = list(
                         deposit_market_size_multiplier = 1,
                         loan_demand_utility_change = 0,
                         default_rate_multiplier = 1,
                         outside_credit_utility_change = 0
                       ), capital_requirement = statutory$capital_requirement,
                       max_equilibrium_iter = 4L, max_value_iter = 50L,
                       value_tolerance = 1e-4, equilibrium_tolerance = 5e-4) {
  dm <- demand_by_type[agricultural_bank == bank_type][1]
  if (!nrow(dm)) stop("Missing BLP demand slopes for bank type ", bank_type)
  J <- 6L
  competitors <- J - 1L
  beta <- 1 / (1 + theta$discount_rate)
  effective_capital_requirement <- max(
    capital_requirement, statutory$management_capital_target
  )
  if (regime != "current_power") stop("Only the current-market-power regime is supported.")
  alpha_l <- dm$alpha_l
  alpha_ag <- dm$alpha_ag
  # The micro BLP semi-elasticity combined with aggregate rate movements
  # overstates the historical aggregate credit/funding sensitivity. Scale the
  # aggregate state pass-through to the observed -10.3 versus the unscaled
  # model's -22.5; policy-specific BLP elasticities remain unchanged.
  state_pass_scale <- 0.30
  agricultural_exposure <- clip(dm$ag_loan_ratio / pmax(dm$loan_ratio, 1e-8), 0, 1)
  alpha_d_mean <- dm$alpha_d
  alpha_d_draws <- pmax(alpha_d_mean + seq(-1, 1, length.out = 10L) * 0.615, 1e-4)
  # BLP quantity is the outstanding loan stock, whereas B in Wang is the flow
  # of new originations. At a stationary loan stock, B = mu*L/(1-mu).
  target_new_loan_ratio <- statutory$maturity_rate * dm$loan_ratio
  target_new_ag_loan_ratio <- statutory$maturity_rate * dm$ag_loan_ratio
  loan_quality <- log(dm$loan_share / pmax(1 - J * dm$loan_share, 1e-8)) + alpha_l * dm$loan_rate
  ag_loan_quality <- log(dm$ag_share / pmax(1 - J * dm$ag_share, 1e-8)) +
    alpha_ag * dm$ag_loan_rate
  deposit_quality <- log(dm$deposit_share / pmax(1 - J * dm$deposit_share, 1e-8)) -
    alpha_d_mean * dm$deposit_rate

  pf <- stationary_vector(P_f)
  pd <- stationary_vector(P_d)
  pz <- stationary_vector(P_z)
  baseline_loan_share <- 0
  baseline_ag_share <- 0
  baseline_deposit_share <- 0
  for (fi in seq_along(f_grid)) for (di in seq_along(d_grid)) for (zi in 1:3) {
    weight <- pf[fi] * pd[di] * pz[zi]
    f0 <- f_grid[fi]
    farm0 <- c(-1, 0, 1)[zi]
    delta0 <- clip(d_grid[di] + agricultural_exposure *
      farm_default_loading * farm0, 0, statutory$maturity_rate)
    total_rate0 <- clip(
      dm$loan_rate + state_pass_scale * (
        dm$loan_funding_pass_through * (f0 - median(f_grid)) +
          dm$loan_default_pass_through * (delta0 - median(d_grid))
      ),
      f0 + delta0, 0.25
    )
    baseline_loan_share <- baseline_loan_share + weight * logit_share(
      loan_quality - alpha_l * total_rate0 - farm_demand_loading * farm0,
      loan_quality - alpha_l * total_rate0 - farm_demand_loading * farm0,
      0, competitors
    )
    baseline_ag_share <- baseline_ag_share + weight * logit_share(
      ag_loan_quality - alpha_ag * dm$ag_loan_rate - farm_demand_loading * farm0,
      ag_loan_quality - alpha_ag * dm$ag_loan_rate - farm_demand_loading * farm0,
      0, competitors
    )
    deposit_rate0 <- clip(dm$deposit_rate + state_pass_scale *
      dm$deposit_funding_pass_through * (f0 - median(f_grid)), 0, 0.20)
    baseline_deposit_share <- baseline_deposit_share + weight * mean(vapply(
      alpha_d_draws,
      function(a) logit_share(deposit_quality + a * deposit_rate0,
        deposit_quality + a * deposit_rate0, 0, competitors),
      numeric(1)
    ))
  }
  loan_market_size <- target_new_loan_ratio / pmax(baseline_loan_share, 1e-8)
  ag_loan_market_size <- target_new_ag_loan_ratio / pmax(baseline_ag_share, 1e-8)
  deposit_market_size <- dm$deposit_ratio / pmax(baseline_deposit_share, 1e-8) *
    theta$wealth_to_loan_market * policy_shock$deposit_market_size_multiplier

  rival_l <- matrix(dm$loan_rate, nrow = length(f_grid), ncol = 3L)
  rival_d <- matrix(dm$deposit_rate, nrow = length(f_grid), ncol = 3L)
  V <- numeric(nrow(states))
  policy <- vector("list", nrow(states))

  for (eq_iter in seq_len(max_equilibrium_iter)) {
    # Demand, current profits, accounting identities, and feasible next bank
    # states depend on the current competitor-rate conjecture but not on V.
    # Cache them once here; the inner value iteration then updates only E[V'].
    candidates <- vector("list", nrow(states))
    for (s in seq_len(nrow(states))) {
      st <- states[s]
      f <- f_grid[st$f_state]
      delta_base <- d_grid[st$d_state]
      farm_index <- c(-1, 0, 1)[st$farm_state]
      delta <- clip(
        delta_base + agricultural_exposure * farm_default_loading * farm_index,
        0, statutory$maturity_rate
      )
      delta <- clip(delta * (1 + agricultural_exposure *
        (policy_shock$default_rate_multiplier - 1)), 0, statutory$maturity_rate)
      L <- l_grid[st$l_state]
      E <- e_grid[st$e_state]
      # The first-stage BLP systems already estimate the current-market-power
      # pricing equilibrium. Reoptimizing rates inside the Bellman block would
      # apply market power twice. Retain the BLP markup and pass state-dependent
      # funding/default cost changes through the farmer and total-loan coupons.
      cost_shift <- state_pass_scale * (
        dm$loan_funding_pass_through * (f - median(f_grid)) +
          dm$loan_default_pass_through * (delta - median(d_grid))
      )
      comp_l <- clip(dm$loan_rate + cost_shift, f + delta, 0.25)
      comp_d <- clip(dm$deposit_rate + state_pass_scale * dm$deposit_funding_pass_through *
        (f - median(f_grid)), 0, 0.20)
      loan_rates <- comp_l
      deposit_rates <- comp_d
      # Wang's SearchC chooses next equity directly. Dividends are the residual;
      # negative dividends are external equity issuance and pay a fixed cost.
      next_equity_choices <- seq(min(e_grid), max(e_grid),
                                 length.out = 7L)
      rows <- vector("list", length(loan_rates) * length(deposit_rates) *
                       length(next_equity_choices))
      rr <- 0L
      for (rl in loan_rates) for (rd in deposit_rates) for (E_target in next_equity_choices) {
        total_loan_utility_shift <- agricultural_exposure *
          (-farm_demand_loading * farm_index + policy_shock$loan_demand_utility_change)
        l_own <- loan_quality - alpha_l * rl + total_loan_utility_shift
        l_rival <- loan_quality - alpha_l * comp_l + total_loan_utility_shift
        sl <- logit_share(
          l_own, l_rival,
          theta$no_borrow_quality + agricultural_exposure *
            policy_shock$outside_credit_utility_change,
          competitors
        )
        B <- loan_market_size * sl
        # Agricultural-production lending is a component of total lending, not
        # a substitute demand system for the entire balance sheet. Conditional
        # on total originations, choose the farmer-facing agricultural coupon
        # from the agricultural BLP system. Because composition does not alter
        # the total-loan state transition, this is the exact static subproblem.
        ag_utility_shift <- -farm_demand_loading * farm_index +
          policy_shock$loan_demand_utility_change
        ag_outside <- theta$no_borrow_quality +
          policy_shock$outside_credit_utility_change
        ag_rate_candidates <- clip(
          dm$ag_loan_rate + seq(-0.03, 0.03, length.out = 31L),
          f + delta, 0.25
        )
        ag_rate_candidates <- unique(ag_rate_candidates)
        ag_shares <- vapply(ag_rate_candidates, function(rag) {
          logit_share(
            ag_loan_quality - alpha_ag * rag + ag_utility_shift,
            ag_loan_quality - alpha_ag * dm$ag_loan_rate + ag_utility_shift,
            ag_outside, competitors
          )
        }, numeric(1))
        ag_originations <- pmin(ag_loan_market_size * ag_shares, B)
        ag_unit_cost <- f + delta + theta$loan_service_cost
        ag_choice <- which.max(ag_originations * (ag_rate_candidates - ag_unit_cost))
        B_ag <- ag_originations[ag_choice]
        r_ag <- ag_rate_candidates[ag_choice]
        B_nonag <- pmax(B - B_ag, 0)
        sd_draws <- vapply(alpha_d_draws, function(a) {
          logit_share(deposit_quality + a * rd, deposit_quality + a * comp_d, 0, competitors)
        }, numeric(1))
        D <- deposit_market_size * mean(sd_draws)
        R <- statutory$reserve_requirement * D
        funding_gap <- L + B + R - D - E
        structural_wholesale <- statutory$structural_wholesale_share * D
        N <- pmax(funding_gap, 0) + structural_wholesale
        G <- pmax(-funding_gap, 0) + structural_wholesale
        # Exact Wang replication-code cash-flow decomposition. The new-loan
        # coupon is the present value of the loan stream; the full outstanding
        # book bears the federal-funds opportunity cost, expected loss, and
        # servicing cost. Deposits and equity offset that benchmark funding
        # cost, and non-reservable borrowing bears a quadratic premium.
        expected_years <- 1 / statutory$maturity_rate
        loan_profit <- beta * (
          (B_nonag * rl + B_ag * r_ag) * expected_years -
            (L + B) * (f + delta + theta$loan_service_cost)
        )
        deposit_profit <- beta * (
          (1 - statutory$reserve_requirement) * D * f - D * rd -
            theta$deposit_service_cost * D + E * f -
            theta$fixed_operating_cost
        )
        finance_profit <- beta * (
          -theta$wholesale_cost * N^2 / (2 * pmax(D, 1e-6))
        )
        profit <- loan_profit + deposit_profit + finance_profit
        after_tax_profit <- profit * (1 - statutory$tax_rate)
        E_next <- E_target
        C <- E + after_tax_profit - E_next
        payout_value <- C - statutory$equity_issuance_cost * as.numeric(C < 0)
        L_next <- (1 - statutory$maturity_rate) * (L + B)
        feasible <- E_next >= capital_requirement * (L + B) &&
          E_next >= statutory$management_capital_target * (L + B + R + G) &&
          E_next > 0 && L_next > 0 && is.finite(profit)
        if (!feasible) next
        rr <- rr + 1L
        rows[[rr]] <- data.table(
          loan_rate = rl, agricultural_loan_rate = r_ag,
          new_agricultural_loans = B_ag,
          deposit_rate = rd, new_loans = B, deposits = D,
          reserves = R, securities = G, wholesale_funding = N, dividends = C,
          payout_value = payout_value,
          profit = profit, next_loans = L_next, next_equity = E_next,
          loan_share = sl, deposit_share = mean(sd_draws),
          next_l_state = nearest(L_next, l_grid),
          next_e_state = nearest(E_next, e_grid)
        )
      }
      if (!rr) stop("No feasible action for model state ", s)
      candidates[[s]] <- rbindlist(rows[seq_len(rr)])
    }

    for (vi in seq_len(max_value_iter)) {
      V_new <- rep(-Inf, nrow(states))
      new_policy <- vector("list", nrow(states))
      # Precompute E[V(s') | current aggregate states, next L, next E]. This
      # removes the 27-state transition sum from every candidate action while
      # leaving the Bellman expectation exactly unchanged.
      EV <- array(0, dim = c(length(f_grid), length(d_grid), 3L,
                             length(l_grid), length(e_grid)))
      for (fc in seq_along(f_grid)) for (dc in seq_along(d_grid)) for (zc in 1:3) {
        for (li in seq_along(l_grid)) for (ei in seq_along(e_grid)) {
          ev <- 0
          for (ff in seq_along(f_grid)) for (dd in seq_along(d_grid)) for (zz in 1:3) {
            ns <- state_index[ff, dd, zz, li, ei]
            ev <- ev + P_f[fc, ff] * P_d[dc, dd] * P_z[zc, zz] * V[ns]
          }
          EV[fc, dc, zc, li, ei] <- ev
        }
      }
      for (s in seq_len(nrow(states))) {
        st <- states[s]
        cand <- candidates[[s]]
        continuation_matrix <- EV[
          st$f_state, st$d_state, st$farm_state, ,
        ]
        continuation <- mapply(
          function(lv, ev) bilinear_value(continuation_matrix, lv, ev),
          cand$next_loans, cand$next_equity
        )
        values <- cand$payout_value + beta * continuation
        best_id <- which.max(values)
        V_new[s] <- values[best_id]
        best <- as.list(cand[best_id])
        best$value <- V_new[s]
        best$payout_value <- NULL
        best$next_l_state <- NULL
        best$next_e_state <- NULL
        new_policy[[s]] <- best
      }
      # Wang et al.'s public solver uses a scale-free Bellman error. An
      # absolute error falsely signals nonconvergence when bank value is large.
      gap <- max(abs(V_new - V) / (abs(V_new) + abs(V) + 0.01))
      V <- V_new
      policy <- new_policy
      if (gap < value_tolerance) break
    }

    pol <- rbindlist(lapply(seq_along(policy), function(i) {
      cbind(states[i], as.data.table(policy[[i]]))
    }))
    updated_l <- pol[, .(rate = weighted.mean(loan_rate, pmax(new_loans, 1e-8))),
                     by = .(f_state, farm_state)]
    updated_d <- pol[, .(rate = weighted.mean(deposit_rate, pmax(deposits, 1e-8))),
                     by = .(f_state, farm_state)]
    new_l <- matrix(updated_l$rate, nrow = length(f_grid), ncol = 3L)
    new_d <- matrix(updated_d$rate, nrow = length(f_grid), ncol = 3L)
    eq_gap <- max(abs(new_l - rival_l), abs(new_d - rival_d))
    rival_l <- 0.5 * rival_l + 0.5 * new_l
    rival_d <- 0.5 * rival_d + 0.5 * new_d
    message("bank_type=", bank_type, " regime=", regime,
            " equilibrium_iteration=", eq_iter,
            " value_iterations=", vi, " equilibrium_gap=", signif(eq_gap, 4))
    if (eq_gap < equilibrium_tolerance) break
  }
  pol[, `:=`(
    agricultural_bank = bank_type, regime = regime,
    capital_requirement = capital_requirement,
    deposit_market_size_multiplier = policy_shock$deposit_market_size_multiplier,
    loan_demand_utility_change = policy_shock$loan_demand_utility_change,
    default_rate_multiplier = policy_shock$default_rate_multiplier,
    outside_credit_utility_change = policy_shock$outside_credit_utility_change,
    equilibrium_iterations = eq_iter, value_iterations = vi,
    equilibrium_gap = eq_gap,
    value_function = V[state_id],
    loan_markup = loan_rate - f_grid[f_state] -
      clip(d_grid[d_state] + farm_default_loading * c(-1, 0, 1)[farm_state], 0,
           statutory$maturity_rate),
    deposit_markdown = f_grid[f_state] - deposit_rate
  )]
  pol[, bellman_residual := gap]
  pol[]
}

if (identical(Sys.getenv("AG_BANKING_DEFINE_ONLY"), "1")) {
  message("Loaded Bellman model definitions without running counterfactuals.")
} else {

channel_path <- file.path(external_dir, "..", "04h_obbba_bank_balance_sheet_channel_shocks.parquet")
lending_path <- file.path(external_dir, "..", "04g_obbba_bank_lending_channel_simulation_2025.parquet")
if (!file.exists(channel_path) || !file.exists(lending_path)) {
  stop("Run OBBBA analysis scripts 15 and 16 before the Bellman counterfactuals.")
}
channel_shocks <- as.data.table(read_parquet(channel_path))
lending_shocks <- as.data.table(read_parquet(lending_path))
type_shocks <- merge(
  channel_shocks[, .(
    deposit_market_size_multiplier = 1 + mean(weighted_county_deposit_growth, na.rm = TRUE),
    payment_intensity_shock = mean(payment_intensity_shock, na.rm = TRUE)
  ), by = agricultural_bank],
  lending_shocks[, .(
    loan_demand_utility_change = mean(predicted_log_ag_loan_change, na.rm = TRUE)
  ), by = agricultural_bank],
  by = "agricultural_bank", all = TRUE
)
type_shocks <- type_shocks[agricultural_bank %in% 0:1]

mal_exposure <- fread(file.path(
  "output", "tables", "04h_balance_sheet_channels",
  "04h_county_marketing_assistance_loan_rate_exposure.csv"
))
mal_rate_increase <- weighted.mean(
  mal_exposure$mal_rate_increase_pct / 100,
  w = mal_exposure$covered_base_acres, na.rm = TRUE
)
mal_outside_utility_change <- log(1 + mal_rate_increase)

scenario_specs <- data.table(
  scenario = c(
    "A_no_policy", "B_obbba_current_market_power",
    "B1_deposit_funding_only", "B2_borrower_liquidity_only",
    "B3_default_risk_only", "B4_marketing_loan_outside_credit_only",
    "B5_obbba_no_default_effect", "B6_obbba_chargeoffs_down_25pct"
  ),
  regime = c(
    "current_power", "current_power", "current_power", "current_power",
    "current_power", "current_power", "current_power", "current_power"
  ),
  use_deposit_shock = c(FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, TRUE, TRUE),
  use_demand_shock = c(FALSE, TRUE, FALSE, TRUE, FALSE, FALSE, TRUE, TRUE),
  default_multiplier = c(1, .90, 1, 1, .90, 1, 1, .75),
  use_outside_credit = c(FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, TRUE, TRUE),
  capital_requirement = rep(statutory$capital_requirement, 8)
)

solve_scenario <- function(spec, bank_type) {
  ts <- type_shocks[agricultural_bank == bank_type][1L]
  ps <- list(
    deposit_market_size_multiplier = if (spec$use_deposit_shock) {
      ts$deposit_market_size_multiplier
    } else 1,
    loan_demand_utility_change = if (spec$use_demand_shock) {
      ts$loan_demand_utility_change
    } else 0,
    default_rate_multiplier = spec$default_multiplier,
    outside_credit_utility_change = if (spec$use_outside_credit) {
      mal_outside_utility_change
    } else 0
  )
  out <- solve_type(
    bank_type, theta, regime = spec$regime, policy_shock = ps,
    capital_requirement = spec$capital_requirement
  )
  out[, scenario := spec$scenario]
  out
}

solution <- rbindlist(lapply(seq_len(nrow(scenario_specs)), function(i) {
  rbindlist(lapply(0:1, function(g) solve_scenario(scenario_specs[i], g)))
}))

summarize_policy <- function(dt) dt[, .(
  result_status = if (file.exists(estimated_parameter_path) && smd_valid) {
    "estimated_SMD_Bellman_counterfactual_passes_fit_gate"
  } else if (file.exists(estimated_parameter_path)) {
    "estimated_SMD_rejected_poor_moment_fit_not_policy_result"
  } else {
    "structural_calibration_not_full_SMD_estimate"
  },
  total_loan_rate = mean(loan_rate),
  agricultural_loan_rate = mean(agricultural_loan_rate),
  deposit_rate = mean(deposit_rate),
  new_total_loans = mean(new_loans),
  new_agricultural_loans = mean(new_agricultural_loans),
  deposits = mean(deposits),
  wholesale_funding = mean(wholesale_funding), securities = mean(securities),
  dividends = mean(dividends), next_equity = mean(next_equity),
  loan_markup = mean(loan_markup), deposit_markdown = mean(deposit_markdown),
  bank_value = mean(value_function)
), by = .(
  scenario,
  bank_type = fifelse(agricultural_bank == 1, "agricultural_banks", "nonagricultural_banks"),
  regime, capital_requirement, deposit_market_size_multiplier,
  loan_demand_utility_change, default_rate_multiplier,
  outside_credit_utility_change
)]
policy_results <- summarize_policy(solution[farm_state == 2L])
setorder(policy_results, bank_type, scenario)
policy_results[, `:=`(
  change_new_total_loans_from_no_policy = new_total_loans -
    new_total_loans[scenario == "A_no_policy"],
  pct_change_new_total_loans_from_no_policy = new_total_loans /
    new_total_loans[scenario == "A_no_policy"] - 1,
  change_new_agricultural_loans_from_no_policy = new_agricultural_loans -
    new_agricultural_loans[scenario == "A_no_policy"],
  pct_change_new_agricultural_loans_from_no_policy = new_agricultural_loans /
    new_agricultural_loans[scenario == "A_no_policy"] - 1,
  change_total_loan_rate_from_no_policy = total_loan_rate -
    total_loan_rate[scenario == "A_no_policy"],
  change_agricultural_loan_rate_from_no_policy = agricultural_loan_rate -
    agricultural_loan_rate[scenario == "A_no_policy"],
  change_deposit_rate_from_no_policy = deposit_rate - deposit_rate[scenario == "A_no_policy"],
  change_wholesale_funding_from_no_policy = wholesale_funding -
    wholesale_funding[scenario == "A_no_policy"],
  change_securities_from_no_policy = securities - securities[scenario == "A_no_policy"],
  change_next_equity_from_no_policy = next_equity - next_equity[scenario == "A_no_policy"]
), by = bank_type]

parameter_table <- data.table(
  parameter = c(names(theta), names(statutory), "farm_demand_loading", "farm_default_loading",
                "farm_demand_reduced_form", "farm_default_reduced_form"),
  value = c(unlist(theta), unlist(statutory), farm_demand_loading, farm_default_loading,
            farm_demand_reduced_form, farm_default_reduced_form),
  status = c(rep("initial_SMD_parameter", length(theta)), rep("statutory_or_direct", length(statutory)),
             "policy_stress_calibration", "policy_stress_calibration",
             "descriptive_not_causal", "descriptive_not_causal")
)
diagnostics <- solution[, .(
  states = .N, feasible_share = mean(is.finite(value_function)),
  equilibrium_iterations = max(equilibrium_iterations),
  equilibrium_gap = max(equilibrium_gap),
  value_iterations = max(value_iterations),
  bellman_residual = max(bellman_residual),
  balance_sheet_error = max(abs(
    (l_grid[l_state] + new_loans + reserves + securities) -
      (deposits + wholesale_funding + e_grid[e_state])
  )),
  capital_constraint_violations = sum(
    next_equity + 1e-10 < capital_requirement * (l_grid[l_state] + new_loans)
  )
), by = .(scenario, agricultural_bank, regime, capital_requirement)]

write_parquet(solution, file.path(external_dir, "04i_wang_full_dynamic_policy_functions.parquet"),
              compression = "zstd")
fwrite(policy_results, file.path(table_dir, "04i_wang_obbba_structural_counterfactuals.csv"))
fwrite(parameter_table, file.path(table_dir, "04i_wang_full_model_parameters.csv"))
fwrite(diagnostics, file.path(table_dir, "04i_wang_full_model_diagnostics.csv"))
fwrite(as.data.table(P_f), file.path(table_dir, "04i_wang_transition_federal_funds.csv"))
fwrite(as.data.table(P_d), file.path(table_dir, "04i_wang_transition_chargeoffs.csv"))
fwrite(as.data.table(P_z), file.path(table_dir, "04i_wang_transition_farm_income.csv"))

message("Solved the corrected Wang-style OBBBA channel and market-power counterfactuals.")
}
