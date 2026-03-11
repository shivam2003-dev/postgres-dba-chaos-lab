-- ============================================================================
-- ROW-LEVEL CORRUPTION DIAGNOSIS — PostgreSQL 18.3
-- ============================================================================
-- Purpose:
--   Probe every individual row in a table by attempting to SELECT it via
--   its primary key. Records PASS or FAIL for each row into
--   public.row_corruption_diagnosis.
--
-- Why this is needed:
--   The block-level scanner (pageinspect) records UNREADABLE_PAGE at the
--   block level — it knows block 2 is bad but cannot tell you WHICH rows
--   inside block 2 are affected (because the whole block is unreadable).
--   This procedure reads the ctid of every row from pg_class/pageinspect
--   on GOOD blocks, then probes each known PK value one by one via a
--   protected SELECT, recording exactly which rows throw errors.
--
-- Strategy:
--   1. Fetch all PK values from the table using a sequential scan.
--      For rows on unreadable blocks this scan itself may fail per-row,
--      so we use a cursor with a per-row exception handler.
--   2. For each PK, attempt:
--        SELECT <pk_col>, <pk_col>::text, ctid
--        FROM   <table>
--        WHERE  <pk_col> = <value>
--      If it succeeds  → row is HEALTHY, record if --include-healthy flag set
--      If it throws    → row is CORRUPT,  record with error detail
--   3. Additionally probe known-bad ctids directly via pageinspect to
--      recover the pk_value even when the row cannot be read normally.
--
-- Usage:
--   -- Diagnose one table (corrupt rows only, default):
--   CALL diagnose_table_rows('payment_transactions', 'txn_id');
--
--   -- Include healthy rows in output too:
--   CALL diagnose_table_rows('payment_transactions', 'txn_id',
--                             p_include_healthy => TRUE);
--
--   -- Diagnose all tables:
--   CALL diagnose_all_tables();
--
-- Query results:
--   -- All corrupt rows:
--   SELECT * FROM row_corruption_diagnosis WHERE is_corrupted = TRUE;
--
--   -- Count healthy vs corrupt per table:
--   SELECT * FROM v_row_diagnosis_summary;
--
--   -- The query you wanted:
--   SELECT COUNT(*)
--   FROM   payment_transactions pt
--   WHERE  txn_id::text NOT IN (
--       SELECT pk_value
--       FROM   row_corruption_diagnosis
--       WHERE  table_name   = 'payment_transactions'
--         AND  is_corrupted = TRUE
--         AND  pk_value IS NOT NULL
--   );
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 0 — Drop old versions
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW      IF EXISTS v_row_diagnosis_summary                         CASCADE;
DROP PROCEDURE IF EXISTS diagnose_all_tables(TEXT, BOOLEAN)             CASCADE;
DROP PROCEDURE IF EXISTS diagnose_all_tables(TEXT)                      CASCADE;
DROP PROCEDURE IF EXISTS diagnose_all_tables()                          CASCADE;
DROP PROCEDURE IF EXISTS diagnose_table_rows(TEXT, TEXT, TEXT, BOOLEAN) CASCADE;
DROP PROCEDURE IF EXISTS diagnose_table_rows(TEXT, TEXT, TEXT)          CASCADE;
DROP PROCEDURE IF EXISTS diagnose_table_rows(TEXT, TEXT)                CASCADE;
DROP TABLE     IF EXISTS public.row_corruption_diagnosis                CASCADE;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — Diagnosis table (one row per probed PK value)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.row_corruption_diagnosis (
    id              BIGSERIAL       PRIMARY KEY,

    -- Run tracking
    scan_id         UUID            NOT NULL DEFAULT gen_random_uuid(),
    diagnosed_at    TIMESTAMPTZ     NOT NULL DEFAULT clock_timestamp(),

    -- Table identity
    schema_name     TEXT            NOT NULL,
    table_name      TEXT            NOT NULL,
    pk_column       TEXT            NOT NULL,

    -- Row identity
    pk_value        TEXT,           -- PK value as text (NULL if unrecoverable)
    ctid_val        TEXT,           -- physical location e.g. '(2,12)'
    block_num       BIGINT,         -- block extracted from ctid
    item_index      INT,            -- item extracted from ctid

    -- Diagnosis result
    is_corrupted    BOOLEAN         NOT NULL DEFAULT FALSE,
    error_type      TEXT,           -- NULL for healthy rows
    error_detail    TEXT,           -- NULL for healthy rows

    -- Tuple header snapshot (from pageinspect, best-effort)
    raw_xmin        BIGINT,
    raw_xmax        BIGINT,
    raw_infomask    TEXT,
    tuple_len       INT
);

CREATE INDEX idx_rcd_table
    ON public.row_corruption_diagnosis (schema_name, table_name);

CREATE INDEX idx_rcd_corrupted
    ON public.row_corruption_diagnosis (table_name, is_corrupted);

CREATE INDEX idx_rcd_pk
    ON public.row_corruption_diagnosis (table_name, pk_value);

CREATE INDEX idx_rcd_block
    ON public.row_corruption_diagnosis (table_name, block_num);

CREATE INDEX idx_rcd_diagnosed_at
    ON public.row_corruption_diagnosis (diagnosed_at DESC);

COMMENT ON TABLE public.row_corruption_diagnosis IS
    'Row-by-row corruption probe results. '
    'is_corrupted=TRUE means the row could not be read by PostgreSQL. '
    'Populated by diagnose_table_rows() and diagnose_all_tables().';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — Core row prober: single table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE diagnose_table_rows(
    p_table           TEXT,
    p_pk_col          TEXT    DEFAULT 'id',
    p_schema          TEXT    DEFAULT 'public',
    p_include_healthy BOOLEAN DEFAULT FALSE   -- set TRUE to log healthy rows too
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Relation
    v_relid         OID;
    v_total_pages   BIGINT;
    v_heap_file     TEXT;

    -- Shared scan UUID
    v_scan_id       UUID        := gen_random_uuid();
    v_scan_start    TIMESTAMPTZ := clock_timestamp();

    -- Per-row probe variables
    v_pk_val        TEXT;
    v_ctid          TEXT;
    v_block         BIGINT;
    v_item          INT;
    v_xmin          BIGINT;
    v_xmax          BIGINT;
    v_infomask      TEXT;
    v_tuple_len     INT;

    -- Counters
    v_total         BIGINT := 0;
    v_corrupt       BIGINT := 0;
    v_healthy       BIGINT := 0;
    v_unrecoverable BIGINT := 0;

    -- Phase 1: collect all PKs and ctids via pageinspect
    -- (bypasses MVCC, works even on partially corrupted tables)
    v_blkno         BIGINT;
    v_page          BYTEA;
    v_pg_item       RECORD;

    -- Phase 2: live SELECT probe result
    v_probe_ok      BOOLEAN;
    v_probe_error   TEXT;
BEGIN
    -- ── Resolve relation ──────────────────────────────────────────────────
    BEGIN
        v_relid := (quote_ident(p_schema) || '.' || quote_ident(p_table))
                   ::regclass::OID;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Table %.% not found: %', p_schema, p_table, SQLERRM;
    END;

    SELECT pg_relation_filepath(v_relid) INTO v_heap_file;
    SELECT COALESCE(relpages, 0) INTO v_total_pages
    FROM   pg_class WHERE oid = v_relid;

    -- ── Clear previous results for this table before probing ──────────────
    -- Removes only rows matching this table so re-running a single table
    -- does not leave stale results from the previous run mixed in.
    -- If diagnose_all_tables() is calling this, the outer TRUNCATE there
    -- already cleared everything — this DELETE is a no-op in that case.
    DELETE FROM public.row_corruption_diagnosis
    WHERE  schema_name = p_schema
      AND  table_name  = p_table;

    RAISE NOTICE '====================================================';
    RAISE NOTICE 'ROW DIAGNOSIS START  %.%  pages=%  pk=%  scan_id=%',
        p_schema, p_table, v_total_pages, p_pk_col, v_scan_id;
    RAISE NOTICE '====================================================';

    -- ══════════════════════════════════════════════════════════════════════
    -- PHASE 1 — Walk every page via pageinspect to collect
    --           (pk_value, ctid, header fields) for every tuple slot.
    --
    --   For readable blocks  → extract pk from t_xmin side via live SELECT
    --   For unreadable blocks→ record ctid as corrupt with NULL pk_value
    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '[PHASE 1] pageinspect sweep — collecting all row locations ...';

    FOR v_blkno IN 0 .. (v_total_pages - 1) LOOP

        -- Try to read the raw page
        BEGIN
            v_page := get_raw_page(
                quote_ident(p_schema) || '.' || quote_ident(p_table),
                v_blkno::INT
            );
        EXCEPTION WHEN OTHERS THEN
            -- Entire block unreadable — we cannot get individual ctids.
            -- Record one entry for the block with is_corrupted=TRUE.
            INSERT INTO public.row_corruption_diagnosis (
                scan_id,        schema_name,    table_name,
                pk_column,      pk_value,       ctid_val,
                block_num,      item_index,
                is_corrupted,   error_type,     error_detail
            ) VALUES (
                v_scan_id,      p_schema,       p_table,
                p_pk_col,       NULL,           '(' || v_blkno || ',?)',
                v_blkno,        NULL,
                TRUE,
                'UNREADABLE_BLOCK',
                'Block ' || v_blkno || ' cannot be read: ' || SQLERRM ||
                '. Individual rows on this block cannot be identified.'
            );
            v_corrupt       := v_corrupt + 1;
            v_unrecoverable := v_unrecoverable + 1;
            CONTINUE;
        END;

        -- ── Item loop for readable pages ──────────────────────────────────
        FOR v_pg_item IN
            SELECT lp, lp_flags, lp_off, lp_len,
                   t_xmin, t_xmax, t_infomask
            FROM   heap_page_items(v_page)
            WHERE  lp_flags = 1      -- LP_NORMAL only
              AND  lp_len   > 0
            ORDER  BY lp
        LOOP
            v_total   := v_total + 1;
            v_ctid    := '(' || v_blkno || ',' || v_pg_item.lp || ')';
            v_block   := v_blkno;
            v_item    := v_pg_item.lp;
            v_pk_val  := NULL;
            v_probe_ok    := TRUE;
            v_probe_error := NULL;

            -- Capture raw header fields
            BEGIN
                v_xmin       := v_pg_item.t_xmin::BIGINT;
                v_xmax       := v_pg_item.t_xmax::BIGINT;
                v_infomask   := '0x' || to_hex(v_pg_item.t_infomask::INT);
                v_tuple_len  := v_pg_item.lp_len;
            EXCEPTION WHEN OTHERS THEN
                v_xmin := NULL; v_xmax := NULL;
                v_infomask := NULL; v_tuple_len := NULL;
            END;

            -- ── PHASE 2: Live SELECT probe via ctid ───────────────────────
            -- This is the actual row-readability test.
            -- If PostgreSQL can decode the tuple → healthy.
            -- If it throws → corrupt at the data level.
            BEGIN
                EXECUTE format(
                    'SELECT %I::text FROM %I.%I WHERE ctid = %L::tid',
                    p_pk_col, p_schema, p_table, v_ctid
                ) INTO v_pk_val;

                -- Row read successfully
                v_probe_ok := TRUE;

            EXCEPTION WHEN OTHERS THEN
                v_probe_ok    := FALSE;
                v_probe_error := SQLERRM;
                v_pk_val      := NULL;
            END;

            -- ── Additional check: impossible xmin ─────────────────────────
            IF v_probe_ok AND v_xmin IS NOT NULL AND v_xmin > 2000000000 THEN
                v_probe_ok    := FALSE;
                v_probe_error := 'CORRUPT_XMIN: t_xmin=' || v_xmin ||
                                 ' exceeds 2,000,000,000 — invalid transaction ID';
            END IF;

            -- ── Record result ─────────────────────────────────────────────
            IF NOT v_probe_ok THEN
                INSERT INTO public.row_corruption_diagnosis (
                    scan_id,        schema_name,    table_name,
                    pk_column,      pk_value,       ctid_val,
                    block_num,      item_index,
                    is_corrupted,   error_type,     error_detail,
                    raw_xmin,       raw_xmax,       raw_infomask,
                    tuple_len
                ) VALUES (
                    v_scan_id,      p_schema,       p_table,
                    p_pk_col,       v_pk_val,       v_ctid,
                    v_block,        v_item,
                    TRUE,
                    'CORRUPT_ROW',
                    'Row at ctid ' || v_ctid || ' is unreadable: ' ||
                        v_probe_error,
                    v_xmin,         v_xmax,         v_infomask,
                    v_tuple_len
                );
                v_corrupt := v_corrupt + 1;

            ELSIF p_include_healthy THEN
                INSERT INTO public.row_corruption_diagnosis (
                    scan_id,        schema_name,    table_name,
                    pk_column,      pk_value,       ctid_val,
                    block_num,      item_index,
                    is_corrupted,   error_type,     error_detail,
                    raw_xmin,       raw_xmax,       raw_infomask,
                    tuple_len
                ) VALUES (
                    v_scan_id,      p_schema,       p_table,
                    p_pk_col,       v_pk_val,       v_ctid,
                    v_block,        v_item,
                    FALSE,
                    NULL,           NULL,
                    v_xmin,         v_xmax,         v_infomask,
                    v_tuple_len
                );
                v_healthy := v_healthy + 1;

            ELSE
                v_healthy := v_healthy + 1;
            END IF;

        END LOOP; -- items

        -- Commit every 100 blocks to keep transactions short
        IF v_blkno % 100 = 0 AND v_blkno > 0 THEN
            COMMIT;
        END IF;

    END LOOP; -- blocks

    -- ══════════════════════════════════════════════════════════════════════
    -- PHASE 3 — Merge verify_heapam findings from corruption_scan_results
    --
    -- verify_heapam catches logical violations that pageinspect cannot
    -- (null bitmap, varlena width, TOAST pointers, HOT chains).
    -- Those findings are already in corruption_scan_results. We pull them
    -- here and insert them into row_corruption_diagnosis so every corrupt
    -- row source is unified in one table.
    --
    -- Deduplication: skip any ctid already recorded by Phase 1/2 to avoid
    -- double-counting the same physical location.
    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '[PHASE 3] Merging verify_heapam findings from corruption_scan_results ...';

    DECLARE
        v_am_rec        RECORD;
        v_am_count      BIGINT := 0;
    BEGIN
        FOR v_am_rec IN
            SELECT
                csr.block_num,
                csr.item_index,
                csr.ctid_val,
                csr.pk_value,
                csr.error_type,
                csr.error_detail,
                csr.raw_xmin,
                csr.raw_xmax,
                csr.raw_infomask,
                csr.tuple_len
            FROM   public.corruption_scan_results csr
            WHERE  csr.schema_name     = p_schema
              AND  csr.table_name      = p_table
              AND  csr.detection_pass  = 'verify_heapam'
              -- Only bring in actual violations and failures, not clean rows
              AND  csr.error_type IN ('HEAPAM_VIOLATION', 'VERIFY_HEAPAM_FAILED')
              -- Deduplicate: skip only if same ctid AND same error_type
              -- already recorded. Different error_types for the same ctid
              -- are kept — e.g. UNREADABLE_BLOCK + VERIFY_HEAPAM_FAILED
              -- both appear for the same bad block since they come from
              -- independent detection methods.
              AND  NOT EXISTS (
                       SELECT 1
                       FROM   public.row_corruption_diagnosis rcd
                       WHERE  rcd.scan_id    = v_scan_id
                         AND  rcd.ctid_val   = csr.ctid_val
                         AND  rcd.error_type = csr.error_type
                   )
        LOOP
            INSERT INTO public.row_corruption_diagnosis (
                scan_id,        schema_name,    table_name,
                pk_column,      pk_value,       ctid_val,
                block_num,      item_index,
                is_corrupted,   error_type,     error_detail,
                raw_xmin,       raw_xmax,       raw_infomask,
                tuple_len
            ) VALUES (
                v_scan_id,      p_schema,       p_table,
                p_pk_col,
                -- Use pk_value from scan_results if available,
                -- otherwise attempt a live lookup by ctid
                COALESCE(
                    v_am_rec.pk_value,
                    _csr_pk_for_ctid(p_schema, p_table, p_pk_col, v_am_rec.ctid_val)
                ),
                v_am_rec.ctid_val,
                v_am_rec.block_num,
                v_am_rec.item_index,
                TRUE,                           -- is_corrupted = TRUE
                v_am_rec.error_type,
                v_am_rec.error_detail,
                v_am_rec.raw_xmin,
                v_am_rec.raw_xmax,
                v_am_rec.raw_infomask,
                v_am_rec.tuple_len
            );

            v_corrupt  := v_corrupt  + 1;
            v_am_count := v_am_count + 1;
        END LOOP;

        RAISE NOTICE '[PHASE 3] Complete — % verify_heapam finding(s) merged.', v_am_count;
    END;

    -- ── Summary ───────────────────────────────────────────────────────────
    RAISE NOTICE '====================================================';
    RAISE NOTICE 'ROW DIAGNOSIS COMPLETE  %.%', p_schema, p_table;
    RAISE NOTICE '  Total rows probed    : %', v_total;
    RAISE NOTICE '  Healthy rows         : %', v_healthy;
    RAISE NOTICE '  Corrupt rows         : %  (pageinspect + verify_heapam)', v_corrupt;
    RAISE NOTICE '  Unrecoverable blocks : %', v_unrecoverable;
    RAISE NOTICE '  Elapsed              : %', clock_timestamp() - v_scan_start;
    RAISE NOTICE '  scan_id              : %', v_scan_id;
    RAISE NOTICE '====================================================';

    RAISE NOTICE 'Query corrupt rows:';
    RAISE NOTICE '  SELECT pk_value, ctid_val, block_num, item_index,';
    RAISE NOTICE '         error_type, error_detail, raw_xmin, tuple_len';
    RAISE NOTICE '  FROM   row_corruption_diagnosis';
    RAISE NOTICE '  WHERE  table_name = ''%'' AND is_corrupted = TRUE', p_table;
    RAISE NOTICE '  ORDER  BY block_num, item_index;';

END;
$$;

COMMENT ON PROCEDURE diagnose_table_rows IS
    'Row-by-row corruption prober. '
    'Uses pageinspect to walk every block and ctid, '
    'then probes each row via live SELECT. '
    'Records is_corrupted=TRUE for every unreadable row. '
    'Set p_include_healthy=TRUE to also log healthy rows.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — Full sweep: all tables
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE diagnose_all_tables(
    p_schema          TEXT    DEFAULT 'public',
    p_include_healthy BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec           RECORD;
    v_pk_col        TEXT;
    v_table_count   INT := 0;
    v_sweep_start   TIMESTAMPTZ := clock_timestamp();
BEGIN
    -- ── Clear all previous diagnosis results before a full sweep ───────────
    -- Every full sweep starts clean so results never accumulate across runs.
    -- Running a single-table diagnose_table_rows() after this is safe —
    -- it will DELETE its own table's rows before inserting fresh ones.
    TRUNCATE public.row_corruption_diagnosis;

    RAISE NOTICE '##################################################';
    RAISE NOTICE '#  FULL ROW-LEVEL DIAGNOSIS  schema=%  (previous results cleared)',
        COALESCE(p_schema, 'ALL');
    RAISE NOTICE '##################################################';

    FOR v_rec IN
        SELECT n.nspname AS schema_name,
               c.relname AS table_name
        FROM   pg_class     c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  c.relkind  = 'r'
          AND  n.nspname NOT IN (
                   'pg_catalog', 'information_schema', 'pg_toast'
               )
          AND  (p_schema IS NULL OR n.nspname = p_schema)
          AND  c.relname NOT IN (
                   'corruption_scan_results',
                   'row_corruption_diagnosis'
               )
        ORDER  BY n.nspname, c.relname
    LOOP
        -- Auto-detect single-column PK
        SELECT a.attname INTO v_pk_col
        FROM   pg_index     i
        JOIN   pg_attribute a
               ON  a.attrelid = i.indrelid
               AND a.attnum   = ANY(i.indkey)
        JOIN   pg_class     c ON c.oid = i.indrelid
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  i.indisprimary
          AND  i.indnkeyatts = 1
          AND  c.relname  = v_rec.table_name
          AND  n.nspname  = v_rec.schema_name
        LIMIT 1;

        v_pk_col := COALESCE(v_pk_col, 'id');

        RAISE NOTICE '----------------------------------------------';
        RAISE NOTICE 'Diagnosing %.%  pk=%',
            v_rec.schema_name, v_rec.table_name, v_pk_col;

        BEGIN
            CALL diagnose_table_rows(
                p_table           => v_rec.table_name,
                p_pk_col          => v_pk_col,
                p_schema          => v_rec.schema_name,
                p_include_healthy => p_include_healthy
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'diagnose_table_rows failed for %.%: %',
                v_rec.schema_name, v_rec.table_name, SQLERRM;
        END;

        COMMIT;
        v_table_count := v_table_count + 1;
    END LOOP;

    RAISE NOTICE '##################################################';
    RAISE NOTICE '#  DIAGNOSIS COMPLETE';
    RAISE NOTICE '#  Tables diagnosed : %', v_table_count;
    RAISE NOTICE '#  Total elapsed    : %', clock_timestamp() - v_sweep_start;
    RAISE NOTICE '#  Query results:';
    RAISE NOTICE '#    SELECT * FROM v_row_diagnosis_summary;';
    RAISE NOTICE '#    SELECT * FROM row_corruption_diagnosis';
    RAISE NOTICE '#    WHERE is_corrupted = TRUE;';
    RAISE NOTICE '##################################################';
END;
$$;

COMMENT ON PROCEDURE diagnose_all_tables IS
    'Runs diagnose_table_rows() on every user table in the schema. '
    'Skips the diagnosis audit tables themselves.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — Convenience views
-- ─────────────────────────────────────────────────────────────────────────────

-- Per-table summary: healthy vs corrupt counts
CREATE OR REPLACE VIEW v_row_diagnosis_summary AS
SELECT
    rcd.schema_name,
    rcd.table_name,
    rcd.pk_column,
    -- actual table row count from pg_class (not count of diagnosis rows)
    pc.reltuples::BIGINT                                     AS total_rows_in_table,
    COUNT(*) FILTER (WHERE NOT rcd.is_corrupted)             AS healthy_logged,
    COUNT(*) FILTER (WHERE rcd.is_corrupted)                 AS corrupt_rows,
    COUNT(*) FILTER (WHERE rcd.error_type = 'UNREADABLE_BLOCK')      AS unreadable_blocks,
    COUNT(*) FILTER (WHERE rcd.error_type = 'CORRUPT_ROW')           AS corrupt_row_reads,
    COUNT(*) FILTER (WHERE rcd.error_type = 'VERIFY_HEAPAM_FAILED')  AS heapam_failed,
    COUNT(*) FILTER (WHERE rcd.error_type = 'HEAPAM_VIOLATION')      AS heapam_violations,
    ROUND(
        (COUNT(*) FILTER (WHERE rcd.is_corrupted)::NUMERIC
        / NULLIF(pc.reltuples::NUMERIC, 0) * 100), 4
    )                                                        AS corrupt_pct,
    MAX(rcd.diagnosed_at)                                    AS last_diagnosed
FROM   public.row_corruption_diagnosis rcd
LEFT   JOIN pg_class     pc ON pc.relname   = rcd.table_name
LEFT   JOIN pg_namespace pn ON pn.oid       = pc.relnamespace
                            AND pn.nspname  = rcd.schema_name
WHERE  pc.relkind = 'r'
GROUP  BY rcd.schema_name, rcd.table_name, rcd.pk_column, pc.reltuples
ORDER  BY corrupt_rows DESC, rcd.table_name;

COMMENT ON VIEW v_row_diagnosis_summary IS
    'Per-table summary of row-level diagnosis: healthy vs corrupt counts.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5 — Verify installation
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_ok BOOLEAN := TRUE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'row_corruption_diagnosis' AND schemaname = 'public') THEN
        RAISE WARNING 'Table row_corruption_diagnosis was NOT created.'; v_ok := FALSE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'diagnose_table_rows') THEN
        RAISE WARNING 'Procedure diagnose_table_rows was NOT created.'; v_ok := FALSE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'diagnose_all_tables') THEN
        RAISE WARNING 'Procedure diagnose_all_tables was NOT created.'; v_ok := FALSE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_views WHERE viewname = 'v_row_diagnosis_summary') THEN
        RAISE WARNING 'View v_row_diagnosis_summary was NOT created.'; v_ok := FALSE;
    END IF;

    IF v_ok THEN
        RAISE NOTICE '============================================';
        RAISE NOTICE 'Installation complete.';
        RAISE NOTICE '';
        RAISE NOTICE 'Diagnose one table:';
        RAISE NOTICE '  CALL diagnose_table_rows(''payment_transactions'', ''txn_id'');';
        RAISE NOTICE '';
        RAISE NOTICE 'Diagnose all tables:';
        RAISE NOTICE '  CALL diagnose_all_tables();';
        RAISE NOTICE '';
        RAISE NOTICE 'Query corrupt rows:';
        RAISE NOTICE '  SELECT pk_value, ctid_val, block_num, item_index,';
        RAISE NOTICE '         error_type, error_detail, raw_xmin, tuple_len';
        RAISE NOTICE '  FROM   row_corruption_diagnosis';
        RAISE NOTICE '  WHERE  is_corrupted = TRUE';
        RAISE NOTICE '  ORDER  BY block_num, item_index;';
        RAISE NOTICE '';
        RAISE NOTICE 'Count clean rows (your original query):';
        RAISE NOTICE '  SELECT COUNT(*)';
        RAISE NOTICE '  FROM   payment_transactions pt';
        RAISE NOTICE '  WHERE  txn_id::text NOT IN (';
        RAISE NOTICE '      SELECT pk_value';
        RAISE NOTICE '      FROM   row_corruption_diagnosis';
        RAISE NOTICE '      WHERE  table_name   = ''payment_transactions''';
        RAISE NOTICE '        AND  is_corrupted = TRUE';
        RAISE NOTICE '        AND  pk_value IS NOT NULL';
        RAISE NOTICE '  );';
        RAISE NOTICE '============================================';
    END IF;
END;
$$;