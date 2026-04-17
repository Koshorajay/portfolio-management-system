# ============================================================
#  Portfolio Management System — app.py
#  Stack : Flask + MySQL (mysql-connector-python)
#  DBMS  : Transactions, Joins, Stored Procedures, Views
# ============================================================

from flask import (Flask, render_template, request,
                   redirect, url_for, session, flash)
import mysql.connector
import hashlib
import os

app = Flask(__name__)
app.secret_key = "pms_secret_key_change_in_prod"

# ──────────────────────────────────────────────
# Database Configuration — edit these values
# ──────────────────────────────────────────────
DB_CONFIG = {
    "host":     "localhost",
    "user":     "root",
    "password": "1234",   
    "database": "portfolio_db",
}


def get_db():
    """Return a new MySQL connection."""
    return mysql.connector.connect(**DB_CONFIG)


def hash_password(password: str) -> str:
    """SHA-256 hash (use bcrypt in production)."""
    return hashlib.sha256(password.encode()).hexdigest()


def login_required(func):
    """Simple decorator — redirect to login if not logged in."""
    from functools import wraps
    @wraps(func)
    def wrapper(*args, **kwargs):
        if "user_id" not in session:
            flash("Please log in first.", "warning")
            return redirect(url_for("login"))
        return func(*args, **kwargs)
    return wrapper


# ============================================================
#  AUTH ROUTES
# ============================================================

@app.route("/")
def index():
    if "user_id" in session:
        return redirect(url_for("dashboard"))
    return redirect(url_for("login"))


# ── Register ─────────────────────────────────
@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        username = request.form["username"].strip()
        email    = request.form["email"].strip()
        password = request.form["password"]

        if not username or not email or not password:
            flash("All fields are required.", "error")
            return render_template("register.html")

        conn = get_db()
        cur  = conn.cursor()
        try:
            # INSERT new user
            cur.execute(
                "INSERT INTO USER (username, email, password_hash) VALUES (%s, %s, %s)",
                (username, email, hash_password(password))
            )
            conn.commit()
            flash("Registration successful! Please log in.", "success")
            return redirect(url_for("login"))
        except mysql.connector.IntegrityError:
            flash("Username or email already exists.", "error")
        finally:
            cur.close()
            conn.close()

    return render_template("register.html")


# ── Login ─────────────────────────────────────
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form["username"].strip()
        password = request.form["password"]

        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        try:
            # SELECT with WHERE — basic query
            cur.execute(
                "SELECT * FROM USER WHERE username = %s AND password_hash = %s",
                (username, hash_password(password))
            )
            user = cur.fetchone()
            if user:
                session["user_id"]  = user["user_id"]
                session["username"] = user["username"]
                return redirect(url_for("dashboard"))
            else:
                flash("Invalid username or password.", "error")
        finally:
            cur.close()
            conn.close()

    return render_template("login.html")


# ── Logout ────────────────────────────────────
@app.route("/logout")
def logout():
    session.clear()
    flash("Logged out.", "success")
    return redirect(url_for("login"))


# ============================================================
#  DASHBOARD
# ============================================================

@app.route("/dashboard")
@login_required
def dashboard():
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    try:
        # JOIN: portfolios belonging to this user
        cur.execute(
            """SELECT p.portfolio_id, p.portfolio_name, p.base_currency,
                      p.created_at,
                      COUNT(DISTINCT h.holding_id) AS num_assets
               FROM PORTFOLIO p
               LEFT JOIN HOLDING h ON p.portfolio_id = h.portfolio_id
               WHERE p.user_id = %s
               GROUP BY p.portfolio_id""",
            (session["user_id"],)
        )
        portfolios = cur.fetchall()
    finally:
        cur.close()
        conn.close()

    return render_template("dashboard.html",
                           portfolios=portfolios,
                           username=session["username"])


# ============================================================
#  PORTFOLIO ROUTES
# ============================================================

# ── Create Portfolio ──────────────────────────
@app.route("/portfolio/create", methods=["GET", "POST"])
@login_required
def create_portfolio():
    if request.method == "POST":
        name     = request.form["portfolio_name"].strip()
        currency = request.form["base_currency"].strip() or "USD"

        if not name:
            flash("Portfolio name is required.", "error")
            return render_template("create_portfolio.html")

        conn = get_db()
        cur  = conn.cursor()
        try:
            cur.execute(
                "INSERT INTO PORTFOLIO (user_id, portfolio_name, base_currency) VALUES (%s, %s, %s)",
                (session["user_id"], name, currency)
            )
            conn.commit()
            flash(f"Portfolio '{name}' created!", "success")
            return redirect(url_for("dashboard"))
        finally:
            cur.close()
            conn.close()

    return render_template("create_portfolio.html")


# ── View Holdings (uses the VIEW) ─────────────
@app.route("/portfolio/<int:portfolio_id>/holdings")
@login_required
def view_holdings(portfolio_id):
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    try:
        # Security check: ensure portfolio belongs to logged-in user
        cur.execute(
            "SELECT * FROM PORTFOLIO WHERE portfolio_id = %s AND user_id = %s",
            (portfolio_id, session["user_id"])
        )
        portfolio = cur.fetchone()
        if not portfolio:
            flash("Portfolio not found.", "error")
            return redirect(url_for("dashboard"))

        # Query the VIEW (JOIN of HOLDING + PORTFOLIO + USER + ASSET)
        cur.execute(
            """SELECT * FROM vw_portfolio_holdings
               WHERE portfolio_id = %s
               ORDER BY symbol""",
            (portfolio_id,)
        )
        holdings = cur.fetchall()

        # Aggregate: total portfolio cost basis
        cur.execute(
            """SELECT ROUND(SUM(total_quantity * average_buy_price), 2) AS total_invested
               FROM HOLDING
               WHERE portfolio_id = %s""",
            (portfolio_id,)
        )
        summary = cur.fetchone()

        # Recent transactions (JOIN)
        cur.execute(
            """SELECT t.transaction_id, a.symbol, t.transaction_type,
                      t.quantity, t.price_per_unit, t.transaction_fee,
                      t.trade_date
               FROM TRANSACTION t
               JOIN ASSET a ON t.asset_id = a.asset_id
               WHERE t.portfolio_id = %s
               ORDER BY t.trade_date DESC
               LIMIT 10""",
            (portfolio_id,)
        )
        transactions = cur.fetchall()

    finally:
        cur.close()
        conn.close()

    return render_template("holdings.html",
                           portfolio=portfolio,
                           holdings=holdings,
                           summary=summary,
                           transactions=transactions)


# ============================================================
#  ASSET ROUTES
# ============================================================

# ── Add Asset ─────────────────────────────────
@app.route("/asset/add", methods=["GET", "POST"])
@login_required
def add_asset():
    if request.method == "POST":
        symbol     = request.form["symbol"].strip().upper()
        name       = request.form["name"].strip()
        asset_type = request.form["asset_type"]
        exchange   = request.form.get("exchange", "").strip() or None
        sector     = request.form.get("sector", "").strip() or None

        if not symbol or not name:
            flash("Symbol and name are required.", "error")
            return render_template("add_asset.html")

        conn = get_db()
        cur  = conn.cursor()
        try:
            cur.execute(
                "INSERT INTO ASSET (symbol, name, asset_type, exchange, sector) VALUES (%s,%s,%s,%s,%s)",
                (symbol, name, asset_type, exchange, sector)
            )
            conn.commit()
            flash(f"Asset '{symbol}' added!", "success")
            return redirect(url_for("dashboard"))
        except mysql.connector.IntegrityError:
            flash(f"Asset with symbol '{symbol}' already exists.", "error")
        finally:
            cur.close()
            conn.close()

    return render_template("add_asset.html")


# ── List Assets ───────────────────────────────
@app.route("/assets")
@login_required
def list_assets():
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    try:
        asset_type = request.args.get("type", "")
        if asset_type in ("stock", "crypto"):
            cur.execute(
                "SELECT * FROM ASSET WHERE asset_type = %s ORDER BY symbol",
                (asset_type,)
            )
        else:
            cur.execute("SELECT * FROM ASSET ORDER BY asset_type, symbol")
        assets = cur.fetchall()
    finally:
        cur.close()
        conn.close()

    return render_template("list_assets.html", assets=assets)


# ============================================================
#  TRANSACTION ROUTES  (calls Stored Procedures)
# ============================================================

def _get_user_portfolios(user_id):
    """Helper: fetch all portfolios for the logged-in user."""
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    try:
        cur.execute(
            "SELECT portfolio_id, portfolio_name FROM PORTFOLIO WHERE user_id = %s",
            (user_id,)
        )
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()


def _get_all_assets():
    """Helper: fetch all assets."""
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    try:
        cur.execute("SELECT asset_id, symbol, name, asset_type FROM ASSET ORDER BY symbol")
        return cur.fetchall()
    finally:
        cur.close()
        conn.close()


# ── Buy Asset ─────────────────────────────────
@app.route("/transaction/buy", methods=["GET", "POST"])
@login_required
def buy_asset():
    portfolios = _get_user_portfolios(session["user_id"])
    assets     = _get_all_assets()

    if request.method == "POST":
        portfolio_id = int(request.form["portfolio_id"])
        asset_id     = int(request.form["asset_id"])
        quantity     = float(request.form["quantity"])
        price        = float(request.form["price_per_unit"])
        fee          = float(request.form.get("transaction_fee") or 0)

        if quantity <= 0 or price <= 0:
            flash("Quantity and price must be positive.", "error")
            return render_template("buy.html", portfolios=portfolios, assets=assets)

        conn = get_db()
        cur  = conn.cursor()
        try:
            # Call the stored procedure sp_buy_asset
            cur.callproc("sp_buy_asset",
                         [portfolio_id, asset_id, quantity, price, fee, ""])
            conn.commit()

            # Retrieve the OUT parameter status
            cur.execute("SELECT @_sp_buy_asset_5")   # OUT param index 5
            result = cur.fetchone()
            status = result[0] if result else "SUCCESS"

            if status == "SUCCESS":
                flash("Buy transaction recorded successfully!", "success")
                return redirect(url_for("view_holdings", portfolio_id=portfolio_id))
            else:
                flash(f"Transaction failed: {status}", "error")
        except Exception as e:
            flash(f"Error: {str(e)}", "error")
        finally:
            cur.close()
            conn.close()

    return render_template("buy.html", portfolios=portfolios, assets=assets)


# ── Sell Asset ────────────────────────────────
@app.route("/transaction/sell", methods=["GET", "POST"])
@login_required
def sell_asset():
    portfolios = _get_user_portfolios(session["user_id"])

    if request.method == "POST":
        portfolio_id = int(request.form["portfolio_id"])
        asset_id     = int(request.form["asset_id"])
        quantity     = float(request.form["quantity"])
        price        = float(request.form["price_per_unit"])
        fee          = float(request.form.get("transaction_fee") or 0)

        if quantity <= 0 or price <= 0:
            flash("Quantity and price must be positive.", "error")

        else:
            conn = get_db()
            cur  = conn.cursor()
            try:
                cur.callproc("sp_sell_asset",
                             [portfolio_id, asset_id, quantity, price, fee, ""])
                conn.commit()

                cur.execute("SELECT @_sp_sell_asset_5")
                result = cur.fetchone()
                status = result[0] if result else "SUCCESS"

                if status == "SUCCESS":
                    flash("Sell transaction recorded successfully!", "success")
                    return redirect(url_for("view_holdings", portfolio_id=portfolio_id))
                elif status == "INSUFFICIENT_QUANTITY":
                    flash("Not enough units in holding to sell.", "error")
                else:
                    flash(f"Transaction failed: {status}", "error")
            except Exception as e:
                flash(f"Error: {str(e)}", "error")
            finally:
                cur.close()
                conn.close()

    # For the sell form, show only assets held in selected portfolio
    selected_pid = request.args.get("portfolio_id") or \
                   (portfolios[0]["portfolio_id"] if portfolios else None)

    holdings = []
    if selected_pid:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        try:
            cur.execute(
                """SELECT h.asset_id, a.symbol, a.name, h.total_quantity
                   FROM HOLDING h
                   JOIN ASSET a ON h.asset_id = a.asset_id
                   WHERE h.portfolio_id = %s AND h.total_quantity > 0""",
                (selected_pid,)
            )
            holdings = cur.fetchall()
        finally:
            cur.close()
            conn.close()

    return render_template("sell.html",
                           portfolios=portfolios,
                           holdings=holdings,
                           selected_pid=int(selected_pid) if selected_pid else None)


# ── Add Market Price Snapshot ─────────────────
@app.route("/market/update", methods=["GET", "POST"])
@login_required
def update_market_price():
    assets = _get_all_assets()

    if request.method == "POST":
        asset_id = int(request.form["asset_id"])
        price    = float(request.form["closing_price"])

        conn = get_db()
        cur  = conn.cursor()
        try:
            # Insert market data record
            cur.execute(
                "INSERT INTO MARKET_DATA (asset_id, closing_price) VALUES (%s, %s)",
                (asset_id, price)
            )
            # Also update holding snapshot for all portfolios holding this asset
            cur.execute(
                """UPDATE HOLDING
                   SET current_value_snapshot = ROUND(total_quantity * %s, 2)
                   WHERE asset_id = %s""",
                (price, asset_id)
            )
            conn.commit()
            flash("Market price updated and holding snapshot refreshed!", "success")
        finally:
            cur.close()
            conn.close()

    return render_template("update_price.html", assets=assets)


# ============================================================
if __name__ == "__main__":
    app.run(debug=True)
