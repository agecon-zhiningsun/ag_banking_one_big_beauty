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

obbba_inputs <- c(
  `2025_PLC_yields_base.xlsx` = "https://www.fsa.usda.gov/sites/default/files/2025-04/plc_county_yields_py2025.xlsx",
  `2025_enrolled_base_county_crop_program.xlsx` = "https://www.fsa.usda.gov/sites/default/files/2026-01/2025_enrolled_base_county_crop_program%20%282026-01-14%29.xlsx",
  `2026_MYA.xlsx` = "https://www.fsa.usda.gov/sites/default/files/2026-08/2026_MYA_1.xlsx",
  `2026_ERP.xlsx` = "https://www.fsa.usda.gov/sites/default/files/2026-08/2026_ERP_0.xlsx",
  `2026_PLC.xlsx` = "https://www.fsa.usda.gov/sites/default/files/2026-08/2026_PLC_0.xlsx",
  `2026_ARCCO.xlsx` = "https://www.fsa.usda.gov/sites/default/files/2026-01/arcco_2026_data%20%282026-01-16%29.xlsx"
)
for (file_name in names(obbba_inputs)) {
  download_once(obbba_inputs[[file_name]], file.path(raw_dir, "fsa_arc_plc", file_name))
}

# CAINC45 is BEA's historical county farm-income-and-expense table. Line 130 is
# total government payments to farm operators. BEA discontinued this detailed
# county table after 2022, so the archive is intentionally versioned here.
download_once(
  "https://apps.bea.gov/regional/zip/CAINC45.zip",
  file.path(raw_dir, "bea", "CAINC45.zip")
)

# Recipient-level FSA annual payment files are used only to recover non-identifying
# county-program aggregates for ARC/PLC and MFP. The current FSA page lists the
# 2014-2023 files first (88 workbooks in the page ordering as retrieved in 2026).
payment_page <- paste0(
  "https://www.fsa.usda.gov/tools/informational/freedom-information-act-foia/",
  "electronic-reading-room/frequently-requested/payment-files"
)
page <- paste(readLines(payment_page, warn = FALSE), collapse = "\n")
hrefs <- unique(regmatches(page, gregexpr(
  'href="[^"]+\\.(xlsx|xls)"', page, ignore.case = TRUE
))[[1L]])
hrefs <- sub('^href="|"$', "", hrefs)
if (length(hrefs) < 88L) stop("FSA payment-file page layout changed; found only ", length(hrefs), " workbooks")
payment_dir <- file.path(raw_dir, "fsa_payment_files")
dir.create(payment_dir, recursive = TRUE, showWarnings = FALSE)
for (href in hrefs[seq_len(88L)]) {
  url <- if (grepl("^https?://", href)) href else paste0("https://www.fsa.usda.gov", href)
  destination <- file.path(payment_dir, utils::URLdecode(basename(href)))
  download_once(url, destination)
}

# The 2024-2025 entries route through FSA document landing pages and therefore
# are not exposed as workbook hrefs in the page HTML used above.
current_payment_urls <- c(
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20al-id.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20ia.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20il-in.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20ks-ky.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20la-mn.foia_.na_.pmt25.finaldt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20ms-mt.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20nd-ok.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20ne-nc.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20or-tn.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20tx-wa.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2026-02/state%20wv-wy.foia_.na_.pmt25.final_.dt25365.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2025-01/state%20al-in.foia_.na_.pmt24.final_.dt25002.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2025-01/state%20mn-nc.foia_.na_.pmt24.final_.dt25002.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2025-01/state%20nd-tn.foia_.na_.pmt24.final_.dt25002.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2025-01/state%20tx-wy.foia_.na_.pmt24.final_.dt25002.xlsx",
  "https://www.fsa.usda.gov/sites/default/files/2025-01/state%20ia-mi.foia_.na_.pmt24.final_.dt25002.xlsx"
)
for (url in current_payment_urls) {
  download_once(url, file.path(payment_dir, utils::URLdecode(basename(url))))
}

message("Policy source files are present in ", raw_dir)
