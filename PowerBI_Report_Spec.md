# Power BI Report Spec - "Fund NAV & Recon Control" (1-page dashboard)

This document is the complete build specification for the Power BI report.
The shipped **`Fund_NAV_Recon_Dashboard_1Page.png`** is a pixel-faithful render
of exactly this layout (same KPIs, same visuals, same numbers) so you can
recreate the report in Power BI in ~15 minutes.

---

## 1. Data model (star schema)

Load from **SQL Server** (`fundctl` schema) or from the engine CSVs
(`outputs/*.csv`, `data/*.csv`) via Power Query.

| Table | Type | Key | Notes |
|---|---|---|---|
| `Date` | Dimension | Date | from `fundctl.Calendar`, mark as date table |
| `Funds` | Dimension | fund_code | fund_name, category, mgmt_fee_bps |
| `Securities` | Dimension | symbol | security_name, sector, asset_type |
| `NAV History` | Fact | nav_date + fund_code | nav, units_close, net_assets, cash_close, holdings_value, daily_return_pct |
| `Transactions` | Fact | txn_id | txn_type, cash_impact, units, qty, price |
| `Holdings EOD` | Fact | eod_date + fund + symbol | qty, close_price, market_value |
| `Recon Breaks` | Fact | break_id | detected_date, recon_source, break_type, severity, impact_inr, age_business_days, sla_status, owner, status |
| `RTANAV` | Fact | nav_date + fund | published_nav |

Relationships: `Date[Date] 1-* NAV History[nav_date]`, `Funds 1-* NAV History`,
`Securities 1-* Holdings EOD`, `Funds 1-* Recon Breaks`, `Date 1-* Recon Breaks[detectived_date]`.

## 2. DAX

All measures are in **`DAX_Measures.dax`** - paste them into the model
(Modeling → New measure, or Tabular Editor for bulk paste).

## 3. Page layout - "Control Dashboard" (single page, 16:9)

Canvas: 1920 x 1080. Background `#F2F4F8`.

```
+----------------------------------------------------------------------------------+
| HEADER (navy #1F2A44):  FUND ACCOUNTING | NAV & RECONCILIATION CONTROL ENGINE     |
|                         Daily Control Dashboard • 3 Schemes • IST      [● LIVE]  |
+----------------------------------------------------------------------------------+
| [FUND: All Schemes ▾]  [PERIOD: Last 30 Business Days ▾]  [CATEGORY: All ▾]        |
+----------------------------------------------------------------------------------+
| [TOTAL AUM]  [WTD AVG NAV]  [RECON MATCH RATE]  [OPEN BREAKS]  [SLA BREACHES] [...]|
|  ₹ 42.26 Cr    9.3497        95.45%              5              1            1 / 5 |
+----------------------------------------------------------------------------------+
| +-----------------------------------+  +------------+  +---------------------+    |
| | NAV TREND - 30 DAYS (line)        |  | AUM BY     |  | RECON STATUS        |    |
| | 3 series: Alpha/Beta/Gamma NAV    |  | FUND (bar) |  | (donut) 95.45%      |    |
| +-----------------------------------+  +------------+  +---------------------+    |
+----------------------------------------------------------------------------------+
| +----------------+ +----------------------------------+ +----------------------+ |
| | BREAKS AGEING  | | TOP OPEN BREAKS (table)          | | CONTROL PANEL        | |
| | (column chart) | | BreakID Fund Source Type Age ₹ SLA| | CHK01..05 PASS/FAIL  | |
| +----------------+ +----------------------------------+ +----------------------+ |
+----------------------------------------------------------------------------------+
| Source: SQL • Python • Excel/VBA • Power BI • Power Automate      Page 1 / 1      |
+----------------------------------------------------------------------------------+
```

### Visual-by-visual field list

| # | Visual | Type | Fields | Format |
|---|---|---|---|---|
| 1 | Header | Text box | - | Navy fill, white bold 20pt, full width |
| 2 | Fund slicer | Slicer | `Funds[fund_name]` | single-select, dark header |
| 3 | Period slicer | Slicer | `Date[Date]` | between, default last 30 business days |
| 4 | Category slicer | Slicer | `Funds[category]` | multi-select |
| 5 | KPI: Total AUM | Card | `[Total AUM (Cr)]` | ₹ #,##0.00 "Cr", 24pt |
| 6 | KPI: Wtd Avg NAV | Card | `[Wtd Avg NAV]` | 0.0000, 24pt |
| 7 | KPI: Match Rate | Card | `[Recon Match Rate %]` | 0.00%, red if < 99% (conditional format) |
| 8 | KPI: Open Breaks | Card | `[Open Breaks]` | 0, red if > 0 |
| 9 | KPI: SLA Breaches | Card | `[SLA Breaches]` | 0, red if > 0 |
| 10 | KPI: Controls | Card | `[Control Status]` | text, red if ALERT |
| 11 | NAV trend | Line chart | X: `Date[Date]`, Y: `MAX('NAV History'[nav])`, Legend: `Funds[fund_code]` | 3 series colors #2E75B6 / #00A9A5 / #ED7D31 |
| 12 | AUM by fund | Bar chart | Y: `Funds[fund_name]`, X: `[Total AUM (Cr)]` | horizontal, #2E75B6, data labels |
| 13 | Recon status | Donut | Legend: Status (Matched/Breaks), Values: count of `Recon Breaks` + matched calc | green #70AD47 / red #C00000, % labels |
| 14 | Breaks ageing | Column chart | X: bucket (0-1d/2-3d/4-7d/>7d), Y: `[Open Breaks]` filtered by bucket | #FFC000/#ED7D31/#C00000 |
| 15 | Top breaks | Table | `Recon Breaks`: break_id, fund_code, recon_source, break_type, age_business_days, impact_inr, sla_status | top 5 by impact, SLA breach rows red |
| 16 | Control panel | Matrix/Card list | CHK01-CHK05 with PASS/FAIL (from `Control_Panel` CSV or measures) | green/red conditional formatting |

## 4. Theme

```json
{
  "name": "FundControl",
  "dataColors": ["#2E75B6", "#00A9A5", "#ED7D31", "#70AD47", "#C00000", "#FFC000", "#7030A0", "#A6A6A6"],
  "background": "#F2F4F8", "foreground": "#1F2A44", "tableAccent": "#1F2A44"
}
```

## 5. Refresh

- **Desktop**: scheduled refresh from SQL Server via Personal/On-prem gateway,
  or folder refresh from `outputs/` (the Python engine writes the CSVs nightly).
- **Service**: publish, set daily 06:45 IST refresh (after the 06:30 Power
  Automate run), enable "email on failure".

## 6. 15-minute build recipe

1. Get Data → Folder → `outputs/` + `data/` → Transform → keep needed columns.
2. Get Data → SQL Server → `fundctl` schema (or just use CSVs for the demo).
3. Model the relationships (section 1), mark `Date` as date table.
4. Paste measures from `DAX_Measures.dax`.
5. Insert visuals per the layout grid (section 3), 16:9 page, canvas `#F2F4F8`.
6. Format conditional colors for status fields (red = BREAK/FAIL/ALERT).
7. Save as `Fund_NAV_Recon_Control.pbix`, publish, schedule refresh.
