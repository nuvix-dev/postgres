-- migrate:up
grant pg_read_all_data, pg_signal_backend to postgres;

DO $$
DECLARE
    sch text;
BEGIN
    FOREACH sch IN ARRAY ARRAY['auth', 'system', 'core']
    LOOP
        -- Revoke from public and limited roles
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC, postgres, anon, authenticated;', sch);
        EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated;', sch);
        EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated;', sch);
        EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated;', sch);
        EXECUTE format('REVOKE ALL ON ALL PROCEDURES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated;', sch);
        EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC, postgres, anon, authenticated;', sch);

        -- Grant full access to nuvix_admin and nuvix_app
        EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('GRANT ALL ON ALL FUNCTIONS IN SCHEMA %I TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('GRANT ALL ON ALL PROCEDURES IN SCHEMA %I TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('GRANT ALL ON ALL ROUTINES IN SCHEMA %I TO nuvix_admin, nuvix_app;', sch);

        -- Set default privileges for future objects
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA %I GRANT ALL ON TABLES TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA %I GRANT ALL ON SEQUENCES TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA %I GRANT ALL ON FUNCTIONS TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA %I GRANT ALL ON ROUTINES TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_app IN SCHEMA %I GRANT ALL ON TABLES TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_app IN SCHEMA %I GRANT ALL ON SEQUENCES TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_app IN SCHEMA %I GRANT ALL ON FUNCTIONS TO nuvix_admin, nuvix_app;', sch);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_app IN SCHEMA %I GRANT ALL ON ROUTINES TO nuvix_admin, nuvix_app;', sch);
        
    END LOOP;
END $$;

GRANT USAGE ON SCHEMA auth, system TO postgres, anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO postgres, anon, authenticated, service_role;

GRANT USAGE ON SCHEMA system TO postgres, service_role;
GRANT EXECUTE ON FUNCTION create_schema(text, text, text) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION apply_table_policies(regclass) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION apply_row_policies(regclass) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION set_id_primary(regclass, boolean) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION system.fix_managed_oid_links(target_schema text) TO postgres, service_role;

grant select, insert, update, delete
on table system.migrations
to postgres, service_role;
-- migrate:down
