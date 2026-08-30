# Сборка собственного образа Babelfish for PostgreSQL на базе AlmaLinux 10

Вместо готового community-образа собираем свой `Containerfile` (multi-stage), базовый образ контейнера — `almalinux:9` (builder и runtime), независимо от версии хост-ОС. Это даёт: контроль над версией Babelfish/PostgreSQL, возможность добавить свои патчи/расширения (PostGIS, tds_fdw), воспроизводимость сборки в CI, независимость от чужого Docker Hub аккаунта.

Актуальная версия на момент написания: **Babelfish 5.4.0 для PostgreSQL 17.7** (тег `BABEL_5_4_0__PG_17_7`). Перед сборкой проверьте актуальный тег на странице релизов: `github.com/babelfish-for-postgresql/babelfish-for-postgresql/releases`.

---

## Содержание
1. Идея multi-stage сборки
2. Структура проекта
3. `Containerfile` целиком
4. Entrypoint-скрипт инициализации
5. Сборка образа
6. Боевой запуск (продакшн, через Quadlet)
7. Публикация в приватный registry (опционально)
8. CI-сборка (GitHub Actions пример)
9. PostGIS / Spatial Datatypes (уже встроено)
10. tds_fdw / Linked Servers (уже встроено)
11. Healthcheck (уже встроено)

---

## 0. Почему база контейнера — AlmaLinux 9, а не 10

Хост под Podman у вас — AlmaLinux 10, но это не имеет значения для того, что происходит **внутри** контейнера: контейнер использует ядро хоста, но собственный набор библиотек (glibc, gcc, openssl, icu) из своего базового образа. Ядро AlmaLinux 10 полностью совместимо с userspace AlmaLinux 9 — проблем на уровне syscalls не возникает.

Смысл в том, чтобы взять базу с toolchain'ом, максимально близким к тому, на чём Babelfish реально тестируется (Ubuntu 22.04):

| | Ubuntu 22.04 (официально тестируется) | AlmaLinux 9 | AlmaLinux 10 |
|---|---|---|---|
| gcc | 11 | 11 | 14 |
| glibc | 2.35 | 2.34 | 2.39 |
| OpenSSL | 3.0 | 3.0 | 3.2 / 3.5 |

AlmaLinux 9 практически идентичен по toolchain'у Ubuntu 22.04 — риск неожиданных ошибок компиляции из-за более строгих проверок gcc 14 или изменившегося API OpenSSL 3.2+ исчезает.

**Важно:** builder и runtime стадии должны использовать одну и ту же версию базового образа (обе `almalinux:9`), а не разные — иначе бинарник, слинкованный с `libicu`/`libssl` из EL9, может не найти совместимый soname в рантайме на EL10 (у ICU, например, soname меняется почти при каждом мажорном апдейте ОС).

---

## 1. Идея multi-stage сборки

Собираем в два этапа:
- **builder** — тяжёлый образ со всеми dev-инструментами (gcc, cmake, java, bison...), в нём компилируется движок PostgreSQL + 4 расширения Babelfish + ANTLR runtime.
- **runtime** — чистый минимальный AlmaLinux 10 с только рантайм-зависимостями (без компиляторов), куда копируются уже собранные бинарники из builder-этапа.

Итоговый образ получается заметно легче, чем если бы всё собиралось и оставалось в одном слое.

## 2. Структура проекта

```
/opt/babelfish-image/
├── Containerfile
├── entrypoint.sh
├── healthcheck.sh
└── postgresql.conf.tmpl   (опционально, свой шаблон конфига)
```

Держим исходники сборки не в домашнем каталоге конкретного пользователя, а в предсказуемом системном месте — так к ним будет одинаковый доступ и у CI-раннера, и у любого админа с sudo, без привязки к тому, кто именно логинился на сервер.

```bash
sudo mkdir -p /opt/babelfish-image
sudo chown "$USER":"$USER" /opt/babelfish-image   # чтобы не собирать через sudo каждую команду
cd /opt/babelfish-image
```

## 3. `Containerfile` целиком

PostGIS / Spatial datatypes и tds_fdw (linked servers) включены по умолчанию — если что-то из этого не нужно, как убрать см. в разделах 9 и 10.

```dockerfile
# syntax=docker/dockerfile:1

########################################
# Этап 1: builder
########################################
FROM almalinux:9 AS builder

ARG BABEL_TAG=BABEL_5_4_0__PG_17_7
ARG ANTLR_VERSION=4.13.2
ARG CMAKE_VERSION=3.28.3
ARG POSTGIS_VERSION=3.5.1
ARG TDS_FDW_VERSION=2.0.4

RUN dnf update -y && \
    dnf groupinstall -y "Development Tools" && \
    dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
        libicu-devel libxml2-devel openssl-devel \
        libuuid-devel \
        gcc gcc-c++ make flex bison \
        readline-devel zlib-devel \
        python3-devel perl-devel \
        java-21-openjdk java-21-openjdk-devel \
        wget unzip git pkgconf-pkg-config krb5-devel \
        geos geos-devel proj proj-devel gdal gdal-devel \
        json-c-devel protobuf-c-devel sqlite-devel \
        freetds-devel && \
    dnf clean all

# Примечание: в EL9 репозиторий с доп. пакетами тоже называется "crb" (CodeReady
# Builder), как и в EL10. ossp-uuid в стандартных репах/EPEL9 по-прежнему нет,
# поэтому используем --with-uuid=e2fs ниже — это официально поддерживаемая
# опция PostgreSQL, а не хак под конкретную ОС. geos/proj/gdal — зависимости
# PostGIS. freetds-devel — зависимость tds_fdw (linked servers).

# cmake (нужна версия 3.20+, в репах может быть старее)
WORKDIR /opt
RUN wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh && \
    sh cmake-${CMAKE_VERSION}-linux-x86_64.sh --skip-license --prefix=/usr/local && \
    rm cmake-${CMAKE_VERSION}-linux-x86_64.sh

ENV cmake=/usr/local/bin/cmake

# Исходники
WORKDIR /build
RUN git clone --depth 1 --branch ${BABEL_TAG} \
        https://github.com/babelfish-for-postgresql/postgresql_modified_for_babelfish.git && \
    git clone --depth 1 --branch ${BABEL_TAG} \
        https://github.com/babelfish-for-postgresql/babelfish_extensions.git

# Сборка движка PostgreSQL, модифицированного для Babelfish
WORKDIR /build/postgresql_modified_for_babelfish
RUN ./configure --prefix=/opt/postgres \
        --without-readline --without-zlib \
        --with-libxml --with-uuid=e2fs --with-icu --with-openssl \
        --with-gssapi \
        --disable-werror && \
    make -j"$(nproc)" && \
    make install && \
    cd contrib && make -j"$(nproc)" && make install

ENV PG_CONFIG=/opt/postgres/bin/pg_config
ENV PG_SRC=/build/postgresql_modified_for_babelfish

# PostGIS — собирается через PGXS против нашего движка (не системного postgres)
WORKDIR /build
RUN wget -q https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz && \
    tar -xzf postgis-${POSTGIS_VERSION}.tar.gz && \
    cd postgis-${POSTGIS_VERSION} && \
    ./configure --with-pgconfig=/opt/postgres/bin/pg_config && \
    make -j"$(nproc)" && \
    make install

# tds_fdw — foreign data wrapper для linked servers (доступ из Babelfish к
# другим SQL Server/Babelfish инстансам по TDS). Собирается через PGXS против
# нашего движка, линкуется с libsybdb из freetds-devel.
WORKDIR /build
RUN git clone --depth 1 --branch v${TDS_FDW_VERSION} \
        https://github.com/tds-fdw/tds_fdw.git && \
    cd tds_fdw && \
    make USE_PGXS=1 PG_CONFIG=/opt/postgres/bin/pg_config && \
    make USE_PGXS=1 PG_CONFIG=/opt/postgres/bin/pg_config install

# ANTLR runtime
WORKDIR /build
RUN cp /build/babelfish_extensions/contrib/babelfishpg_tsql/antlr/thirdparty/antlr/antlr-${ANTLR_VERSION}-complete.jar \
        /usr/local/lib/ && \
    wget -q http://www.antlr.org/download/antlr4-cpp-runtime-${ANTLR_VERSION}-source.zip && \
    unzip -q -d antlr4 antlr4-cpp-runtime-${ANTLR_VERSION}-source.zip && \
    cd antlr4 && mkdir build && cd build && \
    /usr/local/bin/cmake .. \
        -DANTLR_JAR_LOCATION=/usr/local/lib/antlr-${ANTLR_VERSION}-complete.jar \
        -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_DEMO=False && \
    make -j"$(nproc)" && make install && \
    cp /usr/local/lib/libantlr4-runtime.so.${ANTLR_VERSION} /opt/postgres/lib/

# Сборка расширений Babelfish. babelfishpg_common и babelfishpg_tsql собираются
# с -DENABLE_SPATIAL_TYPES (geometry/geography через PostGIS) и, для tsql,
# дополнительно с -DENABLE_TDS_LIB (поддержка linked servers через tds_fdw).
WORKDIR /build/babelfish_extensions/contrib
RUN cd babelfishpg_money  && make -j"$(nproc)" && make install && cd .. && \
    cd babelfishpg_common && \
        PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES' make -j"$(nproc)" && \
        PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES' make install && \
        cd .. && \
    cd babelfishpg_tds    && make -j"$(nproc)" && make install && cd .. && \
    cd babelfishpg_tsql   && \
        PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES -DENABLE_TDS_LIB' \
        SHLIB_LINK='-lsybdb -L/usr/lib64' \
            make -j"$(nproc)" && \
        PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES -DENABLE_TDS_LIB' \
        SHLIB_LINK='-lsybdb -L/usr/lib64' \
            make install

########################################
# Этап 2: runtime (та же версия базы, что и builder — важно для ABI-совместимости)
########################################
FROM almalinux:9 AS runtime

RUN dnf update -y && \
    dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
        libicu libxml2 openssl libuuid krb5-libs \
        geos proj gdal json-c protobuf-c sqlite-libs \
        freetds \
        glibc-langpack-en \
        shadow-utils && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Явная генерация локали поверх пакета glibc-langpack-en — защита на случай,
# если RPM-триггер генерации локали почему-то не сработал в минимальном образе.
RUN localedef -c -f UTF-8 -i en_US en_US.UTF-8 || true

# Пользователь без прав root для запуска postgres
# UID/GID 26 — исторически закреплены за postgres в Fedora/RHEL/AlmaLinux
# (пакет postgresql-server), в отличие от Debian/Ubuntu, где принято 999/70.
# Раз вся база — EL-семейство, используем нативную нумерацию. В минимальном
# almalinux:9 сам пакет postgresql-server не установлен, поэтому UID 26 в
# /etc/passwd ещё не занят — но зарезервирован пакетом setup, так что useradd
# отработает без конфликтов. home-dir — отдельно от PGDATA, чисто для
# shell/профиля пользователя, соответствует конвенции пакета postgresql-server.
RUN groupadd -r postgres --gid=26 && \
    useradd -r -g postgres --uid=26 --home-dir=/var/lib/pgsql --shell=/bin/bash postgres && \
    mkdir -p /var/storage/pgsql/data && \
    chown -R postgres:postgres /var/storage/pgsql

COPY --from=builder /opt/postgres /opt/postgres

ENV PATH="/opt/postgres/bin:${PATH}"
ENV PGDATA=/var/storage/pgsql/data
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

VOLUME ["/var/storage/pgsql/data"]

EXPOSE 5432 1433

# Встроенный healthcheck на уровне самого образа — работает даже если контейнер
# запущен не через Quadlet (например, при разовом podman run в ходе отладки).
# Логика вынесена в отдельный скрипт (раздел 4.1) — читаемее, чем длинный inline CMD.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

USER postgres
ENTRYPOINT ["entrypoint.sh"]
CMD ["postgres"]
```

Комментарии по ключевым решениям:
- `--with-uuid=e2fs` и `--disable-werror` — те же обходные пути под EL10/gcc14, что и в гайде по сборке на голом хосте.
- `--with-gssapi` — включает поддержку Kerberos-аутентификации; `krb5-devel` уже стоит в builder-этапе, а `krb5-libs` — в runtime, отдельно ничего добавлять не нужно.
- PostGIS и tds_fdw собираются через PGXS против нашего собственного движка (`--with-pgconfig`/`PG_CONFIG=/opt/postgres/bin/pg_config`), а не системного `postgres` — иначе расширения попадут не туда.
- `-DENABLE_TDS_LIB` и `SHLIB_LINK='-lsybdb -L/usr/lib64'` при сборке `babelfishpg_tsql` — обязательное условие для поддержки linked servers через tds_fdw; без этого флага расширение соберётся, но T-SQL код, обращающийся к linked server, будет падать с ошибкой.
- Runtime-образ не содержит компиляторов и dev-заголовков (только рантайм-версии `geos`/`proj`/`gdal`/`freetds` без `-devel`) — меньше размер и площадь атаки.
- Контейнер работает от непривилегированного пользователя `postgres` (uid/gid 26 — стандарт для EL-дистрибутивов), с домашним каталогом `/var/lib/pgsql` (RHEL-конвенция) отдельно от `PGDATA=/var/storage/pgsql/data` — соответствует нумерации и структуре, которую использует пакет `postgresql-server` в самом AlmaLinux.
- `glibc-langpack-en` в runtime и `ENV LANG=en_US.UTF-8`/`LC_ALL=en_US.UTF-8` — без этого пакета `initdb --locale=en_US.UTF-8` в `entrypoint.sh` (раздел 4) упадёт на минимальном образе, где эта локаль не сгенерирована.
- `HEALTHCHECK` в самом образе — это дополнение, а не замена `HealthCmd=` в Quadlet-юните (раздел 8 полного гайда): Quadlet-версия управляется systemd и видна в `systemctl status`, встроенная в образ — работает независимо от способа запуска контейнера.

## 4. Entrypoint-скрипт инициализации

`entrypoint.sh`:
```bash
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

init_db() {
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"

    # Пароль суперпользователя ставится сразу при initdb через --pwfile (файловый
    # дескриптор процесса, не аргумент командной строки — не светится в ps/логах).
    # Так пароль известен серверу с первого момента его существования — не нужно
    # отдельно подключаться и делать ALTER USER до/после старта.
    initdb -D "$PGDATA" --username=postgres --pwfile=<(echo "$POSTGRES_PASSWORD") \
        --encoding=UTF8 --locale=en_US.UTF-8

    {
        echo "listen_addresses = '*'"
        echo "shared_preload_libraries = 'babelfishpg_tds, babelfishpg_tsql'"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
    } >> "$PGDATA/postgresql.conf"

    echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"

    pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start || {
        echo "[entrypoint] Не удалось запустить PostgreSQL"
        exit 1
    }

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

    if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
        pg_ctl -D "$PGDATA" -m fast -w stop
    fi
    echo "[entrypoint] Инициализация завершена"
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    init_db
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

exec "$@" -D "$PGDATA"
```

`ENABLE_POSTGIS` и `ENABLE_TDS_FDW` по умолчанию `true`, так как оба расширения уже собраны в образ (раздел 3). Поставьте `Environment=ENABLE_POSTGIS=false` и/или `Environment=ENABLE_TDS_FDW=false` в Quadlet-юните, если что-то из этого не нужно в конкретной базе — сами библиотеки при этом останутся в образе, просто `CREATE EXTENSION` не выполнится.

Обратите внимание: `CREATE EXTENSION tds_fdw` только регистрирует сам foreign data wrapper — сервер и логин для конкретного linked server (`CREATE SERVER ... FOREIGN DATA WRAPPER tds_fdw`, `CREATE USER MAPPING ...`) нужно создавать вручную под свои реквизиты подключения, автоматизировать это в entrypoint нельзя — целевой сервер и его учётные данные заранее не известны.

**Важно про порядок:** пароль суперпользователя ставится через `--pwfile` **на этапе `initdb`**, до какого-либо `psql`-подключения. Не пытайтесь переставить это на `ALTER USER postgres PASSWORD ...` через `psql` сразу после `initdb`, но до `pg_ctl start` — сервер в этот момент ещё не запущен, `psql` не сможет подключиться, скрипт упадёт на `set -e`, а `PG_VERSION` к этому моменту уже будет создан — при следующем перезапуске контейнера entrypoint решит, что кластер уже проинициализирован, и молча пропустит весь блок (без пароля, без `shared_preload_libraries`, без TDS). Это состояние трудно диагностировать и ещё сложнее откатить без потери данных.

**Про `--encoding=UTF8 --locale=en_US.UTF-8`:** минимальный `almalinux:9` может не иметь этой локали сгенерированной, поэтому в runtime-этапе `Containerfile` (раздел 3) обязательно должен стоять пакет `glibc-langpack-en` (и, для подстраховки, явный `localedef`) — без этого `initdb` с этим флагом упадёт. Ниже в разделе 3 это уже добавлено.

```bash
chmod +x entrypoint.sh
```

### 4.1. `healthcheck.sh`

Логика healthcheck вынесена в отдельный файл вместо длинной inline-команды в `HEALTHCHECK` — легче читать и менять отдельно от остального `Containerfile`.

```bash
#!/bin/bash
set -e
pg_isready -U "${BABELFISH_USER:-babelfish_user}" -d "${BABELFISH_DB:-babelfish_db}" || exit 1
```

`set -e` тут не спасает от ненулевого кода самого `pg_isready` внутри `||`-конструкции (проверка в условии не считается "падением" для `set -e`) — поэтому явный `exit 1` обязателен, просто полагаться на `set -e` было бы недостаточно.

```bash
chmod +x healthcheck.sh
```


## 5. Сборка образа

```bash
cd /opt/babelfish-image
sudo podman build -t localhost/babelfish:5.4.0-pg17.7 \
    --build-arg BABEL_TAG=BABEL_5_4_0__PG_17_7 \
    -f Containerfile .
```

Сборка компилирует PostgreSQL + 4 расширения — рассчитывайте на 15–40 минут в зависимости от мощности сервера. Логи компиляции идут в стандартный вывод — если что-то падает, ошибка будет видна прямо в терминале.

## 6. Боевой запуск (продакшн, через Quadlet)

Ниже — полный, самодостаточный набор Quadlet-юнитов для запуска собранного образа в проде. Если вы уже настраивали сеть/секреты по `babelfish-quadlet-full-guide.md` — этот раздел просто их переиспользует, отличие только в `Image=`.

### 6.1. Директории и данные

```bash
sudo mkdir -p /var/storage/pgsql/data
sudo chown 26:26 /var/storage/pgsql/data   # UID/GID postgres внутри контейнера (раздел 3) —
                                             # без этого initdb упадёт с Permission denied,
                                             # т.к. контейнер пишет от непривилегированного
                                             # пользователя, а не от root
sudo chmod 750 /var/storage/pgsql/data
```

### 6.2. Пароль — через env-файл с ограниченными правами

```bash
sudo install -d -m 700 /etc/babelfish
sudo bash -c '{
    echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
    echo "BABELFISH_PASS=$(openssl rand -base64 24)"
} > /etc/babelfish/babelfish.env'
sudo chmod 600 /etc/babelfish/babelfish.env
```

Два независимых пароля, а не один общий: `POSTGRES_PASSWORD` — суперпользователь `postgres` внутри кластера, `BABELFISH_PASS` — прикладной логин (`BABELFISH_USER`, по умолчанию `babelfish_user`), которым реально будут подключаться приложения по TDS. Если задать только `POSTGRES_PASSWORD`, `entrypoint.sh` по умолчанию использует его же и для `BABELFISH_PASS` (см. раздел 4) — так что разделение строго опционально, но раз утечка пароля приложения не должна означать утечку пароля суперпользователя БД, разумно их развести.

(Более строгий вариант — через `podman secret` — см. `babelfish-quadlet-full-guide.md`.)

### 6.3. Сетевой Quadlet-юнит

`/etc/containers/systemd/babelfish.network`:
```ini
[Unit]
Description=Podman network for Babelfish

[Network]
NetworkName=babelfish-net
```

### 6.4. Основной контейнерный Quadlet-юнит

`/etc/containers/systemd/babelfish.container`:
```ini
[Unit]
Description=Babelfish for PostgreSQL (собственная сборка)
Documentation=https://babelfishpg.org/docs
After=network-online.target
Wants=network-online.target

[Container]
Image=localhost/babelfish:5.4.0-pg17.7
ContainerName=babelfish
Network=babelfish-net.network

# TDS (SQL Server протокол) наружу, Postgres-протокол только на loopback
PublishPort=1433:1433
PublishPort=127.0.0.1:5432:5432

# Данные — постоянный volume с корректной SELinux-меткой. Путь одинаковый
# на хосте и внутри контейнера (совпадает с PGDATA из Containerfile,
# см. раздел 3) — меньше путаницы при отладке.
Volume=/var/storage/pgsql/data:/var/storage/pgsql/data:Z

EnvironmentFile=/etc/babelfish/babelfish.env
Environment=BABELFISH_USER=babelfish_user
Environment=BABELFISH_DB=babelfish_db
Environment=BABELFISH_MIGRATION_MODE=single-db
# По желанию — выключить встроенные PostGIS/tds_fdw для конкретной базы:
# Environment=ENABLE_POSTGIS=false
# Environment=ENABLE_TDS_FDW=false

# Ограничения ресурсов — подберите под свой сервер
PodmanArgs=--memory=4g --cpus=2

# Healthcheck на уровне Quadlet (дополняет HEALTHCHECK, встроенный в образ —
# см. раздел 11)
HealthCmd=pg_isready -U babelfish_user -d babelfish_db || exit 1
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=60s

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
```

Если публиковали образ в свой registry (раздел 7) — укажите полный путь (`registry.example.internal/babelfish:5.4.0-pg17.7`) вместо `localhost/...`, тогда Podman будет тянуть его с registry, а не искать локально.

### 6.5. Запуск

```bash
sudo systemctl daemon-reload
sudo systemctl start babelfish.service
sudo systemctl enable babelfish.service   # автозапуск при перезагрузке хоста
sudo systemctl status babelfish.service
```

Логи и статус:
```bash
journalctl -u babelfish.service -f
sudo podman inspect babelfish --format '{{.State.Health.Status}}'
```

### 6.6. Firewall

```bash
sudo firewall-cmd --permanent --add-port=1433/tcp
sudo firewall-cmd --reload
```

### 6.7. Проверка подключения

```bash
tsql -H <IP-сервера> -p 1433 -U babelfish_user -P '<значение BABELFISH_PASS из /etc/babelfish/babelfish.env>'
```

### 6.8. Что дальше

Это минимально достаточный продакшн-набор. Для более полной картины (TLS-шифрование, `podman secret` вместо env-файла, бэкапы, мониторинг, обновление образа с откатом, разбор типичных ошибок) — см. `babelfish-quadlet-full-guide.md`, разделы 5, 12, 14–18. Отличие только одно: там в качестве `Image=` изначально фигурировал сторонний образ — теперь везде используется `localhost/babelfish:5.4.0-pg17.7` (или ваш тег из registry), как задано выше.

## 7. Публикация в приватный registry (опционально)

Если образ нужен на нескольких хостах — публикуем в свой registry вместо пересборки на каждом:

```bash
sudo podman tag localhost/babelfish:5.4.0-pg17.7 registry.example.internal/babelfish:5.4.0-pg17.7
sudo podman push registry.example.internal/babelfish:5.4.0-pg17.7
```

## 8. CI-сборка (пример GitHub Actions)

Если хотите автоматизировать пересборку при выходе новых релизов Babelfish:

```yaml
name: build-babelfish-image
on:
  workflow_dispatch:
    inputs:
      babel_tag:
        description: 'Тег релиза Babelfish'
        default: 'BABEL_5_4_0__PG_17_7'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build image with Podman
        run: |
          podman build -t babelfish:${{ github.event.inputs.babel_tag }} \
            --build-arg BABEL_TAG=${{ github.event.inputs.babel_tag }} \
            -f Containerfile .
      - name: Push to registry
        run: |
          podman login registry.example.internal -u "${{ secrets.REGISTRY_USER }}" -p "${{ secrets.REGISTRY_PASS }}"
          podman tag babelfish:${{ github.event.inputs.babel_tag }} registry.example.internal/babelfish:${{ github.event.inputs.babel_tag }}
          podman push registry.example.internal/babelfish:${{ github.event.inputs.babel_tag }}
```

## 9. PostGIS / Spatial Datatypes (уже встроено)

Babelfish умеет транслировать T-SQL типы `geometry`/`geography` и функции вроде `STPoint`, `STArea`, `STContains`, `STDistance` и т.д. поверх PostGIS. В `Containerfile` из раздела 3 это уже включено по умолчанию:

- в builder-этап добавлены `geos`, `proj`, `gdal` (+`-devel`), `json-c-devel`, `protobuf-c-devel`, `sqlite-devel` — все версии берутся из EPEL9/CRB, отдельно компилировать GEOS/PROJ из исходников (как в оригинальном README проекта, ориентированном на Ubuntu) не нужно;
- PostGIS собирается через PGXS-механизм с флагом `--with-pgconfig=/opt/postgres/bin/pg_config`, то есть против нашего собственного движка, а не системного `postgres`;
- `babelfishpg_common` и `babelfishpg_tsql` собираются с флагом `PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES'`, чтобы T-SQL спатиал-типы транслировались в PostGIS;
- runtime-этап содержит рантайм-версии `geos`/`proj`/`gdal` без `-devel` — без них контейнер стартует, но упадёт при первом обращении к геопространственной функции;
- `entrypoint.sh` (раздел 4) выполняет `CREATE EXTENSION postgis` при первой инициализации базы, если не отключено.

### 9.1. Как отключить, если PostGIS не нужен

Сама библиотека уже в образе, но включение в конкретной базе управляется переменной `ENABLE_POSTGIS` (по умолчанию `true`). Чтобы не создавать расширение при инициализации:

```ini
Environment=ENABLE_POSTGIS=false
```

в Quadlet-юните. Полностью убрать PostGIS из самого образа (уменьшить его размер) можно, вырезав соответствующие пакеты и шаг сборки PostGIS из `Containerfile` в разделе 3 и убрав `-DENABLE_SPATIAL_TYPES` из сборки `babelfishpg_common`/`babelfishpg_tsql` — но тогда пересобирайте образ заново, "на лету" это не отключается.

### 9.2. Проверка

После запуска — через `tsql`/`sqlcmd`:

```sql
SELECT geometry::STGeomFromText('POINT(1 1)', 4326).STAsText();
```

Должно вернуть `POINT (1 1)` без ошибок о неизвестном типе.

### 9.3. Известные ограничения

- Поддерживаются не все геопространственные функции T-SQL — конкретный список зависит от версии Babelfish (в 5.x, например, добавлена поддержка `Linestring`-инстансов и статических методов, но не весь набор SQL Server Spatial API).
- Версию PostGIS привязывайте к тому, что реально тестировалось с вашей версией Babelfish — расхождения версий GEOS/PROJ иногда меняют точность вычислений на границах координатной сетки.

---

## 10. tds_fdw / Linked Servers (уже встроено)

`tds_fdw` — foreign data wrapper, позволяющий из Babelfish обращаться к другим SQL Server/Babelfish инстансам по TDS (аналог linked servers в реальном SQL Server). В `Containerfile` из раздела 3 это уже включено по умолчанию:

- в builder-этап добавлен `freetds-devel` — заголовки и `libsybdb`, нужные для линковки;
- `tds_fdw` собирается через PGXS (`make USE_PGXS=1 PG_CONFIG=/opt/postgres/bin/pg_config`) против нашего собственного движка;
- `babelfishpg_tsql` пересобирается с `-DENABLE_TDS_LIB` и `SHLIB_LINK='-lsybdb -L/usr/lib64'` — без этого флага T-SQL код, обращающийся к linked server, падает с ошибкой даже при установленном `tds_fdw`;
- runtime-этап содержит пакет `freetds` (без `-devel`) — рантайм-библиотеку `libsybdb`;
- `entrypoint.sh` (раздел 4) выполняет `CREATE EXTENSION tds_fdw` при первой инициализации базы, если не отключено переменной `ENABLE_TDS_FDW`.

### 10.1. Настройка конкретного linked server

Сам `CREATE EXTENSION` не создаёt подключение к удалённому серверу — это делается вручную под конкретные реквизиты:

```sql
CREATE SERVER remote_sql_server
    FOREIGN DATA WRAPPER tds_fdw
    OPTIONS (servername '10.0.0.5', port '1433', database 'RemoteDB');

CREATE USER MAPPING FOR babelfish_user
    SERVER remote_sql_server
    OPTIONS (username 'remote_login', password 'remote_password');

CREATE FOREIGN TABLE remote_customers (
    customer_id int,
    customer_name text
) SERVER remote_sql_server
  OPTIONS (table_name 'dbo.Customers');
```

### 10.2. Как отключить, если не нужно

Аналогично PostGIS — переменная `ENABLE_TDS_FDW` (по умолчанию `true`) управляет только `CREATE EXTENSION` в конкретной базе:

```ini
Environment=ENABLE_TDS_FDW=false
```

Полностью убрать из образа — вырезать шаг сборки `tds_fdw` и флаги `-DENABLE_TDS_LIB`/`SHLIB_LINK` из сборки `babelfishpg_tsql` в `Containerfile`, с пересборкой образа.

---

## 11. Healthcheck (уже встроено)

В `Containerfile` (раздел 3) добавлена нативная инструкция `HEALTHCHECK`, вызывающая отдельный скрипт `healthcheck.sh` (раздел 4.1) вместо длинной inline-команды:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh
```

Это дополняет, а не заменяет `HealthCmd=`/`HealthInterval=`/... в самом Quadlet-юните (раздел 8 полного гайда `babelfish-quadlet-full-guide.md`):

| | `HEALTHCHECK` в образе | `HealthCmd=` в Quadlet |
|---|---|---|
| Работает при запуске | Через любой инструмент (Podman/Docker, включая ручной `podman inspect`) | Только когда контейнер управляется через systemd/Quadlet |
| Виден в | `podman inspect --format '{{.State.Health.Status}}'` | Тот же механизм — Quadlet использует нативный Podman healthcheck, но параметры удобно держать в юните рядом с остальной конфигурацией |
| Приоритет | Если задан и в образе, и в Quadlet-юните, значения из `.container`-файла (`HealthCmd=` и т.д.) переопределяют встроенный в образ `HEALTHCHECK` |

Практический смысл: даже если кто-то запустит образ не через Quadlet (например, разовый `podman run` при отладке, без явного `HealthCmd=`), healthcheck всё равно будет работать — он идёт из самого образа.

Проверка вручную:
```bash
sudo podman inspect babelfish --format '{{.State.Health.Status}}'
sudo podman healthcheck run babelfish
```

---

## Открытые вопросы перед сборкой (не подтверждено на 100%)

Ниже — то, что требует вашей проверки/решения перед первым `podman build`, а не автоматически исправлено в этом гайде:

1. **Разные git-теги для двух репозиториев.** Если решите использовать раздельные `PG_BABEL_TAG`/`EXT_BABEL_TAG` (по образцу вашего варианта) вместо единого `BABEL_TAG` для обоих `git clone` — сначала проверьте на GitHub, что оба тега реально существуют в соответствующих репозиториях для нужной версии (`postgresql_modified_for_babelfish` и `babelfish_extensions`). Иначе `git clone --branch` просто упадёт с "not found" на этапе сборки.
2. **Включение PostGIS/tds_fdw в БД по умолчанию.** Сейчас `entrypoint.sh` делает `CREATE EXTENSION` автоматически (управляется `ENABLE_POSTGIS`/`ENABLE_TDS_FDW`). Если хотите включать вручную под конкретную задачу — поменяйте дефолт на `false` или уберите блоки из `entrypoint.sh`.
3. **`babelfishpg_tsql.database_name`.** В этом гайде GUC выставляется через `ALTER SYSTEM` и `pg_reload_conf()`. Существует альтернативный подход — вообще не задавать этот GUC и полагаться только на `migration_mode`; я не нашёл однозначного авторитетного источника, что один из вариантов строго обязателен для конкретно вашей версии Babelfish. Если после инициализации TDS-подключения не находят нужную базу — это первое, что стоит перепроверить в документации к вашей версии.



| Подход | Время первой настройки | Обслуживание | Контроль |
|---|---|---|---|
| Сборка на голом хосте (первый гайд) | Высокое | Сложное (пересборка при апдейте) | Полный |
| Готовый community-образ + Quadlet | Низкое | Простое | Ограниченный (зависит от мейнтейнера) |
| **Свой Containerfile + Quadlet (этот гайд)** | Среднее | Простое (пересборка автоматизируется) | Полный |
