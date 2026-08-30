source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(fixest)
})

final_dir <- file.path(data_root, "processed", "nc1177")
out_dir <- file.path("output", "tables", "payment_retention")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

county <- as.data.table(read_parquet(file.path(final_dir, "county_payment_retention_panel_1994_2022.parquet")))
county <- county[is.finite(delta_county_deposits_thousands) &
                 is.finite(government_payments_thousands) &
                 lag_county_deposits_thousands > 0]
county[, deposit_growth := delta_county_deposits_thousands / lag_county_deposits_thousands]

# Remove clear ratio outliers caused by new/closed SOD markets or tiny lagged
# deposit bases. The coefficient remains dollars of deposit stock per dollar of
# payments because both sides use the same lagged-deposit denominator.
trim <- function(x, p = c(0.01, 0.99)) {
  q <- quantile(x[is.finite(x)], p, na.rm = TRUE)
  x >= q[1L] & x <= q[2L]
}
county <- county[trim(deposit_growth) & trim(government_payment_share_lag_deposits)]

# Dollar retention: change in the county's total branch deposits (thousands of
# dollars) per thousand dollars of government payments. County and year fixed
# effects absorb permanent county scale and national banking/payment shocks.
total_model <- feols(
  deposit_growth ~ government_payment_share_lag_deposits |
    county_fips + year,
  data = county, cluster = ~county_fips
)

arc_sample <- county[year %between% c(2014L, 2018L) & is.finite(arc_plc_payments_dollars)]
arc_sample <- arc_sample[trim(arc_plc_payment_share_lag_deposits)]
arc_model <- feols(
  deposit_growth ~ arc_plc_payment_share_lag_deposits |
    county_fips + year,
  data = arc_sample, cluster = ~county_fips
)

extract <- function(model, label) {
  ct <- coeftable(model)
  data.table(
    specification = label,
    term = rownames(ct)[1L],
    estimate = ct[1L, "Estimate"],
    std_error = ct[1L, "Std. Error"],
    p_value = ct[1L, "Pr(>|t|)"],
    observations = nobs(model),
    counties = length(unique(model$fixef_id[[1L]]))
  )
}

results <- rbindlist(list(
  extract(total_model, "BEA total government payments, county and year FE"),
  extract(arc_model, "FSA ARC/PLC payments, 2014-2018, county and year FE")
))
fwrite(results, file.path(out_dir, "payment_retention_estimates.csv"))
capture.output(etable(total_model, arc_model), file = file.path(out_dir, "payment_retention_models.txt"))

message("Wrote payment-retention estimates to ", out_dir)
