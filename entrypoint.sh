#!/bin/bash
# =============================================================================
# Babelfish for PostgreSQL - Entrypoint Script
# =============================================================================
# Инициализирует новый кластер PostgreSQL с расширениями Babelfish.
# Поддерживает single-db и multi-db режимы миграции.
#
# Переменные окружения:
#   POSTGRES_PASSWORD        - пароль суперпользователя postgres (ОБЯЗАТЕЛЬНО)
#   BABELFISH_USER           - имя T-SQL пользователя (по умолчанию: bb_admin)
#   BABELFISH_PASS           - пароль T-SQL пользователя (по умолчанию: $POSTGRES_PASSWORD)
#   BABELFISH_DB             - имя базы Babelfish (по умолчанию: babelfish_db)
#   BABELFISH_MIGRATION_MODE - режим миграции: single-db или multi-db (по умолчанию: multi-db)
#
# ВАЖНЫЕ ПРИНЦИПЫ ПОРЯДКА ИНИЦИАЛИЗАЦИИ:
#   1. CREATE EXTENSION создаёт схему sys
#   2. GRANT ON SCHEMA sys можно делать СРАЗУ после CREATE EXTENSION
#   3. Схемы dbo, master_dbo, tempdb_dbo, msdb_dbo создаются ТОЛЬКО процедурой
#      SYS.INITIALIZE_BABELFISH — НЕЛЬЗЯ делать GRANT на них до вызова!
#   4. babelfishpg_tsql.database_name должен быть в postgresql.conf ДО первого
#      запуска, иначе TDS-сервер не стартует
#   5. password_encryption = 'md5' — scram-sha-256 НЕ поддерживается TDS
# =============================================================================
set -euo pipefail

PGDATA="${PGDATA:-/var/storage/pgsql/data}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
BABELFISH_USER="${BABELFISH_USER:-bb_admin}"
BABELFISH_PASS="${BABELFISH_PASS:-$POSTGRES_PASSWORD}"
BABELFISH_DB="${BABELFISH_DB:-babelfish_db}"
BABELFISH_MIGRATION_MODE="${BABELFISH_MIGRATION_MODE:-multi-db}"

init_db() {
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"
    echo "[entrypoint] Режим миграции: $BABELFISH_MIGRATION_MODE"
    echo "[entrypoint] База данных: $BABELFISH_DB"
    echo "[entrypoint] Пользователь: $BABELFISH_USER"

    # Создаём временный файл с паролем для initdb
    printf "%s" "$POSTGRES_PASSWORD" > /tmp/pgpass
    chmod 600 /tmp/pgpass
    
    /opt/postgres/bin/initdb -D "$PGDATA" \
        --username=postgres \
        --pwfile=/tmp/pgpass \
        --encoding=UTF8 \
        --locale=en_US.UTF-8
    rm -f /tmp/pgpass

    # =========================================================================
    # Конфигурация postgresql.conf
    # ВАЖНО: babelfishpg_tsql.database_name должен быть здесь ДО первого запуска,
    # иначе TDS-сервер не сможет стартовать
    # =========================================================================
    {
        echo "# === Babelfish Configuration ==="
        echo "listen_addresses = '*'"
        echo "port = 5432"
        echo ""
        echo "# Аутентификация: md5 (scram-sha-256 НЕ поддерживается TDS-протоколом)"
        echo "password_encryption = 'md5'"
        echo ""
        echo "# Загружаем ТОЛЬКО babelfishpg_tds — остальные расширения подтянутся через CASCADE"
        echo "shared_preload_libraries = 'babelfishpg_tds'"
        echo ""
        echo "# TDS-сервер (SQL Server совместимость, порт 1433)"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
        echo ""
        echo "# Режим миграции Babelfish"
        echo "babelfishpg_tsql.migration_mode = '${BABELFISH_MIGRATION_MODE}'"
        echo ""
        echo "# КРИТИЧЕСКИ ВАЖНО: имя базы Babelfish должно быть задано ДО первого запуска"
        echo "babelfishpg_tsql.database_name = '${BABELFISH_DB}'"
    } >> "$PGDATA/postgresql.conf"

    # =========================================================================
    # Конфигурация pg_hba.conf
    # - trust для localhost (удобно для администрирования через psql)
    # - md5 для внешних подключений (безопасно, поддерживается TDS)
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
# Используем md5 для безопасности (пароль передаётся как хеш)
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
PGEOF

    # Запускаем PostgreSQL временно для инициализации
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
    # babelfishpg_tsql подтянет babelfishpg_common через CASCADE
    # Создаётся схема sys с системными объектами
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
SQL

    # =========================================================================
    # ШАГ 3: Права на схему sys
    # ВАЖНО: схема sys существует после CREATE EXTENSION
    # ВАЖНО: НЕЛЬЗЯ делать GRANT на dbo/master_dbo/tempdb_dbo/msdb_dbo здесь!
    #        Эти схемы создаются процедурой SYS.INITIALIZE_BABELFISH
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        GRANT ALL ON SCHEMA sys TO :"usr";
SQL

    # =========================================================================
    # ШАГ 4: Инициализация Babelfish
    # Создаёт:
    #   - Схемы: dbo, master_dbo, tempdb_dbo, msdb_dbo
    #   - Системные таблицы: sys.babelfish_sysdatabases, sys.babelfish_authid_login_ext и др.
    #   - Роли PostgreSQL: sysadmin, bbf_role_admin, securityadmin, dbcreator
    #   - T-SQL логины: регистрирует babelfish_user как sysadmin
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH(:'usr');
SQL

    # =========================================================================
    # ШАГ 5: Объекты-заглушки для совместимости с Azure Data Studio / SSMS
    # Эти клиенты при подключении вызывают служебные процедуры, которых нет
    # в Babelfish. Создаём заглушки, чтобы подключение проходило без ошибок.
    #
    # ПРИМЕЧАНИЕ: sys.dm_os_windows_info НЕ создаём намеренно.
    # ADS получает ошибку "relation does not exist" и корректно её обрабатывает.
    # Если создать view — будет ошибка "permission denied", что выглядит хуже.
    # =========================================================================
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-'SQL'
        -- Заглушка для master.dbo.xp_msver (вызывается ADS при подключении)
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

        -- Делаем babelfish_user владельцем процедуры, чтобы он мог её вызывать
        ALTER PROCEDURE master_dbo.xp_msver() OWNER TO :"usr";
SQL

    # Останавливаем временный сервер
    /opt/postgres/bin/pg_ctl -D "$PGDATA" -m fast -w stop
    
    echo "[entrypoint] Инициализация Babelfish завершена успешно"
}

# =========================================================================
# Основная логика
# =========================================================================
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    init_db
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

# Запускаем PostgreSQL в foreground (требуется для systemd/container)
exec /opt/postgres/bin/postgres -D "$PGDATA"
