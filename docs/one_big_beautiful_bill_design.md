# One Big Beautiful Bill: agricultural-credit research design

## Policy object

Public Law 119-21, enacted July 4, 2025, changed agricultural commodity support, crop insurance and related programs. For this project, the relevant treatment is not a single binary indicator. It is a vector of county/crop/bank exposures that changes farm borrower cash flow, collateral risk, outside credit options and expected loss rates.

Official implementation references:

- USDA ERS, Title I commodity provisions: <https://ers.usda.gov/topics/farm-economy/farm-commodity-policy/title-i-crop-commodity-program-provisions>
- USDA ERS, government risk-management programs: <https://ers.usda.gov/topics/farm-practices-management/risk-management/government-programs-risk>
- USDA FSA, ARC/PLC: <https://www.fsa.usda.gov/resources/income-support/arc-plc>
- Statutory text, Public Law 119-21: <https://www.congress.gov/119/plaws/publ21/PLAW-119publ21.pdf>

## Main credit channels

| Policy change | Borrower mechanism | Bank-model mapping | Expected sign, holding other channels fixed |
|---|---|---|---|
| Higher ARC/PLC support and reference prices | Raises expected transfers and reduces downside cash-flow risk | Higher loan-demand quality; lower default transition | More credit and/or lower loan spreads |
| Up to 30 million additional base acres from 2026 | Expands eligibility unevenly across farms/counties | County/crop exposure shock | Larger effect where eligible acreage rises most |
| ARC guarantee raised from 86% to 90%; payment cap raised | Strengthens revenue insurance and borrower liquidity | Lower tail loss and stronger net worth | Lower charge-offs; ambiguous loan quantity if internal funds crowd out borrowing |
| Higher marketing-assistance loan rates | Improves commodity-collateral floor but expands government credit outside option | Better collateral plus stronger outside option to bank credit | Ambiguous: lower risk but possible bank-loan crowd-out |
| Greater crop-insurance premium support | Reduces premium cost and revenue volatility | Lower default probability and state-contingent losses | Lower risk premium and capital usage |
| Tax investment incentives such as higher Section 179 limits | Encourages equipment investment and changes taxable cash flow | Higher investment-loan demand; altered borrower liquidity | Likely higher term-credit demand, heterogeneous by taxable income |
| Conservation funding | Co-finances capital improvements and practices | Project-specific loan demand and risk | Ambiguous quantity; potentially lower long-run risk |

## Preferred empirical design

### Exposure construction

Construct a predetermined county-crop exposure using pre-law acreage and production shares:

\[
Exposure_c=\sum_k Share_{ck,pre}\times \Delta Support_k,
\]

where `ΔSupport` separately measures reference-price changes, marketing-loan-rate changes, added-base-acre eligibility and insurance subsidy changes. Aggregate county exposure to banks with pre-2025 branch-deposit weights or, preferably, loan geography.

## Historical payment-retention identification

Do not allocate county ARC/PLC payments to individual banks. The preferred
deposit first stage aggregates SOD deposits over all branches in a county and
estimates whether the county deposit stock changes with payments. This outcome
includes nonfarm accounts, so the coefficient is a local-market reduced-form
retention rate rather than a farmer-level propensity to save.

For bank balance-sheet outcomes, construct a shift-share exposure using the
bank's prior-year SOD county deposit shares. Call Report agricultural and total
loans are located at the bank, not at the borrower county, so this is a
service-area exposure and must be labeled accordingly.

Estimate program families separately:

- ARC/PLC identifies recurring commodity-safety-net exposure.
- MFP identifies an exceptional trade-assistance shock.
- CFAP identifies an exceptional pandemic-assistance shock.
- BEA total government payments provide the long county panel and an omnibus
  robustness measure, but should not replace the program-specific estimates.

Pooling MFP and CFAP into ARC/PLC without separate indicators is inappropriate:
their timing, eligibility and spending motives differ. A pooled total-payment
coefficient is useful only as a secondary reduced-form calibration.

The naive county/year fixed-effect estimates currently have negative signs.
That is evidence that contemporaneous payment levels are endogenous to weak
farm conditions and that June SOD timing is imperfect; it is not evidence that
farmers literally withdraw more than the payment. Publication estimates need
predetermined simulated eligibility/payment instruments and timing checks.

## Current OBBBA exposure implementation

`code/03_construct/12_construct_obbba_exposure.R` combines 2023 county-crop
enrolled base acres with the statutory reference-price changes and the ARC
guarantee increase from 86% to 90%. It creates county indices and maps them to
banks with 2025 SOD geography. These are exposure indices, not predicted dollar
payments: realized PLC payments require market-year prices and program yields,
and realized ARC payments require county revenue. The additional 30 million
base acres must remain a separate scenario until county allocations are final
and publicly downloadable.

Do not use realized post-law payments alone as treatment; those payments respond to prices, yields and participation.

### Reduced-form validation

Estimate event-study or difference-in-differences models beginning in 2025/2026:

\[
y_{bct}=\alpha_{bc}+\lambda_t+\sum_{\tau\neq -1}\beta_\tau
(Exposure_{bc}\times 1[t-T=\tau])+X_{bct}'\gamma+\varepsilon_{bct}.
\]

Outcomes should include agricultural loan growth, loan rates/spreads, charge-offs, nonaccruals, capital ratios, deposits, wholesale funding and entry/exit. Test pre-trends and cluster at the policy-exposure level.

### Structural counterfactual

Add a policy state `P_t` to the Bellman model and allow it to shift:

1. agricultural loan utility/demand;
2. expected agricultural charge-offs;
3. borrower outside-option value, especially FSA/CCC credit;
4. bank operating or screening costs where program participation matters; and
5. the transition of farm income/net worth.

Run the following counterfactuals:

- no Public Law 119-21 agricultural provisions;
- income-support channel only;
- risk/default channel only;
- government-credit outside-option channel only;
- tax-investment channel only;
- full policy under estimated market power;
- full policy under competitive loan/deposit pricing; and
- full policy with relaxed/tighter bank capital constraints.

This decomposition is the agricultural analogue of Wang et al.'s friction-removal exercise and directly answers whether bank market power amplifies, dampens or redistributes policy transmission.

## Novel contribution relative to Wang et al.

The paper studies how monetary policy reaches generic borrowers through imperfectly competitive banks. This project can show how **fiscal farm support and monetary policy jointly transmit through agricultural credit markets**, including competition from the Farm Credit System and government credit. The key estimand is not merely whether the law increases farm lending, but how much of the response comes from borrower risk, outside credit, bank market power and capital constraints—and which counties and bank types capture the benefits.

## Data still needed

- FSA ARC/PLC farm or county payment/eligibility files and added-base-acre allocations.
- Commodity-specific statutory reference and marketing-loan rates before/after the law.
- RMA policy, premium, subsidy and indemnity data by county/crop.
- County crop acreage and production shares fixed before enactment.
- Bank agricultural-loan geography or branch-weighted exposure measures.
- FSA/CCC direct and guaranteed loan volumes to measure the outside-credit channel.
- Post-2025 Call Reports, SOD, charge-offs/nonaccruals and interest income/expense.
- Equipment investment or farm capital expenditure proxies for tax-channel analysis.

## Interpretation guardrails

- The law combines many provisions; a post-2025 dummy is not a credible design.
- Statutory generosity and realized payments must be separated.
- The policy can simultaneously reduce credit risk and crowd out bank lending.
- The current dynamic results are illustrative until SMD estimation is completed.
- Report distributional effects by farm type, county exposure, bank size, agricultural-bank status and FCS presence.
