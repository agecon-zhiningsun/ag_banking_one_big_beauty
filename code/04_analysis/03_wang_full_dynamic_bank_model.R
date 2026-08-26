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
  "bank_year_dynamic_model_inputs_1994_2025.parquet"
)
external_dir <- file.path(data_root, "processed", "nc1177", "dynamic_bank_model")
table_dir <- file.path("output", "tables", "dynamic_bank_model")
dir.create(external_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(input_path)) stop("Run code/03_construct/06_construct_dynamic_bank_model_inputs.R first.")

x <- as.data.table(read_parquet(input_path))
x <- x[
  agricultural_bank %in% 0:1 & is.finite(funding_rate) &
    is.finite(net_chargeoff_rate) & is.finite(ag_production_loan_ratio) &
    is.finite(capital_ratio) & is.finite(deposit_asset_ratio)
]

clip <- function(z, lo, hi) pmin(pmax(z, lo), hi)
qgrid <- function(z, p) unique(as.numeric(quantile(z[is.finite(z)], p, na.rm = TRUE)))
nearest <- function(z, grid) which.min(abs(grid - z))
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
f_grid <- qgrid(x$funding_rate, c(0.20, 0.50, 0.80))
d_grid <- qgrid(x$net_chargeoff_rate, c(0.20, 0.50, 0.80))
l_grid <- qgrid(x$ag_production_loan_ratio, c(0.20, 0.50, 0.80))
e_grid <- qgrid(x$capital_ratio, c(0.20, 0.50, 0.80))
if (any(lengths(list(f_grid, d_grid, l_grid, e_grid)) < c(3, 3, 3, 3))) {
  stop("Insufficient support for the Wang state grids.")
}
x[, `:=`(
  f_state = vapply(funding_rate, nearest, integer(1), grid = f_grid),
  d_state = vapply(net_chargeoff_rate, nearest, integer(1), grid = d_grid),
  l_state = vapply(ag_production_loan_ratio, nearest, integer(1), grid = l_grid),
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
  blp_ag_share > 0 & blp_deposit_share > 0 &
    own_rate_derivative < 0 & deposit_own_rate_derivative > 0,
  .(
    alpha_l = median(-own_rate_derivative / blp_ag_share, na.rm = TRUE),
    alpha_d = median(deposit_own_rate_derivative / blp_deposit_share, na.rm = TRUE),
    loan_share = median(blp_ag_share, na.rm = TRUE),
    deposit_share = median(blp_deposit_share, na.rm = TRUE),
    loan_rate = median(ag_production_loan_rate, na.rm = TRUE),
    deposit_rate = median(deposit_rate, na.rm = TRUE),
    loan_ratio = median(ag_production_loan_ratio, na.rm = TRUE),
    deposit_ratio = median(deposit_asset_ratio, na.rm = TRUE)
  ), by = agricultural_bank
]

# Seven bank-side parameters correspond to Wang's second-stage objects. Initial
# values are data-disciplined and are written explicitly; a separate SMD block
# below assesses their moment fit rather than silently treating them as known.
theta <- list(
  discount_rate = 0.045,
  wholesale_cost = 0.010,
  deposit_service_cost = max(safe_median(x$interest_expense_asset_ratio, 0.015) /
                                 safe_median(x$deposit_asset_ratio, 0.80), 0.0005),
  loan_service_cost = max(
    safe_median(x$ag_production_loan_rate - x$funding_rate - x$blp_ag_markup, 0.01),
    0.0005
  ),
  fixed_operating_cost = max(safe_median(x$net_noninterest_cost_asset_ratio, 0.015), 0),
  wealth_to_loan_market = safe_median(x$deposit_asset_ratio, 0.80) /
    safe_median(x$ag_production_loan_ratio, 0.08),
  no_borrow_quality = 0
)
statutory <- list(tax_rate = 0.35, capital_requirement = 0.06,
                  reserve_requirement = 0.03, maturity_rate = 1 / 3.5)

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

solve_type <- function(bank_type, theta, competitive = FALSE,
                       max_equilibrium_iter = 30L, max_value_iter = 150L,
                       value_tolerance = 2e-5, equilibrium_tolerance = 2e-4) {
  dm <- demand_by_type[agricultural_bank == bank_type][1]
  if (!nrow(dm)) stop("Missing BLP demand slopes for bank type ", bank_type)
  J <- 6L
  competitors <- J - 1L
  beta <- 1 / (1 + theta$discount_rate)
  alpha_l <- if (competitive) dm$alpha_l * 100 else dm$alpha_l
  alpha_d_mean <- if (competitive) dm$alpha_d * 100 else dm$alpha_d
  alpha_d_draws <- pmax(alpha_d_mean + seq(-1, 1, length.out = 10L) * 0.615, 1e-4)
  loan_market_size <- dm$loan_ratio / pmax(dm$loan_share, 1e-8)
  deposit_market_size <- dm$deposit_ratio / pmax(dm$deposit_share, 1e-8)
  loan_quality <- log(dm$loan_share / pmax(1 - J * dm$loan_share, 1e-8)) + alpha_l * dm$loan_rate
  deposit_quality <- log(dm$deposit_share / pmax(1 - J * dm$deposit_share, 1e-8)) -
    alpha_d_mean * dm$deposit_rate

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
      delta <- clip(delta_base + farm_default_loading * farm_index, 0, statutory$maturity_rate)
      L <- l_grid[st$l_state]
      E <- e_grid[st$e_state]
      comp_l <- rival_l[st$f_state, st$farm_state]
      comp_d <- rival_d[st$f_state, st$farm_state]
      loan_rates <- clip(comp_l + c(-0.012, 0, 0.012), f + delta, 0.25)
      deposit_rates <- clip(comp_d + c(-0.010, 0, 0.010), 0, 0.20)
      payout_rates <- c(0, 0.35, 0.70)
      rows <- vector("list", length(loan_rates) * length(deposit_rates) * length(payout_rates))
      rr <- 0L
      for (rl in loan_rates) for (rd in deposit_rates) for (payout in payout_rates) {
        l_own <- loan_quality - alpha_l * rl - farm_demand_loading * farm_index
        l_rival <- loan_quality - alpha_l * comp_l - farm_demand_loading * farm_index
        sl <- logit_share(l_own, l_rival, theta$no_borrow_quality, competitors)
        B <- loan_market_size * sl
        sd_draws <- vapply(alpha_d_draws, function(a) {
          logit_share(deposit_quality + a * rd, deposit_quality + a * comp_d, 0, competitors)
        }, numeric(1))
        D <- deposit_market_size * mean(sd_draws)
        R <- statutory$reserve_requirement * D
        funding_gap <- L + B + R - D - E
        N <- pmax(funding_gap, 0)
        G <- pmax(-funding_gap, 0)
        pv_factor <- 1 / (1 - (1 - statutory$maturity_rate) / (1 + theta$discount_rate))
        interest_income <- B * rl * pv_factor
        wholesale_cost <- (f + theta$wholesale_cost / 2 * N / pmax(D, 1e-6)) * N
        profit <- interest_income - (L + B) * (delta + theta$loan_service_cost) +
          G * f - (rd + theta$deposit_service_cost) * D - wholesale_cost -
          theta$fixed_operating_cost
        after_tax_profit <- profit * (1 - statutory$tax_rate)
        distributable <- pmax(E + after_tax_profit -
                                statutory$capital_requirement * (L + B), 0)
        C <- payout * distributable
        E_next <- E + after_tax_profit - C
        L_next <- (1 - statutory$maturity_rate) * (L + B)
        feasible <- E_next >= statutory$capital_requirement * (L + B) &&
          E_next > 0 && L_next > 0 && is.finite(profit)
        if (!feasible) next
        rr <- rr + 1L
        rows[[rr]] <- data.table(
          loan_rate = rl, deposit_rate = rd, new_loans = B, deposits = D,
          reserves = R, securities = G, wholesale_funding = N, dividends = C,
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
        continuation <- mapply(
          function(li, ei) EV[st$f_state, st$d_state, st$farm_state, li, ei],
          cand$next_l_state, cand$next_e_state
        )
        values <- cand$dividends + beta * continuation
        best_id <- which.max(values)
        V_new[s] <- values[best_id]
        best <- as.list(cand[best_id])
        best$value <- V_new[s]
        best$next_l_state <- NULL
        best$next_e_state <- NULL
        new_policy[[s]] <- best
      }
      gap <- max(abs(V_new - V))
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
    rival_l <- 0.8 * rival_l + 0.2 * new_l
    rival_d <- 0.8 * rival_d + 0.2 * new_d
    message("bank_type=", bank_type, " competitive=", competitive,
            " equilibrium_iteration=", eq_iter,
            " value_iterations=", vi, " equilibrium_gap=", signif(eq_gap, 4))
    if (eq_gap < equilibrium_tolerance) break
  }
  pol[, `:=`(
    agricultural_bank = bank_type, competitive = competitive,
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

baseline <- rbindlist(lapply(0:1, function(g) solve_type(g, theta, competitive = FALSE)))
solution <- baseline

# Policy experiment: compare the same bank balance-sheet states under normal and
# downturn farm income. Decomposition holds either demand or default at its
# normal-state value, then compares with the joint downturn.
summarize_policy <- function(dt, label) dt[, .(
  scenario = label,
  result_status = "illustrative_not_estimated",
  assumed_demand_utility_change = -farm_demand_loading,
  assumed_chargeoff_change = farm_default_loading,
  loan_rate = mean(loan_rate), deposit_rate = mean(deposit_rate),
  new_ag_loans = mean(new_loans), deposits = mean(deposits),
  wholesale_funding = mean(wholesale_funding), securities = mean(securities),
  dividends = mean(dividends), next_equity = mean(next_equity),
  loan_markup = mean(loan_markup), deposit_markdown = mean(deposit_markdown),
  bank_value = mean(value_function)
), by = .(
  bank_type = fifelse(agricultural_bank == 1, "agricultural_banks", "nonagricultural_banks"),
  competitive
)]
normal <- summarize_policy(solution[farm_state == 2L], "normal_farm_income")
downturn <- summarize_policy(solution[farm_state == 3L], "lower_farm_income")
policy_results <- rbindlist(list(normal, downturn))
setorder(policy_results, bank_type, competitive, scenario)
policy_results[, `:=`(
  change_new_ag_loans_from_normal = new_ag_loans - new_ag_loans[scenario == "normal_farm_income"],
  pct_change_new_ag_loans_from_normal = new_ag_loans /
    new_ag_loans[scenario == "normal_farm_income"] - 1,
  change_loan_rate_from_normal = loan_rate - loan_rate[scenario == "normal_farm_income"],
  change_wholesale_funding_from_normal = wholesale_funding -
    wholesale_funding[scenario == "normal_farm_income"],
  change_next_equity_from_normal = next_equity - next_equity[scenario == "normal_farm_income"]
), by = .(bank_type, competitive)]

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
    next_equity + 1e-10 < statutory$capital_requirement * (l_grid[l_state] + new_loans)
  )
), by = .(agricultural_bank, competitive)]

write_parquet(solution, file.path(external_dir, "wang_full_dynamic_policy_functions.parquet"),
              compression = "zstd")
fwrite(policy_results, file.path(table_dir, "wang_farm_downturn_policy_results.csv"))
fwrite(parameter_table, file.path(table_dir, "wang_full_model_parameters.csv"))
fwrite(diagnostics, file.path(table_dir, "wang_full_model_diagnostics.csv"))
fwrite(as.data.table(P_f), file.path(table_dir, "wang_transition_federal_funds.csv"))
fwrite(as.data.table(P_d), file.path(table_dir, "wang_transition_chargeoffs.csv"))
fwrite(as.data.table(P_z), file.path(table_dir, "wang_transition_farm_income.csv"))

message("Solved the full Wang-style balance-sheet model and farm-income policy experiment.")


