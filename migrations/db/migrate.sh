#!/bin/sh
set -eu

#######################################
# Used by both ami and docker builds to initialise database schema.
# Env vars:
#   POSTGRES_DB              defaults to postgres
#   POSTGRES_HOST            defaults to localhost
#   POSTGRES_PORT            defaults to 5432
#   POSTGRES_PASSWORD        defaults to ""
#   USE_DBMATE               defaults to ""
# Exit code:
#   0 if migration succeeds, non-zero on error.
#######################################

export PGDATABASE="${POSTGRES_DB:-postgres}"
export PGHOST="${POSTGRES_HOST:-localhost}"
export PGPORT="${POSTGRES_PORT:-5432}"
export PGPASSWORD="${POSTGRES_PASSWORD:-}"

# Connection string for dbmate
connect="$PGPASSWORD@$PGHOST:$PGPORT/$PGDATABASE?sslmode=disable"

# If args are supplied, simply forward to dbmate
if [ "$#" -ne 0 ]; then
    export DATABASE_URL="${DATABASE_URL:-postgres://nuvix_admin:$connect}"
    exec dbmate "$@"
    exit 0
fi

db=$( cd -- "$( dirname -- "$0" )" > /dev/null 2>&1 && pwd )

# Define the bootstrap SQL to ensure all required roles exist securely
BOOTSTRAP_SQL=$(cat <<EOSQL
do \$\$
begin
  -- 1. Ensure postgres role exists
  if not exists (select from pg_roles where rolname = 'postgres') then
    create role postgres superuser login password '$PGPASSWORD';
    alter database postgres owner to postgres;
  else
    alter role postgres with password '$PGPASSWORD';
  end if;

  -- 2. Ensure nuvix_admin role exists and has correct superuser privileges
  if not exists (select from pg_roles where rolname = 'nuvix_admin') then
    create role nuvix_admin with superuser login createdb createrole replication bypassrls password '$PGPASSWORD';
  else
    alter role nuvix_admin with superuser createdb createrole replication bypassrls password '$PGPASSWORD';
  end if;

  -- 3. Ensure nuvix_app role exists for standard API access
  if not exists (select from pg_roles where rolname = 'nuvix_app') then
    create role nuvix_app with login password '$PGPASSWORD';
  else
    alter role nuvix_app with login password '$PGPASSWORD';
  end if;
end \$\$
EOSQL
)

if [ -z "${USE_DBMATE:-}" ]; then
    echo "$0: Bootstrapping roles (postgres, nuvix_admin, nuvix_app)..."
    psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -c "$BOOTSTRAP_SQL"

    # Run init scripts as nuvix_admin user
    for sql in "$db"/init-scripts/*.sql; do
        echo "$0: running $sql"
        psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -f "$sql"
    done

    # Run migrations as nuvix_admin (superuser)
    for sql in "$db"/migrations/*.sql; do
        echo "$0: running $sql"
        psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -f "$sql"
    done

    # Set password for authenticator role if it exists
    if psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'authenticator'" | grep -q 1; then
        psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -c "ALTER ROLE authenticator WITH PASSWORD '$PGPASSWORD';"
    fi
else
    echo "$0: Bootstrapping roles (postgres, nuvix_admin, nuvix_app)..."
    psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -c "$BOOTSTRAP_SQL"

    # Run init scripts as nuvix_admin
    DBMATE_MIGRATIONS_DIR="$db/init-scripts" DATABASE_URL="postgres://nuvix_admin:$connect" dbmate --no-dump-schema migrate

    # Run migrations as nuvix_admin
    DBMATE_MIGRATIONS_DIR="$db/migrations" DATABASE_URL="postgres://nuvix_admin:$connect" dbmate --no-dump-schema migrate

    # Set password for authenticator role if it exists
    if psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'authenticator'" | grep -q 1; then
        psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -c "ALTER ROLE authenticator WITH PASSWORD '$PGPASSWORD';"
    fi
fi

# Run any post migration script to update role passwords if necessary
postinit="/etc/postgresql.schema.sql"
if [ -e "$postinit" ]; then
    echo "$0: running $postinit"
    psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -f "$postinit"
fi

# Once done with everything, reset stats from init
psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -c 'SELECT extensions.pg_stat_statements_reset(); SELECT pg_stat_reset();' || true
