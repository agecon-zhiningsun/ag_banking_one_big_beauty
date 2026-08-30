source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
})

cache <- file.path(data_root, "pipeline_cache", "nc1177")
policy_dir <- file.path(cache, "obbba_policy")
final_dir <- file.path(data_root, "processed", "nc1177")
dir.create(final_dir, recursive = TRUE, showWarnings = FALSE)

payments <- as.data.table(read_parquet(file.path(
  policy_dir, "bea_county_government_payments_1969_2022.parquet"
)))
arc_plc <- as.data.table(read_parquet(file.path(
  policy_dir, "fsa_arc_plc_county_2014_2018.parquet"
)))
county_market <- as.data.table(read_parquet(file.path(
  cache, "sod", "county_market_year_1994_2025.parquet"
)))
county_bank <- as.data.table(read_parquet(file.path(
  cache, "sod", "county_bank_year_1994_2025.parquet"
)))
bea_income <- as.data.table(read_parquet(file.path(
  cache, "bea", "bea_county_farm_income_1969_2024.parquet"
)))

# County-market panel is the preferred deposit design. It never allocates farm
# payments to a specific bank and instead asks whether total deposits located in
# the exposed county rise. Deposits include nonfarm accounts, so estimates are
# intentionally reduced-form local-market effects, not farmer retention rates.
county <- merge(county_market, payments, by = c("county_fips", "year"), all.x = TRUE)
county <- merge(county, arc_plc, by = c("county_fips", "year"), all.x = TRUE)
county <- merge(
  county,
  bea_income[, .(county_fips, year, bea_farm_income_thousands, bea_personal_income_thousands)],
  by = c("county_fips", "year"), all.x = TRUE
)
setorder(county, county_fips, year)
county[, `:=`(
  delta_county_deposits_thousands = county_deposits - shift(county_deposits),
  lag_county_deposits_thousands = shift(county_deposits),
  government_payment_share_lag_deposits = government_payments_thousands / shift(county_deposits),
  arc_plc_payment_share_lag_deposits = (arc_plc_payments_dollars / 1000) / shift(county_deposits)
), by = county_fips]

# Bank exposure uses prior-year SOD geography. This does not claim that a bank's
# customers received the county payment; it is a predetermined service-area
# exposure used with bank-level Call Report outcomes.
county_bank[, weight_total := sum(bank_county_deposits, na.rm = TRUE), by = .(cert, year)]
county_bank[, lagged_sod_weight := fifelse(weight_total > 0, bank_county_deposits / weight_total, NA_real_)]
county_bank[, exposure_year := year + 1L]
payments_for_join <- copy(payments)
arc_plc_for_join <- copy(arc_plc)
setnames(payments_for_join, "year", "exposure_year")
setnames(arc_plc_for_join, "year", "exposure_year")
bank_geo <- merge(county_bank, payments_for_join, by = c("county_fips", "exposure_year"), all.x = TRUE)
bank_geo <- merge(bank_geo, arc_plc_for_join, by = c("county_fips", "exposure_year"), all.x = TRUE)
bank_exposure <- bank_geo[, .(
  weighted_government_payments_thousands = sum(lagged_sod_weight * government_payments_thousands, na.rm = TRUE),
  weighted_arc_plc_payments_thousands = sum(lagged_sod_weight * arc_plc_payments_dollars / 1000, na.rm = TRUE),
  lagged_sod_weight_covered = sum(lagged_sod_weight[!is.na(government_payments_thousands)], na.rm = TRUE),
  counties_served = uniqueN(county_fips)
), by = .(cert, year = exposure_year)]

bank_panel <- as.data.table(read_parquet(file.path(final_dir, "bank_year_market_power_inputs_1994_2025.parquet")))
bank_panel <- merge(bank_panel, bank_exposure, by = c("cert", "year"), all.x = TRUE)

write_parquet(county, file.path(final_dir, "county_payment_retention_panel_1994_2022.parquet"), compression = "zstd")
write_parquet(bank_panel, file.path(final_dir, "bank_policy_exposure_panel_1994_2025.parquet"), compression = "zstd")

message("Wrote county and bank payment-exposure panels to ", final_dir)
