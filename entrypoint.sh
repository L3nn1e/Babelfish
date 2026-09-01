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

    {
        echo "listen_addresses = '*'"
        echo "port = 5432"
        # md5 для совместимости с TDS (scram-sha-256 НЕ поддерживается!)
        echo "password_encryption = 'md5'"
        echo "shared_preload_libraries = 'babelfishpg_tds'"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
        echo "babelfishpg_tsql.migration_mode = '${BABELFISH_MIGRATION_MODE}'"
    } >> "$PGDATA/postgresql.conf"

    # Безопасная конфигурация pg_hba.conf
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
# Используем md5 для безопасности
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
PGEOF

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --set pw="${BABELFISH_PASS}" --set db="${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE USER :"usr" WITH CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
        DROP DATABASE IF EXISTS :"db";
        CREATE DATABASE :"db" OWNER :"usr";
SQL

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
        GRANT ALL ON SCHEMA sys TO :"usr";
SQL

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --set db="${BABELFISH_DB}" --set mode="${BABELFISH_MIGRATION_MODE}" <<-SQL
        ALTER SYSTEM SET babelfishpg_tsql.database_name = :'db';
        ALTER DATABASE :"db" SET babelfishpg_tsql.migration_mode = :'mode';
        SELECT pg_reload_conf();
SQL

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH(:'usr');
SQL

    # Создание объектов-заглушек для совместимости с Azure Data Studio / SSMS
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
        -- Представление sys.dm_os_windows_info
        CREATE OR REPLACE VIEW sys.dm_os_windows_info AS
        SELECT 
            '10.0' AS windows_release,
            'Linux' AS windows_service_pack_level,
            0 AS windows_sku,
            0 AS os_language_version;

        -- Процедура dbo.xp_msver
        CREATE OR REPLACE PROCEDURE dbo.xp_msver()
        LANGUAGE sql
        AS 'SELECT 1, CAST(''ProductName'' AS TEXT), 0, CAST(''Babelfish for PostgreSQL'' AS TEXT) UNION ALL SELECT 2, ''ProductVersion'', 0, ''17.7.0'' UNION ALL SELECT 3, ''Language'', 0, ''English (United States)'' UNION ALL SELECT 4, ''Platform'', 0, ''Linux'' UNION ALL SELECT 5, ''Comments'', 0, ''Babelfish for PostgreSQL with SQL Server Compatibility'' UNION ALL SELECT 6, ''CompanyName'', 0, ''Babelfish for PostgreSQL Project'' UNION ALL SELECT 7, ''FileDescription'', 0, ''PostgreSQL Server'' UNION ALL SELECT 8, ''FileVersion'', 0, ''17.7'' UNION ALL SELECT 9, ''InternalName'', 0, ''postgres'' UNION ALL SELECT 10, ''LegalCopyright'', 0, ''See PostgreSQL copyright'' UNION ALL SELECT 11, ''LegalTrademarks'', 0, '''' UNION ALL SELECT 12, ''OriginalFilename'', 0, ''postgres'' UNION ALL SELECT 13, ''PrivateBuild'', 0, NULL UNION ALL SELECT 14, ''SpecialBuild'', 0, NULL';

        -- Процедура master_dbo.xp_msver (для вызовов master.dbo.xp_msver)
        CREATE OR REPLACE PROCEDURE master_dbo.xp_msver()
        LANGUAGE sql
        AS 'SELECT 1, CAST(''ProductName'' AS TEXT), 0, CAST(''Babelfish for PostgreSQL'' AS TEXT) UNION ALL SELECT 2, ''ProductVersion'', 0, ''17.7.0'' UNION ALL SELECT 3, ''Language'', 0, ''English (United States)'' UNION ALL SELECT 4, ''Platform'', 0, ''Linux'' UNION ALL SELECT 5, ''Comments'', 0, ''Babelfish for PostgreSQL with SQL Server Compatibility'' UNION ALL SELECT 6, ''CompanyName'', 0, ''Babelfish for PostgreSQL Project'' UNION ALL SELECT 7, ''FileDescription'', 0, ''PostgreSQL Server'' UNION ALL SELECT 8, ''FileVersion'', 0, ''17.7'' UNION ALL SELECT 9, ''InternalName'', 0, ''postgres'' UNION ALL SELECT 10, ''LegalCopyright'', 0, ''See PostgreSQL copyright'' UNION ALL SELECT 11, ''LegalTrademarks'', 0, '''' UNION ALL SELECT 12, ''OriginalFilename'', 0, ''postgres'' UNION ALL SELECT 13, ''PrivateBuild'', 0, NULL UNION ALL SELECT 14, ''SpecialBuild'', 0, NULL';

        -- Права
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
