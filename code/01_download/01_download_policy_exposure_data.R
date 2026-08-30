source(file.path("config", "data_paths.R"))

raw_dir <- file.path(data_root, "raw", "obbba_policy")
dir.create(file.path(raw_dir, "fsa_arc_plc"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(raw_dir, "bea"), recursive = TRUE, showWarnings = FALSE)

download_once <- function(url, destination) {
  if (!file.exists(destination)) {
    download.file(url, destination, mode = "wb", quiet = FALSE)
  }
  if (!file.exists(destination) || file.info(destination)$size == 0) {
    stop("Download failed: ", url)
  }
}

fsa_files <- c(
  `2014_county_arc_plc.xlsx` = "https://www.fsa.usda.gov/sites/default/files/documents/2014%20ARCCO_PLC%20Payments%20by%20County.xlsx",
  `2015_county_arc_plc.xlsx` = "https://www.fsa.usda.gov/sites/default/files/documents/2015%20ARCCO_PLC%20Payments%20by%20County.xlsx",
  `2016_county_arc_plc.xlsx` = "https://www.fsa.usda.gov/sites/default/files/documents/2016%20ARCCO_PLC%20Payments%20by%20County.xlsx",
  `2017_county_arc_plc.xlsx` = "https://www.fsa.usda.gov/sites/default/files/documents/2017%20County%20Level%20ARCCO_PLC%20Payments_2019_0301.xlsx",
  `2018_county_arc_plc.xlsx` = "https://www.fsa.usda.gov/sites/default/files/documents/2018_county_level_arcco_plc_payments.xlsx"
)

for (file_name in names(fsa_files)) {
  download_once(fsa_files[[file_name]], file.path(raw_dir, "fsa_arc_plc", file_name))
}

# Latest stable pre-law county-by-crop enrollment file with a durable public URL.
# It is used as a predetermined acreage composition, not as realized 2026 acres.
download_once(
  "https://www.fsa.usda.gov/sites/default/files/documents/2023_enrolled_base_county_crop_program-2024-01-02-.xlsx",
  file.path(raw_dir, "fsa_arc_plc", "2023_enrolled_base_county_crop_program.xlsx")
)

# CAINC45 is BEA's historical county farm-income-and-expense table. Line 130 is
# total government payments to farm operators. BEA discontinued this detailed
# county table after 2022, so the archive is intentionally versioned here.
download_once(
  "https://apps.bea.gov/regional/zip/CAINC45.zip",
  file.path(raw_dir, "bea", "CAINC45.zip")
)

message("Policy source files are present in ", raw_dir)
