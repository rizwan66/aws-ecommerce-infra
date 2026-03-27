"""
Tests for the cart API:
  GET  /api/cart?session=<id>  — retrieve cart
  POST /api/cart?session=<id>  — add item to cart

The cart is backed by Redis (hset/hgetall). All Redis calls are mocked.
"""
import json


class TestCartGet:
    """Tests for GET /api/cart."""

    def test_returns_200_with_empty_cart(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}
        response = c.get("/api/cart?session=test-session")
        assert response.status_code == 200

    def test_response_contains_session_id(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}
        data = json.loads(c.get("/api/cart?session=abc123").data)
        assert data["session"] == "abc123"

    def test_response_contains_items_key(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}
        data = json.loads(c.get("/api/cart?session=test").data)
        assert "items" in data

    def test_empty_cart_returns_empty_items(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}
        data = json.loads(c.get("/api/cart?session=test").data)
        assert data["items"] == {}

    def test_cart_with_items_returned(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {"1": "2", "3": "1"}
        data = json.loads(c.get("/api/cart?session=test").data)
        assert data["items"] == {"1": "2", "3": "1"}

    def test_default_session_used_when_no_param(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}
        data = json.loads(c.get("/api/cart").data)
        assert data["session"] == "demo-session"

    def test_returns_503_when_redis_down(self, client_redis_down):
        response = client_redis_down.get("/api/cart?session=test")
        assert response.status_code == 503

    def test_503_response_has_error_key(self, client_redis_down):
        data = json.loads(client_redis_down.get("/api/cart?session=test").data)
        assert "error" in data
        assert data["status"] == "error"

    def test_cart_key_uses_session_id(self, client):
        """Verify the correct Redis key is used for the session."""
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}
        c.get("/api/cart?session=my-session-42")
        redis_mock.hgetall.assert_called_once_with("cart:my-session-42")


class TestCartPost:
    """Tests for POST /api/cart."""

    def test_returns_200_on_success(self, client):
        c, _, _, redis_mock = client
        response = c.post(
            "/api/cart?session=test",
            json={"product_id": 1, "quantity": 2}
        )
        assert response.status_code == 200

    def test_response_status_ok(self, client):
        c, _, _, redis_mock = client
        data = json.loads(c.post(
            "/api/cart?session=test",
            json={"product_id": 1, "quantity": 1}
        ).data)
        assert data["status"] == "ok"

    def test_response_includes_cart_key(self, client):
        c, _, _, redis_mock = client
        data = json.loads(c.post(
            "/api/cart?session=test",
            json={"product_id": 1, "quantity": 1}
        ).data)
        assert "cart_key" in data
        assert "test" in data["cart_key"]

    def test_calls_redis_hset(self, client):
        c, _, _, redis_mock = client
        c.post("/api/cart?session=test", json={"product_id": 3, "quantity": 2})
        redis_mock.hset.assert_called_once_with("cart:test", "3", 2)

    def test_calls_redis_expire(self, client):
        """Cart should expire after 1 hour (3600 seconds)."""
        c, _, _, redis_mock = client
        c.post("/api/cart?session=test", json={"product_id": 1, "quantity": 1})
        redis_mock.expire.assert_called_once_with("cart:test", 3600)

    def test_add_multiple_items(self, client):
        c, _, _, redis_mock = client
        c.post("/api/cart?session=s1", json={"product_id": 1, "quantity": 2})
        c.post("/api/cart?session=s1", json={"product_id": 2, "quantity": 1})
        assert redis_mock.hset.call_count == 2

    def test_returns_503_when_redis_down(self, client_redis_down):
        response = client_redis_down.post(
            "/api/cart?session=test",
            json={"product_id": 1, "quantity": 1}
        )
        assert response.status_code == 503

    def test_503_has_error_and_status(self, client_redis_down):
        data = json.loads(client_redis_down.post(
            "/api/cart?session=test",
            json={"product_id": 1, "quantity": 1}
        ).data)
        assert data["status"] == "error"
        assert "error" in data

    def test_default_quantity_is_one(self, client):
        """When quantity is not specified, default to 1."""
        c, _, _, redis_mock = client
        c.post("/api/cart?session=test", json={"product_id": 5})
        # quantity should default to 1
        redis_mock.hset.assert_called_once_with("cart:test", "5", 1)

    def test_product_id_stored_as_string(self, client):
        """Redis hash keys are strings."""
        c, _, _, redis_mock = client
        c.post("/api/cart?session=test", json={"product_id": 4, "quantity": 3})
        call_args = redis_mock.hset.call_args
        # Second arg (field) should be a string
        assert isinstance(call_args[0][1], str)


class TestCartSessionIsolation:
    """Verify different sessions don't interfere with each other."""

    def test_different_sessions_use_different_keys(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}

        c.get("/api/cart?session=user-A")
        c.get("/api/cart?session=user-B")

        calls = [str(call) for call in redis_mock.hgetall.call_args_list]
        assert any("cart:user-A" in call for call in calls)
        assert any("cart:user-B" in call for call in calls)

    def test_session_in_cart_key(self, client):
        c, _, _, redis_mock = client
        redis_mock.hgetall.return_value = {}

        data = json.loads(c.get("/api/cart?session=my-unique-session").data)
        # The session should appear in the response
        assert data["session"] == "my-unique-session"
