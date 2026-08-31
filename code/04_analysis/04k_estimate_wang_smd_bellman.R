Sys.setenv(AG_BANKING_DEFINE_ONLY = "1")
source(file.path("code", "04_analysis", "04i_solve_wang_bellman_counterfactuals.R"))

suppressPackageStartupMessages({
  library(data.table)
  library(nloptr)
  library(numDeriv)
})

# Agricultural adaptation of Wang, Whited, Wu, and Xiao's second-stage SMD.
# Every objective evaluation resolves the Bellman problem and the competitors'
# rate fixed point. The adaptation targets moments observable for agricultural
# banks. Market-to-book is not targeted because most sample banks are private.

out_dir <- file.path("output", "tables", "04k_smd_estimation")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

ag <- x[agricultural_bank == 1]
ag[, `:=`(
  book_equity = pmax(asset * capital_ratio, 1e-8),
  dividends_level = dividend_asset_ratio * asset,
  wholesale_level = wholesale_funding_asset_ratio * asset,
  deposit_level = deposit_asset_ratio * asset,
  ag_production_loan_level = ag_production_loan_ratio * asset,
  total_loan_level = total_loan_ratio * asset
)]
ag[, `:=`(
  dividend_book_equity = dividends_level / book_equity,
  wholesale_deposit = wholesale_level / pmax(deposit_level, 1e-8),
  deposit_spread = funding_rate - deposit_rate,
  loan_spread = ag_production_loan_rate - funding_rate - net_chargeoff_rate,
  leverage = asset / book_equity,
  loan_deposit = total_loan_level / pmax(deposit_level, 1e-8),
  roa = net_income_asset_ratio
)]

annual_credit <- ag[, .(
  ag_credit = sum(ag_production_loan_level, na.rm = TRUE),
  funding_rate = weighted.mean(funding_rate, pmax(asset, 1), na.rm = TRUE)
), by = year][is.finite(ag_credit) & ag_credit > 0 & is.finite(funding_rate)]
credit_fit <- lm(diff(log(ag_credit)) ~ diff(funding_rate), data = annual_credit)
data_credit_sensitivity <- unname(coef(credit_fit)[2L])

moment_names <- c(
  "dividend_book_equity", "mean_wholesale_deposit", "sd_wholesale_deposit",
  "deposit_spread", "loan_spread", "deposit_assets",
  "noninterest_cost_assets", "leverage", "loan_deposit", "roa",
  "credit_funding_sensitivity"
)

data_moments <- c(
  median(ag$dividend_book_equity, na.rm = TRUE),
  mean(ag$wholesale_deposit, na.rm = TRUE),
  sd(ag$wholesale_deposit, na.rm = TRUE),
  mean(ag$deposit_spread, na.rm = TRUE),
  mean(ag$loan_spread, na.rm = TRUE),
  mean(ag$deposit_asset_ratio, na.rm = TRUE),
  mean(ag$net_noninterest_cost_asset_ratio, na.rm = TRUE),
  mean(ag$leverage, na.rm = TRUE),
  mean(ag$loan_deposit, na.rm = TRUE),
  mean(ag$roa, na.rm = TRUE),
  data_credit_sensitivity
)
names(data_moments) <- moment_names

bank_moments <- ag[, .(
  dividend_book_equity = median(dividend_book_equity, na.rm = TRUE),
  mean_wholesale_deposit = mean(wholesale_deposit, na.rm = TRUE),
  sd_wholesale_deposit = sd(wholesale_deposit, na.rm = TRUE),
  deposit_spread = mean(deposit_spread, na.rm = TRUE),
  loan_spread = mean(loan_spread, na.rm = TRUE),
  deposit_assets = mean(deposit_asset_ratio, na.rm = TRUE),
  noninterest_cost_assets = mean(net_noninterest_cost_asset_ratio, na.rm = TRUE),
  leverage = mean(leverage, na.rm = TRUE),
  loan_deposit = mean(loan_deposit, na.rm = TRUE),
  roa = mean(roa, na.rm = TRUE)
), by = cert]

set.seed(3049665)
B_boot <- 300L
boot <- matrix(NA_real_, B_boot, length(moment_names))
for (b in seq_len(B_boot)) {
  ids <- sample.int(nrow(bank_moments), nrow(bank_moments), replace = TRUE)
  z <- bank_moments[ids]
  boot[b, 1:10] <- c(
    mean(z$dividend_book_equity, na.rm = TRUE),
    mean(z$mean_wholesale_deposit, na.rm = TRUE),
    mean(z$sd_wholesale_deposit, na.rm = TRUE),
    mean(z$deposit_spread, na.rm = TRUE), mean(z$loan_spread, na.rm = TRUE),
    mean(z$deposit_assets, na.rm = TRUE), mean(z$noninterest_cost_assets, na.rm = TRUE),
    mean(z$leverage, na.rm = TRUE), mean(z$loan_deposit, na.rm = TRUE),
    mean(z$roa, na.rm = TRUE)
  )
  years_b <- sample(annual_credit$year, nrow(annual_credit), replace = TRUE)
  ac <- annual_credit[match(years_b, year)]
  boot[b, 11] <- if (nrow(ac) >= 10L) {
    unname(coef(lm(diff(log(ag_credit)) ~ diff(funding_rate), data = ac))[2L])
  } else NA_real_
}
colnames(boot) <- moment_names
moment_se <- apply(boot, 2, sd, na.rm = TRUE)
moment_se[!is.finite(moment_se) | moment_se < 1e-5] <- pmax(abs(data_moments[!is.finite(moment_se) | moment_se < 1e-5]) * .05, 1e-4)
W1 <- diag(1 / moment_se^2)
cov_boot <- cov(boot, use = "pairwise.complete.obs")
ridge <- 1e-6 * mean(diag(cov_boot), na.rm = TRUE)
W2 <- solve(cov_boot + diag(ridge, nrow(cov_boot)))

stationary_policy <- function(pol) {
  n <- nrow(pol)
  Q <- matrix(0, n, n)
  for (s in seq_len(n)) {
    st <- pol[s]
    li <- nearest(st$next_loans, l_grid)
    ei <- nearest(st$next_equity, e_grid)
    for (ff in seq_along(f_grid)) for (dd in seq_along(d_grid)) for (zz in 1:3) {
      ns <- state_index[ff, dd, zz, li, ei]
      Q[s, ns] <- Q[s, ns] + P_f[st$f_state, ff] * P_d[st$d_state, dd] * P_z[st$farm_state, zz]
    }
  }
  probability <- rep(1 / n, n)
  for (iter in seq_len(5000L)) {
    updated <- drop(probability %*% Q)
    if (max(abs(updated - probability)) < 1e-12) break
    probability <- updated
  }
  probability / sum(probability)
}

model_moments <- function(theta_list, strict = FALSE) {
  pol <- solve_type(
    1L, theta_list,
    max_equilibrium_iter = if (strict) 12L else 5L,
    max_value_iter = if (strict) 500L else 120L,
    value_tolerance = if (strict) 1e-8 else 1e-5,
    # The official replication code uses a 0.01 competitor-rate fixed-point
    # threshold. We use that published criterion and a tighter Bellman error.
    equilibrium_tolerance = if (strict) 1e-2 else 1e-2
  )
  w <- stationary_policy(pol)
  wmean <- function(v) sum(w * v)
  assets <- l_grid[pol$l_state] + pol$new_loans + pol$reserves + pol$securities
  equity <- e_grid[pol$e_state]
  operating_cost <- theta_list$fixed_operating_cost +
    theta_list$deposit_service_cost * pol$deposits +
    theta_list$loan_service_cost * (l_grid[pol$l_state] + pol$new_loans)
  total_credit <- l_grid[pol$l_state] + pol$new_loans
  f <- f_grid[pol$f_state]
  sensitivity <- sum(w * (f - wmean(f)) * (log(pmax(total_credit, 1e-8)) -
    wmean(log(pmax(total_credit, 1e-8))))) / sum(w * (f - wmean(f))^2)
  out <- c(
    wmean(pol$dividends / pmax(equity, 1e-8)),
    wmean(pol$wholesale_funding / pmax(pol$deposits, 1e-8)),
    sqrt(wmean((pol$wholesale_funding / pmax(pol$deposits, 1e-8) -
      wmean(pol$wholesale_funding / pmax(pol$deposits, 1e-8)))^2)),
    wmean(f - pol$deposit_rate),
    wmean(pol$loan_rate - f - d_grid[pol$d_state]),
    wmean(pol$deposits / pmax(assets, 1e-8)),
    wmean(operating_cost / pmax(assets, 1e-8)),
    wmean(assets / pmax(equity, 1e-8)),
    wmean(total_credit / pmax(pol$deposits, 1e-8)),
    wmean(pol$profit * (1 - statutory$tax_rate) / pmax(assets, 1e-8)),
    sensitivity
  )
  names(out) <- moment_names
  attr(out, "diagnostics") <- c(
    equilibrium_gap = max(pol$equilibrium_gap),
    bellman_residual = max(pol$bellman_residual)
  )
  out
}

parameter_names <- names(theta)
lower <- c(.005, .0001, .0001, .0001, 0, 1, -15)
upper <- c(.15, .10, .08, .08, .08, 100, 2)
start <- pmin(pmax(unlist(theta), lower), upper)

cache <- new.env(parent = emptyenv())
evaluate <- function(par, W, strict = FALSE) {
  key <- paste(c(round(par, 8), strict, round(diag(W), 4)), collapse = "|")
  if (exists(key, cache, inherits = FALSE)) return(get(key, cache, inherits = FALSE))
  th <- as.list(setNames(par, parameter_names))
  mm <- tryCatch(model_moments(th, strict = strict), error = function(e) rep(NA_real_, length(data_moments)))
  gap <- mm - data_moments
  objective <- if (all(is.finite(gap))) drop(t(gap) %*% W %*% gap) else 1e12
  result <- list(objective = objective, moments = mm)
  assign(key, result, cache)
  message("SMD objective=", signif(objective, 7), " parameters=", paste(signif(par, 4), collapse = ","))
  result
}

run_stage <- function(start_value, W, maxeval) {
  nloptr(
    x0 = start_value,
    eval_f = function(par) evaluate(par, W)$objective,
    lb = lower, ub = upper,
    opts = list(
      algorithm = "NLOPT_LN_BOBYQA", maxeval = maxeval,
      xtol_rel = 2e-4, ftol_rel = 1e-5, print_level = 1
    )
  )
}

resume_path <- file.path(out_dir, "04k_wang_smd_optimizer_checkpoint.csv")
if (file.exists(resume_path)) {
  checkpoint <- fread(resume_path)
  estimate <- checkpoint$estimate[match(parameter_names, checkpoint$parameter)]
  stage1 <- list(objective = NA_real_, status = NA_integer_)
  stage2 <- list(solution = estimate, objective = checkpoint$stage2_objective[1L],
                 status = checkpoint$stage2_status[1L])
  message("Resuming inference from the saved SMD optimum.")
} else {
  stage1 <- run_stage(start, W1, 24L)
  stage2 <- run_stage(stage1$solution, W2, 32L)
  estimate <- stage2$solution
  fwrite(data.table(
    parameter = parameter_names, estimate = estimate,
    stage2_objective = stage2$objective, stage2_status = stage2$status
  ), resume_path)
}
final <- evaluate(estimate, W2, strict = TRUE)

# Numerical Jacobian and SMD sandwich inference. This requires two additional
# Bellman/equilibrium solutions per parameter around the optimum.
jac <- jacobian(
  func = function(par) evaluate(pmin(pmax(par, lower), upper), W2)$moments,
  x = estimate, method = "simple", method.args = list(eps = 2e-4)
)
G <- jac
vcov_theta <- tryCatch(
  solve(t(G) %*% W2 %*% G) %*% (t(G) %*% W2 %*% cov_boot %*% W2 %*% G) %*%
    solve(t(G) %*% W2 %*% G),
  error = function(e) matrix(NA_real_, length(estimate), length(estimate))
)
parameter_se <- sqrt(pmax(diag(vcov_theta), 0))

parameter_table <- data.table(
  parameter = parameter_names,
  estimate = estimate,
  standard_error = parameter_se,
  lower_95 = estimate - 1.96 * parameter_se,
  upper_95 = estimate + 1.96 * parameter_se,
  lower_bound = lower,
  upper_bound = upper,
  estimation = "two_stage_SMD_full_Bellman_equilibrium"
)
moment_table <- data.table(
  moment = moment_names,
  data = as.numeric(data_moments),
  data_standard_error = moment_se,
  model = as.numeric(final$moments),
  standardized_difference = (as.numeric(final$moments) - data_moments) / moment_se,
  targeted = TRUE
)
diagnostic_table <- data.table(
  statistic = c("stage1_objective", "stage2_objective", "strict_objective",
                "stage1_status", "stage2_status", "equilibrium_gap", "bellman_residual",
                "number_of_data_moments", "number_of_parameters", "bank_years", "banks"),
  value = as.character(c(
    stage1$objective, stage2$objective, final$objective,
    stage1$status, stage2$status,
    attr(final$moments, "diagnostics")["equilibrium_gap"],
    attr(final$moments, "diagnostics")["bellman_residual"],
    length(data_moments), length(estimate), nrow(ag), uniqueN(ag$cert)
  ))
)

fwrite(parameter_table, file.path(out_dir, "04k_wang_smd_parameter_estimates.csv"))
fwrite(moment_table, file.path(out_dir, "04k_wang_smd_moment_fit.csv"))
fwrite(diagnostic_table, file.path(out_dir, "04k_wang_smd_diagnostics.csv"))
vcov_table <- as.data.table(vcov_theta)
setnames(vcov_table, parameter_names)
vcov_table[, parameter := parameter_names]
setcolorder(vcov_table, c("parameter", parameter_names))
fwrite(vcov_table,
       file.path(out_dir, "04k_wang_smd_parameter_vcov.csv"))
saveRDS(list(stage1 = stage1, stage2 = stage2, bootstrap_moments = boot,
             covariance_moments = cov_boot, jacobian = jac),
        file.path(out_dir, "04k_wang_smd_estimation_objects.rds"))

message("Completed two-stage agricultural-bank SMD estimation with Bellman and equilibrium re-solution.")
