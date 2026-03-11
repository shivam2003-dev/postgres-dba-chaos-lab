CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── Drop existing tables (clean slate) ───────────────────
DROP TABLE IF EXISTS order_item_audit     CASCADE;
DROP TABLE IF EXISTS payment_transactions CASCADE;
DROP TABLE IF EXISTS order_items          CASCADE;
DROP TABLE IF EXISTS orders               CASCADE;
DROP TABLE IF EXISTS inventory_log        CASCADE;
DROP TABLE IF EXISTS products             CASCADE;
DROP TABLE IF EXISTS customers            CASCADE;
DROP TABLE IF EXISTS categories           CASCADE;

DROP TABLE IF EXISTs events;
DROP TABLE IF EXISTS metrics;


-- ─── 1. CATEGORIES ────────────────────────────────────────
CREATE TABLE categories (
    category_id   SERIAL,
    name          VARCHAR(100) NOT NULL,
    description   TEXT,
    created_at    TIMESTAMP DEFAULT NOW()
);

-- ─── 2. PRODUCTS ──────────────────────────────────────────
CREATE TABLE products (
    product_id    SERIAL,
    category_id   INT,
    sku           VARCHAR(50)  UNIQUE NOT NULL,
    name          VARCHAR(200) NOT NULL,
    description   TEXT,
    unit_price    NUMERIC(10,2) NOT NULL,
    stock_qty     INT DEFAULT 0,
    is_active     BOOLEAN DEFAULT TRUE,
    created_at    TIMESTAMP,
    updated_at    TIMESTAMP
);

-- ─── 3. CUSTOMERS ─────────────────────────────────────────
CREATE TABLE customers (
    customer_id   SERIAL,
    first_name    VARCHAR(100) ,
    last_name     VARCHAR(100) ,
    email         VARCHAR(255) ,
    phone         VARCHAR(20),
    address       TEXT,
    city          VARCHAR(100),
    country       VARCHAR(100),
    created_at    TIMESTAMP
);

-- ─── 4. ORDERS ────────────────────────────────────────────
-- HIGH-VOLUME TABLE: thousands of inserts per minute
CREATE TABLE orders (
    order_id      BIGSERIAL,
    customer_id   INT ,
    order_status  VARCHAR(30),
    total_amount  NUMERIC(12,2) ,
    currency      CHAR(3) DEFAULT 'USD',
    shipping_addr TEXT,
    notes         TEXT,
    ordered_at    TIMESTAMP,
    updated_at    TIMESTAMP
);

-- ─── 5. ORDER_ITEMS ───────────────────────────────────────
CREATE TABLE order_items (
    item_id       BIGSERIAL,
    order_id      BIGINT,
    product_id    INT,
    quantity      INT,
    unit_price    NUMERIC(10,2),
    discount_pct  NUMERIC(5,2),
    line_total    NUMERIC(12,2)
);

-- ─── 6. PAYMENT_TRANSACTIONS ──────────────────────────────
-- HIGH-VOLUME TABLE: primary target for corruption testing
CREATE TABLE payment_transactions (
    txn_id        BIGSERIAL,
    order_id      BIGINT,
    customer_id   INT,
    txn_type      VARCHAR(20),
    txn_status    VARCHAR(20),
    amount        NUMERIC(12,2),
    currency      CHAR(3) ,
    gateway       VARCHAR(50),      -- e.g. 'STRIPE','PAYPAL','SQUARE'
    gateway_ref   VARCHAR(200),     -- external reference ID
    card_last4    CHAR(4),
    card_brand    VARCHAR(20),
    ip_address    INET,
    processed_at  TIMESTAMP,
    metadata      JSONB
);

-- ─── 7. INVENTORY_LOG ─────────────────────────────────────
CREATE TABLE inventory_log (
    log_id        BIGSERIAL,
    product_id    INT,
    change_type   VARCHAR(30),
    qty_change    INT NOT NULL,     -- positive = in, negative = out
    qty_after     INT NOT NULL,
    order_id      BIGINT,
    notes         TEXT,
    logged_at     TIMESTAMP
);

-- ─── 8. ORDER_ITEM_AUDIT (change log) ─────────────────────
CREATE TABLE order_item_audit (
    audit_id      BIGSERIAL PRIMARY KEY,
    item_id       BIGINT,
    order_id      BIGINT,
    changed_by    VARCHAR(100),
    change_type   VARCHAR(20),
    old_qty       INT,
    new_qty       INT,
    changed_at    TIMESTAMP DEFAULT NOW()
);

----TESTING TABLES-----

CREATE TABLE events (
    id         SERIAL,
    event_type TEXT,
    payload    JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE metrics (
    id         SERIAL,
    host       TEXT,
    metric     TEXT,
    value      FLOAT,
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);




DROP SUBSCRIPTION IF EXISTS analytics_sub;
CREATE SUBSCRIPTION analytics_sub
    CONNECTION 'host=localhost port=5432 user=logical_usr password=logical_pass123 dbname=postgres'
    PUBLICATION analytics_pub
    WITH (slot_name = 'analytics_slot', create_slot = true);


-- ─── Verify ───────────────────────────────────────────────
SELECT 'Schema created successfully' AS status;
SELECT table_name,
       pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) AS size
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

-- Verify subscription
SELECT subname, subenabled, subslotname FROM pg_subscription;
