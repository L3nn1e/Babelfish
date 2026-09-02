# Babelfish for PostgreSQL на AlmaLinux 10: сборка своего образа + продакшн-деплой через Quadlet

> **Предыстория решения.** Изначально рассматривался готовый community-образ (`jonathanpotts/babelfishpg`) как более быстрый путь к запуску. В процессе стало понятно, что собрать образ самостоятельно — не намного дольше по времени первой настройки, зато даёт полный контроль над версией Babelfish/PostgreSQL, независимость от чужого Docker Hub аккаунта и возможность добавлять свои патчи (PostGIS, tds_fdw, Kerberos). Финальная схема: свой `Containerfile` + деплой строго через Quadlet, без стороннего образа и без ручного `podman run`.

Это единый документ — от `git clone` до продакшн-эксплуатации (TLS, бэкапы, мониторинг, диагностика). Более ранние отдельные файлы (`babelfish-almalinux10-guide.md`, `babelfish-quadlet-almalinux10.md`, `babelfish-custom-image-build.md`, `babelfish-quadlet-full-guide.md`) — черновики предыдущих итераций, дальше можно ориентироваться только на этот файл.

---

## Содержание

**Сборка образа**
1. Обзор архитектуры Babelfish
2. Почему база контейнера — AlmaLinux 9, а не 10
3. Идея multi-stage сборки
4. Требования к серверу и подготовка хоста (AlmaLinux 10 + Podman/Quadlet)
5. Структура проекта
6. `Containerfile` целиком
7. `entrypoint.sh`
8. `healthcheck.sh`
9. Сборка образа

**Продакшн-деплой**
10. Секреты (пароли)
11. Директории, volume и SELinux
12. Боевой Quadlet-юнит
13. Запуск и управление сервисом
14. Firewall
15. Первоначальная проверка базы
16. TLS/SSL
17. Подключение клиентов
18. Резервное копирование и восстановление
19. Обновление образа и откат
20. Мониторинг, логи, healthcheck (эксплуатация)

**Встроенные фичи и обслуживание**
21. PostGIS / Spatial Datatypes (уже встроено)
22. tds_fdw / Linked Servers (уже встроено)
23. Healthcheck на уровне образа (уже встроено)
24. Публикация в приватный registry (опционально)
25. CI-сборка (пример GitHub Actions)
26. Диагностика типичных проблем
27. Рекомендации по безопасности
28. Статус и открытые вопросы

---

## 1. Обзор архитектуры Babelfish

Babelfish for PostgreSQL — набор расширений PostgreSQL (`babelfishpg_tds`, `babelfishpg_tsql`, `babelfishpg_common`, `babelfishpg_money`), которые добавляют:

- **TDS-протокол** (Tabular Data Stream) — тот же протокол, что использует SQL Server, обычно на порту **1433**;
- **T-SQL диалект** — процедурный язык SQL Server (хранимые процедуры, системные представления `sys.*` и т.д.);
- обычный **PostgreSQL-протокол** на порту **5432** остаётся доступен параллельно — это по сути тот же кластер Postgres, просто с двумя "входами".

Официальных RPM или Docker-образа от AWS/проекта Babelfish для RHEL-семейства нет — мы собираем свой `Containerfile` и разворачиваем через Quadlet.

---

## 2. Почему база контейнера — AlmaLinux 9, а не 10

Хост под Podman — AlmaLinux 10, но это не имеет значения для того, что происходит **внутри** контейнера: контейнер использует ядро хоста, но собственный набор библиотек (glibc, gcc, openssl, icu) из своего базового образа. Ядро AlmaLinux 10 полностью совместимо с userspace AlmaLinux 9 — проблем на уровне syscalls не возникает.

Смысл — взять базу с toolchain'ом, максимально близким к тому, на чём Babelfish реально тестируется (Ubuntu 22.04):

| | Ubuntu 22.04 (официально тестируется) | AlmaLinux 9 | AlmaLinux 10 |
|---|---|---|---|
| gcc | 11 | 11 | 14 |
| glibc | 2.35 | 2.34 | 2.39 |
| OpenSSL | 3.0 | 3.0 | 3.2 / 3.5 |

AlmaLinux 9 практически идентичен по toolchain'у Ubuntu 22.04 — риск ошибок компиляции из-за более строгих проверок gcc 14 или изменившегося API OpenSSL 3.2+ исчезает.

**Важно:** builder и runtime стадии используют одну и ту же версию базового образа (обе `almalinux:9`), а не разные — иначе бинарник, слинкованный с `libicu`/`libssl` из EL9, может не найти совместимый soname в рантайме на EL10.

---

## 3. Идея multi-stage сборки

Собираем в два этапа:
- **builder** — тяжёлый образ со всеми dev-инструментами (gcc, cmake, java, bison...), в нём компилируется движок PostgreSQL + 4 расширения Babelfish + PostGIS + tds_fdw + ANTLR runtime.
- **runtime** — чистый минимальный AlmaLinux 9 только с рантайм-зависимостями (без компиляторов), куда копируются уже собранные бинарники из builder-этапа.

Итоговый образ получается заметно легче, чем если бы всё собиралось и оставалось в одном слое.

---

## 4. Требования к серверу и подготовка хоста

### 4.1. Требования

- AlmaLinux 10 (x86_64 или aarch64) — хост-ОС, на образ внутри контейнера не влияет (см. раздел 2)
- Минимум 2 vCPU / 4 GB RAM для теста, от 4 vCPU / 8+ GB для реальной нагрузки
- Свободное место под данные БД — планируйте с запасом, PGDATA будет расти
- Root или sudo-доступ
- Открытый исходящий доступ в интернет (для `git clone`/`podman pull`) либо локальное зеркало

### 4.2. Базовые пакеты хоста

```bash
sudo dnf update -y
sudo dnf install -y firewalld freetds postgresql
sudo systemctl enable --now firewalld
```

`freetds` даёт утилиту `tsql` для проверки TDS-подключения, `postgresql` — клиент `psql` для проверки Postgres-стороны (сам сервер СУБД ставить не нужно, он в контейнере).

Проверьте SELinux (должен быть `Enforcing` — это нормально, ниже покажу, как с ним ужиться, а не отключать):

```bash
getenforce
```

### 4.3. Podman и Quadlet

```bash
sudo dnf install -y podman podman-plugins
podman --version
```

Нужна версия Podman **4.4+** — начиная с этой версии Quadlet встроен в сам Podman. В AlmaLinux 10 в базовых репозиториях уже стоит свежий Podman.

```bash
/usr/lib/systemd/system-generators/podman-system-generator --version
```

Директории для Quadlet-юнитов: system-wide (root, автозапуск на уровне хоста) — `/etc/containers/systemd/`; rootless — `~/.config/containers/systemd/`. Этот гайд — **system-wide** вариант, он проще для выделенного сервера БД.

```bash
sudo mkdir -p /etc/containers/systemd
```

---

## 5. Структура проекта

```
/opt/babelfish-image/
├── Containerfile
├── entrypoint.sh
└── healthcheck.sh
```

Держим исходники сборки не в домашнем каталоге конкретного пользователя, а в предсказуемом системном месте — так к ним будет одинаковый доступ и у CI-раннера, и у любого админа с sudo.

```bash
sudo mkdir -p /opt/babelfish-image
sudo chown "$USER":"$USER" /opt/babelfish-image   # чтобы не собирать через sudo каждую команду
cd /opt/babelfish-image
```

---

## 6. `Containerfile` целиком

PostGIS / Spatial datatypes и tds_fdw (linked servers) включены по умолчанию — если что-то из этого не нужно, как убрать см. в разделах 21 и 22.

**Важное структурное решение:** расширения Babelfish (`babelfishpg_money`, `babelfishpg_common`, `babelfishpg_tds`, `babelfishpg_tsql`) собираются **in-tree** — их исходники копируются прямо внутрь `postgresql_modified_for_babelfish/contrib/`, а не собираются отдельно со ссылкой на установленный движок через `PG_CONFIG`. Причина: код этих расширений обращается к внутренним заголовкам backend'а (например, `src/include/lib/qunique.h`, `src/backend/utils/mb/Unicode/*.map`) через относительные пути внутри дерева исходников, которые не попадают в обычный `make install`. `tds_fdw` и PostGIS в эту особенность не упираются — обычные независимые PGXS-расширения, собираются out-of-tree.

```dockerfile
# syntax=docker/dockerfile:1

########################################
# Этап 1: builder
########################################
FROM almalinux:9 AS builder

ARG PG_BABEL_TAG=BABEL_5_4_0__PG_17_7
# EXT_BABEL_TAG подтверждён через git ls-remote (тег BABEL_5_4_0 существует в
# babelfish_extensions) — но при смене версии Babelfish снова проверяйте оба
# тега отдельно, т.к. postgresql_modified_for_babelfish и babelfish_extensions
# используют РАЗНЫЕ схемы версионирования и не обязаны совпадать.
ARG EXT_BABEL_TAG=BABEL_5_4_0
ARG ANTLR_VERSION=4.13.2
ARG CMAKE_VERSION=3.28.3
ARG POSTGIS_VERSION=3.5.1
ARG TDS_FDW_VERSION=2.0.4

RUN dnf update -y && \
    dnf groupinstall -y "Development Tools" && \
    dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y --setopt=install_weak_deps=False \
        gcc gcc-c++ make flex bison \
        libicu-devel libxml2-devel openssl-devel \
        libuuid-devel readline-devel zlib-devel \
        python3-devel \
        perl perl-core perl-devel perl-IPC-Run perl-Test-Simple \
        perl-Getopt-Long perl-File-Basename perl-File-Copy \
        perl-File-Compare perl-Text-ParseWords \
        wget unzip git pkgconf-pkg-config krb5-devel \
        geos-devel proj-devel gdal-devel \
        json-c-devel protobuf-c-devel sqlite-devel \
        freetds-devel \
        java-17-openjdk java-17-openjdk-devel \
        libxslt-devel && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Примечание: в EL9 репозиторий с доп. пакетами тоже называется "crb" (CodeReady
# Builder), как и в EL10. ossp-uuid в стандартных репах/EPEL9 по-прежнему нет,
# поэтому используем --with-uuid=e2fs ниже — это официально поддерживаемая
# опция PostgreSQL, а не хак под конкретную ОС. geos/proj/gdal — зависимости
# PostGIS. freetds-devel — зависимость tds_fdw (linked servers). Широкий набор
# perl-* пакетов (включая метапакет perl-core, реально существующий в EL9) —
# подстраховка от "Can't locate X.pm": PostgreSQL 17 генерирует часть заголовков
# каталога (gen_node_support.pl, genbki.pl) Perl-скриптами прямо во время сборки,
# а perl-devel даёт только заголовки для XS, не core-модули.
# --setopt=install_weak_deps=False — в EL9 dnf по умолчанию тянет Recommends
# (в отличие от Ubuntu apt без --no-install-recommends, на которой тестирует
# сам проект) — некоторые EPEL-пакеты через weak-зависимости способны незаметно
# подтянуть лишний/конфликтующий софт.

# Java 17 явно приоритетным в PATH — нужна конкретно для запуска ANTLR jar
# (генерация парсера T-SQL). Явный ENV JAVA_HOME/PATH гарантирует, что везде
# ниже вызывается именно эта JVM, а не что-то ещё, что могло установиться
# как побочная зависимость другого пакета.
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk
ENV PATH="/usr/local/bin:${JAVA_HOME}/bin:${PATH}"

# cmake (нужна версия 3.20+, в репах может быть старее)
WORKDIR /opt
RUN wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh && \
    sh cmake-${CMAKE_VERSION}-linux-x86_64.sh --skip-license --prefix=/usr/local && \
    rm cmake-${CMAKE_VERSION}-linux-x86_64.sh

# Исходники. ВАЖНО: перед сборкой проверьте точный тег babelfish_extensions
# командой (на хосте, не в контейнере):
#   git ls-remote --tags https://github.com/babelfish-for-postgresql/babelfish_extensions.git | grep -i "5_4_0"
# и передайте его через --build-arg EXT_BABEL_TAG=..., если он отличается
# от значения по умолчанию ниже — единый тег для обоих репозиториев не
# гарантированно существует одновременно в обоих.
WORKDIR /build
RUN git clone --depth 1 --branch ${PG_BABEL_TAG} \
        https://github.com/babelfish-for-postgresql/postgresql_modified_for_babelfish.git && \
    git clone --depth 1 --branch ${EXT_BABEL_TAG} \
        https://github.com/babelfish-for-postgresql/babelfish_extensions.git

# Сборка движка PostgreSQL, модифицированного для Babelfish. "Хирургическое"
# копирование пары заголовков backend'а поверх make install — доп. страховка
# на случай, если что-то всё же соберётся не in-tree (см. пояснение выше);
# при in-tree сборке эти файлы и так на своих местах, но лишним не будет.
WORKDIR /build/postgresql_modified_for_babelfish
RUN ./configure --prefix=/opt/postgres \
        --with-libxml --with-uuid=e2fs --with-icu --with-openssl \
        --with-gssapi --disable-werror && \
    make -j"$(nproc)" && make install && \
    mkdir -p /opt/postgres/include/server/src/include/lib && \
    cp src/include/lib/qunique.h /opt/postgres/include/server/src/include/lib/ && \
    mkdir -p /opt/postgres/include/server/src/backend/utils/mb/Unicode && \
    cp -v src/backend/utils/mb/Unicode/*.map \
       /opt/postgres/include/server/src/backend/utils/mb/Unicode/ && \
    cd contrib && make -j"$(nproc)" && make install

ENV PATH="/opt/postgres/bin:${PATH}"
ENV PG_CONFIG=/opt/postgres/bin/pg_config

# PostGIS — собирается через PGXS против нашего движка (не системного postgres)
WORKDIR /build
RUN wget -q https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz && \
    tar -xzf postgis-${POSTGIS_VERSION}.tar.gz && \
    cd postgis-${POSTGIS_VERSION} && \
    ./configure --with-pgconfig=/opt/postgres/bin/pg_config && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf postgis-${POSTGIS_VERSION} postgis-${POSTGIS_VERSION}.tar.gz

# tds_fdw — foreign data wrapper для linked servers (доступ из Babelfish к
# другим SQL Server/Babelfish инстансам по TDS). Не завязан на in-tree паттерн
# ниже — обычное независимое PGXS-расширение, собирается против нашего движка.
WORKDIR /build
RUN git clone --depth 1 --branch v${TDS_FDW_VERSION} \
        https://github.com/tds-fdw/tds_fdw.git && \
    cd tds_fdw && \
    make USE_PGXS=1 PG_CONFIG=/opt/postgres/bin/pg_config -j"$(nproc)" && \
    make USE_PGXS=1 PG_CONFIG=/opt/postgres/bin/pg_config install && \
    cd .. && rm -rf tds_fdw

# ANTLR C++ runtime — качаем архив исходников с GitHub Releases, а не с
# antlr.org (тот отдаёт по HTTP без TLS и исторически менее стабилен). Ищем
# собранную .so и в lib, и в lib64 — CMake на RHEL-семействе по умолчанию
# кладёт библиотеки в lib64, в отличие от Debian/Ubuntu.
WORKDIR /build
RUN cp /build/babelfish_extensions/contrib/babelfishpg_tsql/antlr/thirdparty/antlr/antlr-${ANTLR_VERSION}-complete.jar \
        /usr/local/lib/ && \
    wget -q https://github.com/antlr/antlr4/archive/refs/tags/${ANTLR_VERSION}.zip -O antlr4-source.zip && \
    unzip -q -d antlr4 antlr4-source.zip && \
    cd antlr4/antlr4-${ANTLR_VERSION}/runtime/Cpp && mkdir build && cd build && \
    /usr/local/bin/cmake .. \
        -DANTLR_JAR_LOCATION=/usr/local/lib/antlr-${ANTLR_VERSION}-complete.jar \
        -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_DEMO=False -DBUILD_SHARED_LIBS=ON && \
    make -j"$(nproc)" && make install && \
    find /usr/local/lib /usr/local/lib64 -maxdepth 1 -name "libantlr4-runtime.so*" \
        -exec cp {} /opt/postgres/lib/ \;

# Симлинк /src — часть сборочных скриптов Babelfish ссылается на этот
# абсолютный путь (унаследовано из их собственного CI/Docker-окружения).
RUN ln -sfn /build/postgresql_modified_for_babelfish/src /src

# Копируем исходники расширений Babelfish IN-TREE — см. пояснение в начале
# раздела про то, почему это необходимо именно для этих четырёх расширений.
WORKDIR /build/postgresql_modified_for_babelfish/contrib
RUN cp -r /build/babelfish_extensions/contrib/babelfishpg_money . && \
    cp -r /build/babelfish_extensions/contrib/babelfishpg_common . && \
    cp -r /build/babelfish_extensions/contrib/babelfishpg_tds . && \
    cp -r /build/babelfish_extensions/contrib/babelfishpg_tsql .

# Генерация Makefile для ANTLR уже в in-tree копии (не в исходном каталоге
# babelfish_extensions) — -DJava_JAVA_EXECUTABLE указан явно, в обход PATH,
# как дополнительная страховка поверх ENV JAVA_HOME/PATH выше.
RUN cd /build/postgresql_modified_for_babelfish/contrib/babelfishpg_tsql/antlr && \
    /usr/local/bin/cmake . \
        -DANTLR_JAR_LOCATION=/usr/local/lib/antlr-${ANTLR_VERSION}-complete.jar \
        -DJava_JAVA_EXECUTABLE=/usr/lib/jvm/java-17-openjdk/bin/java \
        -DCMAKE_PREFIX_PATH=/usr/local -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    make -j"$(nproc)"

# Сборка расширений Babelfish. babelfishpg_common и babelfishpg_tsql собираются
# с -DENABLE_SPATIAL_TYPES (geometry/geography через PostGIS) и, для tsql,
# дополнительно с -DENABLE_TDS_LIB (поддержка linked servers через tds_fdw).
# PG_CONFIG передаётся явным аргументом make на каждый вызов — не полагаемся
# только на ENV, чтобы точно не промахнуться мимо нашего движка.
WORKDIR /build/postgresql_modified_for_babelfish/contrib/babelfishpg_money
RUN make PG_CONFIG=/opt/postgres/bin/pg_config && \
    make PG_CONFIG=/opt/postgres/bin/pg_config install

WORKDIR /build/postgresql_modified_for_babelfish/contrib/babelfishpg_common
RUN PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES' \
        make PG_CONFIG=/opt/postgres/bin/pg_config && \
    PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES' \
        make PG_CONFIG=/opt/postgres/bin/pg_config install

WORKDIR /build/postgresql_modified_for_babelfish/contrib/babelfishpg_tds
RUN make PG_CONFIG=/opt/postgres/bin/pg_config && \
    make PG_CONFIG=/opt/postgres/bin/pg_config install

WORKDIR /build/postgresql_modified_for_babelfish/contrib/babelfishpg_tsql
RUN PG_CPPFLAGS='-I/usr/include -I/usr/local/include -I/usr/local/include/antlr4-runtime -DENABLE_SPATIAL_TYPES -DENABLE_TDS_LIB' \
        SHLIB_LINK='-lsybdb -L/usr/lib64 -L/usr/local/lib -lantlr4-runtime' \
        make PG_CONFIG=/opt/postgres/bin/pg_config && \
    PG_CPPFLAGS='-I/usr/include -I/usr/local/include -I/usr/local/include/antlr4-runtime -DENABLE_SPATIAL_TYPES -DENABLE_TDS_LIB' \
        SHLIB_LINK='-lsybdb -L/usr/lib64 -L/usr/local/lib -lantlr4-runtime' \
        make PG_CONFIG=/opt/postgres/bin/pg_config install

########################################
# Этап 2: runtime (та же версия базы, что и builder — важно для ABI-совместимости)
########################################
FROM almalinux:9 AS runtime

RUN dnf update -y && \
    dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
        libicu libxml2 openssl libuuid krb5-libs \
        readline zlib \
        geos proj gdal json-c protobuf-c sqlite-libs \
        freetds \
        glibc-langpack-en \
        shadow-utils \
        libstdc++ && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# readline/zlib здесь обязательны: builder не передаёт --without-readline
# --without-zlib в ./configure, и раз readline-devel/zlib-devel присутствуют
# в builder, PostgreSQL сам включит их поддержку — psql/pg_dump в итоге
# слинкованы против libreadline.so/libz.so. Без этих пакетов здесь получите
# "error while loading shared libraries" при первом же запуске psql.
# libstdc++ — ANTLR4 C++ runtime (и слинкованный с ним babelfishpg_tsql.so)
# это C++-код, без libstdc++.so контейнер не запустится вообще.

# Явная проверка локали вместо тихой попытки генерации — если glibc-langpack-en
# по какой-то причине не сгенерировал локаль через свой RPM-триггер, сборка
# должна упасть здесь же, с понятным сообщением, а не позже — молча на
# initdb --locale=en_US.UTF-8 внутри entrypoint.sh уже в проде. Обратите
# внимание на формат: locale -a реально выводит "en_US.utf8" (без дефиса,
# нижний регистр), а не "en_US.UTF-8" — частая причина ложного срабатывания
# grep, если писать по аналогии с ENV LANG.
RUN if locale -a | grep -q "en_US.utf8"; then \
        echo "Locale en_US.UTF-8 is available"; \
    else \
        echo "ERROR: en_US.UTF-8 locale not found!" && exit 1; \
    fi

# Пользователь без прав root для запуска postgres, БЕЗ домашней директории —
# для системного сервисного аккаунта она не нужна (не предназначен для
# интерактивного логина); отсутствие $HOME компенсируется ниже через
# ENV PSQL_HISTORY=/dev/null, чтобы psql не пытался писать историю команд
# в несуществующий каталог.
# UID/GID 26 — исторически закреплены за postgres в Fedora/RHEL/AlmaLinux
# (пакет postgresql-server), в отличие от Debian/Ubuntu, где принято 999/70.
RUN groupadd -r postgres --gid=26 && \
    useradd -r -g postgres --uid=26 --shell=/bin/bash postgres && \
    mkdir -p /var/storage/pgsql/data && \
    chown -R postgres:postgres /var/storage/pgsql

COPY --from=builder /opt/postgres /opt/postgres

# Символические ссылки на версионированные имена библиотек. Babelfish
# ссылается на некоторые свои .so через module_pathname с внутренним ABI-
# суффиксом (не совпадающим с номером релиза), не всегда равным голому
# имени файла из make install. Суффикс "-5" подобран под BABEL_5_4_0 —
# при смене версии Babelfish перепроверьте актуальность этого номера
# (например, по ошибке "could not access file ... babelfishpg_tsql-N"
# при CREATE EXTENSION, если суффикс окажется не тем).
RUN ln -s /opt/postgres/lib/babelfishpg_tsql.so /opt/postgres/lib/babelfishpg_tsql-5.so && \
    ln -s /opt/postgres/lib/babelfishpg_common.so /opt/postgres/lib/babelfishpg_common-5.so

# ldconfig — здесь, а не в builder-этапе: builder и runtime это два разных
# FROM, кэш линковщика из builder не переживает переход между стадиями,
# копируются только сами .so-файлы через COPY --from=builder. Обновлять
# кэш нужно после того, как файлы физически оказались в этом слое.
RUN ldconfig

ENV PATH="/opt/postgres/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/postgres/lib:${LD_LIBRARY_PATH}"
ENV PGDATA=/var/storage/pgsql/data
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PSQL_HISTORY=/dev/null

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

VOLUME ["/var/storage/pgsql/data"]

EXPOSE 5432 1433

# Встроенный healthcheck на уровне самого образа — работает даже если контейнер
# запущен не через Quadlet (например, при разовом podman run в ходе отладки).
# Логика вынесена в отдельный скрипт (раздел 8) — читаемее, чем длинный inline CMD.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

USER postgres
ENTRYPOINT ["entrypoint.sh"]
```

Комментарии по ключевым решениям:
- `--with-uuid=e2fs` и `--disable-werror` — обходные пути под более строгий gcc/новый OpenSSL, чем на Ubuntu, где тестирует сам проект.
- `--with-gssapi` — включает поддержку Kerberos-аутентификации; `krb5-devel` уже стоит в builder-этапе, а `krb5-libs` — в runtime, отдельно ничего добавлять не нужно.
- PostGIS и tds_fdw собираются через PGXS против нашего собственного движка (`--with-pgconfig`/`PG_CONFIG=/opt/postgres/bin/pg_config`), а не системного `postgres` — иначе расширения попадут не туда.
- `-DENABLE_TDS_LIB` и `SHLIB_LINK='-lsybdb -L/usr/lib64 -L/usr/local/lib -lantlr4-runtime'` при сборке `babelfishpg_tsql` — обязательное условие для поддержки linked servers через tds_fdw и корректной линковки с ANTLR runtime; без первого флага расширение соберётся, но T-SQL код, обращающийся к linked server, будет падать с ошибкой.
- Runtime-образ не содержит компиляторов и dev-заголовков (только рантайм-версии `geos`/`proj`/`gdal`/`freetds`/`readline`/`zlib`/`libstdc++` без `-devel`) — меньше размер и площадь атаки.
- Контейнер работает от непривилегированного пользователя `postgres` (uid/gid 26 — стандарт для EL-дистрибутивов), без домашней директории (не нужна системному сервисному аккаунту) — `PSQL_HISTORY=/dev/null` компенсирует отсутствие `$HOME` для истории команд `psql`.
- `glibc-langpack-en` в runtime и `ENV LANG=en_US.UTF-8`/`LC_ALL=en_US.UTF-8` — без этого пакета `initdb --locale=en_US.UTF-8` в `entrypoint.sh` (раздел 7) упадёт на минимальном образе, где эта локаль не сгенерирована.
- `HEALTHCHECK` в самом образе — это дополнение, а не замена `HealthCmd=` в Quadlet-юните (раздел 12): Quadlet-версия управляется systemd и видна в `systemctl status`, встроенная в образ — работает независимо от способа запуска контейнера.
- `CMD` больше нет — `entrypoint.sh` теперь сам явно вызывает `exec /opt/postgres/bin/postgres -D "$PGDATA"` в конце (раздел 7), а не полагается на `"$@"` из `CMD ["postgres"]`.

---

## 7. `entrypoint.sh`

```bash
#!/bin/bash
set -euo pipefail

PGDATA="${PGDATA:-/var/storage/pgsql/data}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
BABELFISH_USER="${BABELFISH_USER:-babelfish_user}"
BABELFISH_PASS="${BABELFISH_PASS:-$POSTGRES_PASSWORD}"
BABELFISH_DB="${BABELFISH_DB:-babelfish_db}"
# Дефолт multi-db — основной режим для продакшена в этом гайде: одна БД
# Babelfish экспонирует несколько "логических" T-SQL баз одновременно
# (каждая — комбинация схем в Postgres). В боевом Quadlet-юните (раздел 12)
# значение всё равно всегда передаётся явно через Environment=, так что этот
# дефолт актуален только при запуске образа без явной настройки.
BABELFISH_MIGRATION_MODE="${BABELFISH_MIGRATION_MODE:-multi-db}"
ENABLE_POSTGIS="${ENABLE_POSTGIS:-true}"
ENABLE_TDS_FDW="${ENABLE_TDS_FDW:-true}"
# Опционально: заглушки под GUI-клиенты (SSMS/Azure Data Studio) — см. пояснение
# после блока кода. Не официальная часть Babelfish, чисто quality-of-life.
ENABLE_GUI_CLIENT_STUBS="${ENABLE_GUI_CLIENT_STUBS:-false}"

init_db() {
    echo "[entrypoint] Инициализация нового кластера в $PGDATA"

    # Пароль через временный файл вместо process substitution — эквивалентно
    # по безопасности (не светится в аргументах команды/ps), но чуть надёжнее
    # переносится между разными реализациями shell/initdb.
    printf "%s" "$POSTGRES_PASSWORD" > /tmp/pgpass
    chmod 600 /tmp/pgpass
    /opt/postgres/bin/initdb -D "$PGDATA" --username=postgres --pwfile=/tmp/pgpass \
        --encoding=UTF8 --locale=en_US.UTF-8
    rm -f /tmp/pgpass

    {
        echo "listen_addresses = '*'"
        echo "port = 5432"
        # ВАЖНО: TDS-протокол (используется SQL Server-клиентами — sqlcmd, tsql,
        # SSMS) не поддерживает SCRAM-SHA-256 — это ограничение самого TDS
        # wire-протокола, а не PostgreSQL. babelfishpg_tds для аутентификации
        # клиентов, подключающихся по 1433, нуждается в md5 (или trust/gssapi).
        # scram-sha-256 здесь означает, что аутентификация по TDS не будет
        # работать вообще, даже если обычный psql по 5432 подключается нормально.
        echo "password_encryption = 'md5'"
        echo "shared_preload_libraries = 'babelfishpg_tds'"
        echo "babelfishpg_tds.listen_addresses = '0.0.0.0'"
        echo "babelfishpg_tds.port = 1433"
    } >> "$PGDATA/postgresql.conf"

    # Полностью переопределяем pg_hba.conf, а не дописываем к дефолту от
    # initdb — так весь набор разрешённых подключений явный и предсказуемый,
    # а не зависит от того, что именно сгенерировал initdb по умолчанию.
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

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='localhost'" -w start || {
        echo "[entrypoint] Не удалось запустить PostgreSQL"
        exit 1
    }

    # Пароль и идентификаторы — через psql-переменные (--set + :'pw' / :"usr"),
    # а не подставляются напрямую в SQL-строку. :'x' — безопасный строковый
    # литерал, :"x" — безопасный quoted identifier; оба защищают от спецсимволов
    # в значении и от SQL-инъекции в собственном bootstrap-скрипте.
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --set pw="${BABELFISH_PASS}" --set db="${BABELFISH_DB}" --set usr="${BABELFISH_USER}" <<-SQL
        CREATE USER :"usr" WITH CREATEDB CREATEROLE PASSWORD :'pw' INHERIT;
        DROP DATABASE IF EXISTS :"db";
        CREATE DATABASE :"db" OWNER :"usr";
SQL

    # Оба расширения создаём явно, а не полагаемся на CASCADE от одного —
    # неизвестно заранее, кто от кого зависит в графе (tsql тянет tds+common,
    # или наоборот), безопаснее не гадать.
    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
        CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;

        -- sys — служебная схема Babelfish, обязательна.
        GRANT ALL ON SCHEMA sys TO :"usr";

        -- dbo — схема по умолчанию для пользовательских T-SQL объектов;
        -- владение базой само по себе не даёт прав на конкретную схему.
        GRANT ALL ON SCHEMA dbo TO :"usr";
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA dbo TO :"usr";
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA dbo TO :"usr";
        GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA dbo TO :"usr";
        ALTER DEFAULT PRIVILEGES IN SCHEMA dbo GRANT ALL ON TABLES TO :"usr";
        ALTER DEFAULT PRIVILEGES IN SCHEMA dbo GRANT ALL ON SEQUENCES TO :"usr";
        ALTER DEFAULT PRIVILEGES IN SCHEMA dbo GRANT ALL ON FUNCTIONS TO :"usr";
SQL

    if [ "$ENABLE_POSTGIS" = "true" ]; then
        echo "[entrypoint] Включаю PostGIS в ${BABELFISH_DB}"
        /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
            CREATE EXTENSION IF NOT EXISTS postgis;
SQL
    fi

    if [ "$ENABLE_TDS_FDW" = "true" ]; then
        echo "[entrypoint] Включаю tds_fdw в ${BABELFISH_DB}"
        /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
            CREATE EXTENSION IF NOT EXISTS tds_fdw;
SQL
    fi

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres \
        --set db="${BABELFISH_DB}" --set mode="${BABELFISH_MIGRATION_MODE}" <<-SQL
        ALTER SYSTEM SET babelfishpg_tsql.database_name = :'db';
        ALTER DATABASE :"db" SET babelfishpg_tsql.migration_mode = :'mode';
        SELECT pg_reload_conf();
SQL

    /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" \
        --set usr="${BABELFISH_USER}" <<-SQL
        CALL SYS.INITIALIZE_BABELFISH(:'usr');
SQL

    if [ "$ENABLE_GUI_CLIENT_STUBS" = "true" ]; then
        echo "[entrypoint] Добавляю заглушки для GUI-клиентов (SSMS/Azure Data Studio) в ${BABELFISH_DB}"
        /opt/postgres/bin/psql -v ON_ERROR_STOP=1 --username postgres --dbname "${BABELFISH_DB}" <<-SQL
            CREATE OR REPLACE VIEW sys.dm_os_windows_info AS
            SELECT
                '10.0' AS windows_release,
                'Linux' AS windows_service_pack_level,
                0 AS windows_sku,
                0 AS os_language_version;

            CREATE OR REPLACE PROCEDURE dbo.xp_msver()
            LANGUAGE sql
            AS \$sql\$
                SELECT 1, 'ProductName'::text, 0, 'Babelfish for PostgreSQL'::text
                UNION ALL SELECT 2, 'ProductVersion', 0, '17.7.0'
                UNION ALL SELECT 3, 'Language', 0, 'English (United States)'
                UNION ALL SELECT 4, 'Platform', 0, 'Linux'
            \$sql\$;

            -- master_dbo — то же самое для вызовов master.dbo.xp_msver
            -- (некоторые клиенты обращаются именно так, а не через dbo напрямую)
            CREATE OR REPLACE PROCEDURE master_dbo.xp_msver()
            LANGUAGE sql
            AS \$sql\$
                SELECT 1, 'ProductName'::text, 0, 'Babelfish for PostgreSQL'::text
                UNION ALL SELECT 2, 'ProductVersion', 0, '17.7.0'
                UNION ALL SELECT 3, 'Language', 0, 'English (United States)'
                UNION ALL SELECT 4, 'Platform', 0, 'Linux'
            \$sql\$;

            GRANT SELECT ON sys.dm_os_windows_info TO PUBLIC;
            GRANT EXECUTE ON PROCEDURE dbo.xp_msver() TO PUBLIC;
            GRANT EXECUTE ON PROCEDURE master_dbo.xp_msver() TO PUBLIC;
SQL
    fi

    /opt/postgres/bin/pg_ctl -D "$PGDATA" -m fast -w stop
    echo "[entrypoint] Инициализация завершена"
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    init_db
else
    echo "[entrypoint] Существующий кластер обнаружен в $PGDATA, инициализация пропущена"
fi

exec /opt/postgres/bin/postgres -D "$PGDATA"
```

`ENABLE_POSTGIS` и `ENABLE_TDS_FDW` по умолчанию `true`, так как оба расширения уже собраны в образ (раздел 6). Поставьте `Environment=ENABLE_POSTGIS=false` и/или `Environment=ENABLE_TDS_FDW=false` в Quadlet-юните, если что-то из этого не нужно в конкретной базе.

Обратите внимание: `CREATE EXTENSION tds_fdw` только регистрирует сам foreign data wrapper — сервер и логин для конкретного linked server (`CREATE SERVER ... FOREIGN DATA WRAPPER tds_fdw`, `CREATE USER MAPPING ...`) нужно создавать вручную под свои реквизиты подключения, автоматизировать это в entrypoint нельзя.

**Про заглушки GUI-клиентов (`ENABLE_GUI_CLIENT_STUBS`):** это не официально документированная функциональность Babelfish, а самодельный обход конкретных ошибок, с которыми иногда сталкиваются SSMS/Azure Data Studio при подключении (эти инструменты пытаются вызвать `xp_msver`/прочитать `sys.dm_os_windows_info` при коннекте). По умолчанию выключено (`false`) — включайте, только если реально столкнулись с проблемой подключения именно этих клиентов; для `sqlcmd`/`tsql`/обычных приложений не требуется.

**Про `password_encryption = 'md5'`:** это наиболее вероятная причина, почему T-SQL/TDS-функционал ещё не был подтверждён рабочим в более ранних итерациях этого гайда (см. раздел 28) — TDS как wire-протокол не умеет в SCRAM. Сама эта гипотеза пока тоже не проверена end-to-end реальным TDS-подключением — проверьте после разворачивания и обновите раздел 28, если что-то не сойдётся.

**Важно про порядок:** пароль суперпользователя ставится через `--pwfile` **на этапе `initdb`**, до какого-либо `psql`-подключения. Не переставляйте это на `ALTER USER postgres PASSWORD ...` через `psql` сразу после `initdb`, но до `pg_ctl start` — сервер в этот момент ещё не запущен, `psql` не сможет подключиться, скрипт упадёт на `set -e`, а `PG_VERSION` уже будет создан — при следующем перезапуске контейнера entrypoint решит, что кластер уже проинициализирован, и молча пропустит весь блок.

```bash
chmod +x entrypoint.sh
```

---

## 8. `healthcheck.sh`

Логика healthcheck вынесена в отдельный файл вместо длинной inline-команды в `HEALTHCHECK` — легче читать и менять отдельно от остального `Containerfile`.

```bash
#!/bin/bash
set -e
pg_isready -U "${BABELFISH_USER:-babelfish_user}" -d "${BABELFISH_DB:-babelfish_db}" || exit 1
```

`set -e` тут не спасает от ненулевого кода самого `pg_isready` внутри `||`-конструкции (проверка в условии не считается "падением" для `set -e`) — поэтому явный `exit 1` обязателен.

```bash
chmod +x healthcheck.sh
```

---

## 9. Сборка образа

```bash
cd /opt/babelfish-image
sudo podman build -t localhost/babelfish:5.4.0-pg17.7 \
    --build-arg PG_BABEL_TAG=BABEL_5_4_0__PG_17_7 \
    --build-arg EXT_BABEL_TAG=BABEL_5_4_0 \
    -f Containerfile .
```

Сборка компилирует PostgreSQL + 4 расширения + PostGIS + tds_fdw — рассчитывайте на 15–40 минут в зависимости от мощности сервера. Логи компиляции идут в стандартный вывод — если что-то падает, ошибка будет видна прямо в терминале.

---

## 10. Секреты (пароли)

Хранить пароль прямо в `.container`-файле как `Environment=POSTGRES_PASSWORD=...` небезопасно: файл юнита читаем в `/etc/containers/systemd/` (обычно `644`), попадает в systemd journal при отладке, может оказаться в бэкапах конфигов/git. Два корректных варианта:

### 10.1. Env-файл с ограниченными правами (использован в этом гайде)

```bash
sudo install -d -m 700 /etc/babelfish
sudo bash -c '{
    echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
    echo "BABELFISH_PASS=$(openssl rand -base64 24)"
} > /etc/babelfish/babelfish.env'
sudo chmod 600 /etc/babelfish/babelfish.env
```

Два независимых пароля, а не один общий: `POSTGRES_PASSWORD` — суперпользователь `postgres` внутри кластера, `BABELFISH_PASS` — прикладной логин (`BABELFISH_USER`, по умолчанию `babelfish_user`), которым реально будут подключаться приложения по TDS. Если задать только `POSTGRES_PASSWORD`, `entrypoint.sh` по умолчанию использует его же и для `BABELFISH_PASS` — так что разделение строго опционально, но раз утечка пароля приложения не должна означать утечку пароля суперпользователя БД, разумно их развести.

В Quadlet-юните вместо `Environment=` используем `EnvironmentFile=/etc/babelfish/babelfish.env`.

### 10.2. `podman secret` (более строгий вариант)

```bash
openssl rand -base64 24 | sudo podman secret create babelfish_pg_password -
openssl rand -base64 24 | sudo podman secret create babelfish_user_password -
sudo podman secret ls
```

Секреты подключаются к контейнеру как файлы в `/run/secrets/<name>`. Поскольку образ собственной сборки, поддержку чтения пароля из файла (а не из значения переменной) можно добавить прямо в `entrypoint.sh` — буквально несколько строк вида `POSTGRES_PASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"`. В текущей версии `entrypoint.sh` (раздел 7) этой доработки нет — используется вариант 10.1.

---

## 11. Директории, volume и SELinux

```bash
sudo mkdir -p /var/storage/pgsql/data
sudo chown 26:26 /var/storage/pgsql/data   # UID/GID postgres внутри контейнера (раздел 6) —
                                             # без этого initdb упадёт с Permission denied,
                                             # т.к. контейнер пишет от непривилегированного
                                             # пользователя, а не от root
sudo chmod 750 /var/storage/pgsql/data
```

Под SELinux контейнеру по умолчанию **запрещена** запись в произвольный каталог хоста. Есть два корректных решения (без `setenforce 0`):

1. **Suffix `:Z`/`:z` в определении volume** (используем ниже) — Podman сам проставит нужную SELinux-метку (`container_file_t`) при монтировании. `:Z` — приватный volume (только этот контейнер), `:z` — общий (несколько контейнеров).
2. Альтернатива — вручную задать контекст через `semanage fcontext` + `restorecon`, если `:Z/:z` почему-то не годится.

Для одиночного контейнера с БД `:Z` — то, что нужно.

---

## 12. Боевой Quadlet-юнит

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

# TDS (SQL Server протокол) наружу, Postgres-протокол только на loopback
PublishPort=1433:1433
PublishPort=127.0.0.1:5432:5432

# Данные — постоянный volume с корректной SELinux-меткой. Путь одинаковый
# на хосте и внутри контейнера (совпадает с PGDATA из Containerfile,
# см. раздел 6) — меньше путаницы при отладке.
Volume=/var/storage/pgsql/data:/var/storage/pgsql/data:Z

EnvironmentFile=/etc/babelfish/babelfish.env
Environment=BABELFISH_USER=babelfish_user
Environment=BABELFISH_DB=babelfish_db
Environment=BABELFISH_MIGRATION_MODE=multi-db
# По желанию — выключить встроенные PostGIS/tds_fdw для конкретной базы:
# Environment=ENABLE_POSTGIS=false
# Environment=ENABLE_TDS_FDW=false

# Ограничения ресурсов — подберите под свой сервер
PodmanArgs=--memory=4g --cpus=2

# Healthcheck на уровне Quadlet (дополняет HEALTHCHECK, встроенный в образ —
# см. раздел 23)
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

Комментарии по конкретным строкам:
- `PublishPort=127.0.0.1:5432:5432` — обычный Postgres-порт публикуется только на loopback, чтобы наружу торчал лишь TDS (1433). Если нужен внешний доступ и по 5432 — уберите `127.0.0.1:`.
- `Image=...:5.4.0-pg17.7` — версия зафиксирована явно. **Не используйте `latest` в проде** — обновление должно быть осознанным действием (раздел 19).
- Если публиковали образ в свой registry (раздел 24) — укажите полный путь (`registry.example.internal/babelfish:5.4.0-pg17.7`) вместо `localhost/...`.

---

## 13. Запуск и управление сервисом

```bash
sudo systemctl daemon-reload
sudo systemctl start babelfish.service
sudo systemctl status babelfish.service
```

Quadlet сам генерирует юнит как `WantedBy=multi-user.target`, поэтому автозапуск на загрузке хоста уже включён; явный `enable` не обязателен, но не помешает:

```bash
sudo systemctl enable babelfish.service
```

Полезные команды:

```bash
sudo systemctl restart babelfish.service
sudo systemctl stop babelfish.service
sudo podman ps                              # проверить, что контейнер работает
sudo podman inspect babelfish --format '{{.State.Health.Status}}'
journalctl -u babelfish.service -f          # логи в реальном времени
journalctl -u babelfish.service --since "1 hour ago"
```

---

## 14. Firewall

```bash
sudo firewall-cmd --permanent --add-port=1433/tcp
# Если решили публиковать 5432 наружу, а не только на localhost:
# sudo firewall-cmd --permanent --add-port=5432/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

Если инфраструктура позволяет — ограничьте доступ конкретной подсетью через `firewall-cmd --permanent --add-rich-rule=...` или через zone, а не открывайте порт для `0.0.0.0/0`.

---

## 15. Первоначальная проверка базы

После первого старта `entrypoint.sh` сам инициализирует кластер и создаёт пользователя/базу из переменных окружения. Проверяем:

```bash
sudo podman exec -it babelfish bash
psql -U babelfish_user -d babelfish_db -c "\conninfo"
psql -U babelfish_user -d babelfish_db -c "SHOW babelfishpg_tsql.migration_mode;"
```

Если нужно добавить ещё одну "логическую" базу (типично для `multi-db` — каждая T-SQL база в SQL Server соответствует отдельной Postgres-базе с собственным набором расширений и прав):

```sql
CREATE DATABASE my_app_db;
\c my_app_db
CREATE EXTENSION IF NOT EXISTS "babelfishpg_tsql" CASCADE;
CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
GRANT ALL ON SCHEMA sys TO babelfish_user;
GRANT ALL ON SCHEMA dbo TO babelfish_user;
```

Проверка подключения через FreeTDS (`tsql`, уже установлен в разделе 4):

```bash
tsql -H <IP-сервера> -p 1433 -U babelfish_user -P '<значение BABELFISH_PASS из /etc/babelfish/babelfish.env>'
```

---

## 16. TLS/SSL

Для продакшена нешифрованные подключения — плохая идея, особенно если 1433 торчит наружу.

1. Сертификат (self-signed для теста, от внутреннего CA — для прода):

```bash
sudo mkdir -p /var/storage/pgsql/tls
cd /var/storage/pgsql/tls
sudo openssl req -new -x509 -days 365 -nodes \
    -out server.crt -keyout server.key \
    -subj "/CN=babelfish.internal.example.com"
sudo chmod 600 server.key
sudo chown 26:26 server.key server.crt
```

2. Volume с сертификатами в Quadlet-юнит (раздел 12):
```ini
Volume=/var/storage/pgsql/tls:/certs:Z,ro
```

3. Внутри контейнера (`podman exec` + `ALTER SYSTEM`):
```sql
ALTER SYSTEM SET ssl = 'on';
ALTER SYSTEM SET ssl_cert_file = '/certs/server.crt';
ALTER SYSTEM SET ssl_key_file = '/certs/server.key';
SELECT pg_reload_conf();
```

4. Подключение с проверкой SSL:
```bash
sqlcmd -N -C -S <host>,1433 -U babelfish_user -P '<пароль>'
```
`-N` — включить шифрование, `-C` — доверять self-signed сертификату (для прод-сертификата от доверенного CA этот флаг не нужен).

---

## 17. Подключение клиентов

**FreeTDS / tsql**:
```bash
tsql -H <host> -p 1433 -U babelfish_user -P '<пароль>'
```

**sqlcmd** (если ставили mssql-tools):
```bash
sqlcmd -S <host>,1433 -U babelfish_user -P '<пароль>' -d babelfish_db
```

**psql** (Postgres-сторона, если 5432 доступен):
```bash
psql -h <host> -p 5432 -U babelfish_user -d babelfish_db
```

**JDBC** — стандартный Postgres JDBC-драйвер или MS JDBC-драйвер: `jdbc:sqlserver://<host>:1433;databaseName=babelfish_db;...`

**ODBC / SSMS** — подключение через New Query как к обычному SQL Server-инстансу; Object Explorer в SSMS Babelfish официально не поддерживает.

---

## 18. Резервное копирование и восстановление

Внутри — обычный PostgreSQL, работают стандартные инструменты:

```bash
sudo podman exec babelfish pg_dump -U babelfish_user -Fc babelfish_db > /var/backups/babelfish_$(date +%F).dump
```

Восстановление:
```bash
sudo podman exec -i babelfish pg_restore -U babelfish_user -d babelfish_db --clean < /var/backups/babelfish_2026-08-29.dump
```

"Холодный" бэкап данных целиком — копируем volume, предварительно остановив сервис:
```bash
sudo systemctl stop babelfish.service
sudo tar -czf /var/backups/babelfish-data-$(date +%F).tar.gz -C /var/storage/pgsql data
sudo systemctl start babelfish.service
```

Автоматизация — systemd timer или cron, вызывающий `pg_dump` по расписанию с ротацией старых бэкапов.

---

## 19. Обновление образа и откат

```bash
# 1. Бэкап перед обновлением — обязательно (раздел 18)
sudo podman exec babelfish pg_dump -U babelfish_user -Fc babelfish_db > /var/backups/pre-upgrade.dump

# 2. Пересобрать образ с новым тегом релиза Babelfish (пример для 5.5.0/PG 17.8)
cd /opt/babelfish-image
sudo podman build -t localhost/babelfish:5.5.0-pg17.8 \
    --build-arg PG_BABEL_TAG=BABEL_5_5_0__PG_17_8 \
    --build-arg EXT_BABEL_TAG=BABEL_5_5_0 \
    -f Containerfile .

# 3. Поменять тег в /etc/containers/systemd/babelfish.container
#    Image=localhost/babelfish:5.5.0-pg17.8

# 4. Применить
sudo systemctl daemon-reload
sudo systemctl restart babelfish.service

# 5. Проверить
sudo podman logs babelfish --tail 50
```

`EXT_BABEL_TAG` для новой версии — сначала проверить командой `git ls-remote` (раздел 6), не полагаться на угадывание по аналогии.

Откат — верните старый тег в файле юнита (старый образ остаётся в локальном хранилище Podman, если вы его не удаляли), `daemon-reload` + `restart`; если менялась мажорная схема данных — восстановление из дампа, сделанного в шаге 1.

---

## 20. Мониторинг, логи, healthcheck (эксплуатация)

```bash
sudo podman inspect babelfish --format '{{.State.Health.Status}}'
journalctl -u babelfish.service -f
sudo podman stats babelfish
```

Для интеграции с внешним мониторингом (Prometheus и т.д.) — стандартный `postgres_exporter` можно запустить как обычный процесс или отдельный контейнер на том же хосте и указать на уже опубликованный `127.0.0.1:5432` (раздел 12) — отдельная сеть для этого не нужна.

---

## 21. PostGIS / Spatial Datatypes (уже встроено)

Babelfish умеет транслировать T-SQL типы `geometry`/`geography` и функции вроде `STPoint`, `STArea`, `STContains`, `STDistance` и т.д. поверх PostGIS. В `Containerfile` (раздел 6) это уже включено по умолчанию:

- в builder-этап добавлены `geos`, `proj`, `gdal` (+`-devel`), `json-c-devel`, `protobuf-c-devel`, `sqlite-devel` — все версии берутся из EPEL9/CRB, отдельно компилировать GEOS/PROJ из исходников не нужно;
- PostGIS собирается через PGXS-механизм с флагом `--with-pgconfig=/opt/postgres/bin/pg_config`, против нашего собственного движка;
- `babelfishpg_common` и `babelfishpg_tsql` собираются с флагом `PG_CPPFLAGS='-I/usr/include -DENABLE_SPATIAL_TYPES'`;
- runtime-этап содержит рантайм-версии `geos`/`proj`/`gdal` без `-devel`;
- `entrypoint.sh` (раздел 7) выполняет `CREATE EXTENSION postgis` при первой инициализации базы, если не отключено.

### 21.1. Как отключить, если PostGIS не нужен

```ini
Environment=ENABLE_POSTGIS=false
```

в Quadlet-юните — сама библиотека останется в образе, просто `CREATE EXTENSION` не выполнится. Полностью убрать из образа (уменьшить размер) — вырезать соответствующие пакеты и шаг сборки PostGIS из `Containerfile`, с пересборкой.

### 21.2. Проверка

```sql
SELECT geometry::STGeomFromText('POINT(1 1)', 4326).STAsText();
```

Должно вернуть `POINT (1 1)` без ошибок о неизвестном типе.

### 21.3. Известные ограничения

- Поддерживаются не все геопространственные функции T-SQL — конкретный список зависит от версии Babelfish.
- Версию PostGIS привязывайте к тому, что реально тестировалось с вашей версией Babelfish — расхождения версий GEOS/PROJ иногда меняют точность вычислений на границах координатной сетки.

---

## 22. tds_fdw / Linked Servers (уже встроено)

`tds_fdw` — foreign data wrapper, позволяющий из Babelfish обращаться к другим SQL Server/Babelfish инстансам по TDS. В `Containerfile` (раздел 6) уже включено по умолчанию:

- в builder-этап добавлен `freetds-devel`;
- `tds_fdw` собирается через PGXS против нашего собственного движка;
- `babelfishpg_tsql` пересобирается с `-DENABLE_TDS_LIB` и `SHLIB_LINK='-lsybdb -L/usr/lib64 -L/usr/local/lib -lantlr4-runtime'`;
- runtime-этап содержит пакет `freetds` (без `-devel`);
- `entrypoint.sh` выполняет `CREATE EXTENSION tds_fdw` при первой инициализации, если не отключено переменной `ENABLE_TDS_FDW`.

### 22.1. Настройка конкретного linked server

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

### 22.2. Как отключить, если не нужно

```ini
Environment=ENABLE_TDS_FDW=false
```

Полностью убрать из образа — вырезать шаг сборки `tds_fdw` и флаги `-DENABLE_TDS_LIB`/`SHLIB_LINK` из сборки `babelfishpg_tsql`, с пересборкой.

---

## 23. Healthcheck на уровне образа (уже встроено)

В `Containerfile` (раздел 6) — нативная инструкция `HEALTHCHECK`, вызывающая `healthcheck.sh` (раздел 8):

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh
```

Это дополняет, а не заменяет `HealthCmd=` в самом Quadlet-юните (раздел 12):

| | `HEALTHCHECK` в образе | `HealthCmd=` в Quadlet |
|---|---|---|
| Работает при запуске | Через любой инструмент (Podman/Docker, включая ручной `podman inspect`) | Только когда контейнер управляется через systemd/Quadlet |
| Приоритет | Если задан и в образе, и в Quadlet-юните, значения из `.container`-файла переопределяют встроенный в образ `HEALTHCHECK` | |

Проверка вручную:
```bash
sudo podman inspect babelfish --format '{{.State.Health.Status}}'
sudo podman healthcheck run babelfish
```

---

## 24. Публикация в приватный registry (опционально)

Если образ нужен на нескольких хостах:

```bash
sudo podman tag localhost/babelfish:5.4.0-pg17.7 registry.example.internal/babelfish:5.4.0-pg17.7
sudo podman push registry.example.internal/babelfish:5.4.0-pg17.7
```

---

## 25. CI-сборка (пример GitHub Actions)

```yaml
name: build-babelfish-image
on:
  workflow_dispatch:
    inputs:
      pg_babel_tag:
        description: 'Тег релиза postgresql_modified_for_babelfish'
        default: 'BABEL_5_4_0__PG_17_7'
      ext_babel_tag:
        description: 'Тег релиза babelfish_extensions (может отличаться от pg_babel_tag — см. раздел 6)'
        default: 'BABEL_5_4_0'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build image with Podman
        run: |
          podman build -t babelfish:${{ github.event.inputs.pg_babel_tag }} \
            --build-arg PG_BABEL_TAG=${{ github.event.inputs.pg_babel_tag }} \
            --build-arg EXT_BABEL_TAG=${{ github.event.inputs.ext_babel_tag }} \
            -f Containerfile .
      - name: Push to registry
        run: |
          podman login registry.example.internal -u "${{ secrets.REGISTRY_USER }}" -p "${{ secrets.REGISTRY_PASS }}"
          podman tag babelfish:${{ github.event.inputs.pg_babel_tag }} registry.example.internal/babelfish:${{ github.event.inputs.pg_babel_tag }}
          podman push registry.example.internal/babelfish:${{ github.event.inputs.pg_babel_tag }}
```

---

## 26. Диагностика типичных проблем

| Симптом | Причина | Решение |
|---|---|---|
| `permission denied` при старте, ошибки записи в data-каталог | SELinux не пускает контейнер в volume хоста, либо не выполнен `chown 26:26` на хостовую директорию | Проверить суффикс `:Z` в `Volume=`; `sudo chown 26:26 /var/storage/pgsql/data`; `ausearch -m avc -ts recent` для деталей |
| Контейнер не стартует, `Address already in use` | Порт 1433/5432 занят другим процессом | `sudo ss -tlnp \| grep -E '1433\|5432'`, освободить порт или сменить `PublishPort` |
| Юнит не подхватывается systemd-ом | Не выполнен `daemon-reload` после создания/правки Quadlet-файлов | `sudo systemctl daemon-reload` |
| Клиент не может подключиться снаружи | Firewalld блокирует порт | `sudo firewall-cmd --list-ports`, добавить нужный порт |
| После обновления образа T-SQL запросы падают с ошибками совместимости | Мажорное обновление сломало API/поведение | Проверить changelog версии, при необходимости откатиться (раздел 19) |
| `FATAL: password authentication failed` | Неверный/несинхронизированный пароль между env-файлом и тем, что реально в БД | Обновить пароль внутри БД (`ALTER ROLE ... PASSWORD`) синхронно с env-файлом |
| `git clone --branch` падает с "not found" | Тег указан для одного репозитория, но не существует в другом (см. раздел 6) | `git ls-remote --tags` для проверки точного имени тега перед сборкой |
| `Can't locate FindBin.pm` при сборке движка | Неполный набор Perl core-модулей (`perl-devel` даёт только XS-заголовки) | Убедиться, что в builder стоит широкий набор `perl-*` пакетов (раздел 6) |
| `cp: cannot stat libantlr4-runtime.so...` | CMake на RHEL кладёт `.so` в `lib64`, а не `lib` | Использовать `find` по обоим путям (уже в `Containerfile`, раздел 6) |
| `UnsupportedClassVersionError` при запуске ANTLR jar | Резолвится не та JVM (например, старая Java 8 вместо явно указанной) | Явный `ENV JAVA_HOME`/`PATH` + `-DJava_JAVA_EXECUTABLE` (уже в `Containerfile`, раздел 6) |
| `error while loading shared libraries: libreadline.so...` при запуске psql | В runtime не хватает `readline`/`zlib`, хотя движок собран с их поддержкой | Убедиться, что `readline zlib` есть в runtime `dnf install` (уже в `Containerfile`, раздел 6) |
| `sqlcmd`/`tsql` не могут авторизоваться по TDS (порт 1433), хотя `psql` по 5432 подключается нормально | TDS-протокол не поддерживает SCRAM-SHA-256 — нужен `md5` | Проверить `SHOW password_encryption;` (должно быть `md5`) и метод в `pg_hba.conf` для соответствующей записи (раздел 7) |
| `could not access file "$libdir/babelfishpg_tsql-N"` при `CREATE EXTENSION` | Внутренний ABI-суффикс версии библиотеки Babelfish не совпадает с реально созданным символическим именем | Проверить фактическое имя файла в ошибке, поправить суффикс в символических ссылках (раздел 6) |

---

## 27. Рекомендации по безопасности

- Никогда не публикуйте 1433/5432 на `0.0.0.0` без TLS, если сервер смотрит в интернет.
- Пароли — только через `podman secret` или env-файл с правами `600`, никогда в открытом виде в `.container`-файле, который может попасть в git/бэкапы конфигов.
- Зафиксируйте версию образа тегом, отслеживайте официальные security-advisory Babelfish/PostgreSQL.
- Ограничьте `pg_hba.conf`/сетевые правила конкретными подсетями/хостами, а не `0.0.0.0/0`.
- Регулярные бэкапы + проверка восстановления (бэкап, который никогда не восстанавливали — не бэкап).
- SELinux оставляйте в `Enforcing` — все проблемы выше решаются метками (`:Z`), а не отключением.

---

## 28. Статус и открытые вопросы

**Статус:** `Containerfile` (раздел 6) — подтверждённо рабочая **сборка** (`podman build` проходит от `git clone` до финального образа без ошибок на всех четырёх расширениях, PostGIS и tds_fdw). `entrypoint.sh` (раздел 7, более ранняя версия без `md5`) подтверждённо **успешно запускается**: контейнер стартует, инициализация кластера через `entrypoint.sh` проходит целиком без падений (значит, все вызовы `psql` внутри скрипта отработали — в том числе это косвенно подтверждает, что `readline`/`zlib` в runtime не были проблемой). **Не подтверждено:** реальное T-SQL/TDS-подключение (`sqlcmd`/`tsql`/SSMS на порт 1433) и работоспособность `password_encryption = 'md5'` конкретно для этого — это гипотеза, устраняющая известное ограничение TDS-протокола (несовместимость с SCRAM-SHA-256), но ещё не проверенная end-to-end.

Открытые вопросы, требующие вашего решения или проверки:

1. **Включение PostGIS/tds_fdw в БД по умолчанию.** Сейчас `entrypoint.sh` делает `CREATE EXTENSION` автоматически. Если хотите включать вручную под конкретную задачу — поменяйте дефолт на `false` в переменных `ENABLE_POSTGIS`/`ENABLE_TDS_FDW`.
2. **Секреты через env-файл vs `podman secret`.** Гайд использует env-файл (раздел 10.1) как более простой вариант. Для более строгого изолирования секретов — доработайте `entrypoint.sh` под `*_FILE`-переменные и переходите на `podman secret` (раздел 10.2).
3. **T-SQL/TDS-подключение — главный оставшийся непроверенный пункт.** После деплоя обязательно проверьте `tsql -H <host> -p 1433 -U babelfish_user -P '<пароль>'` (раздел 15/17) и хотя бы один реальный T-SQL-запрос. Если подключение не проходит — первое, что проверять: действительно ли `password_encryption = 'md5'` применился (`SHOW password_encryption;` внутри контейнера) и совпадает ли метод в `pg_hba.conf` с тем, что реально шлёт клиент.
4. **Суффикс `-5` в символических ссылках `babelfishpg_tsql-5.so`/`babelfishpg_common-5.so` (раздел 6).** Подобран под `BABEL_5_4_0` по аналогии с номером релиза — не подтверждён как официально документированное правило именования Babelfish. Контейнер с этими симлинками успешно прошёл инициализацию, что говорит в пользу того, что они как минимум не мешают; но не проверено, действительно ли они были *необходимы*, или расширения загрузились бы и без них. При смене версии Babelfish перепроверяйте по факту ошибки `could not access file`, если она возникнет.
5. **`ENABLE_GUI_CLIENT_STUBS` (заглушки `xp_msver`/`sys.dm_os_windows_info`).** Неофициальный обход под конкретные GUI-клиенты, выключен по умолчанию. Включайте только если реально столкнулись с проблемой подключения SSMS/Azure Data Studio.
