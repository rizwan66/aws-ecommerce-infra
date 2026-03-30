-- Local development seed data for the ecommerce database

CREATE TABLE IF NOT EXISTS products (
    id       SERIAL PRIMARY KEY,
    name     VARCHAR(200) NOT NULL,
    price    NUMERIC(10, 2) NOT NULL,
    stock    INTEGER NOT NULL DEFAULT 0,
    category VARCHAR(100)
);

INSERT INTO products (name, price, stock, category) VALUES
    ('Cloud T-Shirt',       29.99, 150, 'Apparel'),
    ('Terraform Mug',       14.99,  80, 'Accessories'),
    ('AWS Hoodie',          59.99,  45, 'Apparel'),
    ('DevOps Sticker Pack',  9.99, 300, 'Accessories'),
    ('Container Backpack',  79.99,  25, 'Bags'),
    ('Kubernetes Notebook', 19.99, 120, 'Stationery')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS cart_items (
    id         SERIAL PRIMARY KEY,
    session_id VARCHAR(255) NOT NULL,
    product_id INTEGER REFERENCES products(id),
    quantity   INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP DEFAULT NOW()
);
