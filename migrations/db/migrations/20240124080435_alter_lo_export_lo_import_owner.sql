-- migrate:up
alter function pg_catalog.lo_export owner to nuvix_admin;
alter function pg_catalog.lo_import(text) owner to nuvix_admin;
alter function pg_catalog.lo_import(text, oid) owner to nuvix_admin;

-- migrate:down
