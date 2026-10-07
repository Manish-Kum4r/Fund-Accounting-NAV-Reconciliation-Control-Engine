"""
Reconciliation Control Engine (Python) - Fund Accounting NAV & Recon
Control Engine.

Three-way daily reconciliation:
    1. HOLDINGS : books (engine EOD)  vs  custodian file   (qty / price / missing)
    2. CASH     : books (cash ledger) vs  bank statement    (amount)
    3. NAV      : engine NAV          vs  RTA published NAV (variance %)

Every non-matching item becomes a controlled BREAK with:
severity, rupee impact, business-day ageing, T+1 SLA status, owner and
escalation state. A control panel (CHK01-CHK05) summarises the run.

Outputs (in /outputs):
    recon_holdings.csv / recon_cash.csv / recon_nav.csv  - item-level detail
    recon_breaks.csv                                     - consolidated breaks
    recon_summary.json                                   - KPIs for dashboard
    control_panel.csv                                    - CHK01..CHK05 results
"""
import csv
import datetime as dt
import json
from pathlib import Path

from sample_data import load_config

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
OUT_DIR = ROOT / "outputs"

SEVERITY = {"QTY_BREAK": "High", "MISSING_IN_CUSTODIAN": "High",
            "NAV_BREAK": "High", "PRICE_BREAK": "Medium", "AMOUNT_BREAK": "Medium"}
OWNER = {"CUSTODIAN": "Custodian Ops Team",
         "BANK": "Banking Ops Team",
         "RTA": "RTA Ops Team"}


def _read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def run_reconciliation(cfg, days, nav_rows, eod_rows, cash_rows):
    r = cfg["recon"]
    qty_tol = float(r["qty_tolerance_units"])
    px_tol = float(r["price_tolerance_pct"]) / 100.0
    amt_tol = float(r["amount_tolerance_inr"])
    nav_tol = float(r["nav_tolerance_pct"]) / 100.0
    sla_days = int(r["sla_days"])
    as_on = cfg["project"]["as_on"]
    days_iso = [d.isoformat() for d in days]

    cust_rows = _read_csv(DATA_DIR / "custodian_holdings.csv")
    bank_rows = _read_csv(DATA_DIR / "bank_statement.csv")
    rta_rows = _read_csv(DATA_DIR / "rta_nav.csv")

    def biz_age(detected_iso):
        return sum(1 for d in days_iso if detected_iso < d <= as_on)

    breaks = []

    def add_break(source, btype, fund, detected, book_v, ext_v, diff_v,
                  impact, note, ref_key):
        breaks.append({
            "detected_date": detected,
            "fund_code": fund,
            "recon_source": source,
            "break_type": btype,
            "severity": SEVERITY[btype],
            "ref_key": ref_key,
            "book_value": book_v,
            "external_value": ext_v,
            "diff_value": diff_v,
            "impact_inr": round(abs(impact), 2),
            "age_business_days": biz_age(detected),
            "sla_days": sla_days,
            "sla_status": "SLA_BREACH",
            "owner": OWNER[source],
            "status": "OPEN",
            "note": note,
        })

    # ------------------------------------------------ 1. holdings recon
    cust_date = r["custodian_stmt_date"]
    price_map = {(p["price_date"], p["symbol"]): float(p["close_price"])
                 for p in _read_csv(DATA_DIR / "prices.csv")}
    book = {(h["fund_code"], h["symbol"]): h
            for h in eod_rows if h["nav_date"] == cust_date}
    cust = {(c["fund_code"], c["symbol"]): c for c in cust_rows}
    hold_rows = []
    for fc, sym in sorted(set(book) | set(cust)):
        b, c = book.get((fc, sym)), cust.get((fc, sym))
        bq = int(b["qty"]) if b else 0
        bp = float(b["close_price"]) if b else ""
        if c is None:
            status, cq, cp, qdiff, pvar = "MISSING_IN_CUSTODIAN", "", "", "", ""
            impact = bq * bp if bq and bp != "" else 0
        else:
            cq, cp = int(c["custodian_qty"]), float(c["custodian_price"])
            qdiff = bq - cq
            pvar = (cp - bp) / bp if bp else 0.0
            if abs(qdiff) > qty_tol:
                status = "QTY_BREAK"
            elif abs(pvar) > px_tol:
                status = "PRICE_BREAK"
            else:
                status = "MATCHED"
            impact = abs(qdiff) * bp if status == "QTY_BREAK" else (
                abs(cp - bp) * bq if status == "PRICE_BREAK" else 0)
        hold_rows.append({
            "stmt_date": cust_date, "fund_code": fc, "symbol": sym,
            "book_qty": bq, "custodian_qty": cq, "qty_diff": qdiff,
            "book_price": bp, "custodian_price": cp,
            "price_var_pct": round(pvar * 100, 6) if pvar != "" else "",
            "recon_status": status, "impact_inr": round(abs(impact), 2),
        })
        if status != "MATCHED":
            add_break("CUSTODIAN", status, fc, cust_date, bq, cq, qdiff,
                      impact, cfg_note(cfg, "CUSTODIAN", fc, sym, status),
                      f"{fc}|{sym}")

    # ------------------------------------------------ 2. cash recon
    bank_date = r["bank_stmt_date"]
    cash_rows_d = []
    for f in cfg["funds"]:
        fc = f["fund_code"]
        book_cash = next(c["cash_close"] for c in cash_rows
                         if c["fund_code"] == fc and c["nav_date"] == bank_date)
        bank = next(b for b in bank_rows if b["fund_code"] == fc)
        bank_bal = float(bank["bank_balance"])
        diff = round(book_cash - bank_bal, 2)
        status = "AMOUNT_BREAK" if abs(diff) > amt_tol else "MATCHED"
        cash_rows_d.append({
            "stmt_date": bank_date, "fund_code": fc,
            "book_cash": book_cash, "bank_balance": bank_bal,
            "diff_inr": diff, "recon_status": status,
        })
        if status != "MATCHED":
            add_break("BANK", status, fc, bank_date, book_cash, bank_bal,
                      diff, diff, cfg_note(cfg, "BANK", fc, "", status),
                      f"{fc}|CASH")

    # ------------------------------------------------ 3. NAV recon
    nav_rows_d = []
    rta_by_fd = {(x["fund_code"], x["nav_date"]): x for x in rta_rows}
    for h in nav_rows:
        key = (h["fund_code"], h["nav_date"])
        pub = float(rta_by_fd[key]["published_nav"])
        book_nav = h["nav"]
        var = (pub - book_nav) / book_nav
        status = "NAV_BREAK" if abs(var) > nav_tol else "MATCHED"
        nav_rows_d.append({
            "nav_date": h["nav_date"], "fund_code": h["fund_code"],
            "book_nav": book_nav, "published_nav": pub,
            "var_pct": round(var * 100, 6),
            "abs_var_pct": round(abs(var) * 100, 6),
            "recon_status": status,
        })
        if status != "MATCHED":
            impact = abs(var) * h["net_assets"]
            add_break("RTA", status, h["fund_code"], h["nav_date"],
                      book_nav, pub, round(var, 8), impact,
                      cfg_note(cfg, "RTA", h["fund_code"], "", status),
                      f"{h['fund_code']}|{h['nav_date']}")

    # ------------------------------------------------ consolidate breaks
    breaks.sort(key=lambda b: (b["detected_date"], b["fund_code"], b["recon_source"]))
    for i, b in enumerate(breaks, start=1):
        b["break_id"] = f"BRK-{i:03d}"
        b["sla_status"] = "SLA_BREACH" if b["age_business_days"] > sla_days else "OK"
    brk_cols = ["break_id", "detected_date", "fund_code", "recon_source",
                "break_type", "severity", "ref_key", "book_value",
                "external_value", "diff_value", "impact_inr",
                "age_business_days", "sla_days", "sla_status", "owner",
                "status", "note"]
    breaks = [{c: b[c] for c in brk_cols} for b in breaks]

    # ------------------------------------------------ summary
    items = (len(hold_rows) + len(cash_rows_d) + len(nav_rows_d))
    matched = sum(1 for x in hold_rows if x["recon_status"] == "MATCHED") \
        + sum(1 for x in cash_rows_d if x["recon_status"] == "MATCHED") \
        + sum(1 for x in nav_rows_d if x["recon_status"] == "MATCHED")
    n_breaks = len(breaks)
    by_source, by_type, aging = {}, {}, {"0-1": 0, "2-3": 0, "4-7": 0, ">7": 0}
    for src, rows in (("CUSTODIAN", hold_rows), ("BANK", cash_rows_d), ("RTA", nav_rows_d)):
        by_source[src] = {
            "items": len(rows),
            "matched": sum(1 for x in rows if x["recon_status"] == "MATCHED"),
            "breaks": sum(1 for x in rows if x["recon_status"] != "MATCHED"),
        }
    for b in breaks:
        by_type[b["break_type"]] = by_type.get(b["break_type"], 0) + 1
        a = b["age_business_days"]
        aging["0-1" if a <= 1 else "2-3" if a <= 3 else "4-7" if a <= 7 else ">7"] += 1
    sla_breaches = sum(1 for b in breaks if b["sla_status"] == "SLA_BREACH")
    max_nav_var = max(x["abs_var_pct"] for x in nav_rows_d)
    hold_rate = by_source["CUSTODIAN"]["matched"] / by_source["CUSTODIAN"]["items"]
    cash_break_count = by_source["BANK"]["breaks"]
    unowned = sum(1 for b in breaks if not b["owner"])

    controls = [
        {"rule_code": "CHK01", "rule_name": "Holdings recon match rate >= 99%",
         "actual": round(hold_rate, 6), "threshold": 0.99, "comparison": ">=",
         "status": "PASS" if hold_rate >= 0.99 else "FAIL",
         "comment": f"Holdings match rate = {hold_rate*100:.2f}%"},
        {"rule_code": "CHK02", "rule_name": "Cash recon - zero unmatched items",
         "actual": cash_break_count, "threshold": 0, "comparison": "<=",
         "status": "PASS" if cash_break_count == 0 else "FAIL",
         "comment": f"Unmatched cash items = {cash_break_count}"},
        {"rule_code": "CHK03", "rule_name": "Max |NAV variance| vs RTA <= 0.05%",
         "actual": round(max_nav_var / 100, 6), "threshold": nav_tol,
         "comparison": "<=",
         "status": "PASS" if max_nav_var / 100 <= nav_tol else "FAIL",
         "comment": f"Max |NAV var| vs RTA = {max_nav_var:.4f}%"},
        {"rule_code": "CHK04", "rule_name": "Open SLA-breaching breaks = 0",
         "actual": sla_breaches, "threshold": 0, "comparison": "<=",
         "status": "PASS" if sla_breaches == 0 else "FAIL",
         "comment": f"Open SLA breaches = {sla_breaches}"},
        {"rule_code": "CHK05", "rule_name": "100% of open breaks have an owner",
         "actual": 1.0 if unowned == 0 else 0.0, "threshold": 1.0,
         "comparison": ">=",
         "status": "PASS" if unowned == 0 else "FAIL",
         "comment": f"Breaks without owner = {unowned}"},
    ]
    passed = sum(1 for c in controls if c["status"] == "PASS")

    summary = {
        "as_on": as_on,
        "items": items, "matched": matched, "breaks": n_breaks,
        "match_rate_pct": round(matched / items * 100, 4),
        "by_source": by_source, "by_type": by_type, "aging": aging,
        "sla_breaches": sla_breaches,
        "max_nav_var_pct": round(max_nav_var, 6),
        "controls": {"passed": passed, "total": len(controls)},
        "generated_at": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }
    return hold_rows, cash_rows_d, nav_rows_d, breaks, summary, controls


def cfg_note(cfg, source, fund, symbol, btype):
    for b in cfg["sample_breaks"]:
        if b["source"] == source and b["fund"] == fund and b.get("symbol", "") == symbol:
            return b["note"]
        if b["source"] == source and b["fund"] == fund and source != "CUSTODIAN":
            return b["note"]
    return f"{btype} detected by reconciliation control engine"


def write_outputs(hold_rows, cash_rows_d, nav_rows_d, breaks, summary, controls):
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    def w(path, rows):
        with open(path, "w", newline="", encoding="utf-8") as f:
            wr = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            wr.writeheader()
            wr.writerows(rows)

    w(OUT_DIR / "recon_holdings.csv", hold_rows)
    w(OUT_DIR / "recon_cash.csv", cash_rows_d)
    w(OUT_DIR / "recon_nav.csv", nav_rows_d)
    w(OUT_DIR / "recon_breaks.csv", breaks)
    w(OUT_DIR / "control_panel.csv", controls)
    with open(OUT_DIR / "recon_summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(f"  [out ] recon_holdings.csv    {len(hold_rows):>5} rows")
    print(f"  [out ] recon_cash.csv        {len(cash_rows_d):>5} rows")
    print(f"  [out ] recon_nav.csv         {len(nav_rows_d):>5} rows")
    print(f"  [out ] recon_breaks.csv      {len(breaks):>5} rows")
    print(f"  [out ] control_panel.csv     {len(controls):>5} rows")
    print(f"  [out ] recon_summary.json")


def run(cfg, days, nav_rows, eod_rows, cash_rows):
    res = run_reconciliation(cfg, days, nav_rows, eod_rows, cash_rows)
    write_outputs(*res)
    return res


if __name__ == "__main__":
    cfg = load_config()
    from sample_data import build_calendar
    days = build_calendar(cfg)
    run(cfg, days,
        _read_csv(OUT_DIR / "nav_history.csv"),
        _read_csv(OUT_DIR / "holdings_eod.csv"),
        _read_csv(OUT_DIR / "cash_ledger.csv"))
