#!/bin/bash
set -euxo pipefail

# ─── System setup ─────────────────────────────────────────────────────────────
dnf update -y
dnf install -y python3 python3-pip git awscli jq

# ─── Fetch DB password from Secrets Manager ───────────────────────────────────
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${aws_region}" \
  --query SecretString \
  --output text)

# ─── Get instance metadata (IMDSv2) ──────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ─── Write application files inline ──────────────────────────────────────────
# The app is embedded here so the instance is self-sufficient at boot.
# CI/CD can later sync updated code from S3 and trigger a service restart.

mkdir -p /opt/ecommerce/templates

cat > /opt/ecommerce/requirements.txt << 'REQEOF'
flask==3.0.3
gunicorn==23.0.0
psycopg2-binary==2.9.9
redis==5.0.8
boto3==1.35.0
REQEOF

pip3 install -r /opt/ecommerce/requirements.txt

cat > /opt/ecommerce/app.py << 'APPEOF'
"""
Ecommerce Application — AWS multi-tier Flask app.
Displays instance ID, AZ, health status, and a product catalogue.
"""
import os
import time
import logging
from datetime import datetime

import redis
import psycopg2
from flask import Flask, jsonify, render_template, request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

try:
    from config import INSTANCE_ID, AZ, ENVIRONMENT, DB_HOST, DB_NAME, DB_USER, DB_PASS, REDIS_HOST, REDIS_PORT
except ImportError:
    INSTANCE_ID = os.getenv("INSTANCE_ID", "local-dev")
    AZ          = os.getenv("AZ", "local")
    ENVIRONMENT = os.getenv("ENVIRONMENT", "dev")
    DB_HOST     = os.getenv("DB_HOST", "localhost")
    DB_NAME     = os.getenv("DB_NAME", "ecommercedb")
    DB_USER     = os.getenv("DB_USER", "dbadmin")
    DB_PASS     = os.getenv("DB_PASS", "")
    REDIS_HOST  = os.getenv("REDIS_HOST", "localhost")
    REDIS_PORT  = int(os.getenv("REDIS_PORT", "6379"))

DB_SSL_MODE = os.getenv("DB_SSL_MODE", "require")
REDIS_SSL   = os.getenv("REDIS_SSL", "true").lower() == "true"
START_TIME  = time.time()

PRODUCTS = [
    {"id": 1, "name": "Cloud T-Shirt",        "price": 29.99, "stock": 150, "category": "Apparel"},
    {"id": 2, "name": "Terraform Mug",         "price": 14.99, "stock":  80, "category": "Accessories"},
    {"id": 3, "name": "AWS Hoodie",            "price": 59.99, "stock":  45, "category": "Apparel"},
    {"id": 4, "name": "DevOps Sticker Pack",   "price":  9.99, "stock": 300, "category": "Accessories"},
    {"id": 5, "name": "Container Backpack",    "price": 79.99, "stock":  25, "category": "Bags"},
    {"id": 6, "name": "Kubernetes Notebook",   "price": 19.99, "stock": 120, "category": "Stationery"},
]

def _get_db_conn():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS,
        connect_timeout=3, sslmode=DB_SSL_MODE
    )

def _get_redis():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, ssl=REDIS_SSL,
                       socket_connect_timeout=3, decode_responses=True)

def _check_db():
    try:
        conn = _get_db_conn()
        cur  = conn.cursor()
        cur.execute("SELECT version()")
        ver = cur.fetchone()[0]
        cur.close(); conn.close()
        return {"status": "healthy", "version": ver}
    except Exception as exc:
        logger.warning("DB health check failed: %s", exc)
        return {"status": "unhealthy", "error": str(exc)}

def _check_redis():
    try:
        r = _get_redis()
        r.ping()
        return {"status": "healthy", "version": r.info("server").get("redis_version")}
    except Exception as exc:
        logger.warning("Redis health check failed: %s", exc)
        return {"status": "unhealthy", "error": str(exc)}

@app.route("/health")
def health():
    db    = _check_db()
    cache = _check_redis()
    return jsonify({
        "status": "healthy" if db["status"] == "healthy" else "degraded",
        "instance_id": INSTANCE_ID,
        "availability_zone": AZ,
        "environment": ENVIRONMENT,
        "uptime_seconds": int(time.time() - START_TIME),
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "dependencies": {"database": db, "cache": cache},
    }), 200

@app.route("/")
def index():
    db    = _check_db()
    cache = _check_redis()
    cache_hit = False
    try:
        r = _get_redis()
        cache_hit = r.get("product_count") is not None
        if not cache_hit:
            r.setex("product_count", 60, str(len(PRODUCTS)))
    except Exception:
        pass
    return render_template("index.html",
        products=PRODUCTS, instance_id=INSTANCE_ID, az=AZ,
        environment=ENVIRONMENT, db_status=db["status"],
        redis_status=cache["status"], cache_hit=cache_hit,
        uptime=int(time.time() - START_TIME))

@app.route("/api/products")
def api_products():
    return jsonify({"products": PRODUCTS, "count": len(PRODUCTS)})

@app.route("/api/products/<int:product_id>")
def api_product(product_id):
    p = next((p for p in PRODUCTS if p["id"] == product_id), None)
    return jsonify(p) if p else (jsonify({"error": "Not found"}), 404)

@app.route("/api/cart", methods=["GET", "POST"])
def api_cart():
    session_id = request.args.get("session", "demo-session")
    cart_key   = f"cart:{session_id}"
    try:
        r = _get_redis()
        if request.method == "POST":
            d = request.get_json(force=True)
            r.hset(cart_key, str(d.get("product_id", "")), int(d.get("quantity", 1)))
            r.expire(cart_key, 3600)
            return jsonify({"status": "ok", "cart_key": cart_key})
        return jsonify({"session": session_id, "items": r.hgetall(cart_key)})
    except Exception as exc:
        return jsonify({"status": "error", "error": str(exc)}), 503

@app.route("/metrics")
def metrics():
    uptime = int(time.time() - START_TIME)
    body = (
        f"# HELP ecommerce_uptime_seconds Application uptime\n"
        f"# TYPE ecommerce_uptime_seconds gauge\n"
        f"ecommerce_uptime_seconds{{instance=\"{INSTANCE_ID}\",az=\"{AZ}\",env=\"{ENVIRONMENT}\"}} {uptime}\n"
        f"# HELP ecommerce_products_total Total products\n"
        f"# TYPE ecommerce_products_total gauge\n"
        f"ecommerce_products_total {len(PRODUCTS)}\n"
    )
    return body, 200, {"Content-Type": "text/plain; charset=utf-8"}

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=ENVIRONMENT != "prod")
APPEOF

cat > /opt/ecommerce/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>AWS Ecommerce — {{ environment }}</title>
  <style>
    :root{--orange:#FF9900;--dark:#232F3E;--green:#1d8348;--red:#c0392b}
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:Arial,sans-serif;background:#eaecef;color:#333}
    header{background:var(--dark);color:#fff;padding:14px 28px;display:flex;align-items:center;justify-content:space-between}
    header h1{font-size:1.3rem;color:var(--orange)}
    .env-badge{background:var(--orange);color:var(--dark);font-weight:700;padding:4px 12px;border-radius:4px;font-size:.8rem}
    .info-bar{background:#1a252f;color:#aaa;font-size:.75rem;padding:6px 28px;display:flex;gap:20px;flex-wrap:wrap}
    .info-bar span{color:#fff}
    .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px}
    .healthy-dot{background:var(--green)}.unhealthy-dot{background:var(--red)}
    main{max-width:1100px;margin:22px auto;padding:0 14px}
    .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px;margin-bottom:24px}
    .card{background:#fff;border-radius:8px;padding:18px;box-shadow:0 1px 4px rgba(0,0,0,.1)}
    .card h3{font-size:.7rem;text-transform:uppercase;color:#777;margin-bottom:6px}
    .card p{font-size:.95rem;font-weight:600;word-break:break-all}
    .status-row{display:flex;align-items:center;font-weight:600}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:14px}
    .product{background:#fff;border-radius:8px;padding:18px;box-shadow:0 1px 4px rgba(0,0,0,.1);transition:box-shadow .2s}
    .product:hover{box-shadow:0 4px 12px rgba(0,0,0,.15)}
    .cat{font-size:.65rem;text-transform:uppercase;color:#888;margin-bottom:5px}
    .product h4{font-size:.95rem;margin-bottom:7px}
    .price{font-size:1.25rem;font-weight:700;color:var(--dark)}
    .stock{font-size:.75rem;color:#666;margin-top:3px}
    button{margin-top:12px;width:100%;background:var(--orange);border:none;border-radius:4px;padding:8px;font-weight:700;cursor:pointer;font-size:.85rem}
    button:hover{background:#e08c00}
    h2{margin-bottom:14px;font-size:1rem;color:var(--dark)}
    footer{text-align:center;padding:18px;font-size:.75rem;color:#888;margin-top:36px}
    a{color:var(--orange)}
  </style>
</head>
<body>
  <header>
    <h1>AWS Ecommerce Store</h1>
    <span class="env-badge">{{ environment | upper }}</span>
  </header>
  <div class="info-bar">
    <div>Instance: <span>{{ instance_id }}</span></div>
    <div>AZ: <span>{{ az }}</span></div>
    <div>Uptime: <span>{{ uptime }}s</span></div>
    <div>Cache: <span>{{ "HIT" if cache_hit else "MISS" }}</span></div>
  </div>
  <main>
    <div class="cards">
      <div class="card"><h3>Instance ID</h3><p>{{ instance_id }}</p></div>
      <div class="card"><h3>Availability Zone</h3><p>{{ az }}</p></div>
      <div class="card">
        <h3>Database</h3>
        <div class="status-row">
          <span class="dot {{ 'healthy-dot' if db_status == 'healthy' else 'unhealthy-dot' }}"></span>
          {{ db_status | capitalize }}
        </div>
      </div>
      <div class="card">
        <h3>Cache (Redis)</h3>
        <div class="status-row">
          <span class="dot {{ 'healthy-dot' if redis_status == 'healthy' else 'unhealthy-dot' }}"></span>
          {{ redis_status | capitalize }}
        </div>
      </div>
      <div class="card"><h3>Uptime</h3><p>{{ uptime }}s</p></div>
      <div class="card"><h3>Health Check</h3><p><a href="/health">/health</a></p></div>
    </div>
    <h2>Products ({{ products | length }})</h2>
    <div class="grid">
      {% for p in products %}
      <div class="product">
        <div class="cat">{{ p.category }}</div>
        <h4>{{ p.name }}</h4>
        <div class="price">$${{ "%.2f" | format(p.price) }}</div>
        <div class="stock">{{ p.stock }} in stock</div>
        <button onclick="addToCart({{ p.id }})">Add to Cart</button>
      </div>
      {% endfor %}
    </div>
  </main>
  <footer>
    Served by <strong>{{ instance_id }}</strong> in <strong>{{ az }}</strong> &mdash;
    Environment: <strong>{{ environment }}</strong>
  </footer>
  <script>
    async function addToCart(id){
      const r=await fetch('/api/cart?session=demo-'+Date.now(),{method:'POST',
        body:JSON.stringify({product_id:id,quantity:1}),
        headers:{'Content-Type':'application/json'}});
      const d=await r.json();
      alert(d.status==='ok'?'Added to cart!':'Error: '+d.error);
    }
  </script>
</body>
</html>
HTMLEOF

# ─── Write runtime config (instance-specific, generated at boot) ──────────────
# Use Python repr() for DB_PASS so any special chars are safely escaped
DB_PASS_REPR=$(python3 -c "import sys; print(repr(sys.stdin.readline().rstrip('\n')))" <<< "$DB_PASSWORD")
cat > /opt/ecommerce/config.py << EOF
INSTANCE_ID = "$INSTANCE_ID"
AZ          = "$AZ"
ENVIRONMENT = "${environment}"
DB_HOST     = "${db_endpoint}"
DB_NAME     = "${project_name}db"
DB_USER     = "dbadmin"
DB_PASS     = $DB_PASS_REPR
REDIS_HOST  = "${redis_endpoint}"
REDIS_PORT  = 6379
EOF

# ─── Optional: override from S3 if CI/CD has uploaded updated code ───────────
aws s3 sync "s3://${artifacts_bucket_name}/app/" /opt/ecommerce/ \
  --region "${aws_region}" \
  --exclude "config.py" \
  --quiet || true

# ─── Systemd service ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/ecommerce.service << 'SVCEOF'
[Unit]
Description=Ecommerce App
After=network.target

[Service]
User=nobody
WorkingDirectory=/opt/ecommerce
ExecStart=/usr/bin/python3 -m gunicorn --workers 4 --bind 0.0.0.0:8080 --timeout 30 app:app
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ecommerce

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable ecommerce
systemctl start ecommerce

# ─── CloudWatch agent ─────────────────────────────────────────────────────────
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWEOF
{
  "metrics": {
    "namespace": "${project_name}/${environment}",
    "metrics_collected": {
      "cpu":  {"measurement": ["cpu_usage_active"],  "metrics_collection_interval": 60},
      "mem":  {"measurement": ["mem_used_percent"],  "metrics_collection_interval": 60},
      "disk": {"measurement": ["disk_used_percent"], "metrics_collection_interval": 60}
    }
  },
  "logs": {
    "logs_collected": {
      "journald": {
        "collect_list": [{
          "log_group_name":  "/aws/ec2/${project_name}/${environment}/app",
          "log_stream_name": "{instance_id}",
          "filters": [{"type": "include", "expression": "SYSLOG_IDENTIFIER=ecommerce"}]
        }]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s
