#!/bin/sh
set -eu

#######################################
# Database bootstrap for Nuvix.
#
# Authority model:
#   - superuser: platform internal only (bootstrap phase)
#   - nuvix_admin: governance + structural owner
#   - nuvix_app: trusted backend runtime
#   - postgres: project admin (demoted in migrations)
#
# All init + migrations run as nuvix_admin.
#######################################

export PGDATABASE="${POSTGRES_DB:-postgres}"
export PGHOST="${POSTGRES_HOST:-localhost}"
export PGPORT="${POSTGRES_PORT:-5432}"
export PGPASSWORD="${POSTGRES_PASSWORD:-}"

export NUVIX_ADMIN_PASSWORD="${NUVIX_ADMIN_PASSWORD:-$PGPASSWORD}"
export NUVIX_APP_USER_PASSWORD="${NUVIX_APP_USER_PASSWORD:-$PGPASSWORD}"

db="$( cd -- "$( dirname -- "$0" )" > /dev/null 2>&1 && pwd )"

#######################################
# Forward args to dbmate if provided
#######################################
if [ "$#" -ne 0 ]; then
    export DATABASE_URL="postgres://nuvix_admin:${NUVIX_ADMIN_PASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}?sslmode=disable"
    exec dbmate "$@"
    exit 0
fi

#######################################
# Create required roles (bootstrap phase)
# Must be executed by a superuser connection.
#######################################
psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nuvix_admin') THEN
    CREATE ROLE nuvix_admin LOGIN PASSWORD '${NUVIX_ADMIN_PASSWORD}';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nuvix_app') THEN
    CREATE ROLE nuvix_app LOGIN PASSWORD '${NUVIX_APP_USER_PASSWORD}';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres LOGIN PASSWORD '${PGPASSWORD}';
  END IF;
END
\$\$;
EOSQL

#######################################
# Temporarily elevate nuvix_admin for bootstrap
#######################################
psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc <<EOSQL
ALTER ROLE nuvix_admin
  WITH SUPERUSER
       CREATEDB
       CREATEROLE
       REPLICATION
       BYPASSRLS;
EOSQL

#######################################
# Run init scripts as nuvix_admin
#######################################
for sql in "$db"/init-scripts/*.sql; do
    echo "$0: running $sql"
    psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -f "$sql"
done

#######################################
# Run migrations as nuvix_admin
#######################################
for sql in "$db"/migrations/*.sql; do
    echo "$0: running $sql"
    psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -f "$sql"
done

#######################################
# Optional post-init script
#######################################
postinit="/etc/postgresql.schema.sql"
if [ -e "$postinit" ]; then
    echo "$0: running $postinit"
    psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin -f "$postinit"
fi

#######################################
# Reset stats
#######################################
psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc -U nuvix_admin \
  -c 'SELECT extensions.pg_stat_statements_reset(); SELECT pg_stat_reset();' || true

#######################################
# IMPORTANT:
# postgres demotion and final privilege shaping
# must occur inside migrations.
#######################################
