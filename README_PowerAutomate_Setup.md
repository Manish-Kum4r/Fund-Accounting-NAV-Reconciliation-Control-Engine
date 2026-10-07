# Power Automate - Daily NAV Recon Control Flow

**File:** `Flow_Daily_Reconciliation_Control.json`

A scheduled cloud flow that runs the whole control cycle every morning and
escalates breaks automatically.

## What the flow does (06:30 IST, daily)

```
06:30 IST  Recurrence trigger (India Standard Time)
   │
   ▼
Run Python engine        python 02_pythonun_all.py   (via Power Automate Desktop
   │                                           "Run application" on the gateway machine)
   ▼
Load open breaks         SQL: fundctl.ReconBreaks WHERE status='OPEN'
   │
   ▼
Parse recon summary      outputs/recon_summary.json  (breaks, SLA, match rate, controls)
   │
   ▼
Set control variables    open_breaks / sla_breaches / match_rate_pct / controls_passed
   │
   ▼
┌─ IF open_breaks > 0 ─────────────────────────────────────────────┐
│  • Post adaptive card to Teams "Fund Ops Control" channel         │
│  • For each open break: email the owner + mark ESCALATED in SQL   │
│  • Start & wait for approval (Fund Manager) - Approve/Reject      │
│  • Send [CONTROL ALERT] email to Fund Manager (report attached)   │
└───────────────────────────────────────────────────────────────────┘
   │
   ▼ (always)
Run control panel in SQL   EXEC fundctl.usp_RunControlPanel  (CHK01-CHK05)
   │
   ▼
Refresh Power BI dataset   "Fund NAV & Recon Control" (dashboard updates)
   │
   ▼
Write audit log            INSERT INTO fundctl.AuditLog
```

## Setup (15 minutes)

1. **Power Automate portal** → *My flows* → *Import* → *Import package (Legacy)*
   → upload a zip containing this JSON renamed to `definition.json`
   (or recreate the flow manually - every step is listed above).
2. **Connections** needed: `shared_sql` (SQL Server), `shared_teams`,
   `shared_office365outlook`, `shared_approvals`, `shared_powerbi`.
3. **Parameters** to fill in: `EngineFolder`, `SqlServer`, `SqlDatabase`,
   `FundManagerEmail`, `FundOpsTeamId`, `FundOpsChannelId`, `PowerBIDatasetId`.
4. **Gateway machine**: install the *on-premises data gateway (personal mode)*
   on the machine that runs the Python engine, and create a *Run application*
   desktop flow (or use the built-in "Run a script from Power Automate Desktop"
   action) that executes:
   `python.exe 02_python\run_all.py` with working folder = `EngineFolder`.
   Cloud-only alternative: replace that step with an **HTTP** action calling an
   Azure Function / Container App that runs the same command.
5. **SQL prep**: run `01_sql/01_create_schema.sql`, `02_seed_data.sql`, then load
   the engine CSVs (`data/*.csv`, `outputs/*.csv`) with the BCP commands at the
   bottom of `02_seed_data.sql` (or let the flow's SQL steps read the CSVs via
   `OPENROWSET`).
6. **Teams/Outlook**: create the *Fund Ops Control* channel; the adaptive card
   posts there on every alert day.
7. **Power BI**: publish the report from `04_power_bi/` and copy the dataset id
   into `PowerBIDatasetId`; the flow refreshes it every morning after the run.
8. Turn the flow **On**. First run is manual: *Test* → *Manually*.

## Alerting & escalation policy (as configured)

| Condition | Action |
|---|---|
| Any open break | Teams adaptive card + email to break owner + SQL status = ESCALATED |
| Any SLA breach (> T+1) | Approval request to Fund Manager (Approve/Reject) |
| Any control FAIL | [CONTROL ALERT] email to Fund Manager with `run_report.txt` attached |
| Zero breaks | [CONTROL OK] all-clear email to Fund Ops |
| Always | Control panel run (CHK01-05) + Power BI refresh + audit log entry |

## Files produced/consumed by the flow

| Direction | File |
|---|---|
| Consumes | `outputs/recon_summary.json`, `outputs/recon_breaks.csv`, `outputs/run_report.txt` |
| Produces (SQL) | `fundctl.ReconBreaks` (status updates), `fundctl.ReconControlPanel`, `fundctl.AuditLog` |
| Produces (Power BI) | Refreshed `Fund NAV & Recon Control` dataset |
