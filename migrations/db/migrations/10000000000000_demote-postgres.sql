-- migrate:up

-- Demote the default postgres role (still keeps basic ownership but no superuser)
REVOKE ALL PRIVILEGES ON DATABASE postgres FROM postgres;
GRANT CONNECT, TEMP ON DATABASE postgres TO postgres;

REVOKE ALL ON SCHEMA extensions FROM postgres;
GRANT USAGE ON SCHEMA extensions TO postgres;

REVOKE ALL ON ALL TABLES IN SCHEMA extensions FROM postgres;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA extensions TO postgres;

REVOKE ALL ON ALL SEQUENCES IN SCHEMA extensions FROM postgres;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA extensions TO postgres;

REVOKE ALL ON ALL ROUTINES IN SCHEMA extensions FROM postgres;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA extensions TO postgres;

-- Strip dangerous capabilities
ALTER ROLE postgres 
  NOSUPERUSER 
  NOCREATEDB 
  NOCREATEROLE 
  LOGIN 
  REPLICATION 
  BYPASSRLS;
  
-- migrate:down
