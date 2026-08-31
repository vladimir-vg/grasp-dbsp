-- Customers, products, and the orders that link them.
CREATE TABLE customers (
    customer_id   INTEGER,
    customer_name TEXT,
    country       TEXT
);

CREATE TABLE products (
    product_id   INTEGER,
    product_name TEXT,
    price_cents  INTEGER
);

CREATE TABLE orders (
    order_id    INTEGER,
    customer_id INTEGER,
    product_id  INTEGER,
    qty         INTEGER
);

-- Revenue per customer: line totals summed per customer, then joined
-- back to the customer name.
CREATE VIEW customer_spend_set AS
SELECT
    c.customer_id,
    c.customer_name,
    s.total_spend
FROM (
    SELECT
        o.customer_id,
        SUM(o.qty * p.price_cents) AS total_spend
    FROM orders o
    JOIN products p ON p.product_id = o.product_id
    GROUP BY o.customer_id
) s
JOIN customers c ON c.customer_id = s.customer_id;

-- Customers ranked by total spend (highest first). customer_id is the
-- tie-breaker so the ordering is fully deterministic.
CREATE VIEW top_customers_seq AS
SELECT
    customer_id,
    customer_name,
    total_spend,
    RANK()       OVER (ORDER BY total_spend DESC, customer_id ASC) AS rank,
    ROW_NUMBER() OVER (ORDER BY total_spend DESC, customer_id ASC) AS row_number
FROM customer_spend_set
ORDER BY total_spend DESC, customer_id ASC;

-- Customers who have never placed an order.
CREATE VIEW dormant_customers_set AS
SELECT
    c.customer_id,
    c.customer_name
FROM customers c
WHERE NOT EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.customer_id = c.customer_id
);
