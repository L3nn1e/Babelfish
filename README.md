# Полный гайд: Babelfish for PostgreSQL на AlmaLinux 10 (Podman + Quadlet)

> **Предыстория решения.** Изначально рассматривался готовый community-образ (`jonathanpotts/babelfishpg`) как более быстрый путь к запуску. В процессе стало понятно, что собрать образ самостоятельно (`Containerfile` на базе `almalinux:9`, см. `babelfish-custom-image-build.md`) — не намного дольше по времени первой настройки, зато даёт полный контроль над версией Babelfish/PostgreSQL, независимость от чужого Docker Hub аккаунта и возможность добавлять свои патчи (PostGIS, tds_fdw, Kerberos). Поэтому финальная схема — свой образ + деплой строго через Quadlet, без стороннего образа и без ручного `podman run`.

## Содержание
1. Обзор и архитектура
2. Требования к серверу
3. Подготовка AlmaLinux 10
4. Установка и проверка Podman/Quadlet
5. Секреты (пароли) — правильный способ через `podman secret`
6. Volume и права/SELinux
7. Основной контейнерный Quadlet-юнит
8. Запуск и управление сервисом
9. Firewall
10. Первоначальная проверка и настройка базы Babelfish
11. TLS/SSL для TDS и Postgres-подключений
12. Подключение клиентов (tsql, sqlcmd, psql, JDBC/ODBC, SSMS)
13. Резервное копирование и восстановление
14. Обновление образа и откат
15. Мониторинг, логи, healthcheck
16. Диагностика типичных проблем
17. Рекомендации по безопасности
18. Альтернатива: сборка из исходников — когда она оправдана

---

## 1. Обзор и архитектура

Babelfish for PostgreSQL — это набор расширений PostgreSQL (`babelfishpg_tds`, `babelfishpg_tsql`, `babelfishpg_common`, `babelfishpg_money`), которые добавляют:

- **TDS-протокол** (Tabular Data Stream) — тот же протокол, что использует SQL Server, обычно на порту **1433**;
- **T-SQL диалект** — процедурный язык SQL Server (хранимые процедуры, системные представления `sys.*` и т.д.);
- обычный **PostgreSQL-протокол** на порту **5432** остаётся доступен параллельно — это по сути тот же кластер Postgres, просто с двумя "входами".

Официальных RPM или официального Docker-образа от AWS/проекта Babelfish для RHEL-семейства нет. Мы собираем **собственный образ** (`Containerfile` на базе `almalinux:9` — см. отдельный гайд `babelfish-custom-image-build.md`) и разворачиваем его строго через Quadlet — без стороннего community-образа и без ручного `podman run`.

| Путь | Плюсы | Минусы |
|---|---|---|
| Свой образ (Containerfile) + Quadlet (этот гайд) | Полный контроль над версией/патчами, не зависим от чужого registry, systemd-интеграция "из коробки" | Нужно один раз собрать образ (см. `babelfish-custom-image-build.md`) |
| Сборка из исходников прямо на хосте, без контейнера | Тот же официальный процесс, но без изоляции | Хрупко на новых версиях gcc/openssl хоста (AlmaLinux 10), сложно обновлять и тиражировать |

Этот гайд — про деплой собранного образа через Quadlet. Про сборку самого образа — `babelfish-custom-image-build.md`. Про сборку без контейнера вообще — раздел 18.

---

## 2. Требования к серверу

- AlmaLinux 10 (x86_64 или aarch64)
- Минимум 2 vCPU / 4 GB RAM для теста, от 4 vCPU / 8+ GB для реальной нагрузки
- Свободное место под данные БД — планируйте с запасом, PGDATA будет расти
- Root или sudo-доступ
- Открытый исходящий доступ в интернет (для `podman pull`) либо локальный registry/зеркало образов

---

## 3. Подготовка AlmaLinux 10

```bash
sudo dnf update -y
sudo dnf install -y firewalld freetds postgresql
sudo systemctl enable --now firewalld
```

`freetds` даёт утилиту `tsql` для проверки TDS-подключения, `postgresql` — клиент `psql` для проверки Postgres-стороны (сам сервер СУБД ставить не нужно, он будет в контейнере).

Проверьте версию ядра и SELinux (должен быть `Enforcing` — это нормально, ниже покажу, как с ним ужиться, а не отключать):

```bash
uname -r
getenforce
```

---

## 4. Установка и проверка Podman/Quadlet

```bash
sudo dnf install -y podman podman-plugins
podman --version
```

Нужна версия Podman **4.4+** — Quadlet раньше был отдельным проектом, начиная с 4.4 встроен в сам Podman. В AlmaLinux 10 в базовых репозиториях идёт свежий Podman, версия точно подходит.

Проверьте, что генератор Quadlet присутствует и запускается systemd-ом при `daemon-reload`:

```bash
/usr/lib/systemd/system-generators/podman-system-generator --version
```

Директории, куда кладутся Quadlet-юниты:

- system-wide (root, автозапуск на уровне хоста): `/etc/containers/systemd/`
- rootless (конкретный пользователь): `~/.config/containers/systemd/`

Этот гайд — **system-wide** вариант, он проще для выделенного сервера БД.

```bash
sudo mkdir -p /etc/containers/systemd
sudo mkdir -p /var/storage/pgsql/data
```

---

## 5. Секреты (пароли) — правильный способ

Хранить пароль прямо в `.container`-файле как `Environment=POSTGRES_PASSWORD=...` работает, но файл юнита читаем root'ом и попадает в systemd journal при отладке. Правильнее — через `podman secret`:

```bash
# Сгенерировать надёжный пароль и сохранить как secret
openssl rand -base64 24 | sudo podman secret create babelfish_pg_password -
openssl rand -base64 24 | sudo podman secret create babelfish_user_password -
```

Проверить:
```bash
sudo podman secret ls
```

Секреты будут подключены к контейнеру как файлы в `/run/secrets/<name>`. Поскольку образ собственной сборки, поддержку `*_FILE`-переменных (чтения пароля из файла, а не из значения переменной) можно добавить прямо в свой `entrypoint.sh` (см. `babelfish-custom-image-build.md`) — это буквально несколько строк вида `POSTGRES_PASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"`. Если такой доработки ещё не делали, используйте промежуточный вариант — env-файл с ограниченными правами, см. врезку ниже.

**Если образ не поддерживает `_FILE`-переменные:**
```bash
sudo install -d -m 700 /etc/babelfish
sudo bash -c 'echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)" > /etc/babelfish/babelfish.env'
sudo chmod 600 /etc/babelfish/babelfish.env
```
и в Quadlet-юните вместо `Environment=` используем `EnvironmentFile=/etc/babelfish/babelfish.env`.

---

## 6. Volume и права/SELinux

```bash
sudo mkdir -p /var/storage/pgsql/data
sudo chmod 750 /var/storage/pgsql/data
```

Под SELinux контейнеру по умолчанию **запрещена** запись в произвольный каталог хоста. Есть два корректных решения (без `setenforce 0`):

1. **Suffix `:Z`/`:z` в определении volume** (используем ниже) — Podman сам проставит нужную SELinux-метку (`container_file_t`) при монтировании. `:Z` — приватный volume (только этот контейнер), `:z` — общий (несколько контейнеров).
2. Альтернатива — вручную задать контекст через `semanage fcontext` + `restorecon`, если `:Z/:z` почему-то не годится (например, каталог общий с другими нередко переиспользуемыми процессами).

Для одиночного контейнера с БД `:Z` — то, что нужно, дальше в примере используется именно он.

---

## 7. Основной контейнерный Quadlet-юнит

`/etc/containers/systemd/babelfish.container`:

```ini
[Unit]
Description=Babelfish for PostgreSQL
Documentation=https://babelfishpg.org/docs
After=network-online.target
Wants=network-online.target

[Container]
Image=localhost/babelfish:5.4.0-pg17.7
ContainerName=babelfish

# TDS (SQL Server протокол) и обычный Postgres-протокол
PublishPort=1433:1433
PublishPort=127.0.0.1:5432:5432

# Данные — постоянный volume с корректной SELinux-меткой.
# Путь внутри контейнера — как задан в entrypoint.sh собственного образа
# (см. babelfish-custom-image-build.md), а не путь стороннего образа.
Volume=/var/storage/pgsql/data:/var/lib/postgresql/data:Z

# Пароли — через env-файл с ограниченными правами (см. раздел 5)
EnvironmentFile=/etc/babelfish/babelfish.env

Environment=BABELFISH_USER=babelfish_user
Environment=BABELFISH_DB=babelfish_db
Environment=BABELFISH_MIGRATION_MODE=single-db

# Ограничения ресурсов (подберите под свой сервер)
PodmanArgs=--memory=4g --cpus=2

# Health check силами Podman
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

- `PublishPort=127.0.0.1:5432:5432` — обычный Postgres-порт публикуется только на loopback, чтобы наружу торчал лишь TDS (1433). Если вам нужен внешний доступ и по 5432 — уберите `127.0.0.1:`.
- `Image=...:2.3.0` — версия зафиксирована явно. **Не используйте `latest` в проде** — обновление должно быть осознанным действием (см. раздел 14).
- `PodmanArgs=--memory=4g --cpus=2` — пример лимитов, чтобы контейнер не съел весь хост при пиковой нагрузке.

---

## 8. Запуск и управление сервисом

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

## 9. Firewall

```bash
sudo firewall-cmd --permanent --add-port=1433/tcp
# Если решили публиковать 5432 наружу, а не только на localhost:
# sudo firewall-cmd --permanent --add-port=5432/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

Если инфраструктура позволяет — ограничьте доступ конкретной подсетью через `firewall-cmd --permanent --add-rich-rule=...` или через zone, а не открывайте порт для `0.0.0.0/0`.

---

## 10. Первоначальная проверка и настройка базы Babelfish

После первого старта образ сам инициализирует кластер и создаёт пользователя/базу из переменных окружения (`BABELFISH_USER`, `BABELFISH_DB`, пароль из secrets/env-файла). Проверяем:

```bash
sudo podman exec -it babelfish bash
```

Внутри контейнера (пути могут отличаться в зависимости от образа — проверьте `psql --version` и `which psql`):

```bash
psql -U babelfish_user -d babelfish_db -c "\conninfo"
psql -U babelfish_user -d babelfish_db -c "SHOW babelfishpg_tsql.migration_mode;"
```

Если нужно донастроить вручную (например, добавить ещё одну "логическую" базу в multi-db режиме) — это делается штатными Babelfish-процедурами, как в обычной установке:

```sql
CREATE DATABASE my_app_db;
\c my_app_db
CREATE EXTENSION IF NOT EXISTS "babelfishpg_tds" CASCADE;
GRANT ALL ON SCHEMA sys TO babelfish_user;
```

(Если база уже проинициализирована образом с нужным режимом — этот шаг обычно не требуется, он актуален при ручной сборке из раздела 19.)

---

## 11. TLS/SSL для TDS и Postgres-подключений

Для продакшена нешифрованные подключения — плохая идея, особенно если 1433 торчит наружу.

1. Сгенерируйте сертификат (self-signed для теста, от внутреннего CA — для прода):

```bash
sudo mkdir -p /var/storage/pgsql/tls
cd /var/storage/pgsql/tls
sudo openssl req -new -x509 -days 365 -nodes \
    -out server.crt -keyout server.key \
    -subj "/CN=babelfish.internal.example.com"
sudo chmod 600 server.key
sudo chown 26:26 server.key server.crt   # UID/GID 26 — postgres в EL-образе (см. Containerfile в гайде по сборке своего образа)
```

2. Добавьте volume с сертификатами в Quadlet-юнит:
```ini
Volume=/var/storage/pgsql/tls:/certs:Z,ro
```

3. Внутри контейнера в `postgresql.conf` (обычно доступен через volume или `podman exec` + `ALTER SYSTEM`):
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

## 12. Подключение клиентов

**FreeTDS / tsql** (уже установлен в разделе 3):
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

**JDBC** — стандартный Postgres JDBC-драйвер или MS JDBC-драйвер, строка подключения как к обычному SQL Server: `jdbc:sqlserver://<host>:1433;databaseName=babelfish_db;...`

**ODBC / SSMS** — подключение через New Query как к обычному SQL Server-инстансу; Object Explorer в SSMS Babelfish официально не поддерживает.

---

## 13. Резервное копирование и восстановление

Поскольку внутри — обычный PostgreSQL, работают стандартные инструменты Postgres:

```bash
sudo podman exec babelfish pg_dump -U babelfish_user -Fc babelfish_db > /var/backups/babelfish_$(date +%F).dump
```

Восстановление:
```bash
sudo podman exec -i babelfish pg_restore -U babelfish_user -d babelfish_db --clean < /var/backups/babelfish_2026-08-29.dump
```

Для "холодного" бэкапа данных целиком — можно копировать сам volume, предварительно остановив сервис:
```bash
sudo systemctl stop babelfish.service
sudo tar -czf /var/backups/babelfish-data-$(date +%F).tar.gz -C /var/storage/pgsql data
sudo systemctl start babelfish.service
```

Автоматизация — обычный systemd timer или cron, вызывающий `pg_dump` по расписанию, с ротацией старых бэкапов.

---

## 14. Обновление образа и откат

```bash
# 1. Бэкап перед обновлением — обязательно (см. раздел 13)
sudo podman exec babelfish pg_dump -U babelfish_user -Fc babelfish_db > /var/backups/pre-upgrade.dump

# 2. Пересобрать образ с новым тегом релиза Babelfish (пример для 5.5.0/PG 17.8)
cd ~/babelfish-image
sudo podman build -t localhost/babelfish:5.5.0-pg17.8 \
    --build-arg BABEL_TAG=BABEL_5_5_0__PG_17_8 \
    -f Containerfile .

# 3. Поменять тег в /etc/containers/systemd/babelfish.container
#    Image=localhost/babelfish:5.5.0-pg17.8

# 4. Применить
sudo systemctl daemon-reload
sudo systemctl restart babelfish.service

# 5. Проверить
sudo podman logs babelfish --tail 50
```

Откат — просто верните старый тег в файле юнита (старый образ остаётся в локальном хранилище Podman, если вы его не удаляли), `daemon-reload` + `restart`; если менялась мажорная схема данных — восстановление из дампа, сделанного в шаге 1.

---

## 15. Мониторинг, логи, healthcheck

```bash
sudo podman inspect babelfish --format '{{.State.Health.Status}}'
journalctl -u babelfish.service -f
sudo podman stats babelfish
```

Для интеграции с внешним мониторингом (Prometheus и т.д.) — стандартный `postgres_exporter` можно запустить как обычный процесс или отдельный контейнер на том же хосте и указать на уже опубликованный `127.0.0.1:5432` (см. раздел 7) — отдельная общая сеть для этого не нужна.

---

## 16. Диагностика типичных проблем

| Симптом | Причина | Решение |
|---|---|---|
| `permission denied` при старте, ошибки записи в `/data` | SELinux не пускает контейнер в volume хоста | Проверить, что в `Volume=` указан суффикс `:Z`; `ausearch -m avc -ts recent` для деталей |
| Контейнер не стартует, `Address already in use` | Порт 1433/5432 занят другим процессом | `sudo ss -tlnp | grep -E '1433|5432'`, освободить порт или сменить `PublishPort` |
| `podman: command not found` в systemd-контексте | Не выполнен `daemon-reload` после создания Quadlet-файлов | `sudo systemctl daemon-reload` |
| Клиент не может подключиться снаружи | Firewalld блокирует порт | `sudo firewall-cmd --list-ports`, добавить нужный порт |
| После обновления образа T-SQL запросы падают с ошибками совместимости | Мажорное обновление сломало API/поведение | Проверить changelog версии, при необходимости откатиться (раздел 14) |
| `FATAL: password authentication failed` | Неверный/несинхронизированный пароль между env-файлом и тем, что реально в БД (например, после смены пароля вручную) | Обновить пароль внутри БД (`ALTER ROLE ... PASSWORD`) синхронно с env-файлом |

---

## 17. Рекомендации по безопасности

- Никогда не публикуйте 1433/5432 на `0.0.0.0` без TLS, если сервер смотрит в интернет.
- Пароли — только через `podman secret` или env-файл с правами `600`, никогда в открытом виде в `.container`-файле, который может попасть в git/бэкапы конфигов.
- Зафиксируйте версию образа тегом, отслеживайте официальные security-advisory Babelfish/PostgreSQL.
- Ограничьте `pg_hba.conf`/сетевые правила конкретными подсетями/хостами, а не `0.0.0.0/0`.
- Регулярные бэкапы + проверка восстановления (бэкап, который никогда не восстанавливали — не бэкап).
- SELinux оставляйте в `Enforcing` — все проблемы выше решаются метками (`:Z`), а не отключением.

---

## 18. Альтернатива: сборка из исходников — когда она оправдана

Сборка вручную (движок PostgreSQL, модифицированный под Babelfish, + 4 расширения + ANTLR) имеет смысл, если:
- нужен нестандартный патч/фича, которой нет в готовых образах;
- требуется линковка с `tds_fdw` (linked servers) или PostGIS (Spatial types) — эти опции собираются флагами при компиляции и не всегда есть в готовых образах;
- корпоративная политика запрещает тянуть сторонние Docker-образы, и разрешена только сборка из исходников силами внутренней CI.

Подробный пошаговый гайд по сборке из исходников под AlmaLinux 10 я давал раньше в этом чате (файл `babelfish-almalinux10-guide.md`) — в нём отдельно расписаны нюансы EL10 (gcc 14, `--with-uuid=e2fs` вместо `ossp`, `--disable-werror` и т.д.).

Для большинства случаев — путь через Quadlet из этого гайда быстрее, стабильнее в обслуживании и проще в откате.
