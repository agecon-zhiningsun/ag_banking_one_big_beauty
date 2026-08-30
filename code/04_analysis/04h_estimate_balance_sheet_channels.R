source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

final_dir <- file.path(data_root, "processed", "nc1177")
cache_dir <- file.path(data_root, "pipeline_cache", "nc1177")
out_dir <- file.path("output", "tables", "04h_balance_sheet_channels")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

county <- as.data.table(read_parquet(file.path(
  final_dir, "03c_county_payment_retention_panel_1994_2025.parquet"
)))[, .(county_fips, year, total_fsa_payment_share_lag_deposits)]
geo <- as.data.table(read_parquet(file.path(
  cache_dir, "sod", "county_bank_year_1994_2025.parquet"
)))
geo[, weight := bank_county_deposits / sum(bank_county_deposits, na.rm = TRUE),
    by = .(cert, year)]
geo[, year := year + 1L]
exposure <- county[geo, on = .(county_fips, year), nomatch = 0L][, .(
  total_fsa_service_area_intensity = sum(
    weight * total_fsa_payment_share_lag_deposits, na.rm = TRUE
  )
), by = .(cert, year)]

x <- as.data.table(read_parquet(file.path(
  final_dir, "dynamic_bank_model", "03a_bank_year_dynamic_model_inputs_1994_2025.parquet"
)))
x <- merge(x, exposure, by = c("cert", "year"), all = FALSE)
x <- x[year %between% c(2015L, 2025L) & is.finite(total_fsa_service_area_intensity)]
q <- quantile(x$total_fsa_service_area_intensity, c(0.01, 0.99), na.rm = TRUE)
x <- x[total_fsa_service_area_intensity %between% q]

outcomes <- c(
  "net_chargeoff_rate", "wholesale_funding_asset_ratio",
  "cash_reserve_asset_ratio", "capital_ratio", "blp_ag_markup",
  "blp_deposit_markdown", "deposit_rate"
)
models <- lapply(outcomes, function(y) feols(
  as.formula(paste0(y, " ~ total_fsa_service_area_intensity | cert + year")),
  data = x, cluster = ~cert
))
names(models) <- outcomes
extract <- function(m, y) {
  ct <- coeftable(m)
  data.table(
    outcome = y,
    estimate = ct["total_fsa_service_area_intensity", "Estimate"],
    std_error = ct["total_fsa_service_area_intensity", "Std. Error"],
    p_value = ct["total_fsa_service_area_intensity", "Pr(>|t|)"],
    observations = nobs(m),
    status = "descriptive_service_area_association_not_causal"
  )
}
estimates <- rbindlist(Map(extract, models, names(models)))

shock <- as.data.table(read_parquet(file.path(
  final_dir, "04e_obbba_bellman_bank_shocks_2025.parquet"
)))[actual_revenue_share == 0.85 & retention_case == "estimated_total_fsa"]
shock <- merge(
  shock,
  x[year == 2025L, .(cert, observed_net_chargeoff_rate = net_chargeoff_rate)],
  by = "cert", all.x = TRUE
)
shock[, payment_intensity_shock := weighted_county_deposit_growth / retention_rate]
for (y in outcomes) {
  b <- estimates[outcome == y, estimate][1L]
  p <- estimates[outcome == y, p_value][1L]
  shock[, (paste0("predicted_", y, "_change")) := b * payment_intensity_shock]
  shock[, (paste0(y, "_effect_identified_10pct")) := p < 0.10]
}

# Historical payments are targeted to distress, so their charge-off coefficient
# cannot identify the causal insurance/default channel. Supply transparent
# sensitivities around observed bank charge-offs instead of imposing its sign.
default_scenarios <- CJ(
  cert = shock$cert,
  default_risk_case = c("no_default_effect", "chargeoffs_down_10pct", "chargeoffs_down_25pct"),
  unique = TRUE
)
default_scenarios <- merge(
  default_scenarios,
  shock[, .(cert, agricultural_bank,
            net_chargeoff_rate = observed_net_chargeoff_rate,
            payment_intensity_shock)],
  by = "cert", all.x = TRUE
)
default_scenarios[, default_risk_multiplier := fcase(
  default_risk_case == "no_default_effect", 1,
  default_risk_case == "chargeoffs_down_10pct", 0.90,
  default = 0.75
)]
default_scenarios[, calibrated_chargeoff_change :=
                    net_chargeoff_rate * (default_risk_multiplier - 1)]

# OBBBA also raises Marketing Assistance Loan rates. Base acres are used only
# as a transparent county/crop exposure proxy because MAL eligibility follows
# current production, not base acreage; this is not a dollar-volume forecast.
mal <- fread(file.path("docs", "05f_obbba_marketing_assistance_loan_rates.csv"))
base <- as.data.table(read_parquet(file.path(
  final_dir, "04d_obbba_arc_payment_simulation_inputs.parquet"
)))[, .(county_fips, crop_key, base_acres = arc_base_acres)]
plc_base <- as.data.table(read_parquet(file.path(
  final_dir, "04d_obbba_plc_payment_simulation_inputs.parquet"
)))[, .(county_fips, crop_key, base_acres)]
base <- rbindlist(list(base, plc_base), fill = TRUE)[is.finite(base_acres)]
base <- base[, .(base_acres = sum(base_acres)), by = .(county_fips, crop_key)]
mal[, crop_key := commodity]
mal_exposure <- merge(base, mal[, .(crop_key, percent_change)], by = "crop_key")
mal_exposure <- mal_exposure[, .(
  mal_rate_increase_pct = weighted.mean(percent_change, base_acres),
  covered_base_acres = sum(base_acres)
), by = county_fips]

fwrite(estimates, file.path(out_dir, "04h_total_fsa_balance_sheet_channel_estimates.csv"))
fwrite(default_scenarios[, .(
  banks = uniqueN(cert),
  mean_calibrated_chargeoff_change = mean(calibrated_chargeoff_change, na.rm = TRUE)
), by = default_risk_case], file.path(out_dir, "04h_default_risk_scenarios.csv"))
fwrite(mal_exposure, file.path(out_dir, "04h_county_marketing_assistance_loan_rate_exposure.csv"))
write_parquet(shock, file.path(final_dir, "04h_obbba_bank_balance_sheet_channel_shocks.parquet"),
              compression = "zstd")
write_parquet(default_scenarios, file.path(final_dir, "04h_obbba_bank_default_risk_scenarios.parquet"),
              compression = "zstd")
writeLines(capture.output(etable(models)),
           file.path(out_dir, "04h_total_fsa_balance_sheet_channel_models.txt"))

message("Estimated OBBBA balance-sheet channels and prepared default/MAL scenarios.")
