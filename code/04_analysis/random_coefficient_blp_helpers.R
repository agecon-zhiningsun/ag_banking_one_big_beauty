suppressPackageStartupMessages({
  library(data.table)
  library(fixest)
})

# Deterministic normal quadrature draws. More nodes can be supplied for the final run.
default_blp_draws <- qnorm((seq_len(7L) - 0.5) / 7L)

blp_invert_market <- function(observed_share, outside_share, rate, sigma, draws,
                              tolerance = 1e-7, max_iterations = 3000L) {
  delta <- log(observed_share) - log(outside_share)
  mu <- outer(rate, sigma * draws)
  converged <- FALSE
  for (iteration in seq_len(max_iterations)) {
    utility <- delta + mu
    column_max <- pmax(0, apply(utility, 2L, max))
    numerator <- sweep(utility, 2L, column_max, "-")
    numerator <- exp(numerator)
    denominator <- exp(-column_max) + colSums(numerator)
    predicted <- rowMeans(sweep(numerator, 2L, denominator, "/"))
    update <- log(observed_share) - log(pmax(predicted, .Machine$double.xmin))
    if (any(!is.finite(update))) stop("Non-finite BLP contraction update")
    delta <- delta + update
    if (max(abs(update)) < tolerance) {
      converged <- TRUE
      break
    }
  }
  list(delta = delta, converged = converged, iterations = iteration)
}

invert_all_markets <- function(x, sigma, draws) {
  pieces <- vector("list", uniqueN(x$year))
  diagnostics <- vector("list", length(pieces))
  years <- sort(unique(x$year))
  for (i in seq_along(years)) {
    rows <- which(x$year == years[i])
    outside <- unique(x$outside_share[rows])
    if (length(outside) != 1L || !is.finite(outside) || outside <= 0) {
      stop("Invalid outside share in ", years[i])
    }
    ans <- blp_invert_market(x$market_share[rows], outside, x$rate[rows], sigma, draws)
    if (!ans$converged) stop("BLP contraction failed in ", years[i], " at sigma=", sigma)
    pieces[[i]] <- data.table(row_id = rows, delta = ans$delta)
    diagnostics[[i]] <- data.table(year = years[i], iterations = ans$iterations)
  }
  list(
    delta = rbindlist(pieces)[order(row_id)]$delta,
    diagnostics = rbindlist(diagnostics)
  )
}

prepare_blp_sample <- function(dt, rate_name, share_name, outside_name) {
  x <- copy(dt)
  x[, `:=`(
    rate = get(rate_name), market_share = get(share_name),
    outside_share = get(outside_name)
  )]
  x <- x[is.finite(rate) & rate > 0 & rate <= 0.50 &
           is.finite(market_share) & market_share > 0 &
           is.finite(outside_share) & outside_share > 0 &
           is.finite(log_branches) & is.finite(log_employees_per_branch) &
           is.finite(salary_cost_instrument) & is.finite(premises_cost_instrument)]
  # Products excluded because of missing rates/covariates—and banks outside a
  # subgroup estimation—must be part of that estimation sample's outside option.
  x[, outside_share := 1 - sum(market_share), by = year]
  if (x[, any(!is.finite(outside_share) | outside_share <= 0)]) {
    stop("Invalid estimation-sample outside share after filtering")
  }
  setorder(x, year, cert)
  x[, z_salary_residual := resid(feols(
    salary_cost_instrument ~ 1 | cert + year, data = x, notes = FALSE, warn = FALSE,
    fixef.rm = "none"
  ))]
  x[, z_premises_residual := resid(feols(
    premises_cost_instrument ~ 1 | cert + year, data = x, notes = FALSE, warn = FALSE,
    fixef.rm = "none"
  ))]
  x[, z_salary_residual := as.numeric(scale(z_salary_residual))]
  x[, z_premises_residual := as.numeric(scale(z_premises_residual))]
  x
}

fit_linear_iv <- function(x, delta) {
  work <- copy(x)
  work[, delta := delta]
  feols(
    delta ~ log_branches + log_employees_per_branch |
      cert + year |
      rate ~ salary_cost_instrument + premises_cost_instrument,
    data = work, vcov = ~year, notes = FALSE, warn = FALSE, fixef.rm = "none"
  )
}

estimate_random_coefficient_blp <- function(dt, rate_name, share_name, outside_name,
                                            market_label, sample_label,
                                            expected_rate_sign,
                                            draws = default_blp_draws,
                                            sigma_upper = 150) {
  x <- prepare_blp_sample(dt, rate_name, share_name, outside_name)
  objective_history <- list()
  objective <- function(sigma) {
    inversion <- tryCatch(invert_all_markets(x, sigma, draws), error = function(e) NULL)
    if (is.null(inversion)) {
      objective_history[[length(objective_history) + 1L]] <<- data.table(
        sigma = sigma, objective = 1e12, salary_moment = NA_real_,
        premises_moment = NA_real_, monotonic_demand = FALSE
      )
      return(1e12)
    }
    fit <- fit_linear_iv(x, inversion$delta)
    xi <- resid(fit)
    moments <- c(
      mean(x$z_salary_residual * xi),
      mean(x$z_premises_residual * xi)
    )
    alpha_candidate <- unname(coef(fit)["fit_rate"])
    individual_coefficients <- alpha_candidate + sigma * draws
    monotonic <- all(expected_rate_sign * individual_coefficients > 0)
    value <- sum(moments^2)
    if (!monotonic) {
      violation <- pmax(0, -expected_rate_sign * individual_coefficients)
      value <- value + 1e6 + sum(violation^2)
    }
    objective_history[[length(objective_history) + 1L]] <<- data.table(
      sigma = sigma, objective = value, salary_moment = moments[1L],
      premises_moment = moments[2L], monotonic_demand = monotonic
    )
    value
  }
  optimization <- optimize(objective, interval = c(0, sigma_upper), tol = 0.05)
  sigma <- optimization$minimum
  inversion <- invert_all_markets(x, sigma, draws)
  fit <- fit_linear_iv(x, inversion$delta)
  alpha <- unname(coef(fit)["fit_rate"])

  # Full random-coefficient own derivative. With one independently owned bank
  # product per CERT, the ownership matrix is identity, so the ownership-weighted
  # full Jacobian reduces exactly to these diagonal elements. Cross derivatives
  # are summarized separately and are not discarded from demand calculations.
  x[, `:=`(
    mean_rate_coefficient = alpha,
    rate_coefficient_sd = sigma,
    market = market_label,
    estimation_sample = sample_label
  )]
  derivative_diagnostics <- list()
  for (yr in sort(unique(x$year))) {
    rows <- which(x$year == yr)
    delta <- inversion$delta[rows]
    rates <- x$rate[rows]
    mu <- outer(rates, sigma * draws)
    utility <- delta + mu
    column_max <- pmax(0, apply(utility, 2L, max))
    numerator <- exp(sweep(utility, 2L, column_max, "-"))
    individual_shares <- sweep(
      numerator, 2L, exp(-column_max) + colSums(numerator), "/"
    )
    individual_alpha <- alpha + sigma * draws
    own <- rowMeans(sweep(individual_shares * (1 - individual_shares), 2L,
                           individual_alpha, "*"))
    x[rows, own_rate_derivative := own]
    # Sum of cross effects for each product, an exact row-sum diagnostic of the
    # off-diagonal Jacobian without writing an infeasible J-by-J file to disk.
    other_inside_share <- matrix(
      colSums(individual_shares), nrow = length(rows), ncol = length(draws), byrow = TRUE
    ) - individual_shares
    cross_sum <- rowMeans(sweep(
      -individual_shares * other_inside_share, 2L, individual_alpha, "*"
    ))
    derivative_diagnostics[[length(derivative_diagnostics) + 1L]] <- data.table(
      year = yr, products = length(rows), mean_own_derivative = mean(own),
      mean_cross_derivative_sum = mean(cross_sum)
    )
  }
  x[, economically_valid_slope := expected_rate_sign * own_rate_derivative > 0]
  x[, structural_markup := fifelse(
    economically_valid_slope,
    expected_rate_sign * market_share / own_rate_derivative,
    NA_real_
  )]
  list(
    fit = fit, sigma = sigma, optimization = optimization,
    objective_history = rbindlist(objective_history),
    contraction_diagnostics = inversion$diagnostics,
    derivative_diagnostics = rbindlist(derivative_diagnostics),
    observations = x
  )
}

save_random_blp <- function(result, prefix, compact_dir, detailed_dir) {
  dir.create(compact_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(detailed_dir, recursive = TRUE, showWarnings = FALSE)
  fwrite(data.table(
    mean_rate_coefficient = unname(coef(result$fit)["fit_rate"]),
    mean_rate_se = unname(se(result$fit)["fit_rate"]),
    random_rate_sd = result$sigma,
    sigma_search_upper_bound = 150,
    sigma_at_search_boundary = result$sigma >= 149.5,
    gmm_objective = result$optimization$objective,
    observations = nobs(result$fit),
    banks = uniqueN(result$observations$cert),
    years = uniqueN(result$observations$year),
    valid_markup_observations = sum(result$observations$economically_valid_slope),
    invalid_derivative_observations = sum(!result$observations$economically_valid_slope),
    mean_markup = mean(result$observations$structural_markup, na.rm = TRUE),
    median_markup = median(result$observations$structural_markup, na.rm = TRUE)
  ), file.path(compact_dir, paste0(prefix, "_summary.csv")))
  arrow::write_parquet(result$observations[, .(
    cert, year, bank_name, agricultural_bank, market_share, rate,
    mean_rate_coefficient, rate_coefficient_sd, own_rate_derivative,
    economically_valid_slope, structural_markup
  )], file.path(detailed_dir, paste0(prefix, "_bank_year.parquet")), compression = "zstd")
}


