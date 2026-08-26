source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
})

cache <- file.path(data_root, "pipeline_cache")
out_dir <- file.path(cache, "nc1177", "market_power")
final_dir <- file.path(data_root, "processed", "nc1177")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(final_dir, recursive = TRUE, showWarnings = FALSE)

bank_quarter <- as.data.table(read_parquet(file.path(
  cache, "nc1177", "fdic", "bank_quarter_1992_2026.parquet"
)))
bank_quarter[, year := year(report_date)]
bank_quarter <- bank_quarter[year %between% c(1994L, 2025L)]

# Wang et al. define each year as a national demand market. Preserve the raw
# quarterly observations only to construct average annual balance denominators;
# the structural estimation panel itself contains one December observation per
# bank-year. This avoids allowing seasonal agricultural lending to create four
# artificial product markets within a year.
annual_average_balances <- bank_quarter[, .(
  quarters_observed = uniqueN(report_date),
  avg_dep = mean(dep, na.rm = TRUE),
  avg_lnlsgr = mean(lnlsgr, na.rm = TRUE),
  avg_lnag = mean(lnag, na.rm = TRUE)
), by = .(cert, year)]
bank <- bank_quarter[format(report_date, "%m-%d") == "12-31"]
bank <- merge(bank, annual_average_balances, by = c("cert", "year"), all.x = TRUE)
cost <- as.data.table(read_parquet(file.path(cache, "nc1177", "market_power", "market_power_call_report_inputs_1994_2025.parquet")))
cost[, year := year(report_date)]

# Aggregate bank-year SOD branch counts from the existing annual branch files.
sod_dir <- file.path(cache, "nc1177", "sod", "branch_year")
sod_files <- list.files(sod_dir, pattern = "\\.parquet$", full.names = TRUE)
if (!length(sod_files)) stop("No cleaned SOD branch-year files found in ", sod_dir)
sod <- rbindlist(lapply(sod_files, function(p) as.data.table(read_parquet(p))), fill = TRUE)
cert_name <- intersect(c("cert", "CERT"), names(sod))[1L]
year_name <- intersect(c("year", "YEAR"), names(sod))[1L]
if (is.na(cert_name) || is.na(year_name)) stop("SOD files lack cert/year identifiers")
setnames(sod, c(cert_name, year_name), c("cert", "year"), skip_absent = TRUE)
branches <- sod[!is.na(cert), .(branches = .N), by = .(cert = as.integer(cert), year = as.integer(year))]

keep <- c("cert", "year", "bank_name", "state", "agricultural_bank", "asset", "dep",
          "lnlsgr", "lnag", "total_ag_loans", "quarters_observed", "avg_dep",
          "avg_lnlsgr", "avg_lnag")
panel <- merge(bank[, ..keep], cost[, !"report_date"], by = c("cert", "year"), all.x = TRUE)
panel <- merge(panel, branches, by = c("cert", "year"), all.x = TRUE)
panel[is.na(branches), branches := 0L]
panel[, `:=`(
  deposit_rate = fifelse(avg_dep > 0, deposit_interest_expense / avg_dep, NA_real_),
  loan_rate = fifelse(avg_lnlsgr > 0, total_loan_interest_income / avg_lnlsgr, NA_real_),
  ag_production_loan_rate = fifelse(
    avg_lnag > 0, ag_production_interest_income / avg_lnag, NA_real_
  ),
  salary_cost_instrument = fifelse(asset > 0, salary_expense / asset, NA_real_),
  premises_cost_instrument = fifelse(asset > 0, premises_expense / asset, NA_real_),
  log_branches = log1p(branches),
  employees_per_branch = fifelse(branches > 0 & employees > 0, employees / branches, NA_real_)
)]
panel[, log_employees_per_branch := fifelse(
  employees_per_branch > 0, log(employees_per_branch), NA_real_
)]

# National outside options. FRED Financial Accounts levels are millions of dollars;
# Call Report balances are thousands. The deposit denominator currently covers
# households (corporate liquid assets remain a documented missing control).
fred_dir <- file.path(data_root, "raw", "fred", "nc1177_market_power")
read_fred_annual <- function(id) {
  z <- fread(file.path(fred_dir, paste0(id, ".csv")))
  setnames(z, c("observation_date", id), c("date", "value"))
  z[, `:=`(date = as.IDate(date), year = year(as.IDate(date)), value = as.numeric(value))]
  z[!is.na(value), .(value = last(value)), by = year]
}
market <- Reduce(function(a, b) merge(a, b, by = "year", all = TRUE), list(
  setnames(read_fred_annual("DABSHNO"), "value", "hh_currency_deposits_millions"),
  setnames(read_fred_annual("BOGZ1FL153025005A"), "value", "hh_currency_millions"),
  setnames(read_fred_annual("HNOTSAQ027S"), "value", "hh_treasuries_millions"),
  setnames(read_fred_annual("NCBCDTQ027S"), "value", "corp_currency_deposits_millions"),
  setnames(read_fred_annual("NCBTSEA027N"), "value", "corp_treasuries_millions"),
  setnames(read_fred_annual("CMDEBT"), "value", "hh_debt_millions"),
  setnames(read_fred_annual("BCNSDODNS"), "value", "corporate_debt_millions")
))
panel <- merge(panel, market, by = "year", all.x = TRUE)
ers_credit <- as.data.table(read_parquet(file.path(
  cache, "nc1177", "market_power", "ers_nonrealestate_farm_debt_by_lender_1994_2025.parquet"
)))
panel <- merge(panel, ers_credit, by = "year", all.x = TRUE)
panel[, `:=`(
  market_size_deposits = sum(dep, na.rm = TRUE) + 1000 *
    (hh_currency_millions + hh_treasuries_millions + corp_treasuries_millions),
  market_size_loans = 1000 * (hh_debt_millions + corporate_debt_millions),
  market_size_ag_production = all_lenders
), by = year]
panel[, `:=`(
  deposit_share = dep / market_size_deposits,
  loan_share = lnlsgr / market_size_loans,
  ag_production_share_unadjusted = lnag / market_size_ag_production
)]
panel[, `:=`(
  call_report_lnag_total = sum(lnag, na.rm = TRUE),
  ers_commercial_bank_share_used = fifelse(
    !is.na(ers_commercial_bank_share),
    ers_commercial_bank_share,
    sum(lnag, na.rm = TRUE) / first(market_size_ag_production)
  ),
  ers_commercial_share_observed = !is.na(ers_commercial_bank_share)
), by = year]
panel[, ag_production_share := fifelse(
  call_report_lnag_total > 0,
  (lnag / call_report_lnag_total) * ers_commercial_bank_share_used,
  NA_real_
)]
panel[, `:=`(
  deposit_outside_share = 1 - sum(deposit_share, na.rm = TRUE),
  loan_outside_share = 1 - sum(loan_share, na.rm = TRUE),
  ag_production_outside_share = 1 - sum(ag_production_share, na.rm = TRUE)
), by = year]

invalid_ag_market <- panel[, .(
  bank_inside = sum(lnag, na.rm = TRUE),
  ers_all_lenders = first(market_size_ag_production)
), by = year][bank_inside > ers_all_lenders]
if (nrow(invalid_ag_market)) {
  stop("Call Report agricultural-production balances exceed ERS all-lender total in year(s): ",
       paste(invalid_ag_market$year, collapse = ", "))
}

setorder(panel, year, cert)
write_parquet(panel, file.path(final_dir, "bank_year_market_power_inputs_1994_2025.parquet"), compression = "zstd")
fwrite(panel[, .(rows = .N, banks = uniqueN(cert)), by = year],
       file.path(out_dir, "market_power_panel_coverage.csv"))
message("Wrote NC1177 market-power panel to: ", final_dir)


