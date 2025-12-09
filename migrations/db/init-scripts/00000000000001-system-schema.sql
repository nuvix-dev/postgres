-- migrate:up

-- Create schemas
create schema if not exists system authorization nuvix_admin;
create schema if not exists core authorization nuvix_admin;

-- Schemas metadata table
CREATE TABLE IF NOT EXISTS system.schemas (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    type VARCHAR(20) NOT NULL,
    enabled BOOLEAN DEFAULT true,
    description TEXT,
    metadata JSONB DEFAULT '{}' NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Indexes for schemas
CREATE INDEX IF NOT EXISTS schema_name_index ON system.schemas (name);
CREATE UNIQUE INDEX IF NOT EXISTS schema_name_type_index ON system.schemas (name, type);
CREATE INDEX IF NOT EXISTS schema_id_index ON system.schemas (id);
CREATE INDEX IF NOT EXISTS schema_enabled_index ON system.schemas (enabled);


-- Tables metadata (managed tables)
CREATE TABLE IF NOT EXISTS system.tables (
    id BIGSERIAL PRIMARY KEY,
    oid OID NOT NULL UNIQUE,                     -- Postgres table OID
    name TEXT NOT NULL,                          -- Current name of the table
    perms_oid OID,                               -- OID of related _perms table
    schema_id BIGINT NOT NULL REFERENCES system.schemas(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Indexes for tables
CREATE UNIQUE INDEX idx_tables_oid ON system.tables (oid);
CREATE INDEX idx_tables_schema_id ON system.tables (schema_id);
CREATE INDEX idx_tables_name_schema_id ON system.tables (name, schema_id);

-- api logs
CREATE TABLE IF NOT EXISTS system.api_logs (
    id BIGSERIAL PRIMARY KEY,
    request_id UUID NOT NULL,
    method VARCHAR(10) NOT NULL,
    path TEXT NOT NULL,
    status SMALLINT NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    client_ip INET,
    user_agent TEXT,
    url TEXT,
    latency_ms DOUBLE PRECISION,
    region VARCHAR(50),
    error TEXT,
    resource VARCHAR(50),
    metadata JSONB
);

CREATE INDEX idx_api_logs_timestamp ON system.api_logs (timestamp DESC);
CREATE INDEX idx_api_logs_request_id ON system.api_logs (request_id);
CREATE INDEX idx_api_logs_status_ts ON system.api_logs (status, timestamp DESC);
CREATE INDEX idx_api_logs_metadata ON system.api_logs USING GIN (metadata);

alter user nuvix_admin SET search_path TO system, core, auth, extensions;

-- Create functions 

CREATE OR REPLACE FUNCTION system.is_managed_schema(schema_name text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = system, pg_catalog
AS $$
DECLARE
    schema_exists boolean;
BEGIN
    -- Check if the schema exists and is of type 'managed'
    SELECT EXISTS (
        SELECT 1 FROM system.schemas
        WHERE name = schema_name AND type = 'managed'
    ) INTO schema_exists;
    RETURN schema_exists;
END;
$$;

-- System helper: create or update a schema record
CREATE OR REPLACE FUNCTION system.create_schema(
    schema_name TEXT,
    schema_type TEXT,
    schema_description TEXT DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    new_schema_id BIGINT;
BEGIN
    -- create the schema in Postgres if it doesn't exist
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', schema_name);

    -- insert into metadata table
    INSERT INTO system.schemas (name, type, description)
    VALUES (schema_name, schema_type, schema_description)
    ON CONFLICT (name) DO UPDATE
        SET type = EXCLUDED.type,
            description = EXCLUDED.description,
            updated_at = NOW()
    RETURNING id INTO new_schema_id;

    -- Apply baseline permissions for the schema
    PERFORM system.set_schema_permissions(schema_name, schema_type);

    RETURN new_schema_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION system.create_schema(TEXT, TEXT, TEXT) TO postgres;

-- System helper: apply baseline API grants to a schema
CREATE OR REPLACE FUNCTION system.set_schema_permissions(
    p_schema text,
    p_type text -- 'document' | 'managed' | 'unmanaged'
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Validate schema type
    IF p_type NOT IN ('document', 'managed', 'unmanaged') THEN
        RAISE EXCEPTION 'Invalid schema type: %. Must be document, managed, or unmanaged.', p_type;
    END IF;

    -- Make sure schema is owned by postgres
    EXECUTE format('ALTER SCHEMA %I OWNER TO postgres;', p_schema);

    -- Revoke everything first
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC, postgres, anon, authenticated, service_role;', p_schema);
    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated, service_role;', p_schema);
    EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated, service_role;', p_schema);
    EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated, service_role;', p_schema);
    EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated, service_role;', p_schema);

    -- Always grant full to nuvix + nuvix_admin
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('GRANT ALL ON ALL FUNCTIONS IN SCHEMA %I TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('GRANT ALL ON ALL ROUTINES IN SCHEMA %I TO nuvix_admin, nuvix;', p_schema);

    -- Defaults for nuvix + nuvix_admin
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON TABLES TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON SEQUENCES TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON FUNCTIONS TO nuvix_admin, nuvix;', p_schema);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON ROUTINES TO nuvix_admin, nuvix;', p_schema);

    IF p_type = 'document' THEN
        -- postgres = read-only
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT EXECUTE ON ALL ROUTINES IN SCHEMA %I TO postgres;', p_schema);

        -- Defaults for postgres
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON TABLES TO postgres;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON SEQUENCES TO postgres;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO postgres;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT EXECUTE ON ROUTINES TO postgres;', p_schema);

        -- anon + authenticated + service_role: no access

    ELSE
        -- postgres = full access
        EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT ALL ON ALL FUNCTIONS IN SCHEMA %I TO postgres;', p_schema);
        EXECUTE format('GRANT ALL ON ALL ROUTINES IN SCHEMA %I TO postgres;', p_schema);

        -- Defaults for postgres (ensures new tables/seqs auto-grant)
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON TABLES TO postgres;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON SEQUENCES TO postgres;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON FUNCTIONS TO postgres;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON ROUTINES TO postgres;', p_schema);

        -- anon + authenticated + service_role = read/write (but no CREATE/DROP)
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('GRANT EXECUTE ON ALL ROUTINES IN SCHEMA %I TO anon, authenticated, service_role;', p_schema);

        -- Defaults for anon + authenticated + service_role (new objects created by postgres)
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;', p_schema);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT EXECUTE ON ROUTINES TO anon, authenticated, service_role;', p_schema);
    END IF;
END;
$$;

-- System helper: delete related perms rows
CREATE OR REPLACE FUNCTION system.on_managed_table_row_delete()
RETURNS TRIGGER AS $$
DECLARE
    perms_table_oid oid;
    schema_name text;
    table_name text;
BEGIN
    -- Get the schema and table name of the managed table
    SELECT
        n.nspname, c.relname
    INTO
        schema_name, table_name
    FROM
        pg_class c
    JOIN
        pg_namespace n ON n.oid = c.relnamespace
    WHERE
        c.oid = TG_RELID;

    -- Look up the corresponding _perms table OID from our metadata
    SELECT
        t.perms_oid
    INTO
        perms_table_oid
    FROM
        system.tables t
    JOIN
        system.schemas s ON t.schema_id = s.id
    WHERE
        s.name = schema_name AND t.name = table_name;

    -- If the _perms table exists, delete the row
    IF perms_table_oid IS NOT NULL THEN
        EXECUTE format('DELETE FROM %I.%I WHERE row_id = $1', schema_name, table_name || '_perms')
        USING OLD._id;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- System helper: apply rls policies for managed schema
CREATE OR REPLACE FUNCTION system.apply_table_policies(tbl regclass)
RETURNS void AS $$
DECLARE
    perm text;
    policy_name text;
    sql text;
BEGIN
    -- Enable RLS always
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY;', tbl);

    -- Loop over CRUD permissions
    FOR perm IN SELECT unnest(ARRAY['read','create','update','delete']) LOOP
        policy_name := format('nx_table_%s', perm);

        -- Drop existing
        EXECUTE format('DROP POLICY IF EXISTS %I ON %s;', policy_name, tbl);

        -- Build correct clause depending on action
        IF perm = 'read' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR SELECT
                TO anon, authenticated
                USING (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE p.row_id IS NULL
                          AND p.permission = 'read'
                          AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl);

        ELSIF perm = 'create' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR INSERT
                TO anon, authenticated
                WITH CHECK (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE p.row_id IS NULL
                          AND p.permission = 'create'
                          AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl);

        ELSIF perm = 'update' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR UPDATE
                TO anon, authenticated
                USING (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE p.row_id IS NULL
                          AND p.permission = 'update'
                          AND auth.roles() && p.roles
                    )
                )
                WITH CHECK (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE p.row_id IS NULL
                          AND p.permission = 'update'
                          AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl, tbl);

        ELSIF perm = 'delete' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR DELETE
                TO anon, authenticated
                USING (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE p.row_id IS NULL
                          AND p.permission = 'delete'
                          AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl);
        END IF;

        -- Execute create policy
        EXECUTE sql;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- System helper: when create table on managed schema
CREATE OR REPLACE FUNCTION SYSTEM.ON_MANAGED_TABLE_CREATE () 
RETURNS EVENT_TRIGGER 
LANGUAGE PLPGSQL 
SECURITY DEFINER
SET search_path = system, pg_catalog 
AS $$
DECLARE
  cmd record;
  sname text;
  tname text;
  is_managed boolean;
  has_id boolean;
  col_type text;
  is_identity boolean;
  has_default boolean;
  tbl_oid oid;
  perms_oid oid;
  schema_id bigint;
  idx_suffix text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
BEGIN
  FOR cmd IN
    SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE TABLE' AND object_type = 'table'
  LOOP
    sname := cmd.schema_name;
    tname := split_part(cmd.object_identity, '.', 2);

    -- Skip internal/system schemas and perms tables
    CONTINUE WHEN tname ILIKE '%_perms'
           OR sname ILIKE 'pg_%'
           OR sname IN ('information_schema', 'system', 'extensions');

    -- Only act for managed schemas
    SELECT system.is_managed_schema(sname) INTO is_managed;
    IF NOT is_managed THEN
      CONTINUE;
    END IF;

    -- Get schema_id for linking
    SELECT id INTO schema_id
    FROM system.schemas
    WHERE name = sname;

    -- If schema_id not found, skip or raise? Assume exists for managed.
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    -- Check for _id presence, type, identity, and default
    SELECT EXISTS (
      SELECT 1 
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = sname 
        AND c.relname = tname 
        AND a.attname = '_id' 
        AND a.attnum > 0
    ) INTO has_id;

    IF has_id THEN
      SELECT pg_catalog.format_type(a.atttypid, a.atttypmod) INTO col_type
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = sname 
        AND c.relname = tname 
        AND a.attname = '_id';

      SELECT a.attidentity != '' INTO is_identity
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = sname 
        AND c.relname = tname 
        AND a.attname = '_id';

      SELECT a.atthasdef INTO has_default
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = sname 
        AND c.relname = tname 
        AND a.attname = '_id';
    END IF;

    -- Enforce _id as bigint GENERATED ALWAYS AS IDENTITY
    PERFORM set_config('system.is_managed_table_create', 'true', true);
    IF NOT has_id THEN
      EXECUTE format(
        'ALTER TABLE %I.%I ADD COLUMN _id BIGINT GENERATED ALWAYS AS IDENTITY',
        sname, tname
      );
    ELSE
      IF col_type != 'bigint' THEN
        EXECUTE format(
          'ALTER TABLE %I.%I ALTER COLUMN _id TYPE BIGINT USING _id::BIGINT',
          sname, tname
        );
      END IF;

      IF NOT is_identity THEN
        IF has_default THEN
          EXECUTE format(
            'ALTER TABLE %I.%I ALTER COLUMN _id DROP DEFAULT',
            sname, tname
          );
        END IF;
        EXECUTE format(
          'ALTER TABLE %I.%I ALTER COLUMN _id ADD GENERATED ALWAYS AS IDENTITY',
          sname, tname
        );
      END IF;
    END IF;

    -- Add unique index on _id if not exists
    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.%I (_id)',
      tname || idx_suffix || '_id_key', sname, tname
    );
    PERFORM set_config('system.is_managed_table_create', 'false', true);

    -- Create <table>_perms if not exists
    PERFORM set_config('system.skip_perms_check', 'true', true);
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I.%I_perms (
             id BIGSERIAL PRIMARY KEY,
             roles TEXT[] NOT NULL,
             permission TEXT NOT NULL,
             row_id BIGINT DEFAULT NULL,
             extra JSONB DEFAULT NULL,
             created_at TIMESTAMPTZ DEFAULT NOW(),
             updated_at TIMESTAMPTZ DEFAULT NOW(),
             CONSTRAINT chk_permission CHECK (permission IN (''create'',''read'',''update'',''delete''))
         )',
        sname, tname
    );

    -- Remove all privileges and allow only SELECT to anon & authenticated
    EXECUTE format('REVOKE ALL ON TABLE %I.%I_perms FROM anon, authenticated', sname, tname);
    EXECUTE format('GRANT SELECT ON TABLE %I.%I_perms TO anon, authenticated', sname, tname);

    -- Also restrict the backing sequence created by BIGSERIAL
    EXECUTE format('REVOKE ALL ON SEQUENCE %I.%I FROM anon, authenticated', sname, tname || '_perms_id_seq');
    EXECUTE format('GRANT SELECT ON SEQUENCE %I.%I TO anon, authenticated', sname, tname || '_perms_id_seq');
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I.%I_perms TO postgres, service_role, nuvix_admin', sname, tname);

    PERFORM set_config('system.skip_perms_check', 'false', true);

    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I_%s_perms_roles_gin_idx ON %I.%I_perms USING GIN (roles)',
      tname, idx_suffix, sname, tname
    );
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I_%s_perms_perm_row_idx ON %I.%I_perms (permission, row_id)',
      tname, idx_suffix, sname, tname
    );

    EXECUTE format(
      'COMMENT ON TABLE %I.%I_perms IS %L',
      sname, tname, 'Permission system for ' || sname || '.' || tname
    );

    -- apply rls system 
    EXECUTE format('SELECT system.apply_table_policies(%L)', sname || '.' || tname);

    -- apply on row delete trigger
    EXECUTE format(
        'CREATE TRIGGER on_row_delete '
        'AFTER DELETE ON %I.%I '
        'FOR EACH ROW '
        'EXECUTE FUNCTION system.on_managed_table_row_delete()',
        sname, tname
    );

    -- Lookup OIDs
    SELECT c.oid INTO tbl_oid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = sname AND c.relname = tname;

    SELECT c.oid INTO perms_oid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = sname AND c.relname = tname || '_perms';

    -- Insert into system.tables metadata
    INSERT INTO system.tables (oid, name, perms_oid, schema_id)
    VALUES (tbl_oid, tname, perms_oid, schema_id)
    ON CONFLICT (oid) DO UPDATE
      SET name = EXCLUDED.name,
          perms_oid = EXCLUDED.perms_oid,
          schema_id = EXCLUDED.schema_id,
          updated_at = NOW();
  END LOOP;
END;
$$;

DROP EVENT TRIGGER IF EXISTS ON_MANAGED_TABLE_CREATE;

CREATE EVENT TRIGGER ON_MANAGED_TABLE_CREATE ON DDL_COMMAND_END WHEN TAG IN ('CREATE TABLE')
EXECUTE FUNCTION SYSTEM.ON_MANAGED_TABLE_CREATE ();

CREATE OR REPLACE FUNCTION system.on_managed_table_alter()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = system, pg_catalog
AS $$
DECLARE
    cmd RECORD;
    tbl RECORD;
    schema_rec RECORD;

    base_oid OID;
    perms_oid OID;
    target_is_perms BOOLEAN := FALSE;
    target_is_managed BOOLEAN := FALSE;

    -- catalog values after the DDL (available because DDL_COMMAND_END)
    relname_after TEXT;
    nspname_after TEXT;
    id_column_exists BOOLEAN;
BEGIN
    -- Iterate affected commands (only those with tag ALTER TABLE since trigger created with TAG IN ('ALTER TABLE'))
    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP

        -- cmd.objid is the OID of the relation (table) targeted by the ALTER TABLE
        IF cmd.objid IS NULL THEN
            -- Nothing we can do (could be statements not tied to a single oid)
            CONTINUE;
        END IF;

        -- Find if this oid corresponds to a managed table's base or perms table.
        -- First, look for a match on perms_oid (someone targeting the perms table)
        SELECT t.*, s.name AS schema_name, s.type AS schema_type
        INTO tbl
        FROM system.tables t
        JOIN system.schemas s ON t.schema_id = s.id
        WHERE t.perms_oid = cmd.objid
        LIMIT 1;

        IF FOUND THEN
            target_is_perms := TRUE;
            base_oid := tbl.oid;        -- base table oid (for reference)
            perms_oid := tbl.perms_oid; -- equals cmd.objid
            target_is_managed := (tbl.schema_type = 'managed');
        ELSE
            -- Not perms; check if it's a base table
            SELECT t.*, s.name AS schema_name, s.type AS schema_type, s.enabled AS schema_enabled
            INTO tbl
            FROM system.tables t
            JOIN system.schemas s ON t.schema_id = s.id
            WHERE t.oid = cmd.objid
            LIMIT 1;

            IF FOUND THEN
                target_is_perms := FALSE;
                base_oid := tbl.oid;
                perms_oid := tbl.perms_oid;
                target_is_managed := (tbl.schema_type = 'managed');
            ELSE
                -- Not in system.tables, ignore (not a managed table)
                CONTINUE;
            END IF;
        END IF;

        -- If schema not enabled or not managed, skip
        IF NOT target_is_managed THEN
            CONTINUE;
        END IF;

        -- Now inspect the catalog state AFTER the DDL (trigger is DDL_COMMAND_END)
        SELECT c.relname, n.nspname
        INTO relname_after, nspname_after
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.oid = cmd.objid
        LIMIT 1;

        -- If relname_after is null, the table no longer exists (e.g., DROP followed by CREATE?), treat defensively
        IF relname_after IS NULL THEN
            RAISE EXCEPTION 'Managed table %.% seems to be dropped or inaccessible as part of the DDL. This operation is not allowed.',
                tbl.schema_name, tbl.name;
        END IF;

        /*
         * CASE A: Target is the _perms table -> always block direct ALTERs to perms table
         * Reason: perms table schema and behavior must be controlled by Nuvix, not by users.
         * We allow perms table renaming *only* when the base table rename happens (handled below).
         */
        IF target_is_perms THEN
			IF relname_after = tbl.name || '_perms' THEN
				CONTINUE;
			END IF;
            -- Abort the transaction
            RAISE EXCEPTION 'Permission denied: Direct alterations to _perms table %.% are not allowed. Alter the main table instead.',
                nspname_after, relname_after;
        END IF;

        /*
         * CASE B: Target is a base managed table.
         * - Detect if the base table was renamed (catalog relname differs from stored metadata)
         * - Detect if _id column was removed/renamed (check if _id exists now)
         * - Update metadata and propagate rename to perms table if required
         */

        -- 1) Check whether the table's current catalog name differs from stored metadata
        IF relname_after IS DISTINCT FROM tbl.name THEN
            -- Prevent members from creating names that end with _perms
            IF relname_after ILIKE '%_perms' THEN
                RAISE EXCEPTION 'Invalid table name: Using the `_perms` suffix is reserved in managed schemas.';
            END IF;

            -- Rename was performed on the base table. Update metadata and rename perms table if we track one.
            UPDATE system.tables
            SET name = relname_after, updated_at = now()
            WHERE id = tbl.id;

            -- If we have a perms_oid, rename the perms table to newname_perms
            IF tbl.perms_oid IS NOT NULL THEN
                -- get current perms schema and current perms relname (should exist)
                PERFORM 1 FROM pg_class WHERE oid = tbl.perms_oid;
                IF FOUND THEN
                    -- rename the perms table by OID -> find its namespace
                    DECLARE
                        perms_nsp TEXT;
                        perms_rel TEXT;
                        target_perms_new TEXT;
                        perms_schema_oid OID;
                    BEGIN
                        SELECT n.nspname, c.relname, n.oid
                        INTO perms_nsp, perms_rel, perms_schema_oid
                        FROM pg_class c
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE c.oid = tbl.perms_oid
                        LIMIT 1;

                        -- Build final target perms name (new base name + '_perms')
                        target_perms_new := relname_after || '_perms';

                        -- Execute rename using schema and current perms name (safe quoting)
                        EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', perms_nsp, perms_rel, target_perms_new);

                        -- We do NOT update system.tables.perms_oid (the OID stays the same).
                    END;
                ELSE
                    -- perms oid points to missing object; just warn by logging or update metadata
                    RAISE NOTICE 'Managed table % has perms_oid set but perms relation oid % does not exist; metadata may be inconsistent.',
                        tbl.name, tbl.perms_oid;
                END IF;
            END IF;
        END IF;

        -- 2) Check that the protected _id column still exists after the DDL.
        -- If it doesn't, abort unless current_user = nuvix_admin AND system.allow_alter_id = 'true'
        SELECT EXISTS (
            SELECT 1 FROM pg_attribute a
            WHERE a.attrelid = base_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND a.attname = '_id'
        ) INTO id_column_exists;

        IF NOT id_column_exists THEN
            -- allow override for nuvix_admin + specific setting
            IF current_user = 'nuvix_admin' AND COALESCE(current_setting('system.allow_alter_id', TRUE), 'false') = 'true' THEN
                -- allowed; optionally log
                RAISE NOTICE 'nuvix_admin altered _id on managed table %.% while system.allow_alter_id = true', tbl.schema_name, relname_after;
            ELSE
                RAISE EXCEPTION 'Permission denied: Cannot drop or rename the protected _id column on managed table %.%.',
                    tbl.schema_name, relname_after;
            END IF;
        END IF;

    END LOOP;
END;
$$;

DROP EVENT TRIGGER IF EXISTS ON_MANAGED_TABLE_ALTER;

CREATE EVENT TRIGGER ON_MANAGED_TABLE_ALTER ON DDL_COMMAND_END WHEN TAG IN ('ALTER TABLE')
EXECUTE FUNCTION SYSTEM.ON_MANAGED_TABLE_ALTER ();

-- System helper: when drop table on managed schema
CREATE OR REPLACE FUNCTION SYSTEM.ON_MANAGED_TABLE_DROP () RETURNS EVENT_TRIGGER SECURITY DEFINER
SET
	SEARCH_PATH = SYSTEM,
	PG_CATALOG AS $$
DECLARE
    r RECORD;
    schema_info RECORD;
    table_info RECORD;
    base_table_info RECORD;
    schema_type text;
    is_perms_table boolean := false;
    base_table_oid oid;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() 
    WHERE object_type = 'table'
    LOOP
        -- Check if schema is managed
        SELECT s.type INTO schema_type
        FROM system.schemas s
        WHERE s.name = r.schema_name 
        AND s.enabled = true;

        -- Skip if schema is not managed or not found
        IF NOT FOUND OR schema_type != 'managed' THEN
            CONTINUE;
        END IF;

        -- Check if this is a _perms table by looking for base table reference
        SELECT t.* INTO table_info
        FROM system.tables t
        JOIN system.schemas s ON t.schema_id = s.id
        WHERE t.perms_oid = r.objid;

        IF FOUND THEN
            -- This is a _perms table being dropped
            is_perms_table := true;
            base_table_oid := table_info.oid;
        ELSE
            -- Check if it's a base table
            SELECT t.* INTO table_info
            FROM system.tables t
            JOIN system.schemas s ON t.schema_id = s.id
            WHERE t.oid = r.objid;
            
            -- Skip if table not found in system.tables
            IF NOT FOUND THEN
                CONTINUE;
            END IF;
            is_perms_table := false;
        END IF;

        -- Case 1: Someone is trying to drop a _perms table directly
        IF is_perms_table THEN
            RAISE EXCEPTION 
                'Permission denied: Cannot drop _perms table %.% directly. '
                'Drop the main table %.% instead.',
                r.schema_name, r.object_name,
                r.schema_name, table_info.name;
        
        -- Case 2: Base table is being dropped
        ELSE
            -- First, drop the associated _perms table if it exists
			DELETE FROM system.tables 
            WHERE oid = r.objid;
			
            IF table_info.perms_oid IS NOT NULL THEN
                -- Check if the perms table still exists
                IF EXISTS (
                    SELECT 1 FROM pg_class 
                    WHERE oid = table_info.perms_oid
                ) THEN
                    EXECUTE format(
                        'DROP TABLE IF EXISTS %I.%I',
                        r.schema_name,
                        table_info.name || '_perms'
                    );
                END IF;
            END IF;           
        END IF;

    END LOOP;
END;
$$ LANGUAGE PLPGSQL;

-- Create the event trigger for DROP operations
DROP EVENT TRIGGER IF EXISTS ON_MANAGED_TABLE_DROP;

CREATE EVENT TRIGGER ON_MANAGED_TABLE_DROP ON SQL_DROP
EXECUTE FUNCTION SYSTEM.ON_MANAGED_TABLE_DROP ();

-- System helper: block _perms table/view creation in managed schemas
CREATE OR REPLACE FUNCTION SYSTEM.BLOCK_PERMS_CREATION () RETURNS EVENT_TRIGGER AS $$
DECLARE
    r RECORD;
    schema_info RECORD;
    schema_type text;
    object_name text;
    object_type text;
    is_system_operation boolean;
    current_role_name text;
BEGIN
    -- Get current role and check system flags
    current_role_name := current_user;
    is_system_operation := COALESCE(current_setting('system.skip_perms_check', true) = 'true', false);
    
    -- Allow system operations and nuvix_migrate role to bypass
    IF is_system_operation OR current_role_name = 'nuvix_migrate' OR current_role_name = 'nuvix_admin' THEN
        RAISE NOTICE 'System operation detected: skipping _perms creation check';
        RETURN;
    END IF;

    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() 
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'CREATE VIEW', 'CREATE MATERIALIZED VIEW')
    LOOP
        -- Get object name and type
        object_name := split_part(r.object_identity, '.', 2);
        object_type := LOWER(r.object_type);
        
        -- Skip if not a _perms object
        IF object_name NOT LIKE '%\_perms' THEN
            CONTINUE;
        END IF;

        -- Check if schema is managed
        SELECT s.type INTO schema_type
        FROM system.schemas s
        WHERE s.name = r.schema_name 
        AND s.enabled = true;

        -- Skip if schema is not managed or not found
        IF NOT FOUND OR schema_type != 'managed' THEN
            CONTINUE;
        END IF;

        -- Block _perms object creation in managed schemas
        RAISE EXCEPTION 
            'Permission denied: Cannot create _perms % "%" in managed schema "%". '
            '_perms objects are automatically managed by the system.',
            object_type, object_name, r.schema_name;

    END LOOP;
END;
$$ LANGUAGE PLPGSQL;

-- Create the event trigger for CREATE operations
DROP EVENT TRIGGER IF EXISTS BLOCK_PERMS_CREATION;

CREATE EVENT TRIGGER BLOCK_PERMS_CREATION ON DDL_COMMAND_END WHEN TAG IN ('CREATE TABLE', 'CREATE VIEW')
EXECUTE FUNCTION SYSTEM.BLOCK_PERMS_CREATION ();


-- system helper: other rls related function 
CREATE OR REPLACE FUNCTION system.apply_row_policies(tbl regclass)
RETURNS void AS $$
DECLARE
    perm text;
    tbl_policy_name text;
    policy_name text;
    sql text;
BEGIN
    -- Enable RLS always
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY;', tbl);
    -- Loop over CRUD permissions
    FOR perm IN SELECT unnest(ARRAY['read','create','update','delete']) LOOP
        policy_name := format('nx_row_%s', perm);
        tbl_policy_name := format('nx_table_%s', perm);
        -- Drop existing
        EXECUTE format('DROP POLICY IF EXISTS %I ON %s;', policy_name, tbl);
        EXECUTE format('DROP POLICY IF EXISTS %I ON %s;', tbl_policy_name, tbl);
        -- Build correct clause depending on action
        IF perm = 'read' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR SELECT
                TO anon, authenticated
                USING (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE (p.row_id IS NULL OR p.row_id = %s._id)
                        AND p.permission = 'read'
                        AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl, tbl);
        ELSIF perm = 'create' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR INSERT
                TO anon, authenticated
                WITH CHECK (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE (p.row_id IS NULL OR p.row_id = %s._id)
                        AND p.permission = 'create'
                        AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl, tbl);
        ELSIF perm = 'update' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR UPDATE
                TO anon, authenticated
                USING (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE (p.row_id IS NULL OR p.row_id = %s._id)
                        AND p.permission = 'update'
                        AND auth.roles() && p.roles
                    )
                )
                WITH CHECK (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE (p.row_id IS NULL OR p.row_id = %s._id)
                        AND p.permission = 'update'
                        AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl, tbl, tbl, tbl);
        ELSIF perm = 'delete' THEN
            sql := format($p$
                CREATE POLICY %I ON %s
                FOR DELETE
                TO anon, authenticated
                USING (
                    EXISTS (
                        SELECT 1 FROM %s_perms p
                        WHERE (p.row_id IS NULL OR p.row_id = %s._id)
                        AND p.permission = 'delete'
                        AND auth.roles() && p.roles
                    )
                );
            $p$, policy_name, tbl, tbl, tbl);
        END IF;
        -- Execute create policy
        EXECUTE sql;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- system helper: make _id primary or not
CREATE OR REPLACE FUNCTION system.set_id_primary(tbl regclass, make_primary boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    id_col text := '_id';
    existing_pk text;
BEGIN
    -- Get current primary key
    SELECT conname INTO existing_pk
    FROM pg_constraint
    WHERE conrelid = tbl AND contype = 'p';

    PERFORM set_config('system.allow_alter_id', 'true', true);
    -- Ensure _id exists and is identity + not null
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL', tbl, id_col);

    IF make_primary THEN
        -- Drop existing PK if it's not _id
        IF existing_pk IS NOT NULL THEN
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', tbl, existing_pk);
        END IF;

        -- Add _id as primary key
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I PRIMARY KEY (%I)', tbl, tbl::text||'_pkey', id_col);

    ELSE
        -- Remove _id from PK if it is currently PK
        IF existing_pk IS NOT NULL THEN
            PERFORM 1
            FROM pg_constraint
            WHERE conname = existing_pk
              AND conrelid = tbl
              AND contype = 'p'
              AND conkey = (SELECT array_agg(attnum) FROM pg_attribute WHERE attrelid = tbl AND attname = id_col);

            IF FOUND THEN
                EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', tbl, existing_pk);
            END IF;
        END IF;
    END IF;
    PERFORM set_config('system.allow_alter_id', 'false', true);
END;
$$;

CREATE OR REPLACE FUNCTION system.cleanup_schema()
RETURNS event_trigger
SECURITY DEFINER
LANGUAGE plpgsql AS $$
DECLARE
  obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
    IF obj.object_type = 'schema' THEN
      DELETE FROM system.schemas WHERE name = obj.object_identity;
    END IF;
  END LOOP;
END;
$$;

DROP EVENT TRIGGER IF EXISTS cleanup_schema_trigger;
CREATE EVENT TRIGGER cleanup_schema_trigger
ON sql_drop
EXECUTE FUNCTION system.cleanup_schema();
