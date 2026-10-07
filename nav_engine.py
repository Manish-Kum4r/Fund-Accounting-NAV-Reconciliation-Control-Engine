"""
NAV Calculation Engine (Python) - Fund Accounting NAV & Reconciliation
Control Engine.

NAV CONVENTION (documented control):
    NAV = (Cash + HoldingsValue - AccruedLiabilities) / UnitsOutstanding
    - Trades settle in cash at trade price on the trade date.
    - Management fee accrues daily on the previous day's AUM (bps / 365)
      and is paid out (cash out, liability reset) on the last business day
      of the month.
    - Dividends reduce cash on the payout date.
    - Investor subscriptions / redemptions are allocated at the T-1
      application NAV, hence they are NAV-neutral per unit.

Outputs (in /outputs):
    nav_history.csv   - day-end NAV per fund (the control record)
    holdings_eod.csv  - end-of-day positions per fund / security
    cash_ledger.csv   - day-end cash per fund
    nav_summary.json  - latest KPIs used by the dashboard
"""
import csv
import json
from pathlib import Path

from sample_data import load_config, month_end_business_days

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
OUT_DIR = ROOT / "outputs"


def _read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def calculate_nav(cfg, days, txns, price_rows, opening_holdings):
    days_iso = [d.isoformat() for d in days]
    price_map = {(r["price_date"], r["symbol"]): float(r["close_price"])
                 for r in price_rows}
    base_px = {s["symbol"]: float(s["base_price"]) for s in cfg["securities"]}
    me_days = month_end_business_days(days)
    allowed = {fc: list(w.keys()) for fc, w in cfg["fund_holdings"].items()}

    tx_by_fd = {}
    for t in txns:
        tx_by_fd.setdefault((t["fund_code"], t["txn_date"]), []).append(t)

    nav_rows, eod_rows, cash_rows = [], [], []
    summary = {"as_on": days_iso[-1], "window_start": days_iso[0], "funds": {}}

    for f in cfg["funds"]:
        fc = f["fund_code"]
        bps = float(f["mgmt_fee_bps"])
        units = float(f["opening_units"])
        holdings = {sym: 0 for sym in allowed[fc]}
        for h in opening_holdings:
            if h["fund_code"] == fc:
                holdings[h["symbol"]] = int(h["qty"])
        # opening cash = what is left after opening holdings (weights sum 0.95)
        cash = float(f["opening_nav"]) * float(f["opening_units"]) - sum(
            q * base_px[s] for s, q in holdings.items())
        accrued = 0.0
        prev_nav = float(f["opening_nav"])
        fund_rows = []

        for d in days_iso:
            day_tx = tx_by_fd.get((fc, d), [])
            cash_open, units_open = cash, units

            trade_cash = sum(float(t["cash_impact"]) for t in day_tx
                             if t["txn_type"] == "TRADE")
            div_cash = sum(float(t["cash_impact"]) for t in day_tx
                           if t["txn_type"] == "DIVIDEND")
            subs = [t for t in day_tx if t["txn_type"] == "SUBSCRIPTION"]
            reds = [t for t in day_tx if t["txn_type"] == "REDEMPTION"]

            # 1. trades -> cash + positions
            cash += trade_cash
            for t in day_tx:
                if t["txn_type"] == "TRADE":
                    holdings[t["counterparty"]] += int(t["qty"])

            # 2. management fee accrual on previous day's AUM
            fee_accrual = prev_nav * units * bps / 100.0 / 365.0
            accrued += fee_accrual

            # 3. month-end fee payout
            fee_paid = 0.0
            if d in me_days:
                fee_paid = accrued
                accrued = 0.0
                cash -= fee_paid

            # 4. dividend payout
            cash += div_cash

            # 5. EOD valuation + EOD holdings snapshot
            hold_val = 0.0
            for s, q in holdings.items():
                px = price_map[(d, s)]
                hold_val += q * px
                eod_rows.append({
                    "nav_date": d, "fund_code": fc, "symbol": s, "qty": q,
                    "close_price": px, "market_value": round(q * px, 2),
                })
            total_assets = cash + hold_val
            net_assets = total_assets - accrued

            # 6. NAV (flows at T-1 NAV are NAV-neutral)
            nav = net_assets / units_open
            day_ret = nav / prev_nav - 1.0

            # 7. investor flows at T-1 application NAV
            sub_units = sum(float(t["units"]) for t in subs)
            red_units = -sum(float(t["units"]) for t in reds)  # stored negative
            cash += (sum(float(t["cash_impact"]) for t in subs)
                     + sum(float(t["cash_impact"]) for t in reds))
            units += sub_units - red_units

            row = {
                "nav_date": d, "fund_code": fc, "fund_name": f["fund_name"],
                "category": f["category"],
                "units_open": round(units_open, 4),
                "sub_units": round(sub_units, 4),
                "red_units": round(red_units, 4),
                "units_close": round(units, 4),
                "cash_open": round(cash_open, 2),
                "trade_cash": round(trade_cash, 2),
                "dividend_cash": round(div_cash, 2),
                "fee_accrual": round(fee_accrual, 4),
                "fee_paid": round(fee_paid, 2),
                "cash_close": round(cash, 2),
                "holdings_value": round(hold_val, 2),
                "total_assets": round(total_assets, 2),
                "accrued_liab": round(accrued, 4),
                "net_assets": round(net_assets, 2),
                "nav": round(nav, 6),
                "daily_return_pct": round(day_ret * 100, 6),
            }
            nav_rows.append(row)
            fund_rows.append(row)
            cash_rows.append({
                "nav_date": d, "fund_code": fc,
                "cash_open": round(cash_open, 2), "cash_close": round(cash, 2),
            })
            prev_nav = nav

        last, first = fund_rows[-1], fund_rows[0]
        summary["funds"][fc] = {
            "fund_name": f["fund_name"], "category": f["category"],
            "nav": last["nav"], "prev_nav": fund_rows[-2]["nav"] if len(fund_rows) > 1 else f["opening_nav"],
            "day_return_pct": last["daily_return_pct"],
            "window_return_pct": round((last["nav"] / first["nav"] - 1) * 100, 4),
            "units_close": last["units_close"],
            "aum_inr": last["net_assets"],
            "cash_inr": last["cash_close"],
            "holdings_value_inr": last["holdings_value"],
        }

    # portfolio-level KPIs
    total_aum = sum(v["aum_inr"] for v in summary["funds"].values())
    summary["total_aum_inr"] = round(total_aum, 2)
    summary["wtd_avg_nav"] = round(
        sum(v["nav"] * v["aum_inr"] for v in summary["funds"].values()) / total_aum, 6)
    summary["total_units"] = round(sum(v["units_close"] for v in summary["funds"].values()), 4)
    summary["wtd_day_return_pct"] = round(
        sum(v["day_return_pct"] * v["aum_inr"] for v in summary["funds"].values()) / total_aum, 6)
    return nav_rows, eod_rows, cash_rows, summary


def write_outputs(nav_rows, eod_rows, cash_rows, summary):
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    def w(path, rows, fields):
        with open(path, "w", newline="", encoding="utf-8") as f:
            wr = csv.DictWriter(f, fieldnames=fields)
            wr.writeheader()
            wr.writerows(rows)

    w(OUT_DIR / "nav_history.csv", nav_rows, list(nav_rows[0].keys()))
    w(OUT_DIR / "holdings_eod.csv", eod_rows, list(eod_rows[0].keys()))
    w(OUT_DIR / "cash_ledger.csv", cash_rows, list(cash_rows[0].keys()))
    with open(OUT_DIR / "nav_summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(f"  [out ] nav_history.csv       {len(nav_rows):>5} rows")
    print(f"  [out ] holdings_eod.csv      {len(eod_rows):>5} rows")
    print(f"  [out ] cash_ledger.csv       {len(cash_rows):>5} rows")
    print(f"  [out ] nav_summary.json")


def run():
    cfg = load_config()
    from sample_data import build_calendar
    days = build_calendar(cfg)
    txns = _read_csv(DATA_DIR / "transactions.csv")
    prices = _read_csv(DATA_DIR / "prices.csv")
    opening = _read_csv(DATA_DIR / "opening_holdings.csv")
    nav_rows, eod_rows, cash_rows, summary = calculate_nav(
        cfg, days, txns, prices, opening)
    write_outputs(nav_rows, eod_rows, cash_rows, summary)
    return cfg, nav_rows, eod_rows, cash_rows, summary


if __name__ == "__main__":
    run()
