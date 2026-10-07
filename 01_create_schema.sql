/* ============================================================================
   PROJECT : Fund Accounting NAV & Reconciliation Control Engine
   FILE    : 01_create_schema.sql
   TARGET  : Microsoft SQL Server 2016+ (T-SQL)
   PURPOSE : Core schema - master data, transactions, NAV history, external
             control files (custodian / bank / RTA) and reconciliation tables.
   ========================================================================== */
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'fundctl')
    EXEC('CREATE SCHEMA fundctl AUTHORIZATION dbo;');
GO

/* ---------------------------------------------------------------- Calendar */
CREATE TABLE fundctl.Calendar (
    cal_date        DATE NOT NULL PRIMARY KEY,
    is_business_day BIT  NOT NULL DEFAULT 1,
    month_end_bd    BIT  NOT NULL DEFAULT 0   -- last business day of the month
);

/* ------------------------------------------------------------------- Funds */
CREATE TABLE fundctl.Funds (
    fund_id         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    fund_code       VARCHAR(20)   NOT NULL UNIQUE,
    fund_name       NVARCHAR(100) NOT NULL,
    category        VARCHAR(20)   NOT NULL,          -- Equity / Debt / Hybrid
    mgmt_fee_bps    DECIMAL(6,2)  NOT NULL,          -- annual mgmt fee, basis points
    opening_nav     DECIMAL(18,6) NOT NULL,
    opening_units   DECIMAL(18,4) NOT NULL,
    base_currency   CHAR(3)       NOT NULL DEFAULT 'INR',
    is_active       BIT           NOT NULL DEFAULT 1,
    created_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);

/* -------------------------------------------------------------- Securities */
CREATE TABLE fundctl.Securities (
    symbol      VARCHAR(20)   NOT NULL PRIMARY KEY,
    security_name NVARCHAR(100) NOT NULL,
    sector      VARCHAR(30)   NOT NULL,
    asset_type  VARCHAR(10)   NOT NULL,            -- Equity / Debt
    face_value  DECIMAL(18,4) NOT NULL DEFAULT 100,
    is_active   BIT           NOT NULL DEFAULT 1
);

CREATE TABLE fundctl.PriceHistory (
    price_date  DATE          NOT NULL,
    symbol      VARCHAR(20)   NOT NULL REFERENCES fundctl.Securities(symbol),
    close_price DECIMAL(18,6) NOT NULL,
    PRIMARY KEY (price_date, symbol)
);

/* --------------------------------------------------------------- Investors */
CREATE TABLE fundctl.Investors (
    investor_id  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    investor_name NVARCHAR(100) NOT NULL,
    pan_masked   CHAR(10)       NOT NULL,
    investor_type VARCHAR(20)   NOT NULL DEFAULT 'Individual',
    is_active    BIT            NOT NULL DEFAULT 1
);

/* ----------------------------------------------------------- Transactions */
/* One row per economic event. cash_impact is signed (+ inflow / - outflow).
   Investor flows are valued at T-1 application NAV (cut-off convention).   */
CREATE TABLE fundctl.Transactions (
    txn_id       BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    txn_date     DATE          NOT NULL,
    fund_id      INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    txn_type     VARCHAR(20)   NOT NULL
                 CHECK (txn_type IN ('TRADE','SUBSCRIPTION','REDEMPTION','DIVIDEND')),
    counterparty VARCHAR(50)   NOT NULL,          -- investor name or security symbol
    units        DECIMAL(18,6) NULL,              -- signed investor units
    qty          DECIMAL(18,6) NULL,              -- signed security quantity
    price        DECIMAL(18,6) NULL,
    cash_impact  DECIMAL(18,4) NOT NULL DEFAULT 0,
    rate         DECIMAL(18,6) NULL,              -- T-1 NAV used for flow valuation
    description  NVARCHAR(200) NULL,
    created_at   DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_Transactions_fund_date ON fundctl.Transactions(fund_id, txn_date);
CREATE INDEX IX_Transactions_type      ON fundctl.Transactions(txn_type);

/* ------------------------------------------------------ Opening positions */
CREATE TABLE fundctl.OpeningHoldings (
    fund_id INT         NOT NULL REFERENCES fundctl.Funds(fund_id),
    symbol  VARCHAR(20) NOT NULL REFERENCES fundctl.Securities(symbol),
    qty     DECIMAL(18,4) NOT NULL,
    PRIMARY KEY (fund_id, symbol)
);

/* ------------------------------------------------------- Engine output: EOD */
CREATE TABLE fundctl.HoldingsEOD (
    eod_date    DATE          NOT NULL,
    fund_id     INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    symbol      VARCHAR(20)   NOT NULL,
    qty         DECIMAL(18,4) NOT NULL,
    close_price DECIMAL(18,6) NOT NULL,
    market_value DECIMAL(18,2) NOT NULL,
    PRIMARY KEY (eod_date, fund_id, symbol)
);

CREATE TABLE fundctl.CashLedger (
    ledger_date DATE          NOT NULL,
    fund_id     INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    cash_open   DECIMAL(18,2) NOT NULL,
    cash_close  DECIMAL(18,2) NOT NULL,
    PRIMARY KEY (ledger_date, fund_id)
);

CREATE TABLE fundctl.NAVHistory (
    nav_date        DATE          NOT NULL,
    fund_id         INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    units_open      DECIMAL(18,4) NOT NULL,
    sub_units       DECIMAL(18,6) NOT NULL DEFAULT 0,
    red_units       DECIMAL(18,6) NOT NULL DEFAULT 0,
    units_close     DECIMAL(18,4) NOT NULL,
    cash_open       DECIMAL(18,2) NOT NULL,
    trade_cash      DECIMAL(18,2) NOT NULL DEFAULT 0,
    dividend_cash   DECIMAL(18,2) NOT NULL DEFAULT 0,
    fee_accrual     DECIMAL(18,4) NOT NULL DEFAULT 0,
    fee_paid        DECIMAL(18,2) NOT NULL DEFAULT 0,
    cash_close      DECIMAL(18,2) NOT NULL,
    holdings_value  DECIMAL(18,2) NOT NULL,
    total_assets    DECIMAL(18,2) NOT NULL,
    accrued_liab    DECIMAL(18,4) NOT NULL,
    net_assets      DECIMAL(18,2) NOT NULL,
    nav             DECIMAL(18,6) NOT NULL,
    daily_return_pct DECIMAL(10,6) NOT NULL,
    PRIMARY KEY (nav_date, fund_id)
);
CREATE INDEX IX_NAVHistory_fund_date ON fundctl.NAVHistory(fund_id, nav_date DESC);

/* --------------------------------------- External control (source) files */
CREATE TABLE fundctl.CustodianHoldings (
    stmt_date      DATE          NOT NULL,
    fund_id        INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    symbol         VARCHAR(20)   NOT NULL,
    custodian_qty  DECIMAL(18,4) NOT NULL,
    custodian_price DECIMAL(18,6) NOT NULL,
    source_file    NVARCHAR(200) NOT NULL,
    loaded_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (stmt_date, fund_id, symbol)
);

CREATE TABLE fundctl.BankStatement (
    stmt_date    DATE          NOT NULL,
    fund_id      INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    bank_balance DECIMAL(18,2) NOT NULL,
    bank_name    NVARCHAR(100) NOT NULL,
    account_last4 CHAR(4)      NOT NULL,
    loaded_at    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (stmt_date, fund_id)
);

CREATE TABLE fundctl.RTANAV (
    nav_date      DATE          NOT NULL,
    fund_id       INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    published_nav DECIMAL(18,6) NOT NULL,
    rta_name      NVARCHAR(50)  NOT NULL,
    loaded_at     DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (nav_date, fund_id)
);

/* --------------------------------------------------- Reconciliation control */
CREATE TABLE fundctl.ReconTolerance (
    tol_id           INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    qty_tolerance_units DECIMAL(18,6) NOT NULL DEFAULT 0,
    price_tolerance_pct DECIMAL(10,6) NOT NULL DEFAULT 0.0001,  -- 0.01%
    amount_tolerance_inr DECIMAL(18,4) NOT NULL DEFAULT 0.50,
    nav_tolerance_pct   DECIMAL(10,6) NOT NULL DEFAULT 0.0005,  -- 0.05%
    sla_days            INT           NOT NULL DEFAULT 1,
    effective_from      DATE          NOT NULL DEFAULT '2026-01-01'
);

CREATE TABLE fundctl.ReconBreaks (
    break_id        BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    detected_date   DATE          NOT NULL,
    fund_id         INT           NOT NULL REFERENCES fundctl.Funds(fund_id),
    recon_source    VARCHAR(20)   NOT NULL,      -- CUSTODIAN / BANK / RTA
    break_type      VARCHAR(30)   NOT NULL,      -- QTY_BREAK / PRICE_BREAK / ...
    severity        VARCHAR(10)   NOT NULL,      -- High / Medium / Low
    ref_key         NVARCHAR(100) NOT NULL,      -- e.g. 'ALPHA_EQ|HDFCBANK'
    book_value      DECIMAL(18,6) NULL,
    external_value  DECIMAL(18,6) NULL,
    diff_value      DECIMAL(18,6) NULL,
    impact_inr      DECIMAL(18,2) NOT NULL DEFAULT 0,
    age_business_days INT         NOT NULL DEFAULT 0,
    sla_days        INT           NOT NULL DEFAULT 1,
    sla_status      VARCHAR(12)   NOT NULL DEFAULT 'OK',   -- OK / SLA_BREACH
    owner           NVARCHAR(100) NOT NULL,
    status          VARCHAR(12)   NOT NULL DEFAULT 'OPEN', -- OPEN / RESOLVED
    note            NVARCHAR(500) NULL,
    created_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    resolved_at     DATETIME2     NULL
);
CREATE INDEX IX_ReconBreaks_status ON fundctl.ReconBreaks(status, sla_status);

CREATE TABLE fundctl.ControlRules (
    rule_id     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    rule_code   VARCHAR(10)   NOT NULL UNIQUE,   -- CHK01..CHK05
    rule_name   NVARCHAR(200) NOT NULL,
    threshold   DECIMAL(18,6) NOT NULL,
    comparison  VARCHAR(2)    NOT NULL,           -- '>=' or '<='
    severity    VARCHAR(10)   NOT NULL DEFAULT 'High',
    is_active   BIT           NOT NULL DEFAULT 1
);

CREATE TABLE fundctl.ReconControlPanel (
    run_date     DATE         NOT NULL,
    rule_code    VARCHAR(10)  NOT NULL REFERENCES fundctl.ControlRules(rule_code),
    actual_value DECIMAL(18,6) NOT NULL,
    threshold    DECIMAL(18,6) NOT NULL,
    status       VARCHAR(10)  NOT NULL,          -- PASS / FAIL
    comment      NVARCHAR(500) NULL,
    PRIMARY KEY (run_date, rule_code)
);

CREATE TABLE fundctl.AuditLog (
    audit_id    BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    event_time  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    event_type  VARCHAR(50)   NOT NULL,           -- NAV_CALC / RECON_RUN / BREAK_RAISED
    entity      VARCHAR(50)   NOT NULL,
    entity_key  NVARCHAR(100) NOT NULL,
    performed_by NVARCHAR(100) NOT NULL DEFAULT SUSER_SNAME(),
    details     NVARCHAR(MAX) NULL
);
GO
PRINT 'Schema fundctl created successfully.';
GO
