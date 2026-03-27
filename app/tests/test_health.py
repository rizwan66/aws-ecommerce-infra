"""
Tests for the /health endpoint.

The /health endpoint is used by the ALB target group health check.
It must:
  - Always return HTTP 200 (ALB deregisters on non-2xx)
  - Include instance_id and availability_zone
  - Report dependency status for database and cache
  - Include uptime_seconds (monotonically increasing)
  - Include a valid ISO 8601 timestamp
"""
import json
from datetime import datetime


class TestHealthEndpointStructure:
    """Verify the response shape and required fields."""

    def test_returns_200_when_healthy(self, client):
        c, _, _, _ = client
        response = c.get("/health")
        assert response.status_code == 200

    def test_returns_200_when_db_down(self, client_db_down):
        """ALB must receive 200 even when DB is unhealthy — graceful degradation."""
        response = client_db_down.get("/health")
        assert response.status_code == 200

    def test_returns_200_when_redis_down(self, client_redis_down):
        response = client_redis_down.get("/health")
        assert response.status_code == 200

    def test_returns_200_when_all_down(self, client_all_down):
        """Even with all dependencies down, ALB health check must get 200."""
        response = client_all_down.get("/health")
        assert response.status_code == 200

    def test_content_type_is_json(self, client):
        c, _, _, _ = client
        response = c.get("/health")
        assert response.content_type == "application/json"

    def test_has_required_top_level_keys(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        required_keys = {"status", "instance_id", "availability_zone",
                         "environment", "uptime_seconds", "timestamp", "dependencies"}
        assert required_keys.issubset(data.keys()), \
            f"Missing keys: {required_keys - set(data.keys())}"

    def test_has_dependency_keys(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert "database" in data["dependencies"]
        assert "cache" in data["dependencies"]

    def test_dependency_has_status_field(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert "status" in data["dependencies"]["database"]
        assert "status" in data["dependencies"]["cache"]


class TestHealthEndpointValues:
    """Verify the values returned by /health."""

    def test_instance_id_matches_config(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert data["instance_id"] == "i-test1234567890ab"

    def test_az_matches_config(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert data["availability_zone"] == "us-east-1a"

    def test_environment_matches_config(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert data["environment"] == "test"

    def test_uptime_is_non_negative_integer(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert isinstance(data["uptime_seconds"], int)
        assert data["uptime_seconds"] >= 0

    def test_timestamp_is_valid_iso8601(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        ts = data["timestamp"]
        # Should end with Z (UTC)
        assert ts.endswith("Z"), f"Timestamp {ts!r} does not end with Z"
        # Should be parseable
        datetime.fromisoformat(ts.replace("Z", "+00:00"))

    def test_status_healthy_when_db_healthy(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert data["status"] == "healthy"

    def test_status_degraded_when_db_down(self, client_db_down):
        data = json.loads(client_db_down.get("/health").data)
        assert data["status"] == "degraded"

    def test_db_status_healthy(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert data["dependencies"]["database"]["status"] == "healthy"

    def test_db_status_unhealthy_when_db_down(self, client_db_down):
        data = json.loads(client_db_down.get("/health").data)
        assert data["dependencies"]["database"]["status"] == "unhealthy"

    def test_cache_status_healthy(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert data["dependencies"]["cache"]["status"] == "healthy"

    def test_cache_status_unhealthy_when_redis_down(self, client_redis_down):
        data = json.loads(client_redis_down.get("/health").data)
        assert data["dependencies"]["cache"]["status"] == "unhealthy"

    def test_db_includes_version_when_healthy(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/health").data)
        assert "version" in data["dependencies"]["database"]
        assert "PostgreSQL" in data["dependencies"]["database"]["version"]

    def test_db_includes_error_when_unhealthy(self, client_db_down):
        data = json.loads(client_db_down.get("/health").data)
        assert "error" in data["dependencies"]["database"]

    def test_all_down_reports_both_unhealthy(self, client_all_down):
        data = json.loads(client_all_down.get("/health").data)
        assert data["dependencies"]["database"]["status"] == "unhealthy"
        assert data["dependencies"]["cache"]["status"] == "unhealthy"


class TestHealthEndpointConsistency:
    """Verify health endpoint behaviour is consistent across multiple calls."""

    def test_uptime_increases_between_calls(self, client):
        """Uptime should be monotonically non-decreasing."""
        import time
        c, _, _, _ = client
        r1 = json.loads(c.get("/health").data)
        time.sleep(0.1)
        r2 = json.loads(c.get("/health").data)
        assert r2["uptime_seconds"] >= r1["uptime_seconds"]

    def test_multiple_calls_return_same_structure(self, client):
        c, _, _, _ = client
        for _ in range(5):
            response = c.get("/health")
            assert response.status_code == 200
            data = json.loads(response.data)
            assert "status" in data
            assert "instance_id" in data
