-- ============================================================================
-- CORRUPTION SCANNER v4 — PostgreSQL 18.3
-- ============================================================================
-- Changes from v3:
--   • verify_heapam (Pass 2) is now OFF by default.
--     It only runs when p_verify_heapam => TRUE is explicitly passed,
--     and only if the amcheck extension is actually installed.
--     This eliminates the VERIFY_HEAPAM_FAILED noise on every table
--     when amcheck is not installed.
--   • Extensions are auto-created (CREATE EXTENSION IF NOT EXISTS)
--     instead of raising an exception that psql silently skips.
--
-- Usage:
--   -- Pass 1 only (pageinspect, default):
--   CALL scan_all_tables_for_corruption();
--   CALL scan_table_for_corruption('payment_transactions', 'txn_id');
--
--   -- Both passes (requires amcheck):
--   CREATE EXTENSION IF NOT EXISTS amcheck;
--   CALL scan_all_tables_for_corruption(p_schema => 'public', p_verify_heapam => TRUE);
--   CALL scan_table_for_corruption('payment_transactions', 'txn_id', 'public', TRUE);
--
-- Query results:
--   SELECT * FROM v_corruption_latest;
--   SELECT * FROM v_corruption_summary;
--   TRUNCATE corruption_scan_results;  -- clear between runs
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 0 — Drop everything from old versions cleanly
-- ─────────────────────────────────────────────────────────────────────────────
DROP VIEW      IF EXISTS v_corruption_latest                          CASCADE;
DROP VIEW      IF EXISTS v_corruption_summary                         CASCADE;
DROP PROCEDURE IF EXISTS scan_all_tables_for_corruption(TEXT)         CASCADE;
DROP PROCEDURE IF EXISTS scan_all_tables_for_corruption()             CASCADE;
DROP PROCEDURE IF EXISTS scan_all_tables_for_corruption(TEXT,BOOLEAN) CASCADE;
DROP PROCEDURE IF EXISTS scan_table_for_corruption(TEXT,TEXT,TEXT)    CASCADE;
DROP PROCEDURE IF EXISTS scan_table_for_corruption(TEXT,TEXT)         CASCADE;
DROP PROCEDURE IF EXISTS scan_table_for_corruption(TEXT)              CASCADE;
DROP PROCEDURE IF EXISTS scan_table_for_corruption(TEXT,TEXT,TEXT,BOOLEAN) CASCADE;
DROP FUNCTION  IF EXISTS _csr_pk_for_ctid(TEXT,TEXT,TEXT,TEXT)        CASCADE;
DROP FUNCTION  IF EXISTS _corruption_pk_for_ctid(TEXT,TEXT,TEXT,TID)  CASCADE;
DROP TABLE     IF EXISTS public.corruption_scan_results               CASCADE;
DROP TABLE     IF EXISTS public.corruption_scan_log                   CASCADE;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — Auto-create pageinspect (required)
--           amcheck is optional — only needed for Pass 2
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pageinspect;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — Results table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.corruption_scan_results (
    id              BIGSERIAL       PRIMARY KEY,
    scan_id         UUID            NOT NULL DEFAULT gen_random_uuid(),
    detection_pass  TEXT            NOT NULL,   -- 'pageinspect' | 'verify_heapam'

    -- Table location
    schema_name     TEXT            NOT NULL,
    table_name      TEXT            NOT NULL,
    heap_file       TEXT,

    -- Physical position
    block_num       BIGINT,
    item_index      INT,
    ctid_val        TEXT,

    -- Corruption classification
    error_type      TEXT            NOT NULL,
    error_detail    TEXT,

    -- Raw tuple header values
    pk_value        TEXT,
    raw_xmin        BIGINT,
    raw_xmax        BIGINT,
    raw_infomask    TEXT,
    raw_infomask2   TEXT,
    infomask_flags  TEXT,
    lp_flags        INT,
    lp_off          INT,
    tuple_len       INT,

    scanned_at      TIMESTAMPTZ     NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_csr_table      ON public.corruption_scan_results (schema_name, table_name);
CREATE INDEX idx_csr_block      ON public.corruption_scan_results (table_name, block_num);
CREATE INDEX idx_csr_error_type ON public.corruption_scan_results (error_type);
CREATE INDEX idx_csr_pass       ON public.corruption_scan_results (detection_pass);
CREATE INDEX idx_csr_scanned_at ON public.corruption_scan_results (scanned_at DESC);

COMMENT ON TABLE public.corruption_scan_results IS
    'Central audit log for corruption found by scan_table_for_corruption() '
    'and scan_all_tables_for_corruption().';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — Helper: best-effort PK lookup for a ctid
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _csr_pk_for_ctid(
    p_schema  TEXT,
    p_table   TEXT,
    p_pk_col  TEXT,
    p_ctid    TEXT
)
RETURNS TEXT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_result TEXT;
BEGIN
    EXECUTE format(
        'SELECT %I::text FROM %I.%I WHERE ctid = %L::tid',
        p_pk_col, p_schema, p_table, p_ctid
    ) INTO v_result;
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION _csr_pk_for_ctid IS
    'Returns PK value for a ctid string. Returns NULL if tuple cannot be read.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — Core scanner: single table
--
-- Pass 1 (pageinspect) always runs.
-- Pass 2 (verify_heapam) only runs when:
--   a) p_verify_heapam = TRUE  (explicit opt-in), AND
--   b) amcheck extension is installed
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE scan_table_for_corruption(
    p_table          TEXT,
    p_pk_col         TEXT    DEFAULT 'id',
    p_schema         TEXT    DEFAULT 'public',
    p_verify_heapam  BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_relid          OID;
    v_heap_file      TEXT;
    v_total_pages    BIGINT;
    v_blkno          BIGINT;
    v_page           BYTEA;
    v_item           RECORD;
    v_am             RECORD;
    v_ctid           TEXT;

    -- Tuple header fields
    v_xmin           BIGINT;
    v_xmax           BIGINT;
    v_infomask_hex   TEXT;
    v_infomask2_hex  TEXT;
    v_infomask_flags TEXT;

    -- Detection
    v_error_type     TEXT;
    v_error_detail   TEXT;
    v_pk_val         TEXT;
    v_row_ok         BOOLEAN;

    -- amcheck availability
    v_amcheck_ok     BOOLEAN := FALSE;

    -- Scan tracking
    v_scan_id        UUID        := gen_random_uuid();
    v_scan_start     TIMESTAMPTZ := clock_timestamp();
    v_pages_scanned  BIGINT := 0;
    v_items_checked  BIGINT := 0;
    v_p1_corrupt     BIGINT := 0;
    v_p2_corrupt     BIGINT := 0;
BEGIN
    -- ── Resolve relation ──────────────────────────────────────────────────
    BEGIN
        v_relid := (
            quote_ident(p_schema) || '.' || quote_ident(p_table)
        )::regclass::OID;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Table %.% not found: %', p_schema, p_table, SQLERRM;
    END;

    SELECT pg_relation_filepath(v_relid) INTO v_heap_file;

    -- Use pg_relation_size() divided by block_size to get the true on-disk
    -- page count. pg_class.relpages is only updated by VACUUM/ANALYZE — on
    -- a freshly loaded or never-analyzed table it is 0, which causes the
    -- pageinspect loop to run zero iterations and miss all corrupt blocks.
    -- pg_relation_size() reads the actual heap file size so it is always
    -- accurate regardless of whether ANALYZE has been run.
    SELECT pg_relation_size(v_relid)
           / current_setting('block_size')::BIGINT
    INTO   v_total_pages;

    -- Safety fallback: if size returns NULL or 0, try pg_class.relpages
    IF COALESCE(v_total_pages, 0) = 0 THEN
        SELECT COALESCE(relpages, 0) INTO v_total_pages
        FROM   pg_class WHERE oid = v_relid;
    END IF;

    -- ── Check amcheck availability ────────────────────────────────────────
    IF p_verify_heapam THEN
        SELECT EXISTS (
            SELECT 1 FROM pg_extension WHERE extname = 'amcheck'
        ) INTO v_amcheck_ok;

        IF NOT v_amcheck_ok THEN
            RAISE NOTICE '[PASS 2] Skipped — amcheck not installed. '
                         'Run: CREATE EXTENSION amcheck; '
                         'then pass p_verify_heapam => TRUE.';
        END IF;
    END IF;

    RAISE NOTICE '====================================================';
    RAISE NOTICE 'SCAN START  %.%  pages=%  pk=%  heapam=%  scan_id=%',
        p_schema, p_table, v_total_pages, p_pk_col,
        CASE WHEN p_verify_heapam AND v_amcheck_ok THEN 'ON' ELSE 'OFF' END,
        v_scan_id;
    RAISE NOTICE '====================================================';

    -- ══════════════════════════════════════════════════════════════════════
    -- PASS 1 — pageinspect: physical page + tuple header inspection
    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '[PASS 1] pageinspect — physical page scan ...';

    FOR v_blkno IN 0 .. (v_total_pages - 1) LOOP

        -- Page-level try/catch
        -- If get_raw_page() fails (checksum mismatch, zeroed block, bad LSN),
        -- record the entire block as UNREADABLE_PAGE and continue.
        BEGIN
            v_page := get_raw_page(
                quote_ident(p_schema) || '.' || quote_ident(p_table),
                v_blkno::INT
            );
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO public.corruption_scan_results (
                scan_id,      detection_pass,
                schema_name,  table_name,   heap_file,
                block_num,    item_index,   ctid_val,
                error_type,   error_detail
            ) VALUES (
                v_scan_id,    'pageinspect',
                p_schema,     p_table,      v_heap_file,
                v_blkno,      NULL,         NULL,
                'UNREADABLE_PAGE',
                'get_raw_page() failed on block ' || v_blkno || ': ' || SQLERRM
            );
            v_p1_corrupt := v_p1_corrupt + 1;
            CONTINUE;
        END;

        v_pages_scanned := v_pages_scanned + 1;

        -- Item-level loop
        -- heap_page_items() reads from the in-memory BYTEA — no disk re-read.
        -- LP_NORMAL (lp_flags=1) with lp_len > 0 only.
        FOR v_item IN
            SELECT *
            FROM   heap_page_items(v_page)
            WHERE  lp_flags = 1
              AND  lp_len   > 0
            ORDER  BY lp
        LOOP
            v_items_checked  := v_items_checked + 1;
            v_ctid           := '(' || v_blkno || ',' || v_item.lp || ')';
            v_error_type     := NULL;
            v_error_detail   := NULL;
            v_pk_val         := NULL;
            v_xmin           := NULL;
            v_xmax           := NULL;
            v_infomask_hex   := NULL;
            v_infomask2_hex  := NULL;
            v_infomask_flags := NULL;

            -- Row-level try/catch
            -- Try to read the live tuple via ctid through normal access path.
            -- If this throws, the row data itself is corrupt/unreadable.
            v_row_ok := TRUE;
            BEGIN
                EXECUTE format(
                    'SELECT %I::text FROM %I.%I WHERE ctid = %L::tid',
                    p_pk_col, p_schema, p_table, v_ctid
                ) INTO v_pk_val;
            EXCEPTION WHEN OTHERS THEN
                v_row_ok       := FALSE;
                v_error_type   := 'CORRUPT_ROW';
                v_error_detail :=
                    'Row at ctid ' || v_ctid ||
                    ' cannot be read by PostgreSQL: ' || SQLERRM;
            END;

            -- Extract raw tuple header fields
            BEGIN
                v_xmin          := v_item.t_xmin::BIGINT;
                v_xmax          := v_item.t_xmax::BIGINT;
                v_infomask_hex  := '0x' || to_hex(v_item.t_infomask::INT);
                v_infomask2_hex := '0x' || to_hex(v_item.t_infomask2::INT);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;

            -- Check: CORRUPT_XMIN
            -- t_xmin > 2,000,000,000 is an impossibly large transaction ID.
            IF v_error_type IS NULL
               AND v_xmin IS NOT NULL
               AND v_xmin > 2000000000
            THEN
                v_error_type   := 'CORRUPT_XMIN';
                v_error_detail :=
                    'Row at ctid ' || v_ctid ||
                    ' has t_xmin=' || v_xmin ||
                    ' which exceeds 2,000,000,000 — invalid transaction ID.';
            END IF;

            -- Check: CORRUPT_INFOMASK
            -- HEAP_XMIN_COMMITTED + HEAP_XMIN_INVALID cannot both be set.
            IF v_error_type IS NULL
               AND v_item.t_infomask IS NOT NULL
            THEN
                BEGIN
                    SELECT string_agg(flag, ', ' ORDER BY flag)
                    INTO   v_infomask_flags
                    FROM   heap_tuple_infomask_flags(
                               v_item.t_infomask,
                               v_item.t_infomask2
                           ) AS f(flag);
                EXCEPTION WHEN OTHERS THEN
                    v_infomask_flags := NULL;
                END;

                IF v_infomask_flags IS NOT NULL
                   AND v_infomask_flags LIKE '%HEAP_XMIN_COMMITTED%'
                   AND v_infomask_flags LIKE '%HEAP_XMIN_INVALID%'
                THEN
                    v_error_type   := 'CORRUPT_INFOMASK';
                    v_error_detail :=
                        'Row at ctid ' || v_ctid ||
                        ' has contradictory flags: [' || v_infomask_flags ||
                        ']. HEAP_XMIN_COMMITTED and HEAP_XMIN_INVALID '
                        'cannot both be set.';
                END IF;
            END IF;

            -- Record any finding
            IF v_error_type IS NOT NULL THEN
                IF v_row_ok AND v_pk_val IS NULL THEN
                    v_pk_val := _csr_pk_for_ctid(
                        p_schema, p_table, p_pk_col, v_ctid
                    );
                END IF;

                INSERT INTO public.corruption_scan_results (
                    scan_id,         detection_pass,
                    schema_name,     table_name,      heap_file,
                    block_num,       item_index,      ctid_val,
                    error_type,      error_detail,
                    pk_value,        raw_xmin,        raw_xmax,
                    raw_infomask,    raw_infomask2,   infomask_flags,
                    lp_flags,        lp_off,          tuple_len
                ) VALUES (
                    v_scan_id,       'pageinspect',
                    p_schema,        p_table,         v_heap_file,
                    v_blkno,         v_item.lp,       v_ctid,
                    v_error_type,    v_error_detail,
                    v_pk_val,        v_xmin,          v_xmax,
                    v_infomask_hex,  v_infomask2_hex, v_infomask_flags,
                    v_item.lp_flags, v_item.lp_off,   v_item.lp_len
                );
                v_p1_corrupt := v_p1_corrupt + 1;
            END IF;

        END LOOP; -- items

        -- No COMMIT here — safe to be called from scan_all_tables_for_corruption()

    END LOOP; -- blocks

    RAISE NOTICE '[PASS 1] Complete — pages: %  items: %  corrupt: %',
        v_pages_scanned, v_items_checked, v_p1_corrupt;

    -- ══════════════════════════════════════════════════════════════════════
    -- PASS 2 — verify_heapam (amcheck): only when explicitly enabled
    --          AND amcheck extension is installed
    -- ══════════════════════════════════════════════════════════════════════
    IF p_verify_heapam AND v_amcheck_ok THEN
        RAISE NOTICE '[PASS 2] verify_heapam — logical consistency scan ...';

        BEGIN
            FOR v_am IN
                SELECT
                    blkno,
                    offnum,
                    '(' || blkno || ',' || offnum || ')' AS ctid_text,
                    msg
                FROM verify_heapam(
                    relation      => v_relid,
                    on_error_stop => FALSE,
                    check_toast   => TRUE,
                    skip          => 'none'
                )
            LOOP
                INSERT INTO public.corruption_scan_results (
                    scan_id,         detection_pass,
                    schema_name,     table_name,      heap_file,
                    block_num,       item_index,      ctid_val,
                    error_type,      error_detail,
                    pk_value
                ) VALUES (
                    v_scan_id,       'verify_heapam',
                    p_schema,        p_table,         v_heap_file,
                    v_am.blkno,      v_am.offnum,     v_am.ctid_text,
                    'HEAPAM_VIOLATION',
                    v_am.msg,
                    _csr_pk_for_ctid(
                        p_schema, p_table, p_pk_col, v_am.ctid_text
                    )
                );
                v_p2_corrupt := v_p2_corrupt + 1;
            END LOOP;

        EXCEPTION WHEN OTHERS THEN
            -- The error message contains the block number, e.g.:
            --   "invalid page in block 2 of relation base/5/16482"
            -- Extract it so block_num and ctid_val are populated
            -- instead of being left NULL.
            DECLARE
                v_fail_block  BIGINT;
                v_fail_ctid   TEXT;
                v_sqlerrm     TEXT := SQLERRM;
            BEGIN
                v_fail_block := (
                    regexp_match(v_sqlerrm, 'block\s+(\d+)')
                )[1]::BIGINT;

                IF v_fail_block IS NOT NULL THEN
                    v_fail_ctid := '(' || v_fail_block || ',?)';
                END IF;

                INSERT INTO public.corruption_scan_results (
                    scan_id,      detection_pass,
                    schema_name,  table_name,   heap_file,
                    block_num,    item_index,   ctid_val,
                    error_type,   error_detail
                ) VALUES (
                    v_scan_id,    'verify_heapam',
                    p_schema,     p_table,      v_heap_file,
                    v_fail_block, NULL,         v_fail_ctid,
                    'VERIFY_HEAPAM_FAILED',
                    'verify_heapam() failed on ' ||
                        p_schema || '.' || p_table || ': ' || v_sqlerrm
                );
                v_p2_corrupt := v_p2_corrupt + 1;
            END;
        END;

        RAISE NOTICE '[PASS 2] Complete — logical violations: %', v_p2_corrupt;
    ELSE
        RAISE NOTICE '[PASS 2] Skipped (pass p_verify_heapam => TRUE to enable).';
    END IF;

    -- ── Final summary ─────────────────────────────────────────────────────
    RAISE NOTICE '====================================================';
    RAISE NOTICE 'SCAN COMPLETE  %.%', p_schema, p_table;
    RAISE NOTICE '  Pages scanned        : %', v_pages_scanned;
    RAISE NOTICE '  Items checked        : %', v_items_checked;
    RAISE NOTICE '  Pass 1 findings      : % (pageinspect)',   v_p1_corrupt;
    RAISE NOTICE '  Pass 2 findings      : % (verify_heapam)', v_p2_corrupt;
    RAISE NOTICE '  Total corrupt items  : %', v_p1_corrupt + v_p2_corrupt;
    RAISE NOTICE '  Elapsed              : %', clock_timestamp() - v_scan_start;
    RAISE NOTICE '  scan_id              : %', v_scan_id;
    RAISE NOTICE '====================================================';

END;
$$;

COMMENT ON PROCEDURE scan_table_for_corruption IS
    'Two-pass corruption scanner. '
    'Pass 1 (pageinspect) always runs. '
    'Pass 2 (verify_heapam) only runs when p_verify_heapam => TRUE '
    'AND amcheck extension is installed.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5 — Full database sweep
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE scan_all_tables_for_corruption(
    p_schema         TEXT    DEFAULT 'public',
    p_verify_heapam  BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec           RECORD;
    v_pk_col        TEXT;
    v_table_count   INT  := 0;
    v_error_count   INT  := 0;
    v_sweep_start   TIMESTAMPTZ := clock_timestamp();
BEGIN
    -- ── Clear previous results before starting a fresh sweep ──────────────
    -- Without this, every run appends to the table so v_corruption_summary
    -- shows multiplied counts (2 runs = 2x rows, 3 runs = 3x rows).
    -- If you want to retain history across runs, comment out this line
    -- and instead filter by scan_id or scanned_at in your own queries.
    TRUNCATE public.corruption_scan_results;

    RAISE NOTICE '##################################################';
    RAISE NOTICE '#  FULL DATABASE SWEEP  schema=%  heapam=%',
        COALESCE(p_schema, 'ALL'),
        CASE WHEN p_verify_heapam THEN 'ON' ELSE 'OFF' END;
    RAISE NOTICE '#  Previous results cleared (TRUNCATE)';
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
        -- Auto-detect single-column primary key
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
        RAISE NOTICE 'Scanning %.%  pk=%',
            v_rec.schema_name, v_rec.table_name, v_pk_col;

        BEGIN
            CALL scan_table_for_corruption(
                p_table         => v_rec.table_name,
                p_pk_col        => v_pk_col,
                p_schema        => v_rec.schema_name,
                p_verify_heapam => p_verify_heapam
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING
                'scan_table_for_corruption failed for %.%: %',
                v_rec.schema_name, v_rec.table_name, SQLERRM;
            v_error_count := v_error_count + 1;
        END;

        -- COMMIT between tables (outer level — not nested)
        COMMIT;

        v_table_count := v_table_count + 1;
    END LOOP;

    RAISE NOTICE '##################################################';
    RAISE NOTICE '#  SWEEP COMPLETE';
    RAISE NOTICE '#  Tables scanned   : %', v_table_count;
    RAISE NOTICE '#  Scan errors      : %', v_error_count;
    RAISE NOTICE '#  Total elapsed    : %', clock_timestamp() - v_sweep_start;
    RAISE NOTICE '#  Query results    :';
    RAISE NOTICE '#    SELECT * FROM v_corruption_latest;';
    RAISE NOTICE '#    SELECT * FROM v_corruption_summary;';
    RAISE NOTICE '##################################################';
END;
$$;

COMMENT ON PROCEDURE scan_all_tables_for_corruption IS
    'Full database sweep. Pass 2 (verify_heapam) is OFF by default. '
    'To enable: CALL scan_all_tables_for_corruption(p_verify_heapam => TRUE); '
    'Requires amcheck: CREATE EXTENSION amcheck;';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6 — Convenience views
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_corruption_latest AS
-- No time-window filter needed: scan_all_tables_for_corruption() TRUNCATEs
-- the table at the start of every sweep, so ALL rows here are always from
-- the latest run. A time-window caused large tables (scan > 5 seconds) to
-- have their early Pass 1 findings silently excluded from the view.
SELECT
    id,
    detection_pass,
    schema_name,
    table_name,
    block_num,
    item_index,
    ctid_val,
    pk_value,
    error_type,
    error_detail,
    raw_xmin,
    raw_xmax,
    raw_infomask,
    raw_infomask2,
    infomask_flags,
    lp_flags,
    lp_off,
    tuple_len,
    scan_id,
    scanned_at
FROM   public.corruption_scan_results
ORDER  BY schema_name, table_name,
          detection_pass, block_num, item_index;

COMMENT ON VIEW v_corruption_latest IS
    'All results from the current (most recent) scan run. '
    'Safe to use without a time filter because scan_all_tables_for_corruption() '
    'TRUNCATEs the table before every sweep.';


CREATE OR REPLACE VIEW v_corruption_summary AS
-- No time-window filter needed: scan_all_tables_for_corruption() TRUNCATEs
-- the table before every sweep so all rows are always from the latest run.
-- A time-window caused Pass 1 findings from large tables (scan > 5 seconds)
-- to be excluded — blocks found early in a long scan fell outside the window.
SELECT
    schema_name,
    table_name,
    detection_pass,
    error_type,
    COUNT(*)                    AS occurrences,
    COUNT(DISTINCT block_num)   AS affected_blocks,
    MIN(block_num)              AS first_block,
    MAX(block_num)              AS last_block,
    MAX(scanned_at)             AS last_scanned
FROM   public.corruption_scan_results
GROUP  BY schema_name, table_name, detection_pass, error_type
ORDER  BY occurrences DESC;

COMMENT ON VIEW v_corruption_summary IS
    'Aggregated corruption counts per table, pass, and error type. '
    'Safe without a time filter because scan_all_tables_for_corruption() '
    'TRUNCATEs the table before every sweep.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 7 — Verify installation
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_ok BOOLEAN := TRUE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_tables   WHERE tablename  = 'corruption_scan_results' AND schemaname = 'public') THEN RAISE WARNING 'Table not created.';      v_ok := FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc     WHERE proname    = 'scan_table_for_corruption')                         THEN RAISE WARNING 'Procedure 1 not created.'; v_ok := FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc     WHERE proname    = 'scan_all_tables_for_corruption')                    THEN RAISE WARNING 'Procedure 2 not created.'; v_ok := FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_views    WHERE viewname   = 'v_corruption_latest')                               THEN RAISE WARNING 'View 1 not created.';      v_ok := FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_views    WHERE viewname   = 'v_corruption_summary')                              THEN RAISE WARNING 'View 2 not created.';      v_ok := FALSE; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname   = 'pageinspect')                                       THEN RAISE WARNING 'pageinspect not installed.'; v_ok := FALSE; END IF;

    IF v_ok THEN
        RAISE NOTICE '============================================';
        RAISE NOTICE 'Installation complete. All objects created.';
        RAISE NOTICE '';
        RAISE NOTICE 'Pass 1 only (default):';
        RAISE NOTICE '  CALL scan_all_tables_for_corruption();';
        RAISE NOTICE '';
        RAISE NOTICE 'Pass 1 + Pass 2 (requires amcheck):';
        RAISE NOTICE '  CREATE EXTENSION amcheck;';
        RAISE NOTICE '  CALL scan_all_tables_for_corruption(p_verify_heapam => TRUE);';
        RAISE NOTICE '============================================';
    END IF;
END;
$$;
