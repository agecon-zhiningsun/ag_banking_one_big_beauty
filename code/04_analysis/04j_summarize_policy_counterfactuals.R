suppressPackageStartupMessages({
  library(data.table)
})

in_dir <- file.path("output", "tables", "04i_dynamic_model")
out_dir <- file.path("output", "tables", "04j_policy_counterfactuals")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

x <- fread(file.path(in_dir, "04i_wang_obbba_structural_counterfactuals.csv"))
x[, `:=`(
  agricultural_loan_change_percent = 100 * pct_change_new_ag_loans_from_no_policy,
  loan_rate_change_basis_points = 10000 * change_loan_rate_from_no_policy,
  deposit_rate_change_basis_points = 10000 * change_deposit_rate_from_no_policy,
  identification = fcase(
    scenario == "A_no_policy", "baseline",
    scenario == "B1_deposit_funding_only", "estimated total-FSA deposit response; structural allocation",
    scenario == "B2_borrower_liquidity_only", "descriptive total-FSA lending reduced form",
    scenario == "B3_default_risk_only", "calibrated 10-percent charge-off reduction",
    scenario == "B4_marketing_loan_outside_credit_only", "statutory MAL rate change; outside-option elasticity calibrated",
    grepl("default", scenario), "default-risk sensitivity",
    default = "combined estimated and calibrated channels"
  )
)]

compact <- x[, .(
  scenario, bank_type, identification,
  agricultural_loan_change_percent,
  loan_rate_change_basis_points,
  deposit_rate_change_basis_points,
  change_wholesale_funding_from_no_policy,
  change_securities_from_no_policy,
  change_next_equity_from_no_policy,
  equilibrium_gap = NA_real_
)]

diag <- fread(file.path(in_dir, "04i_wang_full_model_diagnostics.csv"))
diag[, bank_type := fifelse(
  agricultural_bank == 1, "agricultural_banks", "nonagricultural_banks"
)]
compact[diag, equilibrium_gap := i.equilibrium_gap,
        on = .(scenario, bank_type)]

implications <- data.table(
  channel = c(
    "farmer liquidity", "default risk", "bank funding allocation",
    "loan market power", "government credit substitution"
  ),
  implemented_result = c(
    "Historical total-FSA exposure predicts lower short-run agricultural borrowing demand.",
    "Historical charge-off response is not identified; Bellman reports 0, 10 and 25 percent charge-off reductions.",
    "Historical total-FSA exposure predicts less wholesale funding; Bellman allocates deposits among funding, securities and loans.",
    "Agricultural BLP markups enter pricing in every reported policy counterfactual.",
    "OBBBA Marketing Assistance Loan rate increases shift the farmer outside option; the elasticity remains calibrated."
  ),
  farmer_interpretation = c(
    "Cash support can reduce operating-loan need even when bank liquidity rises.",
    "Safer repayment can lower marginal loan cost, but magnitude is a sensitivity rather than an estimate.",
    "Additional deposits need not become farm loans; banks can replace wholesale funding or buy securities.",
    "Existing market power can retain part of funding-cost and default-risk savings rather than fully passing them through.",
    "Higher government commodity-loan floors can crowd out commercial bank borrowing while improving farmer financing options."
  )
)

fwrite(compact, file.path(out_dir, "04j_obbba_structural_counterfactual_summary.csv"))
fwrite(implications, file.path(out_dir, "04j_farmer_policy_implications.csv"))

message("Summarized OBBBA structural counterfactual and farmer implications.")
