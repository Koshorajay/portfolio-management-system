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
-- Seed some common assets for testing
-- ──────────────────────────────────────────────
INSERT IGNORE INTO ASSET (symbol, name, asset_type, exchange, sector) VALUES
('AAPL',  'Apple Inc.',          'stock',  'NASDAQ', 'Technology'),
('MSFT',  'Microsoft Corp.',     'stock',  'NASDAQ', 'Technology'),
('GOOGL', 'Alphabet Inc.',       'stock',  'NASDAQ', 'Technology'),
('AMZN',  'Amazon.com Inc.',     'stock',  'NASDAQ', 'Consumer'),
('TSLA',  'Tesla Inc.',          'stock',  'NASDAQ', 'Automotive'),
('RELIANCE', 'Reliance Industries', 'stock', 'NSE', 'Energy'),
('TCS',   'Tata Consultancy',    'stock',  'NSE',    'Technology'),
('BTC',   'Bitcoin',             'crypto', NULL,     NULL),
('ETH',   'Ethereum',            'crypto', NULL,     NULL),
('BNB',   'Binance Coin',        'crypto', NULL,     NULL),
('SOL',   'Solana',              'crypto', NULL,     NULL),
('DOGE',  'Dogecoin',            'crypto', NULL,     NULL);
