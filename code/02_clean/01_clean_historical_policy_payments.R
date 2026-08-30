source(file.path("config", "data_paths.R"))

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(readxl)
})

raw_dir <- file.path(data_root, "raw", "obbba_policy")
out_dir <- file.path(data_root, "pipeline_cache", "nc1177", "obbba_policy")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

clean_names <- function(x) {
  x <- gsub("[^a-z0-9]+", "_", tolower(trimws(x)))
  gsub("^_|_$", "", x)
}

read_fsa_payment_file <- function(path) {
  year_value <- as.integer(substr(basename(path), 1, 4))
  skip <- if (year_value == 2018L) 1L else 0L
  z <- as.data.table(read_excel(path, skip = skip))
  setnames(z, clean_names(names(z)))
  fips_name <- intersect(c("st_cty", "state_county"), names(z))[1L]
  amount_name <- grep("amount_paid", names(z), value = TRUE)[1L]
  if (is.na(fips_name) || is.na(amount_name)) stop("Unexpected FSA layout: ", path)
  z[, .(
    county_fips = sprintf("%05s", as.character(get(fips_name))),
    program_year = year_value,
    program = toupper(as.character(program)),
    crop = toupper(as.character(crop)),
    payment_dollars = as.numeric(get(amount_name))
  )]
}

fsa_files <- list.files(
  file.path(raw_dir, "fsa_arc_plc"), pattern = "^201[4-8]_county_arc_plc\\.xlsx$", full.names = TRUE
)
arc_plc_detail <- rbindlist(lapply(fsa_files, read_fsa_payment_file), fill = TRUE)
arc_plc_detail <- arc_plc_detail[grepl("^(ARC|PLC)", program) & !is.na(payment_dollars)]
arc_plc_county <- arc_plc_detail[, .(
  arc_plc_payments_dollars = sum(payment_dollars, na.rm = TRUE),
  arc_payments_dollars = sum(payment_dollars[grepl("^ARC", program)], na.rm = TRUE),
  plc_payments_dollars = sum(payment_dollars[program == "PLC"], na.rm = TRUE)
), by = .(county_fips, year = program_year)]

zip_path <- file.path(raw_dir, "bea", "CAINC45.zip")
zip_listing <- unzip(zip_path, list = TRUE)
member <- zip_listing$Name[grepl("CAINC45__ALL_AREAS.*\\.csv$", zip_listing$Name)][1L]
if (is.na(member)) stop("BEA CAINC45 all-areas CSV not found in archive")
temp_dir <- tempfile("cainc45_")
dir.create(temp_dir)
unzip(zip_path, files = member, exdir = temp_dir)
bea <- fread(file.path(temp_dir, member), check.names = FALSE)
bea <- bea[LineCode == 130L]
year_columns <- grep("^[0-9]{4}$", names(bea), value = TRUE)
bea <- melt(
  bea, id.vars = c("GeoFIPS", "GeoName"), measure.vars = year_columns,
  variable.name = "year", value.name = "government_payments_thousands"
)
bea[, `:=`(
  county_fips = gsub("[^0-9]", "", GeoFIPS),
  year = as.integer(as.character(year)),
  government_payments_thousands = as.numeric(gsub(",", "", government_payments_thousands))
)]
bea <- bea[nchar(county_fips) == 5L & substr(county_fips, 3, 5) != "000",
           .(county_fips, county_name = GeoName, year, government_payments_thousands)]

write_parquet(arc_plc_detail, file.path(out_dir, "fsa_arc_plc_detail_2014_2018.parquet"), compression = "zstd")
write_parquet(arc_plc_county, file.path(out_dir, "fsa_arc_plc_county_2014_2018.parquet"), compression = "zstd")
write_parquet(bea, file.path(out_dir, "bea_county_government_payments_1969_2022.parquet"), compression = "zstd")

message("Wrote historical payment panels to ", out_dir)
