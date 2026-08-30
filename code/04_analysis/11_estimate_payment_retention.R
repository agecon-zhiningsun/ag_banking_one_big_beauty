source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

final_dir <- file.path(data_root, "processed", "nc1177")
out_dir <- file.path("output", "tables", "payment_retention")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

county <- as.data.table(read_parquet(file.path(final_dir, "county_payment_retention_panel_1994_2025.parquet")))
county <- county[is.finite(delta_county_deposits_thousands) & lag_county_deposits_thousands > 0]
county[, deposit_growth := delta_county_deposits_thousands / lag_county_deposits_thousands]

# Remove clear ratio outliers caused by new/closed SOD markets or tiny lagged
# deposit bases. The coefficient remains dollars of deposit stock per dollar of
# payments because both sides use the same lagged-deposit denominator.
trim <- function(x, p = c(0.01, 0.99)) {
  q <- quantile(x[is.finite(x)], p, na.rm = TRUE)
  x >= q[1L] & x <= q[2L]
}
county <- county[trim(deposit_growth)]

# Dollar retention: change in the county's total branch deposits (thousands of
# dollars) per thousand dollars of government payments. County and year fixed
# effects absorb permanent county scale and national banking/payment shocks.
total_model <- feols(
  deposit_growth ~ government_payment_share_lag_deposits |
    county_fips + year,
  data = county[is.finite(government_payment_share_lag_deposits) &
                  trim(government_payment_share_lag_deposits)], cluster = ~county_fips
)

fsa_total_sample <- county[year %between% c(2014L, 2025L) &
                             is.finite(total_fsa_payment_share_lag_deposits)]
fsa_total_sample <- fsa_total_sample[trim(total_fsa_payment_share_lag_deposits)]
fsa_total_model <- feols(
  deposit_growth ~ total_fsa_payment_share_lag_deposits | county_fips + year,
  data = fsa_total_sample, cluster = ~county_fips
)

arc_sample <- county[year %between% c(2015L, 2024L) & is.finite(arc_plc_payment_share_lag_deposits)]
arc_sample <- arc_sample[trim(arc_plc_payment_share_lag_deposits)]
arc_model <- feols(
  deposit_growth ~ arc_plc_payment_share_lag_deposits |
    county_fips + year,
  data = arc_sample, cluster = ~county_fips
)

mfp_sample <- county[year %between% c(2018L, 2022L) & is.finite(mfp_payment_share_lag_deposits)]
mfp_sample <- mfp_sample[trim(mfp_payment_share_lag_deposits)]
mfp_model <- feols(
  deposit_growth ~ mfp_payment_share_lag_deposits | county_fips + year,
  data = mfp_sample, cluster = ~county_fips
)

cfap_sample <- county[year %between% c(2020L, 2024L) & is.finite(cfap_payment_share_lag_deposits)]
cfap_sample <- cfap_sample[trim(cfap_payment_share_lag_deposits)]
cfap_model <- feols(
  deposit_growth ~ cfap_payment_share_lag_deposits | county_fips + year,
  data = cfap_sample, cluster = ~county_fips
)

joint_sample <- county[year %between% c(2015L, 2024L) &
                         is.finite(arc_plc_payment_share_lag_deposits) &
                         is.finite(mfp_payment_share_lag_deposits) &
                         is.finite(cfap_payment_share_lag_deposits)]
joint_model <- feols(
  deposit_growth ~ arc_plc_payment_share_lag_deposits +
    mfp_payment_share_lag_deposits + cfap_payment_share_lag_deposits |
    county_fips + year,
  data = joint_sample, cluster = ~county_fips
)

extract <- function(model, label) {
  ct <- coeftable(model)
  data.table(
    specification = label,
    term = rownames(ct),
    estimate = ct[, "Estimate"],
    std_error = ct[, "Std. Error"],
    p_value = ct[, "Pr(>|t|)"],
    observations = nobs(model),
    counties = length(unique(model$fixef_id[[1L]]))
  )
}

results <- rbindlist(list(
  extract(total_model, "BEA total government payments, county and year FE"),
  extract(fsa_total_model, "FSA total disbursements, 2014-2025 SOD windows"),
  extract(arc_model, "Univariate FSA ARC/PLC diagnostic"),
  extract(mfp_model, "Univariate FSA MFP diagnostic"),
  extract(cfap_model, "Univariate FSA CFAP diagnostic"),
  extract(joint_model, "Primary conditional FSA program-family model, 2015-2024")
))
fwrite(results, file.path(out_dir, "payment_retention_estimates.csv"))
coverage_path <- file.path(
  data_root, "pipeline_cache", "nc1177", "obbba_policy",
  "fsa_program_payment_coverage_2014_2025.csv"
)
if (file.exists(coverage_path)) {
  fwrite(fread(coverage_path), file.path(out_dir, "fsa_program_payment_coverage_2014_2025.csv"))
}
model_text <- capture.output(etable(
  total_model, fsa_total_model, arc_model, mfp_model, cfap_model, joint_model
))
writeLines(sub("[[:space:]]+$", "", model_text), file.path(out_dir, "payment_retention_models.txt"))

message("Wrote payment-retention estimates to ", out_dir)
