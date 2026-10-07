/* ============================================================================
   PROJECT : Fund Accounting NAV & Reconciliation Control Engine
   FILE    : 03_nav_calculation.sql
   PURPOSE : Daily NAV calculation engine in T-SQL.
             usp_CalculateDailyNAV - computes day-end NAV per fund.
             vw_LatestNAV          - latest NAV / AUM per fund (control view).

   NAV CONVENTION (documented control):
     NAV = (Cash + HoldingsValue - AccruedLiabilities) / UnitsOutstanding
     - Trades settle in cash at trade price on trade date.
     - Management fee accrues daily on previous day's AUM (bps/365),
       paid out (cash out, liability reset) on the last business day of month.
     - Dividends reduce cash on the payout date.
     - Investor subscriptions / redemptions are allocated at the T-1
       application NAV, hence they are NAV-neutral per unit.
   ========================================================================== */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE fundctl.usp_CalculateDailyNAV
    @fund_code  VARCHAR(20),
    @from_date  DATE,
    @to_date    DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @fund_id INT, @bps DECIMAL(6,2), @units DECIMAL(18,4),
            @cash DECIMAL(18,4), @accrued DECIMAL(18,4) = 0,
            @prev_nav DECIMAL(18,6), @nav DECIMAL(18,6),
            @d DATE, @cash_open DECIMAL(18,4), @units_open DECIMAL(18,4),
            @trade_cash DECIMAL(18,4), @div_cash DECIMAL(18,4),
            @fee_accrual DECIMAL(18,4), @fee_paid DECIMAL(18,4),
            @hold_val DECIMAL(18,4), @assets DECIMAL(18,4),
            @net_assets DECIMAL(18,4), @sub_u DECIMAL(18,6), @red_u DECIMAL(18,6),
            @sub_cash DECIMAL(18,4), @red_cash DECIMAL(18,4), @day_ret DECIMAL(10,6);

    SELECT @fund_id = fund_id, @bps = mgmt_fee_bps,
           @units = opening_units, @prev_nav = opening_nav
    FROM fundctl.Funds WHERE fund_code = @fund_code;

    IF @fund_id IS NULL THROW 50001, 'Fund code not found.', 1;

    /* opening cash = opening NAV * units - opening holdings @ first available close */
    SELECT @cash = f.opening_nav * f.opening_units - ISNULL(SUM(oh.qty * ph.close_price), 0)
    FROM fundctl.Funds f
    LEFT JOIN fundctl.OpeningHoldings oh ON oh.fund_id = f.fund_id
    LEFT JOIN fundctl.PriceHistory ph
           ON ph.symbol = oh.symbol
          AND ph.price_date = (SELECT MAX(price_date) FROM fundctl.PriceHistory
                               WHERE price_date < @from_date)
    WHERE f.fund_id = @fund_id
    GROUP BY f.opening_nav, f.opening_units;

    /* running positions */
    CREATE TABLE #pos (symbol VARCHAR(20) PRIMARY KEY, qty DECIMAL(18,4) NOT NULL);
    INSERT INTO #pos (symbol, qty)
    SELECT symbol, qty FROM fundctl.OpeningHoldings WHERE fund_id = @fund_id;

    SET @d = @from_date;
    WHILE @d <= @to_date
    BEGIN
        IF EXISTS (SELECT 1 FROM fundctl.Calendar WHERE cal_date = @d AND is_business_day = 1)
        BEGIN
            SET @cash_open = @cash;
            SET @units_open = @units;

            /* 1. trades -> cash + positions */
            SELECT @trade_cash = ISNULL(SUM(t.cash_impact), 0)
            FROM fundctl.Transactions t
            WHERE t.fund_id = @fund_id AND t.txn_date = @d AND t.txn_type = 'TRADE';

            SELECT @div_cash = ISNULL(SUM(t.cash_impact), 0)
            FROM fundctl.Transactions t
            WHERE t.fund_id = @fund_id AND t.txn_date = @d AND t.txn_type = 'DIVIDEND';

            /* apply trades to running positions (SQL Server upsert) */
            MERGE #pos AS tgt
            USING (SELECT t.counterparty AS symbol, SUM(t.qty) AS qty
                   FROM fundctl.Transactions t
                   WHERE t.fund_id = @fund_id AND t.txn_date = @d AND t.txn_type = 'TRADE'
                   GROUP BY t.counterparty) AS src
            ON tgt.symbol = src.symbol
            WHEN MATCHED THEN UPDATE SET tgt.qty += src.qty
            WHEN NOT MATCHED THEN INSERT (symbol, qty) VALUES (src.symbol, src.qty);

            SET @cash += @trade_cash;

            /* 2. management fee accrual on previous day AUM */
            SET @fee_accrual = @prev_nav * @units * @bps / 100.0 / 365.0;
            SET @accrued += @fee_accrual;

            /* 3. month-end fee payout */
            SET @fee_paid = 0;
            IF EXISTS (SELECT 1 FROM fundctl.Calendar WHERE cal_date = @d AND month_end_bd = 1)
            BEGIN
                SET @fee_paid = @accrued;
                SET @accrued = 0;
                SET @cash -= @fee_paid;
            END

            /* 4. dividend payout */
            SET @cash += @div_cash;

            /* 5. EOD valuation */
            SELECT @hold_val = ISNULL(SUM(p.qty * ph.close_price), 0)
            FROM #pos p
            JOIN fundctl.PriceHistory ph ON ph.symbol = p.symbol AND ph.price_date = @d;

            INSERT INTO fundctl.HoldingsEOD (eod_date, fund_id, symbol, qty, close_price, market_value)
            SELECT @d, @fund_id, p.symbol, p.qty, ph.close_price, p.qty * ph.close_price
            FROM #pos p
            JOIN fundctl.PriceHistory ph ON ph.symbol = p.symbol AND ph.price_date = @d;

            SET @assets = @cash + @hold_val;
            SET @net_assets = @assets - @accrued;

            /* 6. NAV (flows at T-1 NAV are NAV-neutral) */
            SET @nav = @net_assets / NULLIF(@units_open, 0);
            SET @day_ret = (@nav / NULLIF(@prev_nav, 0)) - 1;

            /* 7. investor flows at T-1 application NAV */
            SELECT @sub_u = ISNULL(SUM(t.units), 0), @sub_cash = ISNULL(SUM(t.cash_impact), 0)
            FROM fundctl.Transactions t
            WHERE t.fund_id = @fund_id AND t.txn_date = @d AND t.txn_type = 'SUBSCRIPTION';

            SELECT @red_u = ISNULL(SUM(-t.units), 0), @red_cash = ISNULL(SUM(t.cash_impact), 0)
            FROM fundctl.Transactions t
            WHERE t.fund_id = @fund_id AND t.txn_date = @d AND t.txn_type = 'REDEMPTION';

            SET @cash += @sub_cash + @red_cash;
            SET @units += @sub_u - @red_u;

            INSERT INTO fundctl.NAVHistory (
                nav_date, fund_id, units_open, sub_units, red_units, units_close,
                cash_open, trade_cash, dividend_cash, fee_accrual, fee_paid, cash_close,
                holdings_value, total_assets, accrued_liab, net_assets, nav, daily_return_pct)
            VALUES (
                @d, @fund_id, @units_open, @sub_u, @red_u, @units,
                @cash_open, @trade_cash, @div_cash, @fee_accrual, @fee_paid, @cash,
                @hold_val, @assets, @accrued, @net_assets, @nav, @day_ret);

            INSERT INTO fundctl.CashLedger (ledger_date, fund_id, cash_open, cash_close)
            VALUES (@d, @fund_id, @cash_open, @cash);

            INSERT INTO fundctl.AuditLog (event_type, entity, entity_key, details)
            VALUES ('NAV_CALC', 'FUND', @fund_code,
                    CONCAT('NAV=', @nav, ' AUM=', @net_assets));

            SET @prev_nav = @nav;
        END
        SET @d = DATEADD(DAY, 1, @d);
    END

    DROP TABLE #pos;
END;
GO

/* ------------------------------------------------- Latest NAV control view */
CREATE OR ALTER VIEW fundctl.vw_LatestNAV
AS
SELECT f.fund_code, f.fund_name, f.category,
       h.nav_date, h.nav, h.units_close, h.net_assets AS aum_inr,
       h.cash_close, h.holdings_value, h.daily_return_pct
FROM fundctl.NAVHistory h
JOIN fundctl.Funds f ON f.fund_id = h.fund_id
JOIN (SELECT fund_id, MAX(nav_date) AS max_date
      FROM fundctl.NAVHistory GROUP BY fund_id) m
  ON m.fund_id = h.fund_id AND m.max_date = h.nav_date;
GO

/* Example:
   EXEC fundctl.usp_CalculateDailyNAV @fund_code = 'ALPHA_EQ',
        @from_date = '2026-08-26', @to_date = '2026-10-06';
   SELECT * FROM fundctl.vw_LatestNAV;
*/
