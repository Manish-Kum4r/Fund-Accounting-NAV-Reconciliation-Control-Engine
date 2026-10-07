/* ============================================================================
   PROJECT : Fund Accounting NAV & Reconciliation Control Engine
   FILE    : 04_reconciliation_control.sql
   PURPOSE : Reconciliation control engine in T-SQL.
             usp_ReconcileHoldings  - books vs custodian (qty / price / missing)
             usp_ReconcileCash      - books vs bank statement
             usp_ReconcileNAV       - engine NAV vs RTA published NAV
             usp_UpdateBreakAging   - ageing + SLA status on open breaks
             usp_RunControlPanel    - evaluates ControlRules -> ReconControlPanel
             vw_OpenBreaks / vw_ReconSummary - control views
   ========================================================================== */
SET NOCOUNT ON;
GO

/* ------------------------------------------------- 1. Holdings recon (T+1) */
CREATE OR ALTER PROCEDURE fundctl.usp_ReconcileHoldings
    @stmt_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @qty_tol DECIMAL(18,6), @px_tol DECIMAL(10,6), @sla INT;
    SELECT TOP 1 @qty_tol = qty_tolerance_units, @px_tol = price_tolerance_pct,
           @sla = sla_days
    FROM fundctl.ReconTolerance ORDER BY tol_id DESC;

    /* full outer join of book EOD vs custodian file, tolerance-based match */
    ;WITH book AS (
        SELECT e.fund_id, e.symbol, e.qty AS book_qty, e.close_price AS book_price
        FROM fundctl.HoldingsEOD e
        WHERE e.eod_date = @stmt_date
    ), cust AS (
        SELECT c.fund_id, c.symbol, c.custodian_qty, c.custodian_price
        FROM fundctl.CustodianHoldings c
        WHERE c.stmt_date = @stmt_date
    ), cmp AS (
        SELECT COALESCE(b.fund_id, c.fund_id) AS fund_id,
               COALESCE(b.symbol, c.symbol)   AS symbol,
               b.book_qty, b.book_price,
               c.custodian_qty, c.custodian_price,
               CASE WHEN c.symbol IS NULL THEN 'MISSING_IN_CUSTODIAN'
                    WHEN ABS(b.book_qty - c.custodian_qty) > @qty_tol THEN 'QTY_BREAK'
                    WHEN ABS((c.custodian_price - b.book_price) / NULLIF(b.book_price,0))
                         > @px_tol THEN 'PRICE_BREAK'
                    ELSE 'MATCHED' END AS recon_status
        FROM book b
        FULL OUTER JOIN cust c
          ON c.fund_id = b.fund_id AND c.symbol = b.symbol
    )
    INSERT INTO fundctl.ReconBreaks
        (detected_date, fund_id, recon_source, break_type, severity, ref_key,
         book_value, external_value, diff_value, impact_inr, age_business_days,
         sla_days, sla_status, owner, status, note)
    SELECT @stmt_date, x.fund_id, 'CUSTODIAN', x.recon_status,
           CASE WHEN x.recon_status IN ('QTY_BREAK','MISSING_IN_CUSTODIAN') THEN 'High'
                ELSE 'Medium' END,
           CONCAT(f.fund_code, '|', x.symbol),
           x.book_qty, x.custodian_qty, x.book_qty - x.custodian_qty,
           ABS(x.book_qty - x.custodian_qty) * x.book_price,
           0, @sla, 'OK', 'Custodian Ops Team', 'OPEN',
           CASE x.recon_status
                WHEN 'MISSING_IN_CUSTODIAN' THEN 'Holding present in books, not reported by custodian'
                WHEN 'QTY_BREAK'            THEN 'Quantity mismatch vs custodian file'
                ELSE 'Price mismatch vs custodian file' END
    FROM cmp x
    JOIN fundctl.Funds f ON f.fund_id = x.fund_id
    WHERE x.recon_status <> 'MATCHED';
END;
GO

/* ------------------------------------------------------ 2. Cash recon (T) */
CREATE OR ALTER PROCEDURE fundctl.usp_ReconcileCash
    @stmt_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @amt_tol DECIMAL(18,4), @sla INT;
    SELECT TOP 1 @amt_tol = amount_tolerance_inr, @sla = sla_days
    FROM fundctl.ReconTolerance ORDER BY tol_id DESC;

    INSERT INTO fundctl.ReconBreaks
        (detected_date, fund_id, recon_source, break_type, severity, ref_key,
         book_value, external_value, diff_value, impact_inr, age_business_days,
         sla_days, sla_status, owner, status, note)
    SELECT @stmt_date, cl.fund_id, 'BANK', 'AMOUNT_BREAK', 'Medium',
           CONCAT(f.fund_code, '|CASH'),
           cl.cash_close, bs.bank_balance,
           cl.cash_close - bs.bank_balance,
           ABS(cl.cash_close - bs.bank_balance),
           0, @sla, 'OK', 'Banking Ops Team', 'OPEN',
           'Cash per books does not agree with bank statement'
    FROM fundctl.CashLedger cl
    JOIN fundctl.BankStatement bs
      ON bs.fund_id = cl.fund_id AND bs.stmt_date = cl.ledger_date
    JOIN fundctl.Funds f ON f.fund_id = cl.fund_id
    WHERE cl.ledger_date = @stmt_date
      AND ABS(cl.cash_close - bs.bank_balance) > @amt_tol;
END;
GO

/* ------------------------------------------------------- 3. NAV recon (T) */
CREATE OR ALTER PROCEDURE fundctl.usp_ReconcileNAV
    @from_date DATE, @to_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @nav_tol DECIMAL(10,6), @sla INT;
    SELECT TOP 1 @nav_tol = nav_tolerance_pct, @sla = sla_days
    FROM fundctl.ReconTolerance ORDER BY tol_id DESC;

    INSERT INTO fundctl.ReconBreaks
        (detected_date, fund_id, recon_source, break_type, severity, ref_key,
         book_value, external_value, diff_value, impact_inr, age_business_days,
         sla_days, sla_status, owner, status, note)
    SELECT h.nav_date, h.fund_id, 'RTA', 'NAV_BREAK', 'High',
           CONCAT(f.fund_code, '|', CONVERT(VARCHAR(10), h.nav_date, 23)),
           h.nav, r.published_nav,
           (r.published_nav - h.nav) / NULLIF(h.nav, 0),
           ABS(r.published_nav - h.nav) / NULLIF(h.nav, 0) * h.net_assets,
           0, @sla, 'OK', 'RTA Ops Team', 'OPEN',
           'Published NAV differs from engine NAV beyond tolerance'
    FROM fundctl.NAVHistory h
    JOIN fundctl.RTANAV r
      ON r.fund_id = h.fund_id AND r.nav_date = h.nav_date
    JOIN fundctl.Funds f ON f.fund_id = h.fund_id
    WHERE h.nav_date BETWEEN @from_date AND @to_date
      AND ABS((r.published_nav - h.nav) / NULLIF(h.nav, 0)) > @nav_tol;
END;
GO

/* ------------------------------------------------ 4. Ageing + SLA status */
CREATE OR ALTER PROCEDURE fundctl.usp_UpdateBreakAging
    @as_on DATE
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE b
    SET b.age_business_days = (
            SELECT COUNT(*) FROM fundctl.Calendar c
            WHERE c.is_business_day = 1
              AND c.cal_date > b.detected_date
              AND c.cal_date <= @as_on),
        b.sla_status = CASE
            WHEN (SELECT COUNT(*) FROM fundctl.Calendar c
                  WHERE c.is_business_day = 1
                    AND c.cal_date > b.detected_date
                    AND c.cal_date <= @as_on) > b.sla_days
            THEN 'SLA_BREACH' ELSE 'OK' END
    FROM fundctl.ReconBreaks b
    WHERE b.status = 'OPEN';
END;
GO

/* --------------------------------------------------- 5. Control panel run */
CREATE OR ALTER PROCEDURE fundctl.usp_RunControlPanel
    @run_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @max_nav_var DECIMAL(10,6), @hold_rate DECIMAL(10,6),
            @cash_breaks INT, @sla_breaches INT, @unowned INT;

    /* CHK01 - holdings match rate (latest custodian statement) */
    DECLARE @stmt DATE = (SELECT MAX(stmt_date) FROM fundctl.CustodianHoldings);
    SELECT @hold_rate =
        1.0 * SUM(CASE WHEN x.st = 'MATCHED' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0)
    FROM (
        SELECT CASE WHEN c.symbol IS NULL THEN 'MISSING_IN_CUSTODIAN'
                    WHEN ABS(b.qty - c.custodian_qty) > t.qty_tolerance_units THEN 'QTY_BREAK'
                    WHEN ABS((c.custodian_price - b.close_price)/NULLIF(b.close_price,0))
                         > t.price_tolerance_pct THEN 'PRICE_BREAK'
                    ELSE 'MATCHED' END AS st
        FROM fundctl.HoldingsEOD b
        FULL JOIN fundctl.CustodianHoldings c
          ON c.fund_id = b.fund_id AND c.symbol = b.symbol AND c.stmt_date = b.eod_date
        CROSS JOIN (SELECT TOP 1 * FROM fundctl.ReconTolerance ORDER BY tol_id DESC) t
        WHERE b.eod_date = @stmt
    ) x;

    /* CHK02 - cash recon breaks */
    SELECT @cash_breaks = COUNT(*)
    FROM fundctl.CashLedger cl
    JOIN fundctl.BankStatement bs
      ON bs.fund_id = cl.fund_id AND bs.stmt_date = cl.ledger_date
    CROSS JOIN (SELECT TOP 1 amount_tolerance_inr AS amt_tol
                FROM fundctl.ReconTolerance ORDER BY tol_id DESC) t
    WHERE cl.ledger_date = (SELECT MAX(stmt_date) FROM fundctl.BankStatement)
      AND ABS(cl.cash_close - bs.bank_balance) > t.amt_tol;

    /* CHK03 - max NAV variance vs RTA */
    SELECT @max_nav_var = MAX(ABS((r.published_nav - h.nav) / NULLIF(h.nav, 0)))
    FROM fundctl.NAVHistory h
    JOIN fundctl.RTANAV r ON r.fund_id = h.fund_id AND r.nav_date = h.nav_date;

    /* CHK04 / CHK05 - SLA breaches / unowned breaks */
    SELECT @sla_breaches = COUNT(*) FROM fundctl.ReconBreaks
    WHERE status = 'OPEN' AND sla_status = 'SLA_BREACH';
    SELECT @unowned = COUNT(*) FROM fundctl.ReconBreaks
    WHERE status = 'OPEN' AND (owner IS NULL OR LTRIM(RTRIM(owner)) = '');

    DELETE FROM fundctl.ReconControlPanel WHERE run_date = @run_date;

    INSERT INTO fundctl.ReconControlPanel (run_date, rule_code, actual_value, threshold, status, comment)
    SELECT @run_date, cr.rule_code, a.actual, cr.threshold,
           CASE WHEN (cr.comparison = '>=' AND a.actual >= cr.threshold)
                 OR (cr.comparison = '<=' AND a.actual <= cr.threshold)
                THEN 'PASS' ELSE 'FAIL' END,
           a.comment
    FROM fundctl.ControlRules cr
    CROSS APPLY (VALUES
        ('CHK01', ISNULL(@hold_rate, 0),  CONCAT('Holdings match rate = ', CAST(CAST(ISNULL(@hold_rate,0)*100 AS DECIMAL(9,2)) AS VARCHAR(20)), '%')),
        ('CHK02', ISNULL(@cash_breaks, 0), CONCAT('Unmatched cash items = ', ISNULL(@cash_breaks, 0))),
        ('CHK03', ISNULL(@max_nav_var, 0),CONCAT('Max |NAV var| vs RTA = ', CAST(CAST(ISNULL(@max_nav_var,0)*100 AS DECIMAL(9,4)) AS VARCHAR(20)), '%')),
        ('CHK04', ISNULL(@sla_breaches, 0),CONCAT('Open SLA breaches = ', ISNULL(@sla_breaches, 0))),
        ('CHK05', CASE WHEN @unowned = 0 THEN 1 ELSE 0 END, 'All open breaks owned')
    ) a(rule_code, actual, comment)
    WHERE cr.rule_code = a.rule_code AND cr.is_active = 1;
END;
GO

/* --------------------------------------------------------- Control views */
CREATE OR ALTER VIEW fundctl.vw_OpenBreaks
AS
SELECT b.break_id, b.detected_date, f.fund_code, b.recon_source, b.break_type,
       b.severity, b.ref_key, b.diff_value, b.impact_inr,
       b.age_business_days, b.sla_status, b.owner, b.status, b.note
FROM fundctl.ReconBreaks b
JOIN fundctl.Funds f ON f.fund_id = b.fund_id
WHERE b.status = 'OPEN'
ORDER BY CASE b.sla_status WHEN 'SLA_BREACH' THEN 0 ELSE 1 END,
         b.impact_inr DESC;
GO

CREATE OR ALTER VIEW fundctl.vw_ReconSummary
AS
SELECT f.fund_code,
       b.recon_source,
       COUNT(*) AS items,
       SUM(CASE WHEN b.break_type IS NULL THEN 1 ELSE 0 END) AS matched,
       SUM(CASE WHEN b.break_type IS NOT NULL THEN 1 ELSE 0 END) AS breaks
FROM fundctl.Funds f
LEFT JOIN fundctl.ReconBreaks b ON b.fund_id = f.fund_id
GROUP BY f.fund_code, b.recon_source;
GO

/* Example run:
   EXEC fundctl.usp_ReconcileHoldings @stmt_date = '2026-10-05';
   EXEC fundctl.usp_ReconcileCash     @stmt_date = '2026-10-06';
   EXEC fundctl.usp_ReconcileNAV      @from_date = '2026-08-26', @to_date = '2026-10-06';
   EXEC fundctl.usp_UpdateBreakAging  @as_on = '2026-10-06';
   EXEC fundctl.usp_RunControlPanel   @run_date = '2026-10-06';
   SELECT * FROM fundctl.vw_OpenBreaks;
*/
