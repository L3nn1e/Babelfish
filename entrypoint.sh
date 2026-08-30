#!/bin/bash
set -euo pipefail

PGDATA="${PGDATA:-/var/storage/pgsql/data}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
BABELFISH_USER="${BABELFISH_USER:-babelfish_user}"
BABELFISH_PASS="${BABELFISH_PASS:-$POSTGRES_PASSWORD}"
BABELFISH_DB="${BABELFISH_DB:-babelfish_db}"
BABELFISH_MIGRATION_MODE="${BABELFISH_MIGRATION_MODE:-single-db}"
ENABLE_POSTGIS="${ENABLE_POSTGIS:-true}"
ENABLE_TDS_FDW="${ENABLE_TDS_FDW:-true}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"
    initdb -D "$PGDATA" --username=postgres --pwfile=<(echo "$POSTGRES_PASSWORD") \
        --encoding=UTF8 --locale=en_US.UTF-8

    {
        echo "listen_addresses = '*'"
        echo "shared_preload_libraries = 'babelfishpg_tds, babelfishpg_tsql'"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
    } >> "$PGDATA/postgresql.conf"

    echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"

    pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start

    # Пароль передаётся через psql-переменную (--set + :'pw'), а не подставляется
    # напрямую в SQL-строку — иначе пароль с одинарной кавычкой сломает синтаксис
    # или откроет SQL-инъекцию в собственном bootstrap-скрипте.
    psql -v ON_ERROR_STOP=1 --username postgres --set pw="${BABELFISH_PASS}" <<-SQL
        CREATE USER ${BABELFISH_USER} WITH CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
        DROP DATABASE IF EXISTS ${BABELFISH_DB};
        CREATE DATABASE ${BABELFISH_DB} OWNER ${BABELFISH_USER};
SQL

    psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
        GRANT ALL ON SCHEMA sys TO ${BABELFISH_USER};
SQL

    if [ "$ENABLE_POSTGIS" = "true" ]; then
        echo "[entrypoint] Включаю PostGIS в ${BABELFISH_DB}"
        psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
            CREATE EXTENSION IF NOT EXISTS postgis;
SQL
    fi

    if [ "$ENABLE_TDS_FDW" = "true" ]; then
        echo "[entrypoint] Включаю tds_fdw в ${BABELFISH_DB}"
        psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
            CREATE EXTENSION IF NOT EXISTS tds_fdw;
SQL
    fi

    psql -v ON_ERROR_STOP=1 --username postgres <<-SQL
        ALTER SYSTEM SET babelfishpg_tsql.database_name = '${BABELFISH_DB}';
        ALTER DATABASE ${BABELFISH_DB} SET babelfishpg_tsql.migration_mode = '${BABELFISH_MIGRATION_MODE}';
        SELECT pg_reload_conf();
SQL

    psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH('${BABELFISH_USER}');
SQL

    pg_ctl -D "$PGDATA" -m fast -w stop
    echo "[entrypoint] Инициализация завершена"
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

exec "$@" -D "$PGDATA"
