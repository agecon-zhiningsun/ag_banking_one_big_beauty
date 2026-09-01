source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
})

# Wang-style national model: the farm cycle is an aggregate annual state.
# No county weather, crop-composition, or commodity-price files enter this baseline.

bank_quarter_path <- file.path(
  data_root, "processed", "nc1177",
  "bank_lending_market_structure_1994_2025.parquet"
)
market_path <- file.path(
  data_root, "processed", "nc1177",
  "03b_bank_year_market_power_inputs_1994_2025.parquet"
)
blp_path <- file.path(
  data_root, "processed", "nc1177", "blp_market_power",
  "03b_ag_production_bank_year.parquet"
)
total_blp_path <- file.path(
  data_root, "processed", "nc1177", "blp_market_power",
  "total_loans_bank_year.parquet"
)
deposit_blp_path <- file.path(
  data_root, "processed", "nc1177", "blp_market_power",
  "03b_deposits_bank_year.parquet"
)
wang_raw_dir <- file.path(
  data_root, "raw", "call_reports", "fdic_wang_dynamic_inputs"
)
ers_zip <- file.path(
  data_root, "raw", "ers", "farm_income_wealth",
  "February_5_2026_release.zip"
)
fred_path <- file.path(
  data_root, "raw", "fred", "nc1177_market_power", "DFF.csv"
)
out_dir <- file.path(data_root, "processed", "nc1177", "dynamic_bank_model")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

required <- c(bank_quarter_path, market_path, blp_path, total_blp_path,
              deposit_blp_path, ers_zip, fred_path)
missing <- required[!file.exists(required)]
if (length(missing)) stop("Missing required input(s):\n", paste(missing, collapse = "\n"))
wang_files <- sort(list.files(wang_raw_dir, pattern = "\\.csv$", full.names = TRUE))
if (!length(wang_files)) {
  stop("Required Wang/FDIC source inputs are missing; see docs/05a_data_requirements.md.")
}

bank_quarter <- as.data.table(read_parquet(bank_quarter_path))
bank_quarter <- bank_quarter[year >= 1994L & year <= 2025L]
setorder(bank_quarter, cert, year, report_date)
bank_year_balance <- bank_quarter[, .SD[.N], by = .(cert, year), .SDcols = c(
  "report_date", "asset", "eq", "dep", "coredep", "lnlsgr", "lnag",
  "total_ag_loans", "equity_asset_ratio", "core_deposit_ratio",
  "ag_loans_asset_ratio", "ag_loans_total_loan_ratio", "netinc", "roa"
)]

market <- as.data.table(read_parquet(market_path))
market <- market[year >= 1994L & year <= 2025L]
keep_market <- intersect(c(
  "cert", "year", "bank_name", "state", "agricultural_bank", "asset", "dep",
  "lnag", "total_ag_loans", "ag_production_loan_rate", "deposit_rate",
  "salary_cost_instrument", "premises_cost_instrument", "market_size_ag_production",
  "ag_production_share", "ag_production_outside_share", "farm_credit_system",
  "farm_service_agency", "ers_nonbank_outside_credit"
), names(market))
market <- market[, ..keep_market]

blp <- as.data.table(read_parquet(blp_path))
setnames(
  blp,
  old = intersect(c("shares", "prices", "structural_margin", "own_demand_derivative"), names(blp)),
  new = c(
    shares = "blp_ag_share",
    prices = "blp_ag_rate",
    structural_margin = "blp_ag_markup",
    own_demand_derivative = "own_rate_derivative"
  )[intersect(c("shares", "prices", "structural_margin", "own_demand_derivative"), names(blp))]
)
keep_blp <- intersect(c(
  "cert", "year", "blp_ag_share", "blp_ag_rate", "own_rate_derivative",
  "blp_ag_markup"
), names(blp))
blp <- unique(blp[, ..keep_blp], by = c("cert", "year"))

total_blp <- as.data.table(read_parquet(total_blp_path))
setnames(
  total_blp,
  old = intersect(c("shares", "prices", "structural_margin", "own_demand_derivative"),
                  names(total_blp)),
  new = c(
    shares = "blp_total_share", prices = "blp_total_rate",
    structural_margin = "blp_total_markup",
    own_demand_derivative = "total_own_rate_derivative"
  )[intersect(c("shares", "prices", "structural_margin", "own_demand_derivative"),
              names(total_blp))]
)
keep_total_blp <- intersect(c(
  "cert", "year", "blp_total_share", "blp_total_rate",
  "total_own_rate_derivative", "blp_total_markup"
), names(total_blp))
total_blp <- unique(total_blp[, ..keep_total_blp], by = c("cert", "year"))

deposit_blp <- as.data.table(read_parquet(deposit_blp_path))
if ("own_demand_derivative" %in% names(deposit_blp) &&
    !"own_rate_derivative" %in% names(deposit_blp)) {
  setnames(deposit_blp, "own_demand_derivative", "own_rate_derivative")
}
setnames(
  deposit_blp,
  old = intersect(c("shares", "prices", "structural_margin", "own_rate_derivative"), names(deposit_blp)),
  new = c(
    shares = "blp_deposit_share", prices = "blp_deposit_rate",
    structural_margin = "blp_deposit_markdown",
    own_rate_derivative = "deposit_own_rate_derivative"
  )[intersect(c("shares", "prices", "structural_margin", "own_rate_derivative"), names(deposit_blp))]
)
keep_deposit_blp <- intersect(c(
  "cert", "year", "blp_deposit_share", "blp_deposit_rate",
  "blp_deposit_markdown", "deposit_own_rate_derivative"
), names(deposit_blp))
deposit_blp <- unique(
  deposit_blp[, ..keep_deposit_blp],
  by = c("cert", "year")
)

# Q4 model cash-flow and balance-sheet fields. FDIC ratios reported in percent
# are converted to decimals. Wholesale funding follows Wang's nondeposit
# liability concept and is also cross-checked against reported repos.
wang <- rbindlist(lapply(wang_files, fread), use.names = TRUE, fill = TRUE)
setnames(wang, tolower(names(wang)))
wang[, report_date := as.IDate(as.character(repdte), format = "%Y%m%d")]
wang[, `:=`(cert = as.integer(cert), year = year(report_date))]
wang <- wang[month(report_date) == 12L & year >= 1994L & year <= 2025L]
wang_numeric <- intersect(c(
  "asset", "lnlsnet", "dep", "eq", "liab", "chbal", "nclnlsr",
  "eqcdiv", "itax", "nonix", "nonii", "eintexp", "numemp",
  "bkprem", "frepo", "rbcrwaj", "rbc1aaj"
), names(wang))
wang[, (wang_numeric) := lapply(.SD, as.numeric), .SDcols = wang_numeric]
wang[, `:=`(
  cash_reserve_asset_ratio = fifelse(asset > 0, chbal / asset, NA_real_),
  net_chargeoff_rate = nclnlsr / 100,
  dividend_asset_ratio = fifelse(asset > 0, eqcdiv / asset, NA_real_),
  tax_asset_ratio = fifelse(asset > 0, itax / asset, NA_real_),
  net_noninterest_cost_asset_ratio = fifelse(asset > 0, (nonix - nonii) / asset, NA_real_),
  interest_expense_asset_ratio = fifelse(asset > 0, eintexp / asset, NA_real_),
  wholesale_funding_asset_ratio = fifelse(asset > 0, pmax(liab - dep, 0) / asset, NA_real_),
  repo_asset_ratio = fifelse(asset > 0, frepo / asset, NA_real_),
  premises_asset_ratio = fifelse(asset > 0, bkprem / asset, NA_real_),
  risk_weighted_asset_ratio = fifelse(asset > 0, rbcrwaj / asset, NA_real_),
  tier1_capital_ratio = rbc1aaj / 100
)]
wang <- unique(wang[, .(
  cert, year, cash_reserve_asset_ratio, net_chargeoff_rate,
  dividend_asset_ratio, tax_asset_ratio, net_noninterest_cost_asset_ratio,
  interest_expense_asset_ratio, wholesale_funding_asset_ratio,
  repo_asset_ratio, numemp, premises_asset_ratio,
  risk_weighted_asset_ratio, tier1_capital_ratio
)], by = c("cert", "year"))

ers_member <- unzip(ers_zip, list = TRUE)$Name[1L]
ers <- as.data.table(read.csv(
  unz(ers_zip, ers_member),
  check.names = FALSE, stringsAsFactors = FALSE, fileEncoding = "UTF-8-BOM"
))
ers <- ers[
  State == "US" & VariableDescriptionTotal == "Net cash income" &
    Year >= 1993L & Year <= 2025L,
  .(
    year = as.integer(Year),
    nominal_net_cash_farm_income_thousands = as.numeric(Amount),
    chain_gdp_deflator = as.numeric(ChainType_GDP_Deflator),
    ers_publication_date = PublicationDate
  )
]
ers[, real_net_cash_farm_income_2026_thousands :=
      nominal_net_cash_farm_income_thousands / (chain_gdp_deflator / 100)]
setorder(ers, year)
ers[, farm_income_log_growth :=
      log(real_net_cash_farm_income_2026_thousands) -
      shift(log(real_net_cash_farm_income_2026_thousands))]

# The aggregate downturn state is the negative standardized innovation in real
# national net cash farm income. It is a state variable, not claimed to be an
# externally identified causal shock.
farm_ar <- lm(
  log(real_net_cash_farm_income_2026_thousands) ~
    shift(log(real_net_cash_farm_income_2026_thousands)),
  data = ers
)
ers[, farm_income_innovation := NA_real_]
ers[!is.na(shift(log(real_net_cash_farm_income_2026_thousands))),
    farm_income_innovation := resid(farm_ar)]
innovation_sd <- sd(ers$farm_income_innovation, na.rm = TRUE)
ers[, farm_downturn_state := -farm_income_innovation / innovation_sd]
cut_points <- quantile(
  ers[year >= 1994L & year <= 2025L, farm_downturn_state],
  probs = c(1 / 3, 2 / 3), na.rm = TRUE, names = FALSE
)
ers[, farm_state := fifelse(
  farm_downturn_state <= cut_points[1L], 1L,
  fifelse(farm_downturn_state <= cut_points[2L], 2L, 3L)
)]
ers[, farm_state_label := c("strong", "normal", "downturn")[farm_state]]

fred <- fread(fred_path)
date_col <- names(fred)[1L]
value_col <- names(fred)[2L]
setnames(fred, c(date_col, value_col), c("date", "fed_funds_rate_percent"))
fred[, date := as.IDate(date)]
fred[, fed_funds_rate_percent := as.numeric(fed_funds_rate_percent)]
fred_year <- fred[year(date) >= 1994L & year(date) <= 2025L, .(
  fed_funds_rate_percent = mean(fed_funds_rate_percent, na.rm = TRUE)
), by = .(year = year(date))]

panel <- merge(market, bank_year_balance, by = c("cert", "year"), all.x = TRUE,
               suffixes = c("", "_q4"))
panel <- merge(panel, blp, by = c("cert", "year"), all.x = TRUE)
panel <- merge(panel, total_blp, by = c("cert", "year"), all.x = TRUE)
panel <- merge(panel, deposit_blp, by = c("cert", "year"), all.x = TRUE)
panel <- merge(panel, wang, by = c("cert", "year"), all.x = TRUE)
panel <- merge(panel, ers[year >= 1994L], by = "year", all.x = TRUE)
panel <- merge(panel, fred_year, by = "year", all.x = TRUE)

panel[, `:=`(
  capital_ratio = fifelse(asset_q4 > 0, eq / asset_q4, NA_real_),
  total_loan_ratio = fifelse(asset_q4 > 0, lnlsgr / asset_q4, NA_real_),
  ag_production_loan_ratio = fifelse(asset_q4 > 0, lnag_q4 / asset_q4, NA_real_),
  total_ag_loan_ratio = fifelse(asset_q4 > 0, total_ag_loans_q4 / asset_q4, NA_real_),
  deposit_asset_ratio = fifelse(asset_q4 > 0, dep_q4 / asset_q4, NA_real_),
  core_deposit_asset_ratio = fifelse(asset_q4 > 0, coredep / asset_q4, NA_real_),
  nondeposit_funding_ratio = fifelse(
    asset_q4 > 0, pmax(asset_q4 - dep_q4 - eq, 0) / asset_q4, NA_real_
  ),
  net_income_asset_ratio = fifelse(asset_q4 > 0, netinc / asset_q4, NA_real_),
  funding_rate = fed_funds_rate_percent / 100
)]
setorder(panel, cert, year)
panel[, `:=`(
  ag_production_loan_ratio_lag = shift(ag_production_loan_ratio),
  total_loan_ratio_lag = shift(total_loan_ratio),
  capital_ratio_lag = shift(capital_ratio),
  blp_ag_markup_lag = shift(blp_ag_markup),
  next_ag_production_loan_ratio = shift(ag_production_loan_ratio, type = "lead"),
  next_total_loan_ratio = shift(total_loan_ratio, type = "lead"),
  next_capital_ratio = shift(capital_ratio, type = "lead")
), by = cert]
panel[, ag_production_loan_growth :=
        log(ag_production_loan_ratio) - log(ag_production_loan_ratio_lag)]

model_panel <- panel[
  is.finite(ag_production_loan_ratio) & ag_production_loan_ratio >= 0 &
    is.finite(capital_ratio) & capital_ratio > 0 &
    is.finite(farm_downturn_state) &
    is.finite(blp_total_markup) & blp_total_markup >= 0 &
    is.finite(blp_ag_markup) & blp_ag_markup >= 0 &
    is.finite(blp_deposit_markdown) & blp_deposit_markdown >= 0 &
    is.finite(net_chargeoff_rate) & net_chargeoff_rate >= 0
]

write_parquet(
  model_panel,
  file.path(out_dir, "03a_bank_year_dynamic_model_inputs_1994_2025.parquet"),
  compression = "zstd"
)
fwrite(
  ers[year >= 1994L & year <= 2025L],
  file.path(out_dir, "03a_national_farm_state_1994_2025.csv")
)
fwrite(
  model_panel[, .(
    observations = .N,
    banks = uniqueN(cert),
    first_year = min(year),
    last_year = max(year),
    ag_banks = uniqueN(cert[agricultural_bank == 1]),
    nonag_banks = uniqueN(cert[agricultural_bank == 0]),
    mean_ag_loan_ratio = mean(ag_production_loan_ratio),
    mean_capital_ratio = mean(capital_ratio),
    mean_blp_markup = mean(blp_ag_markup),
    mean_deposit_markdown = mean(blp_deposit_markdown),
    mean_net_chargeoff_rate = mean(net_chargeoff_rate),
    mean_wholesale_funding_ratio = mean(wholesale_funding_asset_ratio)
  )],
  file.path(out_dir, "03a_dynamic_model_input_summary.csv")
)

message("Constructed ", format(nrow(model_panel), big.mark = ","),
        " bank-year observations for the national dynamic model.")
