"""
Tests for product-related routes:
  GET /           — home page (HTML)
  GET /api/products          — list all products
  GET /api/products/<id>     — single product
"""
import json


class TestHomePage:
    """Tests for the / (index) route."""

    def test_returns_200(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert response.status_code == 200

    def test_content_type_is_html(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert "text/html" in response.content_type

    def test_contains_instance_id(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert b"i-test1234567890ab" in response.data

    def test_contains_az(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert b"us-east-1a" in response.data

    def test_contains_environment(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert b"test" in response.data.lower()

    def test_contains_product_names(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert b"Cloud T-Shirt" in response.data
        assert b"Terraform Mug" in response.data
        assert b"AWS Hoodie" in response.data

    def test_contains_health_endpoint_link(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert b"/health" in response.data

    def test_shows_db_status_healthy(self, client):
        c, _, _, _ = client
        response = c.get("/")
        # Template renders "Healthy" (capitalized)
        assert b"healthy" in response.data.lower()

    def test_shows_db_degraded_when_down(self, client_db_down):
        response = client_db_down.get("/")
        assert response.status_code == 200  # Page still loads
        assert b"unhealthy" in response.data.lower()

    def test_cache_miss_shown_when_redis_empty(self, client):
        c, _, _, redis_mock = client
        redis_mock.get.return_value = None  # Ensure cache miss
        response = c.get("/")
        assert b"MISS" in response.data

    def test_cache_hit_shown_when_redis_has_count(self, client):
        c, _, _, redis_mock = client
        redis_mock.get.return_value = "6"  # Cache hit
        response = c.get("/")
        assert b"HIT" in response.data

    def test_six_products_displayed(self, client):
        c, _, _, _ = client
        response = c.get("/")
        # Count product cards — each has "Add to Cart" button
        assert response.data.count(b"Add to Cart") == 6

    def test_prices_displayed(self, client):
        c, _, _, _ = client
        response = c.get("/")
        assert b"29.99" in response.data  # Cloud T-Shirt
        assert b"59.99" in response.data  # AWS Hoodie


class TestProductListAPI:
    """Tests for GET /api/products."""

    def test_returns_200(self, client):
        c, _, _, _ = client
        response = c.get("/api/products")
        assert response.status_code == 200

    def test_content_type_is_json(self, client):
        c, _, _, _ = client
        response = c.get("/api/products")
        assert response.content_type == "application/json"

    def test_returns_products_and_count(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        assert "products" in data
        assert "count" in data

    def test_count_matches_products_length(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        assert data["count"] == len(data["products"])

    def test_returns_six_products(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        assert data["count"] == 6
        assert len(data["products"]) == 6

    def test_each_product_has_required_fields(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        required = {"id", "name", "price", "stock", "category"}
        for product in data["products"]:
            assert required.issubset(product.keys()), \
                f"Product {product.get('id')} missing fields: {required - set(product.keys())}"

    def test_product_ids_are_unique(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        ids = [p["id"] for p in data["products"]]
        assert len(ids) == len(set(ids)), "Duplicate product IDs found"

    def test_product_prices_are_positive(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        for product in data["products"]:
            assert product["price"] > 0, f"Product {product['id']} has non-positive price"

    def test_product_stock_is_non_negative(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        for product in data["products"]:
            assert product["stock"] >= 0, f"Product {product['id']} has negative stock"

    def test_product_names_are_strings(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        for product in data["products"]:
            assert isinstance(product["name"], str)
            assert len(product["name"]) > 0

    def test_known_product_in_list(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products").data)
        names = [p["name"] for p in data["products"]]
        assert "Cloud T-Shirt" in names
        assert "Terraform Mug" in names


class TestProductDetailAPI:
    """Tests for GET /api/products/<id>."""

    def test_returns_200_for_valid_id(self, client):
        c, _, _, _ = client
        response = c.get("/api/products/1")
        assert response.status_code == 200

    def test_returns_404_for_invalid_id(self, client):
        c, _, _, _ = client
        response = c.get("/api/products/9999")
        assert response.status_code == 404

    def test_returns_404_for_id_zero(self, client):
        c, _, _, _ = client
        response = c.get("/api/products/0")
        assert response.status_code == 404

    def test_404_response_has_error_key(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products/9999").data)
        assert "error" in data

    def test_returns_correct_product_id_1(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products/1").data)
        assert data["id"] == 1
        assert data["name"] == "Cloud T-Shirt"
        assert data["price"] == 29.99
        assert data["category"] == "Apparel"

    def test_returns_correct_product_id_2(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products/2").data)
        assert data["id"] == 2
        assert data["name"] == "Terraform Mug"

    def test_all_valid_product_ids_return_200(self, client):
        c, _, _, _ = client
        for product_id in range(1, 7):
            response = c.get(f"/api/products/{product_id}")
            assert response.status_code == 200, \
                f"Expected 200 for product {product_id}, got {response.status_code}"

    def test_product_has_all_required_fields(self, client):
        c, _, _, _ = client
        data = json.loads(c.get("/api/products/3").data)
        assert "id" in data
        assert "name" in data
        assert "price" in data
        assert "stock" in data
        assert "category" in data
