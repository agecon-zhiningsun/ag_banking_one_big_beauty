source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(readxl)
})

raw_dir <- file.path(data_root, "raw", "obbba_policy", "fsa_payment_files")
out_dir <- file.path(data_root, "pipeline_cache", "nc1177", "obbba_policy")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

files <- list.files(raw_dir, pattern = "\\.xlsx$", full.names = TRUE, ignore.case = TRUE)
if (!length(files)) stop("No FSA annual payment workbooks found in ", raw_dir)

infer_payment_year <- function(path) {
  name <- tolower(basename(path))
  hit <- regmatches(name, regexpr("pmt(14|15|16|17|18|19|20|22|23|24|25)", name))
  if (length(hit) && nzchar(hit)) return(2000L + as.integer(sub("pmt", "", hit)))
  # FSA's 2021 files have generic state-range names between the PMT22 and PMT20
  # releases. The downloader puts only 2014-2025 workbooks in this directory.
  2021L
}

standard_name <- function(x) gsub("[^a-z0-9]+", "_", tolower(trimws(x)))

aggregate_file <- function(path) {
  message("Aggregating ", basename(path))
  z <- as.data.table(read_excel(path))
  setnames(z, standard_name(names(z)))
  required <- c(
    "state_fsa_code", "county_fsa_code", "disbursement_amount",
    "payment_date", "accounting_program_description", "accounting_program_year"
  )
  if (!all(required %in% names(z))) stop("Unexpected FSA workbook layout: ", path)
  z <- z[, ..required]
  z[, description := toupper(as.character(accounting_program_description))]
  z[, program_family := fcase(
    grepl("AGRICULTURAL RISK COVERAGE|PRICE LOSS COVERAGE", description), "ARC_PLC",
    grepl("MARKET FACILITATION PROGRAM", description), "MFP",
    grepl("CORONAVIRUS FOOD ASSISTANCE|(^|[^A-Z])CFAP([^A-Z]|$)", description), "CFAP",
    default = "OTHER_FSA"
  )]
  z[, payment_year := as.integer(format(as.Date(payment_date), "%Y"))]
  z[is.na(payment_year), payment_year := infer_payment_year(path)]
  z[, payment_month := as.integer(format(as.Date(payment_date), "%m"))]
  z[is.na(payment_month), payment_month := 6L]
  # SOD deposits are measured June 30. Payments from July of t-1 through June
  # of t therefore map to the t SOD observation.
  z[, sod_year := payment_year + as.integer(payment_month > 6L)]
  z[, .(
    payment_dollars = sum(as.numeric(disbursement_amount), na.rm = TRUE),
    transactions = .N
  ), by = .(
    county_fips = sprintf("%02d%03d", as.integer(state_fsa_code), as.integer(county_fsa_code)),
    payment_year,
    sod_year,
    program_year = as.integer(accounting_program_year),
    program_family
  )]
}

payments <- rbindlist(lapply(files, aggregate_file), fill = TRUE)
payments <- payments[nchar(county_fips) == 5L & substr(county_fips, 3, 5) != "000"]
county_year <- payments[, .(
  arc_plc_payments_dollars = sum(payment_dollars[program_family == "ARC_PLC"], na.rm = TRUE),
  mfp_payments_dollars = sum(payment_dollars[program_family == "MFP"], na.rm = TRUE),
  cfap_payments_dollars = sum(payment_dollars[program_family == "CFAP"], na.rm = TRUE),
  selected_program_payment_dollars = sum(payment_dollars[program_family != "OTHER_FSA"], na.rm = TRUE),
  total_fsa_payments_dollars = sum(payment_dollars, na.rm = TRUE)
), by = .(county_fips, year = sod_year)]

write_parquet(payments, file.path(out_dir, "02b_fsa_county_program_payments_detail_2014_2025.parquet"), compression = "zstd")
write_parquet(county_year, file.path(out_dir, "02b_fsa_county_program_payments_2014_2025.parquet"), compression = "zstd")
fwrite(payments[, .(
  payment_dollars = sum(payment_dollars), transactions = sum(transactions), counties = uniqueN(county_fips)
), by = .(payment_year, program_family)][order(payment_year, program_family)],
file.path(out_dir, "02b_fsa_program_payment_coverage_2014_2025.csv"))

message("Wrote county-program aggregates to ", out_dir)
