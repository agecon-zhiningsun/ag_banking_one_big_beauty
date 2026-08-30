source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
  library(fixest)
  library(SQUAREM)
})

input <- file.path(data_root, "processed", "nc1177",
                   "03b_bank_year_market_power_inputs_1994_2025.parquet")
out_table <- file.path("output", "tables", "04a_blp")
out_data <- file.path(data_root, "processed", "nc1177", "blp_final")
dir.create(out_table, recursive = TRUE, showWarnings = FALSE)
dir.create(out_data, recursive = TRUE, showWarnings = FALSE)
d0 <- as.data.table(read_parquet(input))

market_characteristics <- function(market, instrument_set) {
  if (instrument_set == "wang_supply_costs" || market == "deposits") {
    c("log_branches", "log_employees_per_branch")
  } else {
    c("log_branches", "log_employees_per_branch", "log_assets",
      "equity_asset_ratio", "core_deposit_ratio", "gross_loans_asset_ratio",
      "real_estate_loans_asset_ratio", "ci_loans_asset_ratio",
      "consumer_loans_asset_ratio", "ag_loans_total_loan_ratio")
  }
}

prepare_market <- function(market, instrument_set) {
  d <- copy(d0)
  if (market == "deposits") {
    d[, `:=`(prices = deposit_rate, shares = deposit_share,
             outside_share = deposit_outside_share, quantity = dep)]
  } else if (market == "total_loans") {
    d[, `:=`(prices = loan_rate, shares = loan_share,
             outside_share = loan_outside_share, quantity = lnlsgr)]
  } else if (market == "ag_production") {
    d[, `:=`(prices = ag_production_loan_rate, shares = ag_production_share,
             outside_share = ag_production_outside_share, quantity = lnag)]
  } else stop("Unknown market")
  chars <- market_characteristics(market, instrument_set)
  needed <- c("prices", "shares", "outside_share", chars,
              "salary_cost_instrument", "premises_cost_instrument")
  d <- d[year %between% c(1994L, 2025L) & quarters_observed == 4L &
           quantity > 0 & prices > 0 & prices <= .50 & shares > 0 &
           outside_share > 0 & complete.cases(d[, ..needed])]
  setorder(d, year, cert)

  # Market-specific all-rival quadratic differentiation instruments.
  for (x in chars) {
    zx <- paste0("z_", x)
    iv <- paste0("rival_diff_", x)
    d[, (zx) := {
      sx <- sd(get(x)); if (is.finite(sx) && sx > 0)
        (get(x) - mean(get(x))) / sx else 0
    }, by = year]
    d[, (iv) := .N * get(zx)^2 - 2 * get(zx) * sum(get(zx)) +
        sum(get(zx)^2), by = year]
  }
  excluded <- if (instrument_set == "wang_supply_costs") {
    c("salary_cost_instrument", "premises_cost_instrument")
  } else {
    paste0("rival_diff_", chars)
  }
  list(data = d, chars = chars, excluded = excluded)
}

# Fixed-effect 2SLS/GMM linear step used inside nonlinear BLP. All variables are
# absorbed by bank and year before the small matrix calculation.
make_linear_problem <- function(d, chars, excluded) {
  vars <- c("prices", chars, excluded)
  dm <- demean(as.matrix(d[, ..vars]), f = list(d$cert, d$year))
  colnames(dm) <- vars
  X <- dm[, c("prices", chars), drop = FALSE]
  Z <- dm[, c(chars, excluded), drop = FALSE]
  keep_z <- apply(Z, 2, sd) > 1e-10
  Z <- Z[, keep_z, drop = FALSE]
  W1 <- solve(crossprod(Z) / nrow(Z) + diag(1e-10, ncol(Z)))
  list(X = X, Z = Z, W1 = W1)
}

linear_gmm <- function(delta, d, lp, W) {
  y <- as.numeric(demean(delta, f = list(d$cert, d$year)))
  X <- lp$X; Z <- lp$Z; n <- length(y)
  XZW <- crossprod(X, Z) %*% W
  beta <- solve(XZW %*% crossprod(Z, X), XZW %*% crossprod(Z, y))
  xi <- y - as.numeric(X %*% beta)
  g <- crossprod(Z, xi) / n
  list(beta = beta, xi = xi, objective = as.numeric(crossprod(g, W %*% g)))
}

normal_draws <- qnorm((seq_len(20) - 0.5) / 20)

rc_components <- function(delta, price, group, sigma) {
  ng <- max(group)
  shares <- numeric(length(delta))
  derivative_component <- matrix(0, nrow = length(delta), ncol = 2L)
  for (v in normal_draws) {
    u <- delta + sigma * price * v
    max_g <- pmax(0, as.numeric(tapply(u, group, max)))
    eu <- exp(u - max_g[group])
    den_g <- exp(-max_g) + as.numeric(rowsum(eu, group, reorder = FALSE))
    s <- eu / den_g[group]
    shares <- shares + s / length(normal_draws)
    derivative_component[, 1L] <- derivative_component[, 1L] +
      s * (1 - s) / length(normal_draws)
    derivative_component[, 2L] <- derivative_component[, 2L] +
      v * s * (1 - s) / length(normal_draws)
  }
  list(shares = shares, derivative_component = derivative_component)
}

invert_shares <- function(d, sigma, start = NULL, tol = 1e-7, maxit = 3000L) {
  delta <- if (is.null(start)) log(d$shares) - log(d$outside_share) else start
  group <- as.integer(factor(d$year))
  mapping <- function(current) {
    predicted <- rc_components(delta, d$prices,
                               group, sigma)$shares
    current + log(d$shares) - log(pmax(predicted, 1e-300))
  }
  # Ensure the mapping evaluates its argument, not the outer starting vector.
  mapping <- function(current) {
    predicted <- rc_components(current, d$prices, group, sigma)$shares
    current + log(d$shares) - log(pmax(predicted, 1e-300))
  }
  fit <- squarem(delta, mapping, control = list(tol = tol, maxiter = maxit,
                                                trace = FALSE))
  check <- mapping(fit$par) - fit$par
  if (max(abs(check)) > max(10 * tol, 1e-5))
    stop("Accelerated BLP contraction did not converge")
  list(delta = fit$par, iterations = fit$fpevals)
}

estimate_market <- function(market, instrument_set) {
  prep <- prepare_market(market, instrument_set)
  d <- prep$data
  lp <- make_linear_problem(d, prep$chars, prep$excluded)
  base_delta <- log(d$shares) - log(d$outside_share)
  if (market == "deposits") {
    evaluate_grid <- function(grid, W, start_delta) {
      values <- vector("list", length(grid))
      current <- start_delta
      for (i in seq_along(grid)) {
        current_inv <- invert_shares(d, grid[[i]], start = current, tol = 1e-6)
        current <- current_inv$delta
        current_lin <- linear_gmm(current, d, lp, W)
        values[[i]] <- list(sigma = grid[[i]], inv = current_inv,
                            lin = current_lin)
        message(market, " / ", instrument_set, ": sigma=", grid[[i]],
                ", objective=", signif(current_lin$objective, 6))
      }
      values
    }
    coarse <- c(0, 0.1, 0.25, 0.5, 1, 2, 5)
    pass1 <- evaluate_grid(coarse, lp$W1, base_delta)
    best1 <- pass1[[which.min(vapply(pass1, function(x) x$lin$objective,
                                    numeric(1L)))]]
    inv1 <- best1$inv
    lin1 <- best1$lin
    Zxi <- lp$Z * lin1$xi
    S <- crossprod(Zxi) / nrow(Zxi)
    W2 <- solve(S + diag(1e-10, ncol(S)))
    center <- best1$sigma
    fine <- sort(unique(pmax(0, center + c(-0.25, -0.1, -0.05, 0, 0.05, 0.1, 0.25))))
    pass2 <- evaluate_grid(fine, W2, inv1$delta)
    best2 <- pass2[[which.min(vapply(pass2, function(x) x$lin$objective,
                                    numeric(1L)))]]
    sigma <- best2$sigma
    inv <- best2$inv
    lin <- best2$lin
  } else {
    sigma <- 0
    inv <- list(delta = base_delta, iterations = 0L)
    lin1 <- linear_gmm(inv$delta, d, lp, lp$W1)
    Zxi <- lp$Z * lin1$xi
    S <- crossprod(Zxi) / nrow(Zxi)
    W2 <- solve(S + diag(1e-10, ncol(S)))
    lin <- linear_gmm(inv$delta, d, lp, W2)
  }
  alpha <- unname(lin$beta[[1L]])
  derivative <- numeric(nrow(d))
  if (market == "deposits") {
    comp <- rc_components(inv$delta, d$prices,
                          as.integer(factor(d$year)), sigma)$derivative_component
    derivative <- alpha * comp[, 1L] + sigma * comp[, 2L]
    raw_margin <- d$shares / derivative
    valid_slope <- derivative > 0
  } else {
    derivative <- alpha * d$shares * (1 - d$shares)
    raw_margin <- -d$shares / derivative
    valid_slope <- derivative < 0
  }
  valid_margin <- valid_slope & is.finite(raw_margin) & raw_margin >= 0
  result <- data.table(
    market, instrument_set, observations = nrow(d), banks = uniqueN(d$cert),
    years = uniqueN(d$year), mean_rate_coefficient_decimal = alpha,
    mean_rate_coefficient_percentage_points = alpha / 100,
    random_rate_sd_decimal = sigma,
    contraction_iterations = inv$iterations,
    valid_demand_derivatives = sum(valid_slope),
    valid_nonnegative_markups = sum(valid_margin),
    mean_markup = mean(raw_margin[valid_margin]),
    median_markup = median(raw_margin[valid_margin]),
    p10_markup = quantile(raw_margin[valid_margin], .1),
    p90_markup = quantile(raw_margin[valid_margin], .9),
    gmm_objective = lin$objective
  )
  panel <- d[, .(cert, year, agricultural_bank, prices, shares)]
  panel[, `:=`(own_demand_derivative = derivative,
               raw_structural_margin = raw_margin,
               structural_margin = fifelse(valid_margin, raw_margin, NA_real_),
               retained_nonnegative_margin = valid_margin,
               instrument_set = instrument_set)]
  write_parquet(panel, file.path(out_data, paste0("04a_", market, "_", instrument_set,
                                                  "_bank_year.parquet")))
  result
}

results <- rbindlist(lapply(
  c("deposits", "total_loans", "ag_production"),
  function(m) rbindlist(lapply(
    c("wang_supply_costs", "all_rival_characteristics"),
    function(iv) estimate_market(m, iv)
  ))
))
fwrite(results, file.path(out_table, "04a_final_blp_summary.csv"))
message("Wrote final BLP results to ", out_table)
