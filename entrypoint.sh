#!/bin/bash
set -euo pipefail

# =============================================================================
# Babelfish for PostgreSQL - Entrypoint Script
# =============================================================================
# Переменные окружения:
#   - Из babelfish.env: POSTGRES_PASSWORD, BABELFISH_PASS
#   - Из Quadlet-файла: BABELFISH_USER, BABELFISH_DB, BABELFISH_MIGRATION_MODE
# =============================================================================

PGDATA="${PGDATA:-/var/storage/pgsql/data}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
BABELFISH_USER="${BABELFISH_USER:-babelfish_user}"
BABELFISH_PASS="${BABELFISH_PASS:-$POSTGRES_PASSWORD}"
BABELFISH_DB="${BABELFISH_DB:-babelfish_db}"
BABELFISH_MIGRATION_MODE="${BABELFISH_MIGRATION_MODE:-multi-db}"

init_db() {
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"
    echo "[entrypoint] Режим миграции: $BABELFISH_MIGRATION_MODE"
    echo "[entrypoint] База данных: $BABELFISH_DB"
    echo "[entrypoint] Пользователь: $BABELFISH_USER"

    printf "%s" "$POSTGRES_PASSWORD" > /tmp/pgpass
    chmod 600 /tmp/pgpass
    
    /opt/postgres/bin/initdb -D "$PGDATA" \
        --username=postgres \
        --pwfile=/tmp/pgpass \
        --encoding=UTF8 \
        --locale=en_US.UTF-8
    rm -f /tmp/pgpass

    # =========================================================================
    # postgresql.conf — ВАЖНО: database_name ДО первого запуска
    # =========================================================================
    {
        echo "# === Babelfish Configuration ==="
        echo "listen_addresses = '*'"
        echo "port = 5432"
        echo ""
        echo "# Аутентификация: md5 (scram-sha-256 НЕ поддерживается TDS)"
        echo "password_encryption = 'md5'"
        echo ""
        echo "# Загружаем ТОЛЬКО babelfishpg_tds — остальные через CASCADE"
        echo "shared_preload_libraries = 'babelfishpg_tds'"
        echo ""
        echo "# TDS-сервер (SQL Server совместимость, порт 1433)"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
        echo ""
        echo "# Режим миграции Babelfish"
        echo "babelfishpg_tsql.migration_mode = '${BABELFISH_MIGRATION_MODE}'"
        echo ""
        echo "# КРИТИЧЕСКИ ВАЖНО: имя базы Babelfish ДО первого запуска"
        echo "babelfishpg_tsql.database_name = '${BABELFISH_DB}'"
    } >> "$PGDATA/postgresql.conf"

    # =========================================================================
    # pg_hba.conf
    # =========================================================================
    cat > "$PGDATA/pg_hba.conf" <<PGEOF
# Локальные подключения (PostgreSQL protocol, порт 5432)
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

# Репликация
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust

# Удалённые подключения через TDS (порт 1433)
# Babelfish TDS поддерживает: trust, password, md5, gssapi
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
PGEOF

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start

    # =========================================================================
    # ШАГ 1: Создание PostgreSQL-пользователя и базы данных
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --set pw="${BABELFISH_PASS}" \
        --set db="${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        CREATE USER :"usr" WITH CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
        DROP DATABASE IF EXISTS :"db";
        CREATE DATABASE :"db" OWNER :"usr";
SQL

    # =========================================================================
    # ШАГ 2: Установка расширений Babelfish
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
SQL

    # =========================================================================
    # ШАГ 3: Дополнительные расширения (PostGIS, tds_fdw)
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS postgis;
        CREATE EXTENSION IF NOT EXISTS tds_fdw;
SQL

    # =========================================================================
    # ШАГ 4: Права на схему sys
    # ВАЖНО: НЕЛЬЗЯ делать GRANT на dbo/master_dbo до INITIALIZE_BABELFISH!
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        GRANT ALL ON SCHEMA sys TO :"usr";
SQL

    # =========================================================================
    # ШАГ 5: Инициализация Babelfish
    # Создаёт: dbo, master_dbo, tempdb_dbo, msdb_dbo,
    #         системные таблицы, роли, регистрирует login
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH(:'usr');
SQL

    # =========================================================================
    # ШАГ 6: Заглушки для совместимости с Azure Data Studio / SSMS
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-'SQL'
        CREATE OR REPLACE PROCEDURE master_dbo.xp_msver()
        LANGUAGE sql
        AS $sql$
            SELECT 1,  CAST('ProductName'     AS TEXT), 0, CAST('Babelfish for PostgreSQL' AS TEXT)
            UNION ALL SELECT 2, 'ProductVersion', 0, '17.7.0'
            UNION ALL SELECT 3, 'Language',         0, 'English (United States)'
            UNION ALL SELECT 4, 'Platform',         0, 'Linux'
            UNION ALL SELECT 5, 'Comments',         0, 'Babelfish for PostgreSQL with SQL Server Compatibility'
            UNION ALL SELECT 6, 'CompanyName',      0, 'Babelfish for PostgreSQL Project'
            UNION ALL SELECT 7, 'FileDescription',  0, 'PostgreSQL Server'
            UNION ALL SELECT 8, 'FileVersion',      0, '17.7'
            UNION ALL SELECT 9, 'InternalName',     0, 'postgres'
            UNION ALL SELECT 10, 'LegalCopyright',  0, 'See PostgreSQL copyright'
            UNION ALL SELECT 11, 'LegalTrademarks', 0, ''
            UNION ALL SELECT 12, 'OriginalFilename',0, 'postgres'
            UNION ALL SELECT 13, 'PrivateBuild',    0, NULL
            UNION ALL SELECT 14, 'SpecialBuild',    0, NULL
        $sql$;

        ALTER PROCEDURE master_dbo.xp_msver() OWNER TO :"usr";
SQL

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -m fast -w stop
    
    echo "[entrypoint] Инициализация Babelfish завершена успешно"
    echo "[entrypoint] Установленные расширения: babelfishpg_tsql, babelfishpg_tds, postgis, tds_fdw"
}

# =========================================================================
# Основная логика
# =========================================================================
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    init_db
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

exec /opt/postgres/bin/postgres -D "$PGDATA"
chmod +x /opt/babelfish-image/entrypoint.sh
