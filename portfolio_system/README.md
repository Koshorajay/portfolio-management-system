# Portfolio Management System
### DBMS Mini Project — Flask + MySQL + HTML

---

## Project Structure

```
portfolio_system/
├── app.py               ← Flask application (all routes)
├── schema.sql           ← All SQL: tables, view, stored procedures, seed data
├── requirements.txt     ← Python dependencies
├── README.md
└── templates/
    ├── base.html        ← Common navbar + styles
    ├── login.html
    ├── register.html
    ├── dashboard.html
    ├── create_portfolio.html
    ├── holdings.html    ← View holdings + recent transactions
    ├── buy.html
    ├── sell.html
    ├── add_asset.html
    ├── list_assets.html
    └── update_price.html
```

---

## DBMS Concepts Used

| Concept | Where |
|---|---|
| Primary & Foreign Keys | All tables — referential integrity |
| UNIQUE Constraints | USER.username, ASSET.symbol, HOLDING(portfolio_id, asset_id) |
| CHECK Constraints | TRANSACTION.quantity > 0, price_per_unit > 0 |
| Indexes | TRANSACTION(portfolio_id), TRANSACTION(asset_id), MARKET_DATA(asset_id, recorded_at) |
| SQL TRANSACTION (BEGIN/COMMIT/ROLLBACK) | sp_buy_asset, sp_sell_asset |
| Row-level Locking (FOR UPDATE) | sp_sell_asset — prevents overselling |
| Stored Procedures + OUT parameters | sp_buy_asset, sp_sell_asset |
| INSERT … ON DUPLICATE KEY UPDATE | HOLDING upsert in sp_buy_asset |
| VIEW | vw_portfolio_holdings — JOIN of 4 tables |
| Aggregation (SUM, COUNT) | Dashboard portfolio count, holdings cost basis |
| JOIN | Holdings page, transaction list, dashboard |
| ENUM data type | TRANSACTION.transaction_type, ASSET.asset_type |
| CASCADE DELETE | Deleting a user removes portfolios; deleting portfolio removes holdings/transactions |
| Normalization (3NF) | Each table has a single responsibility; no repeating groups |

---

## Setup Instructions

### 1. Install Python dependencies
```bash
pip install -r requirements.txt
```

### 2. Set up MySQL
```bash
mysql -u root -p
```
Inside MySQL shell:
```sql
SOURCE /path/to/schema.sql;
```
Or run directly:
```bash
mysql -u root -p < schema.sql
```

### 3. Configure DB credentials
Open `app.py` and edit the `DB_CONFIG` section:
```python
DB_CONFIG = {
    "host":     "localhost",
    "user":     "root",
    "password": "your_actual_password",   # ← change this
    "database": "portfolio_db",
}
```

### 4. Run the app
```bash
python app.py
```
Open your browser at: **http://127.0.0.1:5000**

---

## User Flow

```
Register → Login → Create Portfolio → Buy Asset → View Holdings → Sell Asset
                                   → Add Custom Asset
                                   → Update Market Price
```

---

## Notes
- Passwords are stored as SHA-256 hashes (use bcrypt in a real app).
- Market prices are entered manually — no live API is used (keeping it simple).
- The sell form uses a 2-step approach (select portfolio first, then sell) without any JavaScript.
- All currency values are stored as DECIMAL(18,8) to support both stocks and crypto.
