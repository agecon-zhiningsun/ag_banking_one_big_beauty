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

Estimate program families separately as diagnostics:

- ARC/PLC identifies recurring commodity-safety-net exposure.
- MFP identifies an exceptional trade-assistance shock.
- CFAP identifies an exceptional pandemic-assistance shock.
- BEA total government payments provide the long county panel and an omnibus
  robustness measure, but should not replace the program-specific estimates.

Pooling MFP and CFAP into ARC/PLC without separate indicators would obscure
their different timing and eligibility. However, the policy counterfactual can
use the separately estimated total-FSA coefficient when the empirical question
is the response to the overall dollar flow rather than a program-specific
behavioral response.

The long BEA total-payment estimate is negative and the separate FSA
program-family estimates are imprecise. By contrast, the total-FSA coefficient
is positive and statistically significant: 0.0762 dollars of county deposit
stock per dollar of FSA disbursement. The implemented deposit-only policy
counterfactual uses that coefficient. It remains a reduced-form association,
not a farmer-level saving propensity or a fully causal estimate; publication
estimates still need predetermined simulated eligibility/payment instruments
and timing checks.

The implemented annual FSA file pipeline now covers payment windows associated
with 2014-2025 disbursement files. ARC/PLC disbursements first appear in 2015;
there is no valid ARC/PLC series for 1994-2013 because the program did not yet
exist. BEA total government payments provide the longer 1994-2022 overlap with
SOD deposits. Payments are aligned to June SOD years: July-December payments
are assigned to the following June observation.

BEA discontinued the detailed county farm-income table CAINC45 after 2022, so
its government-payment line cannot be truthfully extended to 2025. The project
therefore retains BEA total government payments through 2022 and adds a
separately labeled total-FSA-disbursement measure through 2025. These concepts
must not be spliced without a source indicator because BEA is broader and uses
different accounting conventions.

Separate diagnostic coefficients are reported for ARC/PLC, MFP, CFAP and total
government payments. The primary overlapping-years regression includes
ARC/PLC, MFP and CFAP jointly; therefore ARC/PLC is not omitted during the MFP
or CFAP episodes. Because those conditional program-specific point estimates
are not statistically different from zero, they are not used in the main
simulation. The simulation reports the percentage increase in total FSA
payments and applies only the significant total-FSA coefficient. In levels this
is algebraically `0.0762 * incremental OBBBA payments`; the percentage form is
retained for interpretation and the level form handles counties whose 2025 FSA
baseline is zero.

## Lending and farmer interpretation

The deposit channel is a bank funding shock, not an assumption that deposits
must be transformed one-for-one into agricultural loans. The project therefore
estimates a second, bank-level reduced form relating agricultural-production
loan balances and rates to total-FSA payment intensity in the bank's service
area. This response combines three mechanisms: farmers may need less operating
credit after receiving cash support, stronger repayment capacity may expand
loan supply, and banks may replace wholesale funding or hold securities rather
than immediately originate loans.

The lending reduced form must be read together with the deposit result. A
positive deposit response and negative agricultural-loan-balance response are
economically compatible: farmer liquidity improves while short-run borrowing
need falls. The estimated loan-rate response determines whether there is
evidence of price pass-through. These estimates remain descriptive because FSA
payments respond to adverse agricultural conditions. The structural Bellman
stage will separately vary deposit market power, loan market power, and the
capital constraint; it must not force the invalid conclusion that added bank
funding automatically raises farm lending.

## Current OBBBA exposure implementation

`code/03_construct/12_construct_obbba_exposure.R` combines 2025 county-crop
enrolled base acres with the statutory reference-price changes and the ARC
guarantee increase from 86% to 90%. It creates county indices and maps them to
banks with 2025 SOD geography. These are exposure indices, not predicted dollar
payments: realized PLC payments require market-year prices and program yields,
and realized ARC payments require county revenue. The additional 30 million
base acres must remain a separate scenario until county allocations are final
and publicly downloadable.

`code/04_analysis/12_simulate_obbba_arc_plc_payments.R` uses official 2025
county PLC yields and enrolled acres, USDA's projected 2026 effective prices
and PLC rates, and 2026 ARC benchmark revenues. PLC is compared with a
pre-OBBBA statutory-floor counterfactual. ARC is simulated at actual revenue
equal to 70, 80, 85, 90 and 100 percent of benchmark revenue. The 30-million-
acre case is allocated proportionally to the observed 2025 county/crop/program
mix and must be labeled a scenario rather than an official county allocation.

## Bellman integration status

`code/04_analysis/13_prepare_obbba_bellman_counterfactuals.R` converts county
deposit changes into bank-specific percentage shocks using 2025 branch-deposit
geography and creates Bellman-ready deposit-market-size multipliers. The
counterfactual registry covers no policy, current market power, competitive
deposits, competitive lending, both markets competitive, and no capital
constraint. Only the deposit input is currently ready. Borrower loan-demand and
default-risk shocks must be estimated before the full OBBBA Bellman solution is
interpretable. Competitive cases also require corrected pricing constraints;
the earlier demand-slope-times-100 shortcut remains prohibited.

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
