source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
})

final_dir <- file.path(data_root, "processed", "nc1177")
out_dir <- file.path("output", "tables", "04f_deposit_counterfactual")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# This is the identified deposit-only A-versus-B counterfactual. It deliberately
# does not manufacture loan-demand/default shocks or use the invalid historical
# "competitive = slope * 100" shortcut in the legacy Bellman code.
shock <- as.data.table(read_parquet(file.path(
  final_dir, "04e_obbba_bellman_bank_shocks_2025.parquet"
)))[actual_revenue_share == 0.85 & retention_case == "estimated_total_fsa"]

if (!nrow(shock)) stop("Run scripts 12 and 13 before the deposit counterfactual.")

shock[, bank_type := fcase(
  agricultural_bank == 1, "agricultural_banks",
  agricultural_bank == 0, "nonagricultural_banks",
  default = "unmatched_bank_characteristics"
)]

bank_results <- rbindlist(list(
  shock[, .(
    cert, bank_type, scenario = "A_no_policy",
    deposits_thousands = dep,
    deposit_change_thousands = 0,
    deposit_growth = 0,
    deposit_asset_ratio_change = 0
  )],
  shock[, .(
    cert, bank_type, scenario = "B_obbba_current_market_power",
    deposits_thousands = dep + predicted_bank_deposit_change_thousands,
    deposit_change_thousands = predicted_bank_deposit_change_thousands,
    deposit_growth = weighted_county_deposit_growth,
    deposit_asset_ratio_change = predicted_deposit_asset_ratio_change
  )]
))

summary <- bank_results[, .(
  banks = uniqueN(cert),
  aggregate_deposits_thousands = sum(deposits_thousands, na.rm = TRUE),
  aggregate_deposit_change_thousands = sum(deposit_change_thousands, na.rm = TRUE),
  deposit_weighted_growth = sum(deposit_change_thousands, na.rm = TRUE) /
    pmax(sum(deposits_thousands - deposit_change_thousands, na.rm = TRUE), 1),
  mean_bank_deposit_growth = mean(deposit_growth, na.rm = TRUE),
  median_bank_deposit_growth = median(deposit_growth, na.rm = TRUE),
  mean_deposit_asset_ratio_change = mean(deposit_asset_ratio_change, na.rm = TRUE)
), by = .(scenario, bank_type)]

write_parquet(
  bank_results,
  file.path(final_dir, "04f_obbba_identified_deposit_counterfactual_2025.parquet"),
  compression = "zstd"
)
fwrite(summary, file.path(out_dir, "04f_identified_deposit_policy_counterfactual.csv"))

message("Ran the identified A-versus-B OBBBA deposit counterfactual.")
