-- migrate:up
-- Mark the public schema as managed
SELECT system.create_schema('public', 'managed', 'Public schema for user-defined tables and functions');

-- migrate:down
