"""
pytest configuration and shared fixtures.

All fixtures that mock external dependencies (Redis, PostgreSQL, AWS)
live here so tests are fast and hermetic — no real AWS calls.
"""
import sys
import os
from unittest.mock import MagicMock, patch
import pytest

# ─── Inject fake config before app is imported ────────────────────────────────
# The app tries `from config import ...` which only exists on EC2.
# We provide the same names via monkeypatching sys.modules.
FAKE_CONFIG_MODULE = type(sys)("config")
FAKE_CONFIG_MODULE.INSTANCE_ID = "i-test1234567890ab"
FAKE_CONFIG_MODULE.AZ = "us-east-1a"
FAKE_CONFIG_MODULE.ENVIRONMENT = "test"
FAKE_CONFIG_MODULE.DB_HOST = "localhost"
FAKE_CONFIG_MODULE.DB_NAME = "testdb"
FAKE_CONFIG_MODULE.DB_USER = "testuser"
FAKE_CONFIG_MODULE.DB_PASS = "testpass"
FAKE_CONFIG_MODULE.REDIS_HOST = "localhost"
FAKE_CONFIG_MODULE.REDIS_PORT = 6379
sys.modules["config"] = FAKE_CONFIG_MODULE

# Add parent dir so `from app import ...` resolves
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


@pytest.fixture
def client():
    """Flask test client with mocked external dependencies."""
    # Patch both DB and Redis so no network calls are made
    with patch("app._check_db") as mock_db, \
         patch("app._check_redis") as mock_redis, \
         patch("app._get_redis") as mock_get_redis:

        # Default: everything healthy
        mock_db.return_value = {"status": "healthy", "version": "PostgreSQL 16.3"}
        mock_redis.return_value = {"status": "healthy", "version": "7.1.0"}

        # Redis client mock (for cart operations)
        redis_mock = MagicMock()
        redis_mock.get.return_value = None          # cache miss by default
        redis_mock.hgetall.return_value = {}
        redis_mock.hset.return_value = 1
        redis_mock.expire.return_value = True
        redis_mock.setex.return_value = True
        redis_mock.ping.return_value = True
        redis_mock.info.return_value = {"redis_version": "7.1.0"}
        mock_get_redis.return_value = redis_mock

        import app as flask_app
        flask_app.app.config["TESTING"] = True
        with flask_app.app.test_client() as c:
            yield c, mock_db, mock_redis, redis_mock


@pytest.fixture
def client_db_down():
    """Flask test client simulating a database failure."""
    with patch("app._check_db") as mock_db, \
         patch("app._check_redis") as mock_redis, \
         patch("app._get_redis") as mock_get_redis:

        mock_db.return_value = {"status": "unhealthy", "error": "Connection refused"}
        mock_redis.return_value = {"status": "healthy", "version": "7.1.0"}

        redis_mock = MagicMock()
        redis_mock.get.return_value = None
        redis_mock.hgetall.return_value = {}
        mock_get_redis.return_value = redis_mock

        import app as flask_app
        flask_app.app.config["TESTING"] = True
        with flask_app.app.test_client() as c:
            yield c


@pytest.fixture
def client_redis_down():
    """Flask test client simulating a Redis failure."""
    with patch("app._check_db") as mock_db, \
         patch("app._check_redis") as mock_redis, \
         patch("app._get_redis") as mock_get_redis:

        mock_db.return_value = {"status": "healthy", "version": "PostgreSQL 16.3"}
        mock_redis.return_value = {"status": "unhealthy", "error": "Connection refused"}
        mock_get_redis.side_effect = Exception("Redis connection refused")

        import app as flask_app
        flask_app.app.config["TESTING"] = True
        with flask_app.app.test_client() as c:
            yield c


@pytest.fixture
def client_all_down():
    """Flask test client simulating total dependency failure."""
    with patch("app._check_db") as mock_db, \
         patch("app._check_redis") as mock_redis, \
         patch("app._get_redis") as mock_get_redis:

        mock_db.return_value = {"status": "unhealthy", "error": "Connection refused"}
        mock_redis.return_value = {"status": "unhealthy", "error": "Connection refused"}
        mock_get_redis.side_effect = Exception("Redis connection refused")

        import app as flask_app
        flask_app.app.config["TESTING"] = True
        with flask_app.app.test_client() as c:
            yield c
