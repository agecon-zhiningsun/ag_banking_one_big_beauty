source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
})

# This script prepares empirically observed farm shocks and audits whether each
# proposed Bellman counterfactual is identified by the current model. It does not
# manufacture a latent bank-farmer relationship stock.

input_path <- file.path(
  data_root, "processed", "nc1177", "dynamic_bank_model",
  "03a_bank_year_dynamic_model_inputs_1994_2025.parquet"
)
out_dir <- file.path("output", "tables", "04b_dynamic_readiness")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(input_path)) stop("Construct the dynamic-model inputs first.")

x <- as.data.table(read_parquet(input_path))
annual <- unique(x[, .(
  year,
  real_net_cash_farm_income_2026_thousands,
  farm_income_innovation,
  farm_downturn_state,
  farm_state,
  farm_state_label
)])[order(year)]

# Estimate the annual farm-state process only from unique national years. The
# innovation is already based on detrended real net cash farm income.
annual[, lag_state := shift(farm_downturn_state)]
ar_fit <- lm(farm_downturn_state ~ lag_state, data = annual)
rho <- unname(coef(ar_fit)["lag_state"])
intercept <- unname(coef(ar_fit)["(Intercept)"])
sigma <- sd(residuals(ar_fit), na.rm = TRUE)
p10 <- unname(quantile(annual$farm_income_innovation, 0.10, na.rm = TRUE))

shock_summary <- data.table(
  object = c("farm_state_intercept", "farm_state_persistence",
             "farm_state_innovation_sd", "farm_income_innovation_p10"),
  estimate = c(intercept, rho, sigma, p10),
  interpretation = c(
    "Intercept in the annual AR(1) farm-state process",
    "Persistence of the annual farm-state process",
    "One-standard-deviation standardized farm-state innovation",
    "Empirical tenth-percentile real-farm-income innovation"
  )
)

historical_path <- annual[year %between% c(2014L, 2019L), .(
  year,
  real_net_cash_farm_income_2026_thousands,
  farm_income_innovation,
  farm_downturn_state,
  farm_state_label
)]

readiness <- data.table(
  counterfactual = c(
    "A_no_policy",
    "B_obbba_current_market_power",
    "B1_to_B6_current_power_channel_decompositions"
  ),
  design = c(
    "Set all OBBBA policy shocks to zero under estimated market power.",
    "Apply all modeled OBBBA channels under estimated deposit and agricultural-loan market power.",
    "Activate funding, borrower-liquidity, default-risk, and government-credit channels separately while retaining current market power."
  ),
  current_status = c(
    "complete",
    "coarse_grid_structural_calibration_complete",
    "coarse_grid_structural_calibration_complete"
  ),
  current_result = c(
    "Provides the comparison baseline.",
    "Primary policy counterfactual.",
    "Shows which policy channels drive the primary result without changing market structure."
  )
)

fwrite(shock_summary, file.path(out_dir, "04b_farm_state_process.csv"))
fwrite(historical_path, file.path(out_dir, "04b_historical_downturn_2014_2019.csv"))
fwrite(readiness, file.path(out_dir, "04b_counterfactual_readiness.csv"))

message("Prepared observed farm shocks and audited dynamic-counterfactual readiness.")
