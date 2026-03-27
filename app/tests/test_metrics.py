"""
Tests for the /metrics endpoint.

The /metrics endpoint returns Prometheus plain-text format,
suitable for scraping by Prometheus or CloudWatch agent.
"""


class TestMetricsEndpoint:
    """Tests for GET /metrics."""

    def test_returns_200(self, client):
        c, _, _, _ = client
        response = c.get("/metrics")
        assert response.status_code == 200

    def test_content_type_is_plain_text(self, client):
        c, _, _, _ = client
        response = c.get("/metrics")
        assert "text/plain" in response.content_type

    def test_charset_is_utf8(self, client):
        c, _, _, _ = client
        response = c.get("/metrics")
        assert "utf-8" in response.content_type

    def test_contains_uptime_metric_name(self, client):
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b"ecommerce_uptime_seconds" in response.data

    def test_contains_products_total_metric_name(self, client):
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b"ecommerce_products_total" in response.data

    def test_contains_help_comments(self, client):
        """Each metric should have a HELP comment."""
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b"# HELP ecommerce_uptime_seconds" in response.data
        assert b"# HELP ecommerce_products_total" in response.data

    def test_contains_type_comments(self, client):
        """Each metric should have a TYPE comment."""
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b"# TYPE ecommerce_uptime_seconds gauge" in response.data
        assert b"# TYPE ecommerce_products_total gauge" in response.data

    def test_contains_instance_label(self, client):
        """Uptime metric should include instance label with instance ID."""
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b'instance="i-test1234567890ab"' in response.data

    def test_contains_az_label(self, client):
        """Uptime metric should include az label."""
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b'az="us-east-1a"' in response.data

    def test_contains_env_label(self, client):
        """Uptime metric should include env label."""
        c, _, _, _ = client
        response = c.get("/metrics")
        assert b'env="test"' in response.data

    def test_products_total_value_is_6(self, client):
        """There are 6 products in the catalogue."""
        c, _, _, _ = client
        response = c.get("/metrics")
        lines = response.data.decode().split("\n")
        products_line = next(
            (l for l in lines if l.startswith("ecommerce_products_total")), None
        )
        assert products_line is not None, "ecommerce_products_total metric not found"
        value = products_line.split()[-1]
        assert value == "6"

    def test_uptime_value_is_numeric(self, client):
        """Uptime value should be a non-negative integer."""
        c, _, _, _ = client
        response = c.get("/metrics")
        lines = response.data.decode().split("\n")
        uptime_line = next(
            (l for l in lines
             if l.startswith("ecommerce_uptime_seconds{") and not l.startswith("#")),
            None
        )
        assert uptime_line is not None
        value = int(uptime_line.split()[-1])
        assert value >= 0

    def test_ends_with_newline(self, client):
        """Prometheus exposition format requires trailing newline."""
        c, _, _, _ = client
        response = c.get("/metrics")
        assert response.data.endswith(b"\n")

    def test_prometheus_format_valid(self, client):
        """Verify basic Prometheus text format: each non-comment line has metric{labels} value."""
        c, _, _, _ = client
        response = c.get("/metrics")
        for line in response.data.decode().strip().split("\n"):
            if line.startswith("#") or not line:
                continue
            parts = line.split()
            assert len(parts) >= 2, f"Invalid metric line: {line!r}"
            # Value should be numeric
            float(parts[-1])
