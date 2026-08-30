source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

final_dir <- file.path(data_root, "processed", "nc1177")
cache_dir <- file.path(data_root, "pipeline_cache", "nc1177")
out_dir <- file.path("output", "tables", "obbba_lending")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Construct a bank service-area payment intensity using prior-year SOD county
# weights. This does not allocate payments to particular bank customers.
county <- as.data.table(read_parquet(file.path(
  final_dir, "county_payment_retention_panel_1994_2025.parquet"
)))[, .(county_fips, year, total_fsa_payment_share_lag_deposits)]
geo <- as.data.table(read_parquet(file.path(
  cache_dir, "sod", "county_bank_year_1994_2025.parquet"
)))
geo[, weight_total := sum(bank_county_deposits, na.rm = TRUE), by = .(cert, year)]
geo[, lagged_sod_weight := bank_county_deposits / weight_total]
geo[, year := year + 1L]
geo <- county[geo, on = .(county_fips, year), nomatch = 0L]
exposure <- geo[, .(
  total_fsa_service_area_intensity = sum(
    lagged_sod_weight * total_fsa_payment_share_lag_deposits, na.rm = TRUE
  ),
  exposure_weight_covered = sum(
    lagged_sod_weight[is.finite(total_fsa_payment_share_lag_deposits)], na.rm = TRUE
  )
), by = .(cert, year)]

bank <- as.data.table(read_parquet(file.path(
  final_dir, "bank_year_market_power_inputs_1994_2025.parquet"
)))
panel <- merge(bank, exposure, by = c("cert", "year"), all = FALSE)
panel <- panel[
  year %between% c(2015L, 2025L) & avg_lnag > 0 & avg_lnlsgr > 0 &
    is.finite(total_fsa_service_area_intensity)
]
q <- quantile(panel$total_fsa_service_area_intensity, c(0.01, 0.99), na.rm = TRUE)
panel <- panel[total_fsa_service_area_intensity %between% q]
panel[, `:=`(
  log_ag_production_loans = log(avg_lnag),
  log_total_loans = log(avg_lnlsgr)
)]

# These are reduced-form service-area associations with bank and year fixed
# effects. They combine borrower demand, bank supply, risk and program targeting;
# they are not a causal decomposition of those mechanisms.
models <- list(
  ag_loan_balance = feols(
    log_ag_production_loans ~ total_fsa_service_area_intensity | cert + year,
    data = panel, cluster = ~cert
  ),
  ag_loan_rate = feols(
    ag_production_loan_rate ~ total_fsa_service_area_intensity | cert + year,
    data = panel, cluster = ~cert
  ),
  total_loan_balance = feols(
    log_total_loans ~ total_fsa_service_area_intensity | cert + year,
    data = panel, cluster = ~cert
  )
)

extract <- function(model, outcome) {
  ct <- coeftable(model)
  data.table(
    outcome,
    term = rownames(ct),
    estimate = ct[, "Estimate"],
    std_error = ct[, "Std. Error"],
    p_value = ct[, "Pr(>|t|)"],
    observations = nobs(model),
    interpretation = "descriptive bank service-area reduced form; not causal"
  )
}
estimates <- rbindlist(Map(extract, models, names(models)))

# Dividing predicted deposit growth by beta_D recovers the same incremental-
# payment/local-deposit intensity used in the central deposit experiment.
shock <- as.data.table(read_parquet(file.path(
  final_dir, "obbba_bellman_bank_shocks_2025.parquet"
)))[actual_revenue_share == 0.85 & retention_case == "estimated_total_fsa"]
beta_ag_balance <- estimates[outcome == "ag_loan_balance", estimate][1L]
se_ag_balance <- estimates[outcome == "ag_loan_balance", std_error][1L]
beta_ag_rate <- estimates[outcome == "ag_loan_rate", estimate][1L]
ag_rate_p_value <- estimates[outcome == "ag_loan_rate", p_value][1L]
shock[, obbba_payment_service_area_intensity :=
        weighted_county_deposit_growth / retention_rate]
shock[, `:=`(
  predicted_log_ag_loan_change = beta_ag_balance * obbba_payment_service_area_intensity,
  predicted_log_ag_loan_change_ci_low = (beta_ag_balance - 1.96 * se_ag_balance) *
    obbba_payment_service_area_intensity,
  predicted_log_ag_loan_change_ci_high = (beta_ag_balance + 1.96 * se_ag_balance) *
    obbba_payment_service_area_intensity,
  predicted_ag_loan_rate_change = fifelse(
    ag_rate_p_value < 0.10,
    beta_ag_rate * obbba_payment_service_area_intensity,
    NA_real_
  )
)]
shock[, predicted_ag_loan_change_thousands :=
        avg_lnag * (exp(predicted_log_ag_loan_change) - 1)]
shock[, `:=`(
  predicted_ag_loan_change_ci_low_thousands =
    avg_lnag * (exp(predicted_log_ag_loan_change_ci_low) - 1),
  predicted_ag_loan_change_ci_high_thousands =
    avg_lnag * (exp(predicted_log_ag_loan_change_ci_high) - 1)
)]
shock[, bank_type := fcase(
  agricultural_bank == 1, "agricultural_banks",
  agricultural_bank == 0, "nonagricultural_banks",
  default = "unmatched_bank_characteristics"
)]

simulation <- shock[, .(
  banks = uniqueN(cert),
  aggregate_baseline_ag_loans_thousands = sum(avg_lnag, na.rm = TRUE),
  aggregate_predicted_ag_loan_change_thousands =
    sum(predicted_ag_loan_change_thousands, na.rm = TRUE),
  aggregate_predicted_ag_loan_change_ci_low_thousands =
    sum(predicted_ag_loan_change_ci_low_thousands, na.rm = TRUE),
  aggregate_predicted_ag_loan_change_ci_high_thousands =
    sum(predicted_ag_loan_change_ci_high_thousands, na.rm = TRUE),
  aggregate_predicted_ag_loan_pct = 100 *
    sum(predicted_ag_loan_change_thousands, na.rm = TRUE) /
    pmax(sum(avg_lnag, na.rm = TRUE), 1),
  mean_predicted_ag_loan_pct = 100 * mean(
    exp(predicted_log_ag_loan_change) - 1, na.rm = TRUE
  ),
  median_predicted_ag_loan_pct = 100 * median(
    exp(predicted_log_ag_loan_change) - 1, na.rm = TRUE
  ),
  mean_predicted_ag_loan_rate_change_basis_points =
    fifelse(ag_rate_p_value < 0.10,
            10000 * mean(predicted_ag_loan_rate_change, na.rm = TRUE), NA_real_),
  loan_rate_effect_status = fifelse(
    ag_rate_p_value < 0.10, "estimated", "not_statistically_identified"
  )
), by = bank_type]

fwrite(estimates, file.path(out_dir, "total_fsa_lending_reduced_form_estimates.csv"))
fwrite(simulation, file.path(out_dir, "obbba_lending_channel_simulation.csv"))
write_parquet(
  shock,
  file.path(final_dir, "obbba_bank_lending_channel_simulation_2025.parquet"),
  compression = "zstd"
)
writeLines(capture.output(etable(models)),
           file.path(out_dir, "total_fsa_lending_reduced_form_models.txt"))

message("Estimated and simulated the total-FSA agricultural-lending channel.")
