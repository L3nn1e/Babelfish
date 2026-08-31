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
    dnf install -y \
        libicu-devel libxml2-devel openssl-devel \
        libuuid-devel \
        gcc gcc-c++ make flex bison \
        readline-devel zlib-devel \
        python3-devel perl-devel perl-FindBin perl-Data-Dumper \
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
# perl-FindBin/perl-Data-Dumper — PostgreSQL 17 генерирует часть заголовков
# каталога (gen_node_support.pl, genbki.pl) Perl-скриптами прямо во время
# сборки; perl-devel даёт только заголовки для XS, не core-модули — в EL их
# нужно ставить отдельными подпакетами, иначе "Can't locate FindBin.pm".

# cmake (нужна версия 3.20+, в репах может быть старее)
WORKDIR /opt
RUN wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh && \
    sh cmake-${CMAKE_VERSION}-linux-x86_64.sh --skip-license --prefix=/usr/local && \
    rm cmake-${CMAKE_VERSION}-linux-x86_64.sh

ENV cmake=/usr/local/bin/cmake

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
        -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib -DWITH_DEMO=False && \
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
