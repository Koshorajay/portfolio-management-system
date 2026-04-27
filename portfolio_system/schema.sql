-- ============================================================
--  Portfolio Management System - Database Schema
--  DBMS Concepts: Primary Keys, Foreign Keys, Constraints,
--                 Indexes, Transactions, Normalization
-- ============================================================

CREATE DATABASE IF NOT EXISTS portfolio_db;
USE portfolio_db;

-- ──────────────────────────────────────────────
-- TABLE 1: USER
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS USER (
    user_id       INT          AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    email         VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    created_at    DATETIME     DEFAULT CURRENT_TIMESTAMP
);

-- ──────────────────────────────────────────────
-- TABLE 2: PORTFOLIO
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS PORTFOLIO (
    portfolio_id   INT          AUTO_INCREMENT PRIMARY KEY,
    user_id        INT          NOT NULL,
    portfolio_name VARCHAR(100) NOT NULL,
    base_currency  VARCHAR(10)  DEFAULT 'USD',
    created_at     DATETIME     DEFAULT CURRENT_TIMESTAMP,

    -- Foreign Key: links portfolio to its owner
    CONSTRAINT fk_portfolio_user
        FOREIGN KEY (user_id) REFERENCES USER(user_id)
        ON DELETE CASCADE
);

-- ──────────────────────────────────────────────
-- TABLE 3: ASSET
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ASSET (
    asset_id   INT          AUTO_INCREMENT PRIMARY KEY,
    symbol     VARCHAR(20)  NOT NULL UNIQUE,
    name       VARCHAR(100) NOT NULL,
    asset_type ENUM('stock','crypto') NOT NULL,
    exchange   VARCHAR(50),
    sector     VARCHAR(50)
);

-- ──────────────────────────────────────────────
-- TABLE 4: TRANSACTION
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS TRANSACTION (
    transaction_id   INT            AUTO_INCREMENT PRIMARY KEY,
    portfolio_id     INT            NOT NULL,
    asset_id         INT            NOT NULL,
    transaction_type ENUM('BUY','SELL') NOT NULL,
    quantity         DECIMAL(18, 8) NOT NULL CHECK (quantity > 0),
    price_per_unit   DECIMAL(18, 8) NOT NULL CHECK (price_per_unit > 0),
    transaction_fee  DECIMAL(18, 8) DEFAULT 0.00,
    trade_date       DATETIME       DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_txn_portfolio
        FOREIGN KEY (portfolio_id) REFERENCES PORTFOLIO(portfolio_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_txn_asset
        FOREIGN KEY (asset_id) REFERENCES ASSET(asset_id)
        ON DELETE RESTRICT
);

-- Index for fast lookup of transactions by portfolio
CREATE INDEX idx_txn_portfolio ON TRANSACTION(portfolio_id);
CREATE INDEX idx_txn_asset     ON TRANSACTION(asset_id);

-- ──────────────────────────────────────────────
-- TABLE 5: HOLDING
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS HOLDING (
    holding_id              INT            AUTO_INCREMENT PRIMARY KEY,
    portfolio_id            INT            NOT NULL,
    asset_id                INT            NOT NULL,
    total_quantity          DECIMAL(18, 8) NOT NULL DEFAULT 0,
    average_buy_price       DECIMAL(18, 8) NOT NULL DEFAULT 0,
    current_value_snapshot  DECIMAL(18, 8) DEFAULT 0,

    -- Composite UNIQUE: one holding row per asset per portfolio
    UNIQUE KEY uq_holding (portfolio_id, asset_id),

    CONSTRAINT fk_holding_portfolio
        FOREIGN KEY (portfolio_id) REFERENCES PORTFOLIO(portfolio_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_holding_asset
        FOREIGN KEY (asset_id) REFERENCES ASSET(asset_id)
        ON DELETE RESTRICT
);

-- ──────────────────────────────────────────────
-- TABLE 6: MARKET_DATA
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS MARKET_DATA (
    price_id      INT            AUTO_INCREMENT PRIMARY KEY,
    asset_id      INT            NOT NULL,
    closing_price DECIMAL(18, 8) NOT NULL,
    recorded_at   DATETIME       DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_market_asset
        FOREIGN KEY (asset_id) REFERENCES ASSET(asset_id)
        ON DELETE CASCADE
);

-- Index for latest price lookups
CREATE INDEX idx_market_asset_date ON MARKET_DATA(asset_id, recorded_at DESC);

-- ──────────────────────────────────────────────
-- VIEW: Portfolio summary (JOIN example)
-- Returns holdings with asset details and cost basis
-- ──────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_portfolio_holdings AS
SELECT
    h.holding_id,
    p.portfolio_id,
    p.portfolio_name,
    u.username,
    a.symbol,
    a.name        AS asset_name,
    a.asset_type,
    a.exchange,
    h.total_quantity,
    h.average_buy_price,
    ROUND(h.total_quantity * h.average_buy_price, 2) AS cost_basis,
    h.current_value_snapshot
FROM HOLDING      h
JOIN PORTFOLIO    p ON h.portfolio_id = p.portfolio_id
JOIN USER         u ON p.user_id      = u.user_id
JOIN ASSET        a ON h.asset_id     = a.asset_id;

-- ──────────────────────────────────────────────
-- STORED PROCEDURE: Execute a BUY transaction
-- Demonstrates: Transactions, Conditional Logic,
--               INSERT … ON DUPLICATE KEY UPDATE
-- ──────────────────────────────────────────────
DELIMITER $$

CREATE PROCEDURE sp_buy_asset (
    IN  p_portfolio_id   INT,
    IN  p_asset_id       INT,
    IN  p_quantity       DECIMAL(18,8),
    IN  p_price          DECIMAL(18,8),
    IN  p_fee            DECIMAL(18,8),
    OUT p_status         VARCHAR(50)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_status = 'ERROR';
    END;

    START TRANSACTION;

    -- Step 1: Record the transaction
    INSERT INTO TRANSACTION (portfolio_id, asset_id, transaction_type,
                             quantity, price_per_unit, transaction_fee)
    VALUES (p_portfolio_id, p_asset_id, 'BUY', p_quantity, p_price, p_fee);

    -- Step 2: Upsert HOLDING with new weighted average price
    INSERT INTO HOLDING (portfolio_id, asset_id, total_quantity, average_buy_price)
    VALUES (p_portfolio_id, p_asset_id, p_quantity, p_price)
    ON DUPLICATE KEY UPDATE
        average_buy_price = ROUND(
            ((total_quantity * average_buy_price) + (p_quantity * p_price))
            / (total_quantity + p_quantity), 8
        ),
        total_quantity = total_quantity + p_quantity;

    COMMIT;
    SET p_status = 'SUCCESS';
END$$

-- ──────────────────────────────────────────────
-- STORED PROCEDURE: Execute a SELL transaction
-- ──────────────────────────────────────────────
CREATE PROCEDURE sp_sell_asset (
    IN  p_portfolio_id   INT,
    IN  p_asset_id       INT,
    IN  p_quantity       DECIMAL(18,8),
    IN  p_price          DECIMAL(18,8),
    IN  p_fee            DECIMAL(18,8),
    OUT p_status         VARCHAR(50)
)
BEGIN
    DECLARE v_held DECIMAL(18,8) DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_status = 'ERROR';
    END;

    START TRANSACTION;

    -- Check available quantity
    SELECT total_quantity INTO v_held
    FROM HOLDING
    WHERE portfolio_id = p_portfolio_id AND asset_id = p_asset_id
    FOR UPDATE;                          -- row-level lock

    IF v_held IS NULL OR v_held < p_quantity THEN
        ROLLBACK;
        SET p_status = 'INSUFFICIENT_QUANTITY';
    ELSE
        -- Record the SELL transaction
        INSERT INTO TRANSACTION (portfolio_id, asset_id, transaction_type,
                                 quantity, price_per_unit, transaction_fee)
        VALUES (p_portfolio_id, p_asset_id, 'SELL', p_quantity, p_price, p_fee);

        -- Update or remove holding
        IF v_held = p_quantity THEN
            DELETE FROM HOLDING
            WHERE portfolio_id = p_portfolio_id AND asset_id = p_asset_id;
        ELSE
            UPDATE HOLDING
            SET total_quantity = total_quantity - p_quantity
            WHERE portfolio_id = p_portfolio_id AND asset_id = p_asset_id;
        END IF;

        COMMIT;
        SET p_status = 'SUCCESS';
    END IF;
END$$

DELIMITER ;

-- ──────────────────────────────────────────────
-- Seed: Assets (Global + Indian + Crypto)
-- ──────────────────────────────────────────────
INSERT IGNORE INTO ASSET (symbol, name, asset_type, exchange, sector) VALUES
-- US Stocks (NASDAQ)
('AAPL',  'Apple Inc.',              'stock', 'NASDAQ', 'Technology'),
('MSFT',  'Microsoft Corp.',         'stock', 'NASDAQ', 'Technology'),
('GOOGL', 'Alphabet Inc.',           'stock', 'NASDAQ', 'Technology'),
('AMZN',  'Amazon.com Inc.',         'stock', 'NASDAQ', 'Consumer'),
('TSLA',  'Tesla Inc.',              'stock', 'NASDAQ', 'Automotive'),
('NVDA',  'NVIDIA Corp.',            'stock', 'NASDAQ', 'Technology'),
('META',  'Meta Platforms Inc.',     'stock', 'NASDAQ', 'Technology'),
('NFLX',  'Netflix Inc.',            'stock', 'NASDAQ', 'Entertainment'),
('AMD',   'Advanced Micro Devices',  'stock', 'NASDAQ', 'Technology'),
('INTC',  'Intel Corp.',             'stock', 'NASDAQ', 'Technology'),
('UBER',  'Uber Technologies',       'stock', 'NYSE',   'Transport'),
('V',     'Visa Inc.',               'stock', 'NYSE',   'Finance'),
('JPM',   'JPMorgan Chase',          'stock', 'NYSE',   'Finance'),
('WMT',   'Walmart Inc.',            'stock', 'NYSE',   'Retail'),
('DIS',   'Walt Disney Co.',         'stock', 'NYSE',   'Entertainment'),
-- Indian Stocks (NSE)
('RELIANCE',    'Reliance Industries',      'stock', 'NSE', 'Energy'),
('TCS',         'Tata Consultancy Services','stock', 'NSE', 'Technology'),
('INFY',        'Infosys Ltd.',             'stock', 'NSE', 'Technology'),
('WIPRO',       'Wipro Ltd.',               'stock', 'NSE', 'Technology'),
('HDFCBANK',    'HDFC Bank Ltd.',           'stock', 'NSE', 'Finance'),
('ICICIBANK',   'ICICI Bank Ltd.',          'stock', 'NSE', 'Finance'),
('SBIN',        'State Bank of India',      'stock', 'NSE', 'Finance'),
('BAJFINANCE',  'Bajaj Finance Ltd.',       'stock', 'NSE', 'Finance'),
('HINDUNILVR',  'Hindustan Unilever',       'stock', 'NSE', 'FMCG'),
('MARUTI',      'Maruti Suzuki India',      'stock', 'NSE', 'Automotive'),
('TATAMOTORS',  'Tata Motors Ltd.',         'stock', 'NSE', 'Automotive'),
('SUNPHARMA',   'Sun Pharmaceutical',       'stock', 'NSE', 'Healthcare'),
('TITAN',       'Titan Company Ltd.',       'stock', 'NSE', 'Consumer'),
('ADANIENT',    'Adani Enterprises',        'stock', 'NSE', 'Conglomerate'),
('NESTLEIND',   'Nestle India Ltd.',        'stock', 'NSE', 'FMCG'),
('POWERGRID',   'Power Grid Corp.',         'stock', 'NSE', 'Utilities'),
('ULTRACEMCO',  'UltraTech Cement',         'stock', 'NSE', 'Materials'),
('ONGC',        'Oil & Natural Gas Corp.',  'stock', 'NSE', 'Energy'),
('COALINDIA',   'Coal India Ltd.',          'stock', 'NSE', 'Energy'),
('ITC',         'ITC Ltd.',                 'stock', 'NSE', 'FMCG'),
-- Crypto
('BTC',   'Bitcoin',        'crypto', NULL, NULL),
('ETH',   'Ethereum',       'crypto', NULL, NULL),
('BNB',   'Binance Coin',   'crypto', NULL, NULL),
('SOL',   'Solana',         'crypto', NULL, NULL),
('DOGE',  'Dogecoin',       'crypto', NULL, NULL),
('XRP',   'XRP (Ripple)',   'crypto', NULL, NULL),
('ADA',   'Cardano',        'crypto', NULL, NULL),
('AVAX',  'Avalanche',      'crypto', NULL, NULL),
('MATIC', 'Polygon',        'crypto', NULL, NULL),
('LTC',   'Litecoin',       'crypto', NULL, NULL);

-- ──────────────────────────────────────────────
-- Seed: Market prices (approximate Jan 2025 prices)
-- Using INSERT ... SELECT so subqueries work correctly in MySQL
-- ──────────────────────────────────────────────

-- US Stocks (USD)
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   229.00 FROM ASSET WHERE symbol='AAPL';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   415.00 FROM ASSET WHERE symbol='MSFT';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   192.00 FROM ASSET WHERE symbol='GOOGL';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   220.00 FROM ASSET WHERE symbol='AMZN';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   390.00 FROM ASSET WHERE symbol='TSLA';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   138.00 FROM ASSET WHERE symbol='NVDA';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   590.00 FROM ASSET WHERE symbol='META';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   870.00 FROM ASSET WHERE symbol='NFLX';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   124.00 FROM ASSET WHERE symbol='AMD';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,    20.00 FROM ASSET WHERE symbol='INTC';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,    70.00 FROM ASSET WHERE symbol='UBER';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   310.00 FROM ASSET WHERE symbol='V';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   240.00 FROM ASSET WHERE symbol='JPM';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   100.00 FROM ASSET WHERE symbol='WMT';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   112.00 FROM ASSET WHERE symbol='DIS';

-- Indian Stocks (INR)
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  1280.00 FROM ASSET WHERE symbol='RELIANCE';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  4100.00 FROM ASSET WHERE symbol='TCS';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  1900.00 FROM ASSET WHERE symbol='INFY';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   310.00 FROM ASSET WHERE symbol='WIPRO';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  1740.00 FROM ASSET WHERE symbol='HDFCBANK';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  1280.00 FROM ASSET WHERE symbol='ICICIBANK';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   780.00 FROM ASSET WHERE symbol='SBIN';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  7200.00 FROM ASSET WHERE symbol='BAJFINANCE';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  2350.00 FROM ASSET WHERE symbol='HINDUNILVR';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id, 11500.00 FROM ASSET WHERE symbol='MARUTI';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   760.00 FROM ASSET WHERE symbol='TATAMOTORS';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  1820.00 FROM ASSET WHERE symbol='SUNPHARMA';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  3300.00 FROM ASSET WHERE symbol='TITAN';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  2450.00 FROM ASSET WHERE symbol='ADANIENT';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id, 22000.00 FROM ASSET WHERE symbol='NESTLEIND';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   330.00 FROM ASSET WHERE symbol='POWERGRID';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id, 11200.00 FROM ASSET WHERE symbol='ULTRACEMCO';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   270.00 FROM ASSET WHERE symbol='ONGC';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   410.00 FROM ASSET WHERE symbol='COALINDIA';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   470.00 FROM ASSET WHERE symbol='ITC';

-- Crypto (USD)
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id, 97000.00 FROM ASSET WHERE symbol='BTC';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,  3400.00 FROM ASSET WHERE symbol='ETH';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   710.00 FROM ASSET WHERE symbol='BNB';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   190.00 FROM ASSET WHERE symbol='SOL';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,     0.38 FROM ASSET WHERE symbol='DOGE';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,     2.40 FROM ASSET WHERE symbol='XRP';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,     1.05 FROM ASSET WHERE symbol='ADA';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,    38.00 FROM ASSET WHERE symbol='AVAX';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,     0.52 FROM ASSET WHERE symbol='MATIC';
INSERT INTO MARKET_DATA (asset_id, closing_price) SELECT asset_id,   105.00 FROM ASSET WHERE symbol='LTC';
