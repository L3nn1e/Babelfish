#!/bin/bash
set -euo pipefail

PGDATA="${PGDATA:-/var/storage/pgsql/data}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
BABELFISH_USER="${BABELFISH_USER:-bb_admin}"
BABELFISH_PASS="${BABELFISH_PASS:-$POSTGRES_PASSWORD}"
BABELFISH_DB="${BABELFISH_DB:-babelfish_db}"
BABELFISH_MIGRATION_MODE="${BABELFISH_MIGRATION_MODE:-multi-db}"

init_db() {
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"
    printf "%s" "$POSTGRES_PASSWORD" > /tmp/pgpass
    chmod 600 /tmp/pgpass
    
    /opt/postgres/bin/initdb -D "$PGDATA" --username=postgres --pwfile=/tmp/pgpass --encoding=UTF8 --locale=en_US.UTF-8
    rm -f /tmp/pgpass

    # Конфигурация PostgreSQL — ВСЕ параметры ДО первого запуска
    {
        echo "listen_addresses = '*'"
        echo "port = 5432"
        echo "password_encryption = 'md5'"
        echo "shared_preload_libraries = 'babelfishpg_tds'"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
        echo "babelfishpg_tsql.migration_mode = '${BABELFISH_MIGRATION_MODE}'"
        echo "babelfishpg_tsql.database_name = '${BABELFISH_DB}'"
    } >> "$PGDATA/postgresql.conf"

    cat > "$PGDATA/pg_hba.conf" <<PGEOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
PGEOF

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start

    # 1. Создание пользователя и базы данных
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --set pw="${BABELFISH_PASS}" --set db="${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE USER :"usr" WITH CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
        DROP DATABASE IF EXISTS :"db";
        CREATE DATABASE :"db" OWNER :"usr";
SQL

    # 2. Установка расширений Babelfish
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
SQL

    # 3. ВАЖНО: Права на схемы ДО инициализации Babelfish!
    # Это позволяет INITIALIZE_BABELFISH создать все объекты от имени пользователя
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        GRANT ALL ON SCHEMA sys TO :"usr";
        GRANT ALL ON SCHEMA dbo TO :"usr";
        GRANT ALL ON SCHEMA information_schema_tsql TO :"usr";
SQL

    # 4. Инициализация Babelfish — создаёт системные таблицы И регистрирует login
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH(:'usr');
SQL

    # 5. Дополнительные права ПОСЛЕ инициализации
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA dbo TO :"usr";
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA dbo TO :"usr";
        GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA dbo TO :"usr";
        ALTER DEFAULT PRIVILEGES IN SCHEMA dbo GRANT ALL ON TABLES TO :"usr";
        ALTER DEFAULT PRIVILEGES IN SCHEMA dbo GRANT ALL ON SEQUENCES TO :"usr";
        ALTER DEFAULT PRIVILEGES IN SCHEMA dbo GRANT ALL ON FUNCTIONS TO :"usr";
SQL

    # 6. Создание объектов-заглушек для совместимости с Azure Data Studio / SSMS
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" <<-SQL
        CREATE OR REPLACE VIEW sys.dm_os_windows_info AS
        SELECT 
            '10.0' AS windows_release,
            'Linux' AS windows_service_pack_level,
            0 AS windows_sku,
            0 AS os_language_version;

        CREATE OR REPLACE PROCEDURE dbo.xp_msver()
        LANGUAGE sql
        AS \$sql\$SELECT 1, CAST('ProductName' AS TEXT), 0, CAST('Babelfish for PostgreSQL' AS TEXT) UNION ALL SELECT 2, 'ProductVersion', 0, '17.7.0' UNION ALL SELECT 3, 'Language', 0, 'English (United States)' UNION ALL SELECT 4, 'Platform', 0, 'Linux' UNION ALL SELECT 5, 'Comments', 0, 'Babelfish for PostgreSQL with SQL Server Compatibility' UNION ALL SELECT 6, 'CompanyName', 0, 'Babelfish for PostgreSQL Project' UNION ALL SELECT 7, 'FileDescription', 0, 'PostgreSQL Server' UNION ALL SELECT 8, 'FileVersion', 0, '17.7' UNION ALL SELECT 9, 'InternalName', 0, 'postgres' UNION ALL SELECT 10, 'LegalCopyright', 0, 'See PostgreSQL copyright' UNION ALL SELECT 11, 'LegalTrademarks', 0, '' UNION ALL SELECT 12, 'OriginalFilename', 0, 'postgres' UNION ALL SELECT 13, 'PrivateBuild', 0, NULL UNION ALL SELECT 14, 'SpecialBuild', 0, NULL\$sql\$;

        CREATE OR REPLACE PROCEDURE master_dbo.xp_msver()
        LANGUAGE sql
        AS \$sql\$SELECT 1, CAST('ProductName' AS TEXT), 0, CAST('Babelfish for PostgreSQL' AS TEXT) UNION ALL SELECT 2, 'ProductVersion', 0, '17.7.0' UNION ALL SELECT 3, 'Language', 0, 'English (United States)' UNION ALL SELECT 4, 'Platform', 0, 'Linux' UNION ALL SELECT 5, 'Comments', 0, 'Babelfish for PostgreSQL with SQL Server Compatibility' UNION ALL SELECT 6, 'CompanyName', 0, 'Babelfish for PostgreSQL Project' UNION ALL SELECT 7, 'FileDescription', 0, 'PostgreSQL Server' UNION ALL SELECT 8, 'FileVersion', 0, '17.7' UNION ALL SELECT 9, 'InternalName', 0, 'postgres' UNION ALL SELECT 10, 'LegalCopyright', 0, 'See PostgreSQL copyright' UNION ALL SELECT 11, 'LegalTrademarks', 0, '' UNION ALL SELECT 12, 'OriginalFilename', 0, 'postgres' UNION ALL SELECT 13, 'PrivateBuild', 0, NULL UNION ALL SELECT 14, 'SpecialBuild', 0, NULL\$sql\$;

        GRANT SELECT ON sys.dm_os_windows_info TO PUBLIC;
        GRANT EXECUTE ON PROCEDURE dbo.xp_msver() TO PUBLIC;
        GRANT EXECUTE ON PROCEDURE master_dbo.xp_msver() TO PUBLIC;
SQL

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -m fast -w stop
    echo "[entrypoint] Инициализация Babelfish завершена успешно"
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    init_db
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

exec /opt/postgres/bin/postgres -D "$PGDATA"
chmod +x /opt/babelfish-image/entrypoint.sh
