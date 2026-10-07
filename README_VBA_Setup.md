# Excel / VBA Control Workbook - Setup Guide

**File:** `Fund_Accounting_Control_Workbook.xlsx` (openpyxl-generated, live formulas)
**VBA modules:** `vba/Module_NAV.bas`, `vba/Module_Reconciliation.bas`, `vba/ThisWorkbook.bas`

The workbook already contains **live Excel formulas** for the full NAV calculation
and all three reconciliations - it works out of the box. The VBA modules add the
"control room" macros (one-click refresh, recon run, exports, Outlook escalation).

## Step 1 - Enable macros
1. Open `Fund_Accounting_Control_Workbook.xlsx`.
2. **File → Save As → `Fund_Accounting_Control_Workbook.xlsm`** (Keep current format →
   "Use Excel Macro-Enabled Workbook"). From now on use the `.xlsm`.
3. Trust the file: **File → Options → Trust Center → Trust Center Settings →
   Trusted Locations → Add** the project folder (or enable macros when prompted).

## Step 2 - Import the VBA modules
1. Press **Alt + F11** (Visual Basic editor).
2. **File → Import File...** → select `vba/Module_NAV.bas` → Import.
3. Repeat for `vba/Module_Reconciliation.bas` and `vba/ThisWorkbook.bas`
   (for `ThisWorkbook.bas` use **File → Import File** as well - it replaces the
   empty code-behind; if asked to remove the existing module first, choose Yes).
4. **Ctrl + S** → Keep VBA format. Close the editor (Alt + Q).

## Step 3 - Run the controls
| Macro | What it does |
|---|---|
| `RefreshAllData` | Full recalculation of NAV + recon formulas |
| `RunReconciliation` | **Main control macro** - refresh, count breaks/SLA breaches, export breaks CSV, alert |
| `CalculateNAVForFund` | Recalc + audit stamp for one fund |
| `ShowLatestNAV` | Popup with latest NAV per fund |
| `ExportNAVHistoryCSV` | Timestamped CSV of `NAV_Calc` (feeds Power BI / SQL BCP) |
| `ExportOpenBreaksCSV` | Timestamped CSV of `Recon_Breaks` (feeds Power Automate / SQL) |
| `EmailBreakReportToFundManager` | Drafts the break report email in Outlook |
| `EscalateSLABreaches` | Lists SLA breaches (production: fires the Power Automate flow) |

Run macros with **Alt + F8 → select → Run**.

## Sheet map
| Sheet | Purpose |
|---|---|
| `Dashboard` | KPI cards (live), NAV trend chart, AUM chart, recon pie, top-5 breaks |
| `Funds` / `Securities` / `Opening_Holdings` | Master data (opening cash = live formula) |
| `Transactions` | All engine transactions (SQL `fundctl.Transactions` mirror) |
| `Price_Matrix` / `Holdings_EOD` | Price grid + EOD positions (engine feeds) |
| `NAV_Calc` | **Daily NAV - live formulas** (units, cash, fee accrual, liabilities, NAV) |
| `ChartData` | Chart source ranges (SUMIFS) |
| `Recon_Holdings` / `Recon_Cash` / `Recon_NAV` | **Live reconciliation formulas** with tolerance cells |
| `Recon_Breaks` | Consolidated break log (ageing = `NETWORKDAYS` formula, SLA formula) |
| `Control_Panel` | CHK01-CHK05 with PASS/FAIL formulas + overall status |

## NAV convention (same as Python & SQL engines)
`NAV = (Cash + HoldingsValue - AccruedLiabilities) / UnitsOutstanding`
- Fees accrue daily on previous day's AUM (`bps/365`), paid out on the last
  business day of the month (`EOMONTH` formula).
- Investor flows are allocated at the **T-1 application NAV** (cut-off convention).
- `holdings_value` is the engine EOD feed (`Holdings_EOD` x `Price_Matrix`) -
  exactly how a production workbook receives the custodian/valuation feed.
