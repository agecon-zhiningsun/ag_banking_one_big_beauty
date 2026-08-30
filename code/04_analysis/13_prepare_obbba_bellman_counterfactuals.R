source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
})

final_dir <- file.path(data_root, "processed", "nc1177")
out_dir <- file.path("output", "tables", "obbba_bellman")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

shocks <- as.data.table(read_parquet(file.path(
  final_dir, "obbba_bank_payment_deposit_scenarios.parquet"
)))
bank <- as.data.table(read_parquet(file.path(
  final_dir, "bank_year_market_power_inputs_1994_2025.parquet"
)))[year == 2025L]

# Central dynamic input grid. Keep multiple retention assumptions because the
# reduced-form program-family coefficients remain imprecise.
shocks <- shocks[
  actual_revenue_share %in% c(0.80, 0.85, 0.90) &
    retention_case %in% c("estimated_naive", "ten_percent", "twenty_five_percent")
]
bellman <- merge(shocks, bank, by = "cert", all.x = TRUE)
bellman[, `:=`(
  deposit_market_size_multiplier = pmax(1 + weighted_county_deposit_growth, 0),
  predicted_bank_deposit_change_thousands = dep * weighted_county_deposit_growth,
  predicted_deposit_asset_ratio_change = dep * weighted_county_deposit_growth / pmax(asset, 1),
  initial_wholesale_funding_offset_thousands = pmax(dep * weighted_county_deposit_growth, 0)
)]

write_parquet(
  bellman,
  file.path(final_dir, "obbba_bellman_bank_shocks_2025.parquet"),
  compression = "zstd"
)

summary <- bellman[, .(
  banks = uniqueN(cert),
  mean_deposit_market_size_multiplier = mean(deposit_market_size_multiplier, na.rm = TRUE),
  median_deposit_market_size_multiplier = median(deposit_market_size_multiplier, na.rm = TRUE),
  aggregate_predicted_deposit_change_thousands = sum(predicted_bank_deposit_change_thousands, na.rm = TRUE),
  mean_deposit_asset_ratio_change = mean(predicted_deposit_asset_ratio_change, na.rm = TRUE)
), by = .(actual_revenue_share, retention_case, retention_rate)]
fwrite(summary, file.path(out_dir, "bellman_shock_summary.csv"))

counterfactuals <- data.table(
  counterfactual = c(
    "A_no_policy", "B_obbba_current_market_power",
    "C_obbba_competitive_deposits", "D_obbba_competitive_lending",
    "E_obbba_both_markets_competitive", "F_obbba_no_capital_constraint"
  ),
  required_change = c(
    "Set deposit and borrower policy shocks to zero.",
    "Apply the estimated/scenario deposit-market-size shock and later add borrower demand/default shocks.",
    "Apply OBBBA and impose the correctly derived competitive deposit-pricing condition.",
    "Apply OBBBA and constrain the loan rate to risk-adjusted marginal cost.",
    "Impose both competitive pricing conditions and re-solve.",
    "Apply OBBBA while relaxing the capital constraint and re-solve."
  ),
  current_status = c(
    "input_ready", "deposit_input_ready_borrower_channels_pending",
    "solver_change_required", "solver_change_required",
    "solver_change_required", "solver_change_required"
  )
)
fwrite(counterfactuals, file.path(out_dir, "counterfactual_registry.csv"))

message("Prepared OBBBA bank shocks and Bellman counterfactual registry.")
