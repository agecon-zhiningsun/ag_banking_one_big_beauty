source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(readxl)
})

raw_dir <- file.path(data_root, "raw", "obbba_policy", "fsa_arc_plc")
final_dir <- file.path(data_root, "processed", "nc1177")
out_dir <- file.path("output", "tables", "obbba_simulation")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

key <- function(x) gsub("[^a-z0-9]+", "_", tolower(trimws(x)))
aliases <- c(
  "grain_sorghum" = "grain_sorghum", "soybean" = "soybeans", "soybeans" = "soybeans",
  "beans_large_chickpeas" = "large_chickpeas", "large_chickpeas" = "large_chickpeas",
  "beans_small_chickpeas" = "small_chickpeas", "small_chickpeas" = "small_chickpeas",
  "seed_cotton" = "seed_cotton", "sunflower_seed" = "sunflower_seed",
  "rice_long_grain" = "long_grain_rice", "rice_long_grain_" = "long_grain_rice",
  "rice_med_grain" = "medium_short_grain_rice",
  "rice_med_short_grain_3_" = "medium_short_grain_rice",
  "rice_temperate_japonica" = "temperate_japonica_rice",
  "rice_temperate_japonica_" = "temperate_japonica_rice",
  "dry_peas" = "dry_peas", "peanuts" = "peanuts"
)
normalize_crop <- function(x) {
  out <- key(x)
  hit <- out %in% names(aliases)
  out[hit] <- unname(aliases[out[hit]])
  out
}

base <- as.data.table(read_excel(
  file.path(raw_dir, "2025_enrolled_base_county_crop_program.xlsx"), skip = 2
))
setnames(base, c("ST_CTY", "Crop Name", "Program", "Enrolled Base"),
         c("county_fips", "crop", "program", "base_acres"))
base[, `:=`(
  county_fips = sprintf("%05s", county_fips),
  crop_key = normalize_crop(crop),
  program = toupper(program),
  base_acres = as.numeric(base_acres)
)]

yields <- as.data.table(read_excel(file.path(raw_dir, "2025_PLC_yields_base.xlsx"), skip = 2))
setnames(yields, c("State", "County", "Crop Name", "PLC Yield", "PLC Yield Units"),
         c("state_fips", "county_code", "crop", "plc_yield", "yield_unit"))
yields[, `:=`(
  county_fips = sprintf("%02s%03s", state_fips, county_code),
  crop_key = normalize_crop(crop),
  plc_yield = as.numeric(plc_yield)
)]
yields <- unique(yields[, .(county_fips, crop_key, plc_yield, yield_unit)])

plc <- as.data.table(read_excel(file.path(raw_dir, "2026_PLC.xlsx"), skip = 6))
plc <- plc[!is.na(Commodity)]
plc[, crop_key := normalize_crop(gsub("[0-9]+/", "", Commodity))]
setnames(
  plc,
  c("Projected (P) or Final (F) 2026 Effective Price",
    "Projected (P) or Final (F) 2026 PLC Payment Rate",
    "2026 Effective Reference Price"),
  c("projected_effective_price", "obbba_plc_rate", "obbba_effective_reference_price")
)
plc <- plc[, .(
  crop_key, payment_unit = Unit,
  projected_effective_price = as.numeric(projected_effective_price),
  obbba_plc_rate = as.numeric(obbba_plc_rate),
  obbba_effective_reference_price = as.numeric(obbba_effective_reference_price)
)]

statutory <- fread(file.path("docs", "obbba_plc_reference_prices.csv"))
statutory[, crop_key := commodity]
# Convert statutory dollars per cwt/ton to the FSA payment-rate unit matching
# county program yields (pounds except flaxseed, which is bushels).
statutory[, old_reference_per_yield_unit := pre_obbba_statutory_reference_price]
statutory[unit == "cwt", old_reference_per_yield_unit := old_reference_per_yield_unit / 100]
statutory[unit == "ton", old_reference_per_yield_unit := old_reference_per_yield_unit / 2000]
statutory[crop_key == "flaxseed", old_reference_per_yield_unit :=
            pre_obbba_statutory_reference_price * 56 / 100]

plc_inputs <- merge(base[program == "PLC"], yields, by = c("county_fips", "crop_key"), all.x = TRUE)
plc_inputs <- merge(plc_inputs, plc, by = "crop_key", all.x = TRUE)
plc_inputs <- merge(
  plc_inputs,
  statutory[, .(crop_key, old_reference_per_yield_unit)],
  by = "crop_key", all.x = TRUE
)
plc_inputs[, baseline_plc_rate := pmax(old_reference_per_yield_unit - projected_effective_price, 0)]
plc_inputs[, `:=`(
  baseline_plc_payment = 0.85 * base_acres * plc_yield * baseline_plc_rate,
  obbba_plc_payment = 0.85 * base_acres * plc_yield * obbba_plc_rate
)]
plc_inputs[, incremental_plc_payment := obbba_plc_payment - baseline_plc_payment]

arc <- as.data.table(read_excel(file.path(raw_dir, "2026_ARCCO.xlsx"), skip = 3))
setnames(
  arc,
  c("ST_Cty", "Crop Name", "2026 Benchmark Revenue"),
  c("county_fips", "crop", "benchmark_revenue")
)
arc[, `:=`(
  county_fips = sprintf("%05s", county_fips),
  crop_key = normalize_crop(crop),
  benchmark_revenue = as.numeric(benchmark_revenue)
)]
arc_inputs <- merge(
  base[grepl("ARC", program), .(county_fips, crop_key, arc_base_acres = base_acres)],
  arc[, .(county_fips, crop_key, benchmark_revenue)],
  by = c("county_fips", "crop_key"), all.x = TRUE
)

revenue_scenarios <- data.table(actual_revenue_share = c(0.70, 0.80, 0.85, 0.90, 1.00))
arc_inputs[, cross_join_key := 1L]
revenue_scenarios[, cross_join_key := 1L]
arc_scenarios <- merge(arc_inputs, revenue_scenarios, by = "cross_join_key", allow.cartesian = TRUE)
arc_scenarios[, cross_join_key := NULL]
arc_scenarios[, `:=`(
  baseline_arc_rate = pmin(pmax((0.86 - actual_revenue_share) * benchmark_revenue, 0),
                           0.10 * benchmark_revenue),
  obbba_arc_rate = pmin(pmax((0.90 - actual_revenue_share) * benchmark_revenue, 0),
                        0.125 * benchmark_revenue)
)]
arc_scenarios[, `:=`(
  baseline_arc_payment = 0.85 * arc_base_acres * baseline_arc_rate,
  obbba_arc_payment = 0.85 * arc_base_acres * obbba_arc_rate
)]
arc_scenarios[, incremental_arc_payment := obbba_arc_payment - baseline_arc_payment]

plc_county <- plc_inputs[, .(
  baseline_plc_payment = sum(baseline_plc_payment, na.rm = TRUE),
  obbba_plc_payment = sum(obbba_plc_payment, na.rm = TRUE),
  incremental_plc_payment = sum(incremental_plc_payment, na.rm = TRUE)
), by = county_fips]
arc_county <- arc_scenarios[, .(
  baseline_arc_payment = sum(baseline_arc_payment, na.rm = TRUE),
  obbba_arc_payment = sum(obbba_arc_payment, na.rm = TRUE),
  incremental_arc_payment = sum(incremental_arc_payment, na.rm = TRUE)
), by = .(county_fips, actual_revenue_share)]
county <- merge(arc_county, plc_county, by = "county_fips", all = TRUE)
for (field in names(county)[grepl("payment$", names(county))]) setnafill(county, fill = 0, cols = field)

# Explicit 30-million-acre scenario: allocate new acres proportionally to the
# observed 2025 county/crop/program mix. This is not an official county allocation.
total_existing <- sum(base$base_acres, na.rm = TRUE)
county[, proportional_added_base_multiplier := 30000000 / total_existing]
county[, added_base_payment_scenario := proportional_added_base_multiplier *
         (obbba_arc_payment + obbba_plc_payment)]
county[, full_incremental_payment_scenario := incremental_arc_payment +
         incremental_plc_payment + added_base_payment_scenario]

retention <- fread(file.path("output", "tables", "payment_retention", "payment_retention_estimates.csv"))
arc_retention <- retention[grepl("ARC/PLC disbursements", specification), estimate][1L]
retention_scenarios <- data.table(
  retention_case = c("zero", "estimated_naive", "ten_percent", "twenty_five_percent"),
  retention_rate = c(0, arc_retention, 0.10, 0.25)
)
county[, cross_join_key := 1L]
retention_scenarios[, cross_join_key := 1L]
county_deposit <- merge(county, retention_scenarios, by = "cross_join_key", allow.cartesian = TRUE)
county_deposit[, cross_join_key := NULL]
county_deposit[, predicted_deposit_change := retention_rate * full_incremental_payment_scenario]

# Bank mapping uses 2025 branch-deposit shares and remains a service-area exposure.
county_bank <- as.data.table(read_parquet(file.path(
  data_root, "pipeline_cache", "nc1177", "sod", "county_bank_year_1994_2025.parquet"
)))[year == 2025L]
county_bank[, weight := bank_county_deposits / sum(bank_county_deposits, na.rm = TRUE), by = cert]
bank <- county_deposit[county_bank, on = "county_fips", allow.cartesian = TRUE]
bank <- bank[, .(
  predicted_incremental_policy_payments = sum(weight * full_incremental_payment_scenario, na.rm = TRUE),
  predicted_deposit_change = sum(weight * predicted_deposit_change, na.rm = TRUE),
  exposure_weight_covered = sum(weight[!is.na(full_incremental_payment_scenario)], na.rm = TRUE)
), by = .(cert, actual_revenue_share, retention_case, retention_rate)]

write_parquet(plc_inputs, file.path(final_dir, "obbba_plc_payment_simulation_inputs.parquet"), compression = "zstd")
write_parquet(arc_scenarios, file.path(final_dir, "obbba_arc_payment_simulation_inputs.parquet"), compression = "zstd")
write_parquet(county_deposit, file.path(final_dir, "obbba_county_payment_deposit_scenarios.parquet"), compression = "zstd")
write_parquet(bank, file.path(final_dir, "obbba_bank_payment_deposit_scenarios.parquet"), compression = "zstd")

summary <- county_deposit[, .(
  baseline_arc_payments = sum(baseline_arc_payment),
  obbba_arc_payments = sum(obbba_arc_payment),
  baseline_plc_payments = sum(baseline_plc_payment),
  obbba_plc_payments = sum(obbba_plc_payment),
  added_base_payment_scenario = sum(added_base_payment_scenario),
  full_incremental_payments = sum(full_incremental_payment_scenario),
  predicted_deposit_change = sum(predicted_deposit_change)
), by = .(actual_revenue_share, retention_case, retention_rate)]
fwrite(summary, file.path(out_dir, "national_scenario_summary.csv"))
fwrite(plc_inputs[, .(
  plc_rows = .N,
  matched_yield_share = sum(base_acres[is.finite(plc_yield)], na.rm = TRUE) / sum(base_acres),
  matched_rate_share = sum(base_acres[is.finite(obbba_plc_rate)], na.rm = TRUE) / sum(base_acres)
)], file.path(out_dir, "plc_input_coverage.csv"))

message("Wrote OBBBA ARC/PLC payment and deposit scenarios to ", out_dir)
