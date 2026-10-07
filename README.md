# 🏦 Fund Accounting — NAV & Reconciliation Control Engine

A production-style **daily control engine** for a mutual fund / PMS back office:

1. **Calculates day-end NAV** per fund (cash + holdings − accrued liabilities ÷ units).
2. **Reconciles** the books against three external sources every day:
   - **Custodian** holdings (quantity / price / missing items)
   - **Bank** statement (cash)
   - **RTA** published NAV (variance %)
3. **Controls & escalates**: tolerance-based matching, break classification,
   business-day ageing, **T+1 SLA**, owners, a **CHK01–CHK05 control panel**,
   and automated alerts (Teams card, Outlook mail, approval workflow).
4. **Reports** through a **Power BI style one-page dashboard** (PNG included +
   full report spec + DAX to rebuild it in Power BI).

---

## 🧰 Skills used (exactly the ones requested)

| Skill | Where it lives in this project |
|---|---|
| **SQL** | `01_sql/` — schema (`fundctl`), seed data, T-SQL NAV stored procedure `usp_CalculateDailyNAV`, reconciliation procedures `usp_ReconcileHoldings / usp_ReconcileCash / usp_ReconcileNAV`, ageing `usp_UpdateBreakAging`, control panel `usp_RunControlPanel`, views |
| **Python** | `02_python/` — config-driven engine: `sample_data.py`, `nav_engine.py` (daily NAV), `reconciliation_engine.py` (3-way recon + breaks + SLA + control panel), `run_all.py` orchestrator |
| **Excel / VBA** | `03_excel_vba/` — `Fund_Accounting_Control_Workbook.xlsx` (14 sheets, **live formulas** for NAV & all recons, KPI dashboard, charts, conditional formatting) + VBA modules (`RunReconciliation`, `EmailBreakReportToFundManager`, `EscalateSLABreaches`, exports) |
| **Power BI** | `04_power_bi/` — `DAX_Measures.dax` (20+ measures), `PowerBI_Report_Spec.md` (data model + 1-page layout + 15-min build recipe), `make_dashboard.py` + **`Fund_NAV_Recon_Dashboard_1Page.png`** (the Power BI style 1-page dashboard) |
| **Power Automate** | `05_power_automate/` — `Flow_Daily_Reconciliation_Control.json` (scheduled 06:30 IST flow: run engine → load SQL → Teams adaptive card → approvals → emails → Power BI refresh → audit log) + setup guide |
| **Reconciliation** | Core of the engine — tolerance matching, break types (`QTY_BREAK`, `PRICE_BREAK`, `MISSING_IN_CUSTODIAN`, `AMOUNT_BREAK`, `NAV_BREAK`), ageing buckets, SLA, owners, control panel — implemented in **Python + SQL + Excel** (three independent implementations that cross-check each other) |

## 🏗️ Architecture

```
  EXTERNAL FILES                ENGINES                          CONTROLS & REPORTING
 ┌──────────────┐   ┌──────────────────────────┐   ┌──────────────────────────────┐
 │ Custodian    │   │  Python engine           │   │  Excel / VBA workbook        │
 │ (T-1 dump)   │──▶│  • sample data           │   │  • NAV_Calc (live formulas)  │
 ├──────────────┤   │  • NAV engine            │──▶│  • Recon sheets (formulas)   │
 │ Bank stmt    │──▶│  • Reconciliation engine │   │  • Control_Panel CHK01-05    │
 ├──────────────┤   │  • run_all.py            │   │  • Dashboard + charts + VBA  │
 │ RTA NAV file │──▶│                          │   └──────────────────────────────┘
 ├──────────────┤   └────────────┬─────────────┘                  ▲
 │ Market prices│──▶               │                                │
 └──────────────┘                  ▼                                │
                          ┌──────────────────┐   refresh   ┌────────┴───────────┐
                          │  SQL Server      │────────────▶│  Power BI          │
                          │  fundctl schema  │             │  1-page dashboard  │
                          │  • tables        │             │  (PNG + spec+DAX)  │
                          │  • usp_Calculate │             └────────────────────┘
                          │    DailyNAV      │                      ▲
                          │  • usp_Reconcile*│             ┌────────┴──────────────┐
                          │  • usp_RunControl│◀────────────│  Power Automate       │
                          └──────────────────┘  alerts     │  06:30 IST daily      │
                                                            │  Teams / Outlook /    │
                                                            │  Approvals / refresh  │
                                                            └───────────────────────┘
```

See `docs/architecture.png` for the diagram version.

## 📁 Folder structure

```
fund_nav_recon_engine/
├── README.md                          ← you are here
├── requirements.txt                   ← pip install -r requirements.txt
├── 01_sql/                            ── SQL layer (SQL Server / T-SQL)
│   ├── 01_create_schema.sql           ← fundctl schema (16 tables)
│   ├── 02_seed_data.sql               ← funds, securities, calendar, control rules
│   ├── 03_nav_calculation.sql         ← usp_CalculateDailyNAV + vw_LatestNAV
│   └── 04_reconciliation_control.sql  ← recon procs + control panel + views
├── 02_python/                         ── Python engine
│   ├── config.yaml                    ← funds, securities, tolerances, SLA, breaks
│   ├── sample_data.py                 ← seeded demo data generator
│   ├── nav_engine.py                  ← daily NAV calculation
│   ├── reconciliation_engine.py       ← 3-way recon + breaks + control panel
│   └── run_all.py                     ← one-command pipeline + daily report
├── 03_excel_vba/                      ── Excel / VBA control workbook
│   ├── Fund_Accounting_Control_Workbook.xlsx
│   ├── build_excel.py                 ← regenerates the workbook
│   ├── README_VBA_Setup.md
│   └── vba/ (Module_NAV.bas, Module_Reconciliation.bas, ThisWorkbook.bas)
├── 04_power_bi/                       ── Power BI layer
│   ├── Fund_NAV_Recon_Dashboard_1Page.png   ★ the 1-page dashboard (Power BI style)
│   ├── DAX_Measures.dax               ← 20+ measures
│   ├── PowerBI_Report_Spec.md         ← data model + layout + build recipe
│   └── make_dashboard.py              ← renders the PNG from engine outputs
├── 05_power_automate/                 ── Power Automate layer
│   ├── Flow_Daily_Reconciliation_Control.json
│   └── README_PowerAutomate_Setup.md
├── data/                              ← generated sample inputs (CSV)
├── outputs/                           ← engine results (NAV, recon, control panel)
│   └── run_report.txt                 ← the daily control report
└── docs/
    └── architecture.png
```

## 🚀 Quick start

### 1) Python engine (2 minutes)
```bash
pip install -r requirements.txt
python 02_python/run_all.py
```
Output: `data/*.csv` (inputs), `outputs/*.csv|json` (NAV history, recon detail,
breaks, control panel) and `outputs/run_report.txt` — the daily control report.

### 2) SQL (SQL Server)
```sql
-- 1. run 01_sql/01_create_schema.sql   (creates schema fundctl)
-- 2. run 01_sql/02_seed_data.sql       (master data + calendar + rules)
-- 3. bulk load data/*.csv with the BCP commands at the bottom of 02_seed_data.sql
-- 4. run 01_sql/03_nav_calculation.sql
EXEC fundctl.usp_CalculateDailyNAV @fund_code='ALPHA_EQ', @from_date='2026-08-26', @to_date='2026-10-06';
-- 5. run 01_sql/04_reconciliation_control.sql
EXEC fundctl.usp_ReconcileHoldings @stmt_date='2026-10-05';
EXEC fundctl.usp_ReconcileCash     @stmt_date='2026-10-06';
EXEC fundctl.usp_ReconcileNAV      @from_date='2026-08-26', @to_date='2026-10-06';
EXEC fundctl.usp_UpdateBreakAging  @as_on='2026-10-06';
EXEC fundctl.usp_RunControlPanel   @run_date='2026-10-06';
SELECT * FROM fundctl.vw_OpenBreaks;
```

### 3) Excel / VBA
Open `03_excel_vba/Fund_Accounting_Control_Workbook.xlsx` → **Save As `.xlsm`** →
import the three `.bas` files (Alt+F11 → File → Import) → run `RunReconciliation`
with **Alt+F8**. See `03_excel_vba/README_VBA_Setup.md`.

### 4) Power BI
Rebuild the report from `04_power_bi/PowerBI_Report_Spec.md` + `DAX_Measures.dax`
(≈15 min), or simply use the shipped **`Fund_NAV_Recon_Dashboard_1Page.png`**.
Regenerate the PNG anytime with `python 04_power_bi/make_dashboard.py`.

### 5) Power Automate
Import `05_power_automate/Flow_Daily_Reconciliation_Control.json`
(My flows → Import). Fill the parameters, connect SQL/Teams/Outlook/Power BI,
point it at the engine folder, and switch it on. See the setup guide.

## 📊 The dashboard (1 page)

`04_power_bi/Fund_NAV_Recon_Dashboard_1Page.png` — 1920×1080, Power BI style:

- **Header** + slicers (Fund / Period / Category) + LIVE badge
- **6 KPI cards**: Total AUM ₹ 42.26 Cr · Wtd Avg NAV 9.3497 · Recon Match Rate 95.45% · Open Breaks 5 · SLA Breaches 1 · Controls Passed 1/5
- **NAV trend** (30 business days, 3 funds) · **AUM by fund** · **Recon status donut**
- **Breaks ageing** (business days) · **Top open breaks table** · **Control panel CHK01–CHK05**

## 🧪 Sample run (what the engine caught)

```
Items checked : 110      Matched: 105      Open breaks: 5   (match rate 95.45%)
SLA breaches  : 1        Controls passed: 1/5

BRK-001  GAMMA_BAL  RTA        NAV_BREAK              age 4   ₹  1,10,085   SLA_BREACH  RTA Ops Team
BRK-002  ALPHA_EQ   CUSTODIAN  QTY_BREAK              age 1   ₹    85,351   OK          Custodian Ops Team
BRK-003  BETA_DEBT  CUSTODIAN  MISSING_IN_CUSTODIAN   age 1   ₹ 2,21,36,449 OK          Custodian Ops Team
BRK-004  GAMMA_BAL  CUSTODIAN  PRICE_BREAK            age 1   ₹ 1,70,697   OK          Custodian Ops Team
BRK-005  ALPHA_EQ   BANK       AMOUNT_BREAK           age 0   ₹    12,500   OK          Banking Ops Team

CHK01 [FAIL] Holdings recon match rate >= 99%     (82.35%)
CHK02 [FAIL] Cash recon - zero unmatched items    (1)
CHK03 [FAIL] Max |NAV variance| vs RTA <= 0.05%   (0.0800%)
CHK04 [FAIL] Open SLA-breaching breaks = 0        (1)
CHK05 [PASS] 100% of open breaks have an owner
OVERALL: CONTROL ALERT - 5 open breaks, 1/5 controls passed
```

The sample data contains **5 deliberate breaks** (configured in
`02_python/config.yaml → sample_breaks`) so the control engine demonstrably
catches real issues on day one.

## 📐 Conventions & assumptions (documented controls)

- **NAV** = (Cash + Holdings Value − Accrued Liabilities) ÷ Units Outstanding.
- **Management fee** accrues daily on the previous day's AUM (`bps/365`),
  paid out on the last business day of the month.
- **Investor flows** (subscriptions/redemptions) are allocated at the **T-1
  application NAV** (cut-off convention) — hence NAV-neutral per unit.
- **Business days** = Mon–Fri; exchange holidays are not modelled in the demo
  calendar (add them to `fundctl.Calendar` / `build_calendar()` in production).
- **Tolerances**: qty 0 units · price 0.01% · cash ₹ 0.50 · NAV 0.05% (5 bps).
- **SLA**: breaks must be resolved within **T+1 business day**.
- The Excel workbook recomputes NAV with live formulas (holdings value is the
  engine EOD feed, exactly like a production workbook receives the valuation
  feed); Python and T-SQL are the calculation engines of record.

## ⚠️ Disclaimer

Demo project with **seeded sample data** (3 funds, 15 securities, 30 business
days). Not for production NAV publication — contract with your fund
administrator / RTA / custodian before using any NAV output. The control logic,
tolerances, SLA and escalation design are production-shaped and can be adopted
as-is.

---
*Built end-to-end with: SQL · Python · Excel/VBA · Power BI · Power Automate · Reconciliation*
