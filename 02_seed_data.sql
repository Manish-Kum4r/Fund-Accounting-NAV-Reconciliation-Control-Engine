/* ============================================================================
   PROJECT : Fund Accounting NAV & Reconciliation Control Engine
   FILE    : 02_seed_data.sql
   PURPOSE : Master data + calendar + control rules seed.
             (Transaction-level data is bulk-loaded from the Python engine
              outputs using BCP - commands at the bottom of this file.)
   ========================================================================== */
SET NOCOUNT ON;
GO

/* ------------------------------------------------------- Business calendar */
;WITH d AS (
    SELECT CAST('2025-01-01' AS DATE) AS cal_date
    UNION ALL
    SELECT DATEADD(DAY, 1, cal_date) FROM d WHERE cal_date < '2027-12-31'
)
INSERT INTO fundctl.Calendar (cal_date, is_business_day, month_end_bd)
SELECT cal_date,
       CASE WHEN DATEPART(WEEKDAY, cal_date) IN (1, 7) THEN 0 ELSE 1 END,
       0
FROM d
WHERE NOT EXISTS (SELECT 1 FROM fundctl.Calendar c WHERE c.cal_date = d.cal_date)
OPTION (MAXRECURSION 0);
GO

/* month_end_bd = last business day of each month */
UPDATE c
SET c.month_end_bd = 1
FROM fundctl.Calendar c
JOIN (
    SELECT MONTH(cal_date) AS m, YEAR(cal_date) AS y, MAX(cal_date) AS last_bd
    FROM fundctl.Calendar
    WHERE is_business_day = 1
    GROUP BY MONTH(cal_date), YEAR(cal_date)
) m ON c.cal_date = m.last_bd;
GO

/* ------------------------------------------------------------------- Funds */
INSERT INTO fundctl.Funds (fund_code, fund_name, category, mgmt_fee_bps, opening_nav, opening_units)
VALUES
    ('ALPHA_EQ',  N'Alpha Equity Fund',   'Equity', 150.00, 10.000000, 10000000),
    ('BETA_DEBT', N'Beta Debt Fund',      'Debt',    75.00, 10.000000, 20000000),
    ('GAMMA_BAL', N'Gamma Balanced Fund', 'Hybrid', 125.00, 10.000000, 15000000);
GO

/* -------------------------------------------------------------- Securities */
INSERT INTO fundctl.Securities (symbol, security_name, sector, asset_type, face_value) VALUES
    ('HDFCBANK',   N'HDFC Bank Ltd',          'Financials', 'Equity', 2),
    ('ICICIBANK',  N'ICICI Bank Ltd',         'Financials', 'Equity', 2),
    ('INFY',       N'Infosys Ltd',            'IT',         'Equity', 5),
    ('TCS',        N'Tata Consultancy Svcs',  'IT',         'Equity', 1),
    ('RELIANCE',   N'Reliance Industries',    'Energy',     'Equity', 5),
    ('ITC',        N'ITC Ltd',                'FMCG',       'Equity', 1),
    ('SBIN',       N'State Bank of India',    'Financials', 'Equity', 1),
    ('LT',         N'Larsen & Toubro',        'Infra',      'Equity', 2),
    ('MARUTI',     N'Maruti Suzuki India',    'Auto',       'Equity', 5),
    ('HINDUNILVR', N'Hindustan Unilever',     'FMCG',       'Equity', 1),
    ('GOI7.26-36', N'GOI 7.26% 2036',         'G-Sec',      'Debt',   100),
    ('GOI8.2-33',  N'GOI 8.20% 2033',         'G-Sec',      'Debt',   100),
    ('SDL-MH-32',  N'SDL Maharashtra 2032',   'SDL',        'Debt',   100),
    ('CP-TATA',    N'Tata Motors CP 90D',     'Money Mkt',  'Debt',   100),
    ('NCD-REL',    N'Reliance NCD 9.10%',     'Corporate',  'Debt',   1000);
GO

/* --------------------------------------------------------------- Investors */
INSERT INTO fundctl.Investors (investor_name, pan_masked, investor_type) VALUES
    (N'Aarav Sharma',   'AAAPS1234A', 'Individual'),
    (N'Priya Nair',     'ABCPN5678B', 'Individual'),
    (N'Rahul Mehta',    'ACARM6789C', 'Individual'),
    (N'Sneha Iyer',     'ADSIS2345D', 'Individual'),
    (N'Vikram Reddy',   'AVBRS7890E', 'Individual'),
    (N'Ananya Gupta',   'AANJG3456F', 'Individual'),
    (N'Karan Singh',    'AKLSG4567G', 'Individual'),
    (N'Deepa Kulkarni', 'DKDKL5678H', 'Individual'),
    (N'Arjun Patel',    'APAPL6789I', 'HNI'),
    (N'Meera Joshi',    'MMJMJ7890K', 'HNI');
GO

/* ------------------------------------------------------ Opening holdings */
INSERT INTO fundctl.OpeningHoldings (fund_id, symbol, qty)
SELECT f.fund_id, s.symbol, s.qty
FROM (VALUES
    ('ALPHA_EQ',  'HDFCBANK',   575700), ('ALPHA_EQ',  'ICICIBANK', 760300),
    ('ALPHA_EQ',  'INFY',       611600), ('ALPHA_EQ',  'TCS',       394300),
    ('ALPHA_EQ',  'RELIANCE',   703700), ('ALPHA_EQ',  'ITC',      1979100),
    ('BETA_DEBT', 'GOI7.26-36', 5882300), ('BETA_DEBT', 'GOI8.2-33', 4354800),
    ('BETA_DEBT', 'SDL-MH-32', 2968500), ('BETA_DEBT', 'CP-TATA',  1503000),
    ('BETA_DEBT', 'NCD-REL',     448100),
    ('GAMMA_BAL', 'HDFCBANK',   287800), ('GAMMA_BAL', 'INFY',       152900),
    ('GAMMA_BAL', 'LT',         156200), ('GAMMA_BAL', 'MARUTI',     208300),
    ('GAMMA_BAL', 'GOI7.26-36', 2451000), ('GAMMA_BAL', 'SDL-MH-32',  1484100)
) s(fund_code, symbol, qty)
JOIN fundctl.Funds f ON f.fund_code = s.fund_code;
GO

/* ------------------------------------------------------- Recon tolerances */
INSERT INTO fundctl.ReconTolerance
    (qty_tolerance_units, price_tolerance_pct, amount_tolerance_inr, nav_tolerance_pct, sla_days)
VALUES (0, 0.000100, 0.50, 0.000500, 1);
GO

/* ----------------------------------------------------------- Control rules */
INSERT INTO fundctl.ControlRules (rule_code, rule_name, threshold, comparison, severity) VALUES
    ('CHK01', N'Holdings reconciliation match rate >= 99%',        0.990000, '>=', 'High'),
    ('CHK02', N'Cash reconciliation - zero unmatched items',       0.000000, '<=', 'High'),
    ('CHK03', N'Max |NAV variance| vs RTA <= 0.05% (all days)',   0.000500, '<=', 'High'),
    ('CHK04', N'Open SLA-breaching breaks = 0',                   0.000000, '<=', 'High'),
    ('CHK05', N'100% of open breaks have an owner assigned',      1.000000, '>=', 'Medium');
GO

/* ============================================================================
   BULK LOAD (run after the Python engine has produced CSVs in /data):
   bcp fundctl.dbo.Transactions      in data\transactions.csv      -S . -T -c -t,
   bcp fundctl.dbo.PriceHistory      in data\prices.csv            -S . -T -c -t,
   bcp fundctl.dbo.CustodianHoldings in data\custodian_holdings.csv -S . -T -c -t,
   bcp fundctl.dbo.BankStatement     in data\bank_statement.csv    -S . -T -c -t,
   bcp fundctl.dbo.RTANAV            in data\rta_nav.csv           -S . -T -c -t,
   ========================================================================== */
PRINT 'Seed data loaded.';
GO
