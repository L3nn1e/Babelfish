#!/bin/bash
set -euo pipefail

PGDATA="${PGDATA:-/var/storage/pgsql/data}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
BABELFISH_USER="${BABELFISH_USER:-bb_admin}"
BABELFISH_PASS="${BABELFISH_PASS:-$POSTGRES_PASSWORD}"
BABELFISH_DB="${BABELFISH_DB:-babelfish_db}"
BABELFISH_MIGRATION_MODE="${BABELFISH_MIGRATION_MODE:-single-db}"

init_db() {
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"
    printf "%s" "$POSTGRES_PASSWORD" > /tmp/pgpass
    chmod 600 /tmp/pgpass
    
    /opt/postgres/bin/initdb -D "$PGDATA" --username=postgres --pwfile=/tmp/pgpass --encoding=UTF8 --locale=en_US.UTF-8
    rm -f /tmp/pgpass

    # ВАЖНО: В shared_preload_libraries ТОЛЬКО babelfishpg_tds
    # babelfishpg_tsql и babelfishpg_common устанавливаются через CREATE EXTENSION CASCADE
    {
        echo "listen_addresses = '*'"
        echo "port = 5432"
        echo "shared_preload_libraries = 'babelfishpg_tds'"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
        echo "babelfishpg_tsql.migration_mode = '${BABELFISH_MIGRATION_MODE}'"
    } >> "$PGDATA/postgresql.conf"

    echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"

    # Запускаем PostgreSQL для инициализации
    /opt/postgres/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start

    # Создаём пользователя и базу
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --set pw="${BABELFISH_PASS}" --set db="${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE USER :"usr" WITH CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
        DROP DATABASE IF EXISTS :"db";
        CREATE DATABASE :"db" OWNER :"usr";
SQL

    # Устанавливаем расширения через CASCADE
    # babelfishpg_tsql подтянет babelfishpg_common автоматически
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
        GRANT ALL ON SCHEMA sys TO :"usr";
SQL

    # Настраиваем Babelfish
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --set db="${BABELFISH_DB}" --set mode="${BABELFISH_MIGRATION_MODE}" <<-SQL
        ALTER SYSTEM SET babelfishpg_tsql.database_name = :'db';
        ALTER DATABASE :"db" SET babelfishpg_tsql.migration_mode = :'mode';
        SELECT pg_reload_conf();
SQL

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH(:'usr');
SQL

    # Останавливаем PostgreSQL
    /opt/postgres/bin/pg_ctl -D "$PGDATA" -m fast -w stop
    echo "[entrypoint] Инициализация Babelfish завершена успешно"
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    init_db
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

exec /opt/postgres/bin/postgres -D "$PGDATA"
