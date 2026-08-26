source(file.path("config", "data_paths.R"))
suppressPackageStartupMessages({library(data.table); library(arrow); library(fixest)})
source(file.path("code", "04_analysis", "random_coefficient_blp_helpers.R"))

dt <- as.data.table(read_parquet(file.path(
  data_root, "processed", "nc1177", "bank_year_market_power_inputs_1994_2025.parquet"
)))
compact_dir <- file.path("output", "tables", "blp_market_power")
detailed_dir <- file.path(data_root, "processed", "nc1177", "blp_market_power")

specifications <- list(
  list(market = "total_loans", rate = "loan_rate", share = "loan_share",
       outside = "loan_outside_share", condition = dt$lnlsgr > 0,
       expected_rate_sign = -1)
)
samples <- list(
  all_banks = rep(TRUE, nrow(dt)),
  ag_banks = dt$agricultural_bank == 1L,
  nonag_banks = dt$agricultural_bank == 0L
)

for (spec in specifications) {
  for (sample_name in names(samples)) {
    message("Estimating random-coefficient BLP: ", spec$market, " / ", sample_name)
    use <- spec$condition & samples[[sample_name]]
    result <- estimate_random_coefficient_blp(
      dt[use], spec$rate, spec$share, spec$outside,
      spec$market, sample_name, spec$expected_rate_sign
    )
    save_random_blp(
      result, paste(spec$market, sample_name, sep = "_"), compact_dir, detailed_dir
    )
  }
}
message("Completed legacy total-loan BLP estimates: ", compact_dir)


