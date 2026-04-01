"""
Ecommerce Application
Multi-tier Flask app for AWS infrastructure demonstration.
Displays instance metadata, AZ, health status, and a sample product catalogue.
"""
import os
import time
import logging
from datetime import datetime

import redis
import psycopg2
from flask import Flask, jsonify, render_template, request

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# ─── Config ───────────────────────────────────────────────────────────────────
try:
    from config import INSTANCE_ID, AZ, ENVIRONMENT, DB_HOST, DB_NAME, DB_USER, DB_PASS, REDIS_HOST, REDIS_PORT
except ImportError:
    # Fallback for local dev
    INSTANCE_ID = os.getenv("INSTANCE_ID", "local-dev")
    AZ = os.getenv("AZ", "local")
    ENVIRONMENT = os.getenv("ENVIRONMENT", "dev")
    DB_HOST = os.getenv("DB_HOST", "localhost")
    DB_NAME = os.getenv("DB_NAME", "ecommercedb")
    DB_USER = os.getenv("DB_USER", "dbadmin")
    DB_PASS = os.getenv("DB_PASS", "")
    REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
    REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

# SSL is required on AWS (RDS + ElastiCache enforce it).
# Disable for local Docker dev where services run without TLS.
DB_SSL_MODE = os.getenv("DB_SSL_MODE", "require")
REDIS_SSL = os.getenv("REDIS_SSL", "true").lower() == "true"

START_TIME = time.time()

# Sample product catalogue
PRODUCTS = [
    {"id": 1, "name": "Cloud T-Shirt", "price": 29.99, "stock": 150, "category": "Apparel"},
    {"id": 2, "name": "Terraform Mug", "price": 14.99, "stock": 80, "category": "Accessories"},
    {"id": 3, "name": "AWS Hoodie", "price": 59.99, "stock": 45, "category": "Apparel"},
    {"id": 4, "name": "DevOps Sticker Pack", "price": 9.99, "stock": 300, "category": "Accessories"},
    {"id": 5, "name": "Container Backpack", "price": 79.99, "stock": 25, "category": "Bags"},
    {"id": 6, "name": "Kubernetes Notebook", "price": 19.99, "stock": 120, "category": "Stationery"},
]


# ─── Helpers ──────────────────────────────────────────────────────────────────
def _get_db_conn():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS,
        connect_timeout=3, sslmode=DB_SSL_MODE
    )


def _get_redis():
    return redis.Redis(
        host=REDIS_HOST, port=REDIS_PORT, ssl=REDIS_SSL,
        socket_connect_timeout=3, decode_responses=True
    )


def _check_db() -> dict:
    try:
        conn = _get_db_conn()
        cur = conn.cursor()
        cur.execute("SELECT version()")
        version = cur.fetchone()[0]
        cur.close()
        conn.close()
        return {"status": "healthy", "version": version}
    except Exception as exc:
        logger.warning("DB health check failed: %s", exc)
        return {"status": "unhealthy", "error": str(exc)}


def _check_redis() -> dict:
    try:
        r = _get_redis()
        r.ping()
        info = r.info("server")
        return {"status": "healthy", "version": info.get("redis_version", "unknown")}
    except Exception as exc:
        logger.warning("Redis health check failed: %s", exc)
        return {"status": "unhealthy", "error": str(exc)}


# ─── Routes ───────────────────────────────────────────────────────────────────
@app.route("/health")
def health():
    """Health check endpoint for ALB target group."""
    db_status = _check_db()
    redis_status = _check_redis()

    overall = "healthy" if db_status["status"] == "healthy" else "degraded"
    status_code = 200 if overall == "healthy" else 200  # Keep 200 for ALB; degrade gracefully

    payload = {
        "status": overall,
        "instance_id": INSTANCE_ID,
        "availability_zone": AZ,
        "environment": ENVIRONMENT,
        "uptime_seconds": int(time.time() - START_TIME),
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "dependencies": {
            "database": db_status,
            "cache": redis_status,
        },
    }
    logger.info("Health check: %s", overall)
    return jsonify(payload), status_code


@app.route("/")
def index():
    """Home page — shows instance info and product catalogue."""
    db_status = _check_db()
    redis_status = _check_redis()

    # Cache-aside: check Redis before hitting DB
    cache_hit = False
    cached_count = None
    try:
        r = _get_redis()
        cached_count = r.get("product_count")
        if cached_count:
            cache_hit = True
    except Exception:
        pass

    if not cache_hit:
        try:
            r = _get_redis()
            r.setex("product_count", 60, str(len(PRODUCTS)))
        except Exception:
            pass

    return render_template(
        "index.html",
        products=PRODUCTS,
        instance_id=INSTANCE_ID,
        az=AZ,
        environment=ENVIRONMENT,
        db_status=db_status["status"],
        redis_status=redis_status["status"],
        cache_hit=cache_hit,
        uptime=int(time.time() - START_TIME),
    )


@app.route("/api/products")
def api_products():
    """JSON API: list all products."""
    return jsonify({"products": PRODUCTS, "count": len(PRODUCTS)})


@app.route("/api/products/<int:product_id>")
def api_product(product_id):
    """JSON API: get a single product."""
    product = next((p for p in PRODUCTS if p["id"] == product_id), None)
    if product is None:
        return jsonify({"error": "Product not found"}), 404
    return jsonify(product)


@app.route("/api/cart", methods=["GET", "POST"])
def api_cart():
    """Simple cart API backed by Redis."""
    session_id = request.args.get("session", "demo-session")
    cart_key = f"cart:{session_id}"

    if request.method == "POST":
        data = request.get_json(force=True)
        product_id = str(data.get("product_id", ""))
        quantity = int(data.get("quantity", 1))
        try:
            r = _get_redis()
            r.hset(cart_key, product_id, quantity)
            r.expire(cart_key, 3600)
            return jsonify({"status": "ok", "cart_key": cart_key})
        except Exception as exc:
            return jsonify({"status": "error", "error": str(exc)}), 503

    try:
        r = _get_redis()
        cart = r.hgetall(cart_key)
        return jsonify({"session": session_id, "items": cart})
    except Exception as exc:
        return jsonify({"status": "error", "error": str(exc)}), 503


@app.route("/metrics")
def metrics():
    """Prometheus-style plain-text metrics endpoint."""
    uptime = int(time.time() - START_TIME)
    lines = [
        "# HELP ecommerce_uptime_seconds Application uptime",
        "# TYPE ecommerce_uptime_seconds gauge",
        f'ecommerce_uptime_seconds{{instance="{INSTANCE_ID}",az="{AZ}",env="{ENVIRONMENT}"}} {uptime}',
        "# HELP ecommerce_products_total Total products in catalogue",
        "# TYPE ecommerce_products_total gauge",
        f"ecommerce_products_total {len(PRODUCTS)}",
    ]
    return "\n".join(lines) + "\n", 200, {"Content-Type": "text/plain; charset=utf-8"}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=ENVIRONMENT != "prod")
