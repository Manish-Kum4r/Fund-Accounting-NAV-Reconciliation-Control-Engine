"""
run_all.py - one-command orchestrator for the whole engine.

    python 02_python/run_all.py

Pipeline:
    1. Generate sample data            (data/*.csv)
    2. Calculate daily NAV             (outputs/nav_history.csv ...)
    3. Generate external control files (custodian / bank / RTA, data/*.csv)
    4. Run reconciliation control      (outputs/recon_*.csv, control_panel.csv)
    5. Print the daily control report
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import sample_data
import nav_engine
import reconciliation_engine

BANNER = "=" * 74


def main():
    print(BANNER)
    print("  FUND ACCOUNTING - NAV & RECONCILIATION CONTROL ENGINE")
    print(BANNER)

    print("\n[1/4] Generating sample data (seeded, deterministic)")
    cfg = sample_data.load_config()
    days, prices, opening, txns, price_map = sample_data.generate_base(cfg)

    print("\n[2/4] Calculating daily NAV (30 business days x 3 funds)")
    nav_rows, eod_rows, cash_rows, nav_summary = nav_engine.calculate_nav(
        cfg, days, txns, prices, opening)
    nav_engine.write_outputs(nav_rows, eod_rows, cash_rows, nav_summary)

    print("\n[3/4] Generating external control files (custodian / bank / RTA)")
    sample_data.generate_external(cfg, nav_rows, eod_rows, cash_rows, price_map)

    print("\n[4/4] Running reconciliation control engine")
    hold_rows, cash_rows_d, nav_rows_d, breaks, recon_summary, controls = \
        reconciliation_engine.run(cfg, days, nav_rows, eod_rows, cash_rows)

    # ---------------------------------------------------------- report
    lines = []
    lines.append(BANNER)
    lines.append("  DAILY CONTROL REPORT - NAV & RECONCILIATION")
    lines.append(f"  As on: {nav_summary['as_on']} (IST)   Window: {nav_summary['window_start']} -> {nav_summary['as_on']}")
    lines.append(BANNER)
    lines.append("")
    lines.append("  NAV SUMMARY (per fund)")
    lines.append(f"  {'Fund':<12}{'NAV':>12}{'Day Ret %':>12}{'Window Ret %':>15}{'AUM (INR Cr)':>15}")
    for fc, v in nav_summary["funds"].items():
        lines.append(f"  {fc:<12}{v['nav']:>12.4f}{v['day_return_pct']:>12.3f}"
                     f"{v['window_return_pct']:>15.3f}{v['aum_inr']/1e7:>15.2f}")
    lines.append(f"  {'TOTAL':<12}{'':>12}{'':>12}{'':>15}{nav_summary['total_aum_inr']/1e7:>15.2f}")
    lines.append(f"  Wtd avg NAV: {nav_summary['wtd_avg_nav']:.4f}   "
                 f"Wtd day return: {nav_summary['wtd_day_return_pct']:+.3f}%")
    lines.append("")
    lines.append("  RECONCILIATION CONTROL")
    lines.append(f"  Items checked : {recon_summary['items']}")
    lines.append(f"  Matched       : {recon_summary['matched']}")
    lines.append(f"  Open breaks   : {recon_summary['breaks']}   "
                 f"(match rate {recon_summary['match_rate_pct']:.2f}%)")
    lines.append(f"  SLA breaches  : {recon_summary['sla_breaches']}")
    lines.append(f"  By source     : " + "   ".join(
        f"{k}={v['breaks']}brk/{v['items']}" for k, v in recon_summary["by_source"].items()))
    lines.append(f"  By type       : " + (", ".join(f"{k}={v}" for k, v in recon_summary["by_type"].items()) or "none"))
    lines.append(f"  Ageing (bdays): " + "   ".join(f"{k}d={v}" for k, v in recon_summary["aging"].items()))
    lines.append("")
    lines.append("  OPEN BREAKS")
    lines.append(f"  {'ID':<9}{'Fund':<11}{'Source':<10}{'Type':<22}{'Age':>4}{'Impact INR':>14}  {'SLA':<10}Owner")
    for b in breaks:
        lines.append(f"  {b['break_id']:<9}{b['fund_code']:<11}{b['recon_source']:<10}"
                     f"{b['break_type']:<22}{b['age_business_days']:>4}"
                     f"{b['impact_inr']:>14,.0f}  {b['sla_status']:<12}{b['owner']}")
    lines.append("")
    lines.append("  CONTROL PANEL")
    for c in controls:
        lines.append(f"  {c['rule_code']}  [{c['status']:<4}] {c['rule_name']:<45} actual={c['actual']}  ({c['comment']})")
    lines.append("")
    overall = "ALL CONTROLS PASS" if recon_summary["controls"]["passed"] == recon_summary["controls"]["total"] \
        else f"CONTROL ALERT - {recon_summary['breaks']} open breaks, " \
             f"{recon_summary['controls']['passed']}/{recon_summary['controls']['total']} controls passed"
    lines.append(f"  OVERALL: {overall}")
    lines.append(BANNER)

    report = "\n".join(lines)
    print("\n" + report)
    (nav_engine.OUT_DIR / "run_report.txt").write_text(report, encoding="utf-8")
    print(f"\n  Full report saved to outputs/run_report.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
