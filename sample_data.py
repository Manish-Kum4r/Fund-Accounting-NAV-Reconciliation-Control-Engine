"""
Sample data generator - Fund Accounting NAV & Reconciliation Control Engine.

Generates deterministic (seeded) demo data:
  data/prices.csv              - business-day price history (random walk)
  data/transactions.csv        - trades, subscriptions, redemptions, dividends
  data/opening_holdings.csv    - opening positions per fund
  data/custodian_holdings.csv  - external custodian file (T-1, with injected breaks)
  data/bank_statement.csv      - external bank statement (with injected break)
  data/rta_nav.csv             - RTA published NAV (with injected break)

Run via run_all.py (this module is not meant to be executed standalone).
"""
import csv
import datetime as dt
import random
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"


# ------------------------------------------------------------------ helpers
def load_config():
    with open(ROOT / "02_python" / "config.yaml", "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def build_calendar(cfg):
    """Last N business days (Mon-Fri) ending on the as-on date."""
    end = dt.date.fromisoformat(cfg["project"]["as_on"])
    n = int(cfg["project"]["business_days"])
    days, d = [], end
    while len(days) < n:
        if d.weekday() < 5:  # holidays are not modelled - see README
            days.append(d)
        d -= dt.timedelta(days=1)
    return sorted(days)


def month_end_business_days(days):
    """Last business day of each month inside the window (ISO strings)."""
    me = {}
    for d in days:
        me[d.month] = d.isoformat()  # sorted asc -> last one wins
    return set(me.values())


def write_csv(path, rows, fieldnames):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
    print(f"  [data] {path.name:<28} {len(rows):>5} rows")


# ------------------------------------------------------------- generators
def gen_price_history(cfg, days, rng):
    rows = []
    for sec in cfg["securities"]:
        p = float(sec["base_price"])
        drift = 0.0007 if sec["type"] == "Equity" else 0.00012
        for d in days:
            p = p * (1 + drift + rng.gauss(0, sec["vol"]))
            rows.append({
                "price_date": d.isoformat(),
                "symbol": sec["symbol"],
                "security_name": sec["name"],
                "sector": sec["sector"],
                "asset_type": sec["type"],
                "close_price": round(p, 4),
            })
    return rows


def gen_opening_holdings(cfg):
    """Positions sized so weights x (NAV x units) are invested; ~5% stays cash."""
    base_px = {s["symbol"]: float(s["base_price"]) for s in cfg["securities"]}
    rows = []
    for f in cfg["funds"]:
        target = f["opening_nav"] * f["opening_units"]
        for sym, w in cfg["fund_holdings"][f["fund_code"]].items():
            qty = int(round(target * w / base_px[sym] / 100.0) * 100)  # lot of 100
            rows.append({"fund_code": f["fund_code"], "symbol": sym, "qty": qty})
    return rows


def gen_trades(cfg, days, price_map, opening_holdings, rng):
    allowed = {fc: list(w.keys()) for fc, w in cfg["fund_holdings"].items()}
    held = {(h["fund_code"], h["symbol"]): h["qty"] for h in opening_holdings}
    rows = []
    for f in cfg["funds"]:
        fc = f["fund_code"]
        for d in days:
            for _ in range(rng.choice([1, 1, 2, 2, 3])):
                sym = rng.choice(allowed[fc])
                side = rng.choice(["BUY", "SELL"])
                qty = rng.choice([100, 200, 500, 1000]) * rng.randint(1, 8)
                if side == "SELL" and held[(fc, sym)] < qty:
                    side = "BUY"
                signed = qty if side == "BUY" else -qty
                px = round(price_map[(d.isoformat(), sym)] * (1 + rng.uniform(-0.002, 0.002)), 4)
                held[(fc, sym)] += signed
                rows.append({
                    "txn_date": d.isoformat(),
                    "fund_code": fc,
                    "txn_type": "TRADE",
                    "counterparty": sym,
                    "units": "",
                    "qty": signed,
                    "price": px,
                    "cash_impact": round(-signed * px, 2),
                    "rate": "",
                    "description": f"{side} {qty} {sym} @ {px}",
                })
    return rows


def gen_investor_flows(cfg, days, rng):
    """
    Subscriptions / redemptions valued at a T-1 proxy NAV (cut-off convention).
    Dividend of Rs 0.10/unit paid on 15-Sep if inside the window.
    """
    investors = cfg["investors"]
    proxy = {f["fund_code"]: float(f["opening_nav"]) for f in cfg["funds"]}
    div_date = next((d for d in days if d.month == 9 and d.day == 15), None)
    rows = []
    for f in cfg["funds"]:
        fc = f["fund_code"]
        prev_proxy = proxy[fc]
        for d in days:
            proxy[fc] *= (1 + rng.gauss(0.0003, 0.008))
            rate = prev_proxy  # T-1 application NAV
            prev_proxy = proxy[fc]

            if rng.random() < 0.70:  # subscription
                inv = rng.choice(investors)
                amt = round(rng.uniform(5_000, 500_000), 2)
                units = round(amt / rate, 4)
                rows.append({
                    "txn_date": d.isoformat(), "fund_code": fc,
                    "txn_type": "SUBSCRIPTION", "counterparty": inv["name"],
                    "units": units, "qty": "", "price": "",
                    "cash_impact": round(units * rate, 2), "rate": round(rate, 4),
                    "description": f"Subscription by {inv['name']} ({inv['pan']})",
                })
            if rng.random() < 0.50:  # redemption
                inv = rng.choice(investors)
                units = round(f["opening_units"] * rng.uniform(0.0005, 0.003), 4)
                rows.append({
                    "txn_date": d.isoformat(), "fund_code": fc,
                    "txn_type": "REDEMPTION", "counterparty": inv["name"],
                    "units": -units, "qty": "", "price": "",
                    "cash_impact": round(-units * rate, 2), "rate": round(rate, 4),
                    "description": f"Redemption by {inv['name']} ({inv['pan']})",
                })
            if d == div_date:  # dividend payout
                total = round(0.10 * f["opening_units"], 2)
                rows.append({
                    "txn_date": d.isoformat(), "fund_code": fc,
                    "txn_type": "DIVIDEND", "counterparty": "UNIT HOLDERS",
                    "units": "", "qty": "", "price": "",
                    "cash_impact": -total, "rate": "",
                    "description": "Dividend payout @ Rs 0.10 per unit",
                })
    return rows


def gen_external_statements(cfg, nav_history, holdings_eod, cash_ledger, price_map):
    """
    External control files built FROM the engine outputs, then perturbed with
    the deliberate sample breaks defined in config.yaml.
    """
    breaks = cfg["sample_breaks"]
    cust_date = cfg["recon"]["custodian_stmt_date"]
    bank_date = cfg["recon"]["bank_stmt_date"]

    # ---- custodian holdings (book EOD at custodian stmt date + breaks)
    book = {(h["fund_code"], h["symbol"]): h
            for h in holdings_eod if h["nav_date"] == cust_date}
    cust_breaks = {(b["fund"], b["symbol"]): b for b in breaks if b["source"] == "CUSTODIAN"}
    cust_rows = []
    for (fc, sym), h in sorted(book.items()):
        b = cust_breaks.get((fc, sym))
        if b and b["type"] == "MISSING_IN_CUSTODIAN":
            continue  # not reported by custodian -> break
        qty = int(h["qty"]) + (b["qty_delta"] if b else 0)
        px = price_map[(cust_date, sym)]
        if b and b.get("price_delta_pct"):
            px = round(px * (1 + b["price_delta_pct"] / 100.0), 4)
        cust_rows.append({
            "stmt_date": cust_date, "fund_code": fc, "symbol": sym,
            "custodian_qty": qty, "custodian_price": px,
            "source_file": f"CUSTODIAN_DUMP_{cust_date.replace('-', '')}.csv",
        })

    # ---- bank statement (book cash at bank stmt date + breaks)
    bank_rows = []
    for f in cfg["funds"]:
        fc = f["fund_code"]
        book_cash = next(c["cash_close"] for c in cash_ledger
                         if c["fund_code"] == fc and c["nav_date"] == bank_date)
        delta = next((b["amount_delta"] for b in breaks
                      if b["source"] == "BANK" and b["fund"] == fc), 0.0)
        bank_rows.append({
            "stmt_date": bank_date, "fund_code": fc,
            "bank_balance": round(book_cash + delta, 2),
            "bank_name": "HDFC Bank - Fund Collection A/c", "account_last4": "4471",
        })

    # ---- RTA published NAV (engine NAV + breaks)
    rta_rows = []
    for h in nav_history:
        nav = h["nav"]
        for b in breaks:
            if (b["source"] == "RTA" and b["fund"] == h["fund_code"]
                    and b["date"] == h["nav_date"]):
                nav = round(nav * (1 + b["nav_delta_pct"] / 100.0), 6)
        rta = "Karvy" if h["fund_code"] == "BETA_DEBT" else "CAMS"
        rta_rows.append({
            "nav_date": h["nav_date"], "fund_code": h["fund_code"],
            "published_nav": nav, "rta_name": rta,
        })
    return cust_rows, bank_rows, rta_rows


# ------------------------------------------------------------------ writers
def generate_base(cfg):
    """Everything the NAV engine needs (no external files yet)."""
    rng = random.Random(cfg["random_seed"])
    days = build_calendar(cfg)
    print(f"  [data] calendar: {days[0]} -> {days[-1]} ({len(days)} business days)")

    prices = gen_price_history(cfg, days, rng)
    opening = gen_opening_holdings(cfg)
    price_map = {(r["price_date"], r["symbol"]): float(r["close_price"]) for r in prices}
    trades = gen_trades(cfg, days, price_map, opening, rng)
    flows = gen_investor_flows(cfg, days, rng)

    txns = trades + flows
    txns.sort(key=lambda t: (t["txn_date"], t["fund_code"], t["txn_type"]))
    for i, t in enumerate(txns, start=1):
        t["txn_id"] = i
    # reorder columns
    cols = ["txn_id", "txn_date", "fund_code", "txn_type", "counterparty",
            "units", "qty", "price", "cash_impact", "rate", "description"]
    txns = [{c: t[c] for c in cols} for t in txns]

    write_csv(DATA_DIR / "prices.csv", prices,
              ["price_date", "symbol", "security_name", "sector", "asset_type", "close_price"])
    write_csv(DATA_DIR / "opening_holdings.csv", opening,
              ["fund_code", "symbol", "qty"])
    write_csv(DATA_DIR / "transactions.csv", txns, cols)
    return days, prices, opening, txns, price_map


def generate_external(cfg, nav_history, holdings_eod, cash_ledger, price_map):
    cust_rows, bank_rows, rta_rows = gen_external_statements(
        cfg, nav_history, holdings_eod, cash_ledger, price_map)
    write_csv(DATA_DIR / "custodian_holdings.csv", cust_rows,
              ["stmt_date", "fund_code", "symbol", "custodian_qty",
               "custodian_price", "source_file"])
    write_csv(DATA_DIR / "bank_statement.csv", bank_rows,
              ["stmt_date", "fund_code", "bank_balance", "bank_name", "account_last4"])
    write_csv(DATA_DIR / "rta_nav.csv", rta_rows,
              ["nav_date", "fund_code", "published_nav", "rta_name"])
