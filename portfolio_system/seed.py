# ============================================================
#  seed.py  —  Run this ONCE to set up the database
#  Usage:  python seed.py
# ============================================================

import mysql.connector
import sys

# ── Change these to match your MySQL credentials ──────────
HOST     = "localhost"
USER     = "root"
PASSWORD = "your_mysql_password"   # ← same as in app.py
# ─────────────────────────────────────────────────────────

def run():
    # Step 1: Connect without selecting a database
    try:
        conn = mysql.connector.connect(host=HOST, user=USER, password=PASSWORD)
    except Exception as e:
        print(f"ERROR: Cannot connect to MySQL — {e}")
        sys.exit(1)

    cur = conn.cursor()

    # Step 2: Create database and tables
    print("Creating database and tables...")
    statements = [
        "DROP DATABASE IF EXISTS portfolio_db",
        "CREATE DATABASE portfolio_db",
        "USE portfolio_db",

        """CREATE TABLE USER (
            user_id       INT AUTO_INCREMENT PRIMARY KEY,
            username      VARCHAR(50)  NOT NULL UNIQUE,
            email         VARCHAR(100) NOT NULL UNIQUE,
            password_hash VARCHAR(255) NOT NULL,
            created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
        )""",

        """CREATE TABLE PORTFOLIO (
            portfolio_id   INT AUTO_INCREMENT PRIMARY KEY,
            user_id        INT NOT NULL,
            portfolio_name VARCHAR(100) NOT NULL,
            base_currency  VARCHAR(10)  DEFAULT 'USD',
            created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT fk_portfolio_user
                FOREIGN KEY (user_id) REFERENCES USER(user_id)
                ON DELETE CASCADE
        )""",

        """CREATE TABLE ASSET (
            asset_id   INT AUTO_INCREMENT PRIMARY KEY,
            symbol     VARCHAR(20)  NOT NULL UNIQUE,
            name       VARCHAR(100) NOT NULL,
            asset_type ENUM('stock','crypto') NOT NULL,
            exchange   VARCHAR(50),
            sector     VARCHAR(50)
        )""",

        """CREATE TABLE `TRANSACTION` (
            transaction_id   INT AUTO_INCREMENT PRIMARY KEY,
            portfolio_id     INT NOT NULL,
            asset_id         INT NOT NULL,
            transaction_type ENUM('BUY','SELL') NOT NULL,
            quantity         DECIMAL(18,8) NOT NULL CHECK (quantity > 0),
            price_per_unit   DECIMAL(18,8) NOT NULL CHECK (price_per_unit > 0),
            transaction_fee  DECIMAL(18,8) DEFAULT 0.00,
            trade_date       DATETIME DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT fk_txn_portfolio
                FOREIGN KEY (portfolio_id) REFERENCES PORTFOLIO(portfolio_id)
                ON DELETE CASCADE,
            CONSTRAINT fk_txn_asset
                FOREIGN KEY (asset_id) REFERENCES ASSET(asset_id)
                ON DELETE RESTRICT
        )""",

        "CREATE INDEX idx_txn_portfolio ON `TRANSACTION`(portfolio_id)",
        "CREATE INDEX idx_txn_asset     ON `TRANSACTION`(asset_id)",

        """CREATE TABLE HOLDING (
            holding_id             INT AUTO_INCREMENT PRIMARY KEY,
            portfolio_id           INT NOT NULL,
            asset_id               INT NOT NULL,
            total_quantity         DECIMAL(18,8) NOT NULL DEFAULT 0,
            average_buy_price      DECIMAL(18,8) NOT NULL DEFAULT 0,
            current_value_snapshot DECIMAL(18,8) DEFAULT 0,
            UNIQUE KEY uq_holding (portfolio_id, asset_id),
            CONSTRAINT fk_holding_portfolio
                FOREIGN KEY (portfolio_id) REFERENCES PORTFOLIO(portfolio_id)
                ON DELETE CASCADE,
            CONSTRAINT fk_holding_asset
                FOREIGN KEY (asset_id) REFERENCES ASSET(asset_id)
                ON DELETE RESTRICT
        )""",

        """CREATE TABLE MARKET_DATA (
            price_id      INT AUTO_INCREMENT PRIMARY KEY,
            asset_id      INT NOT NULL,
            closing_price DECIMAL(18,8) NOT NULL,
            recorded_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT fk_market_asset
                FOREIGN KEY (asset_id) REFERENCES ASSET(asset_id)
                ON DELETE CASCADE
        )""",

        "CREATE INDEX idx_market_asset_date ON MARKET_DATA(asset_id, recorded_at)",

        """CREATE OR REPLACE VIEW vw_portfolio_holdings AS
           SELECT h.holding_id, p.portfolio_id, p.portfolio_name, u.username,
                  a.symbol, a.name AS asset_name, a.asset_type, a.exchange,
                  h.total_quantity, h.average_buy_price,
                  ROUND(h.total_quantity * h.average_buy_price, 2) AS cost_basis,
                  h.current_value_snapshot
           FROM HOLDING h
           JOIN PORTFOLIO p ON h.portfolio_id = p.portfolio_id
           JOIN USER      u ON p.user_id      = u.user_id
           JOIN ASSET     a ON h.asset_id     = a.asset_id""",
    ]

    for sql in statements:
        cur.execute(sql)
    conn.commit()
    print("  ✔ Tables and view created.")

    # Step 3: Seed Assets
    print("Seeding 50 assets...")
    assets = [
        # symbol, name, asset_type, exchange, sector
        # US Stocks
        ('AAPL',  'Apple Inc.',               'stock', 'NASDAQ', 'Technology'),
        ('MSFT',  'Microsoft Corp.',          'stock', 'NASDAQ', 'Technology'),
        ('GOOGL', 'Alphabet Inc.',            'stock', 'NASDAQ', 'Technology'),
        ('AMZN',  'Amazon.com Inc.',          'stock', 'NASDAQ', 'Consumer'),
        ('TSLA',  'Tesla Inc.',               'stock', 'NASDAQ', 'Automotive'),
        ('NVDA',  'NVIDIA Corp.',             'stock', 'NASDAQ', 'Technology'),
        ('META',  'Meta Platforms Inc.',      'stock', 'NASDAQ', 'Technology'),
        ('NFLX',  'Netflix Inc.',             'stock', 'NASDAQ', 'Entertainment'),
        ('AMD',   'Advanced Micro Devices',   'stock', 'NASDAQ', 'Technology'),
        ('INTC',  'Intel Corp.',              'stock', 'NASDAQ', 'Technology'),
        ('UBER',  'Uber Technologies',        'stock', 'NYSE',   'Transport'),
        ('V',     'Visa Inc.',                'stock', 'NYSE',   'Finance'),
        ('JPM',   'JPMorgan Chase',           'stock', 'NYSE',   'Finance'),
        ('WMT',   'Walmart Inc.',             'stock', 'NYSE',   'Retail'),
        ('DIS',   'Walt Disney Co.',          'stock', 'NYSE',   'Entertainment'),
        # Indian Stocks (NSE)
        ('RELIANCE',   'Reliance Industries',       'stock', 'NSE', 'Energy'),
        ('TCS',        'Tata Consultancy Services', 'stock', 'NSE', 'Technology'),
        ('INFY',       'Infosys Ltd.',              'stock', 'NSE', 'Technology'),
        ('WIPRO',      'Wipro Ltd.',                'stock', 'NSE', 'Technology'),
        ('HDFCBANK',   'HDFC Bank Ltd.',            'stock', 'NSE', 'Finance'),
        ('ICICIBANK',  'ICICI Bank Ltd.',           'stock', 'NSE', 'Finance'),
        ('SBIN',       'State Bank of India',       'stock', 'NSE', 'Finance'),
        ('BAJFINANCE', 'Bajaj Finance Ltd.',        'stock', 'NSE', 'Finance'),
        ('HINDUNILVR', 'Hindustan Unilever',        'stock', 'NSE', 'FMCG'),
        ('MARUTI',     'Maruti Suzuki India',       'stock', 'NSE', 'Automotive'),
        ('TATAMOTORS', 'Tata Motors Ltd.',          'stock', 'NSE', 'Automotive'),
        ('SUNPHARMA',  'Sun Pharmaceutical',        'stock', 'NSE', 'Healthcare'),
        ('TITAN',      'Titan Company Ltd.',        'stock', 'NSE', 'Consumer'),
        ('ADANIENT',   'Adani Enterprises',         'stock', 'NSE', 'Conglomerate'),
        ('NESTLEIND',  'Nestle India Ltd.',         'stock', 'NSE', 'FMCG'),
        ('POWERGRID',  'Power Grid Corp.',          'stock', 'NSE', 'Utilities'),
        ('ULTRACEMCO', 'UltraTech Cement',          'stock', 'NSE', 'Materials'),
        ('ONGC',       'Oil & Natural Gas Corp.',   'stock', 'NSE', 'Energy'),
        ('COALINDIA',  'Coal India Ltd.',           'stock', 'NSE', 'Energy'),
        ('ITC',        'ITC Ltd.',                  'stock', 'NSE', 'FMCG'),
        # Crypto
        ('BTC',   'Bitcoin',       'crypto', None, None),
        ('ETH',   'Ethereum',      'crypto', None, None),
        ('BNB',   'Binance Coin',  'crypto', None, None),
        ('SOL',   'Solana',        'crypto', None, None),
        ('DOGE',  'Dogecoin',      'crypto', None, None),
        ('XRP',   'XRP (Ripple)',  'crypto', None, None),
        ('ADA',   'Cardano',       'crypto', None, None),
        ('AVAX',  'Avalanche',     'crypto', None, None),
        ('MATIC', 'Polygon',       'crypto', None, None),
        ('LTC',   'Litecoin',      'crypto', None, None),
    ]
    cur.executemany(
        "INSERT IGNORE INTO ASSET (symbol, name, asset_type, exchange, sector) VALUES (%s,%s,%s,%s,%s)",
        assets
    )
    conn.commit()
    print(f"  ✔ {cur.rowcount} assets inserted.")

    # Step 4: Seed Market Prices
    print("Seeding market prices...")
    prices = {
        # US Stocks (USD)
        'AAPL':  229.00, 'MSFT':  415.00, 'GOOGL': 192.00,
        'AMZN':  220.00, 'TSLA':  390.00, 'NVDA':  138.00,
        'META':  590.00, 'NFLX':  870.00, 'AMD':   124.00,
        'INTC':   20.00, 'UBER':   70.00, 'V':     310.00,
        'JPM':   240.00, 'WMT':   100.00, 'DIS':   112.00,
        # Indian Stocks (INR)
        'RELIANCE':   1280.00, 'TCS':       4100.00, 'INFY':      1900.00,
        'WIPRO':       310.00, 'HDFCBANK':  1740.00, 'ICICIBANK': 1280.00,
        'SBIN':        780.00, 'BAJFINANCE':7200.00, 'HINDUNILVR':2350.00,
        'MARUTI':    11500.00, 'TATAMOTORS': 760.00, 'SUNPHARMA': 1820.00,
        'TITAN':      3300.00, 'ADANIENT':  2450.00, 'NESTLEIND':22000.00,
        'POWERGRID':   330.00, 'ULTRACEMCO':11200.00,'ONGC':       270.00,
        'COALINDIA':   410.00, 'ITC':        470.00,
        # Crypto (USD)
        'BTC':  97000.00, 'ETH':  3400.00, 'BNB':  710.00,
        'SOL':    190.00, 'DOGE':    0.38, 'XRP':    2.40,
        'ADA':      1.05, 'AVAX':   38.00, 'MATIC':  0.52,
        'LTC':    105.00,
    }
    inserted = 0
    for symbol, price in prices.items():
        cur.execute(
            "INSERT INTO MARKET_DATA (asset_id, closing_price) "
            "SELECT asset_id, %s FROM ASSET WHERE symbol = %s",
            (price, symbol)
        )
        inserted += cur.rowcount
    conn.commit()
    print(f"  ✔ {inserted} price records inserted.")

    # Step 5: Stored Procedures
    print("Creating stored procedures...")
    cur.execute("""
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
            BEGIN ROLLBACK; SET p_status = 'ERROR'; END;
            START TRANSACTION;
            INSERT INTO `TRANSACTION` (portfolio_id, asset_id, transaction_type,
                                       quantity, price_per_unit, transaction_fee)
            VALUES (p_portfolio_id, p_asset_id, 'BUY', p_quantity, p_price, p_fee);
            INSERT INTO HOLDING (portfolio_id, asset_id, total_quantity, average_buy_price)
            VALUES (p_portfolio_id, p_asset_id, p_quantity, p_price)
            ON DUPLICATE KEY UPDATE
                average_buy_price = ROUND(
                    ((total_quantity * average_buy_price) + (p_quantity * p_price))
                    / (total_quantity + p_quantity), 8),
                total_quantity = total_quantity + p_quantity;
            COMMIT;
            SET p_status = 'SUCCESS';
        END
    """)
    cur.execute("""
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
            BEGIN ROLLBACK; SET p_status = 'ERROR'; END;
            START TRANSACTION;
            SELECT total_quantity INTO v_held FROM HOLDING
            WHERE portfolio_id = p_portfolio_id AND asset_id = p_asset_id FOR UPDATE;
            IF v_held IS NULL OR v_held < p_quantity THEN
                ROLLBACK; SET p_status = 'INSUFFICIENT_QUANTITY';
            ELSE
                INSERT INTO `TRANSACTION` (portfolio_id, asset_id, transaction_type,
                                           quantity, price_per_unit, transaction_fee)
                VALUES (p_portfolio_id, p_asset_id, 'SELL', p_quantity, p_price, p_fee);
                IF v_held = p_quantity THEN
                    DELETE FROM HOLDING WHERE portfolio_id = p_portfolio_id AND asset_id = p_asset_id;
                ELSE
                    UPDATE HOLDING SET total_quantity = total_quantity - p_quantity
                    WHERE portfolio_id = p_portfolio_id AND asset_id = p_asset_id;
                END IF;
                COMMIT; SET p_status = 'SUCCESS';
            END IF;
        END
    """)
    conn.commit()
    print("  ✔ Stored procedures created.")

    cur.close()
    conn.close()
    print("\n✅ Database setup complete! You can now run: python app.py")

if __name__ == "__main__":
    run()
