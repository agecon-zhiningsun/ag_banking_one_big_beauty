source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(readxl)
})

raw_file <- file.path(
  data_root, "raw", "obbba_policy", "fsa_arc_plc",
  "2023_enrolled_base_county_crop_program.xlsx"
)
out_dir <- file.path(data_root, "processed", "nc1177")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

base <- as.data.table(read_excel(raw_file, skip = 3, col_names = c(
  "county_fips", "state_name", "county_name", "crop", "program", "enrolled_base_acres"
)))
base[, `:=`(
  county_fips = sprintf("%05s", as.character(county_fips)),
  crop_key = gsub("[^a-z0-9]+", "_", tolower(trimws(crop))),
  program = toupper(gsub("[^A-Za-z]", "", program)),
  enrolled_base_acres = as.numeric(enrolled_base_acres)
)]

prices <- fread(file.path("docs", "obbba_plc_reference_prices.csv"))
prices[, crop_key := commodity]

# FSA naming differs slightly from the statutory table.
aliases <- c(
  "grain_sorghum" = "grain_sorghum", "sorghum" = "grain_sorghum",
  "soybean" = "soybeans", "soybeans" = "soybeans",
  "dry_pea" = "dry_peas", "dry_peas" = "dry_peas",
  "chickpeas_large" = "large_chickpeas", "chickpeas_small" = "small_chickpeas",
  "large_chickpea" = "large_chickpeas", "small_chickpea" = "small_chickpeas",
  "seed_cotton" = "seed_cotton", "sunflower" = "sunflower_seed",
  "sunflower_seed" = "sunflower_seed", "rice_long_grain" = "long_grain_rice",
  "long_grain_rice" = "long_grain_rice", "rice_med_short_grain" = "medium_short_grain_rice",
  "medium_grain_rice" = "medium_short_grain_rice",
  "rice_temperate_japonica" = "temperate_japonica_rice",
  "temperate_japonica_rice" = "temperate_japonica_rice"
)
base[crop_key %in% names(aliases), crop_key := unname(aliases[crop_key])]
base <- prices[base, on = "crop_key"]
base[, reference_price_pct_change :=
       obbba_2026_2030_reference_price / pre_obbba_statutory_reference_price - 1]

# These are exposure indices, not dollar payment forecasts. PLC depends on the
# realized market-year price and program yield; ARC depends on realized county
# revenue. The indices isolate the statutory shift using predetermined acres.
county <- base[is.finite(enrolled_base_acres), .(
  total_enrolled_base_acres = sum(enrolled_base_acres, na.rm = TRUE),
  plc_base_acres = sum(enrolled_base_acres[program == "PLC"], na.rm = TRUE),
  arc_base_acres = sum(enrolled_base_acres[grepl("ARC", program)], na.rm = TRUE),
  matched_reference_price_acres = sum(enrolled_base_acres[is.finite(reference_price_pct_change)], na.rm = TRUE),
  plc_reference_price_exposure = weighted.mean(
    fifelse(program == "PLC", reference_price_pct_change, 0),
    enrolled_base_acres, na.rm = TRUE
  ),
  arc_guarantee_exposure = sum(enrolled_base_acres[grepl("ARC", program)], na.rm = TRUE) /
    sum(enrolled_base_acres, na.rm = TRUE) * (0.90 / 0.86 - 1)
), by = .(county_fips, state_name, county_name)]

# Map the county shock to banks using the pre-policy 2025 SOD deposit geography.
# This is service-area exposure, not an assertion that all depositors are farms.
county_bank <- as.data.table(read_parquet(file.path(
  data_root, "pipeline_cache", "nc1177", "sod", "county_bank_year_1994_2025.parquet"
)))[year == 2025L]
county_bank[, bank_deposit_total := sum(bank_county_deposits, na.rm = TRUE), by = cert]
county_bank[, bank_county_weight := fifelse(
  bank_deposit_total > 0, bank_county_deposits / bank_deposit_total, NA_real_
)]
mapped <- county[county_bank, on = "county_fips"]
bank <- mapped[, .(
  obbba_plc_reference_price_exposure = sum(bank_county_weight * plc_reference_price_exposure, na.rm = TRUE),
  obbba_arc_guarantee_exposure = sum(bank_county_weight * arc_guarantee_exposure, na.rm = TRUE),
  exposure_weight_covered = sum(bank_county_weight[!is.na(total_enrolled_base_acres)], na.rm = TRUE),
  counties_served_2025 = uniqueN(county_fips)
), by = cert]

write_parquet(base, file.path(out_dir, "obbba_crop_county_base_acre_inputs.parquet"), compression = "zstd")
write_parquet(county, file.path(out_dir, "obbba_county_policy_exposure.parquet"), compression = "zstd")
write_parquet(bank, file.path(out_dir, "obbba_bank_policy_exposure.parquet"), compression = "zstd")

dir.create(file.path("output", "tables", "obbba_exposure"), recursive = TRUE, showWarnings = FALSE)
fwrite(county[, .(
  counties = .N,
  total_enrolled_base_acres = sum(total_enrolled_base_acres, na.rm = TRUE),
  median_plc_reference_price_exposure = median(plc_reference_price_exposure, na.rm = TRUE),
  median_arc_guarantee_exposure = median(arc_guarantee_exposure, na.rm = TRUE)
)], file.path("output", "tables", "obbba_exposure", "county_exposure_summary.csv"))

message("Wrote OBBBA county and bank exposure indices to ", out_dir)
