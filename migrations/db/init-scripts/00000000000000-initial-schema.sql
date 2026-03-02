-- migrate:up

-- Set up realtime
-- defaults to empty publication
create publication nuvix_realtime;
grant all on database postgres to nuvix_app;

-- Extension namespacing
create schema if not exists extensions;
create extension if not exists "uuid-ossp"      with schema extensions;
create extension if not exists pgcrypto         with schema extensions;


-- Set up auth roles for the developer
create role anon                nologin noinherit;
create role authenticated       nologin noinherit; -- "logged in" user: web_user, app_user, etc
create role service_role        nologin noinherit bypassrls; -- allow developers to create JWT's that bypass their policies


-- Allow Extensions to be used in the API
grant usage                     on schema extensions to nuvix_app, postgres, service_role;

-- Set up namespacing
alter user nuvix_admin SET search_path TO extensions;

-- Set short statement/query timeouts for API roles
alter role anon set statement_timeout = '3s';
alter role authenticated set statement_timeout = '8s';

alter role nuvix_app set statement_timeout = '30s';

-- migrate:down
