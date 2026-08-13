# GoshaCrash 3.7.4

GoshaCrash — установщик и контроллер Mihomo для ASUSWRT. Этот README одновременно является пользовательской инструкцией и **картой кода**: для каждой публичной команды указано, какой `case` её принимает, какие функции вызываются и какие буквальные строки из `goshacrash.sh` выполняют основное действие.

> Здесь специально приводятся **строки кода, а не номера строк**. Номера меняются после каждого коммита, а сами выражения и имена функций показывают реальный путь выполнения.

## Установка

```sh
wget --no-check-certificate \
  -O /tmp/install.sh \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'

sh /tmp/install.sh
```

`install.sh` сам ищет USB и Download Master, определяет платформу, устанавливает обязательные зависимости, скачивает контроллер/Mihomo/Zashboard, создаёт конфиг и hooks, затем запускает GoshaCrash.

### Какие строки `install.sh` отвечают за основные действия

Версия установщика:

```sh
INSTALLER_VERSION="3.7.4"
```

Профиль legacy ARMv5 выбирается логикой определения платформы; для RT-AC68U результат сохраняется как `legacy-armv5-gvisor`, `routing=manual`, `tun.stack=gvisor`.

Обязательные пакеты проверяются и ставятся до основного развёртывания. Для старого Optware учитывается настоящий Info-ZIP `/opt/bin/unzip-unzip`, а `nano` является обязательной зависимостью.

После установки контроллер вызывается глобальной командой `gc`.

---

# Словарь публичных команд `gc`

## `gc`

**Диспетчер:**

```sh
menu) menu;;
```

**Цепочка:**

```text
menu
 ├─ menu_terminal_init
 ├─ полноценный TTY -> menu_draw / menu_read_key
 └─ старый ASUSWRT -> menu_basic
```

Ключевой fallback:

```sh
if ! menu_terminal_init; then
    menu_basic
    return $?
fi
```

То есть отсутствие совместимого `stty` не блокирует управление: `gc` переходит на обычное меню через `read`.

---

## `gc status`

**Диспетчер:**

```sh
status) status;;
```

**Функция:** `status()`.

Проверка процесса Mihomo:

```sh
if p="$(running_pid)"; then
    echo "Mihomo: работает, PID=$p"
else
    echo "Mihomo: не запущен"
fi
```

Проверка TUN:

```sh
net_link_exists "$TUN_DEVICE" && echo "TUN: $TUN_DEVICE работает" || echo "TUN: $TUN_DEVICE не найден"
```

Проверка маршрутизации:

```sh
if running_pid >/dev/null 2>&1 && route_status >/dev/null 2>&1; then
    echo "Состояние маршрутизации: работает"
else
    echo "Состояние маршрутизации: не работает"
fi
```

URL панели:

```sh
echo "Zashboard: $(dashboard_base_url)"
```

**Итог:** `gc status` только читает состояние. Он не останавливает, не запускает и не переписывает конфиг.

---

## `gc edit`

**Диспетчер:**

```sh
edit) edit_config;;
```

**Цепочка:**

```text
edit_config
 ├─ load_platform
 ├─ find_editor
 ├─ pkg_install nano        (только если nano неожиданно отсутствует)
 ├─ backup_config
 ├─ nano config.yaml
 ├─ check_config
 └─ restart
```

Поиск `nano`:

```sh
editor="$(find_editor 2>/dev/null)"
if [ -z "$editor" ]; then
    warn "nano не найден; устанавливаю через Download Master"
    pkg_install nano || return 1
    editor="$(find_editor 2>/dev/null)" || { fail "nano не найден после установки"; return 1; }
fi
```

Резервная копия **до редактирования**:

```sh
backup="$(backup_config)" || { fail "Не создана резервная копия config.yaml"; return 1; }
say "Резервная копия: $backup"
```

Открытие редактора:

```sh
TERM="${TERM:-xterm}" "$editor" "$CONFIG" || { warn "Редактор завершился с ошибкой"; return 1; }
```

Проверка изменённого YAML/Mihomo-конфига:

```sh
if ! check_config; then
    cp -f "$backup" "$CONFIG"
    fail "Конфиг некорректен; восстановлена предыдущая версия"
    return 1
fi
```

Применение:

```sh
if ! restart; then
    cp -f "$backup" "$CONFIG"
    warn "Новый конфиг не запустился; восстановлен старый"
    restart || true
    return 1
fi
```

Успешный финал:

```sh
ok "config.yaml сохранён и применён"
```

**Итог:** `gc edit` = backup → nano → `mihomo -t` через `check_config` → полноценный restart. При ошибке проверки или запуска старый конфиг восстанавливается.

---

## `gc restart`

**Диспетчер:**

```sh
restart) restart;;
```

**Цепочка:**

```text
restart
 ├─ check_config
 ├─ backup_config
 ├─ watchdog_stop
 ├─ stop_runtime
 ├─ with_start_lock start_runtime
 ├─ watchdog_start
 └─ fallback config.last-good.yaml при неудачном новом запуске
```

Самое важное: конфиг проверяется **до остановки рабочего процесса**:

```sh
check_config || return 1
backup_config >/dev/null 2>&1 || true
```

Затем runtime пересобирается:

```sh
watchdog_stop
stop_runtime
with_start_lock start_runtime
rc=$?
```

При успехе возвращается watchdog:

```sh
if [ "$rc" -eq 0 ]; then
    watchdog_start
    return 0
fi
```

Автоматический last-good fallback:

```sh
if [ -f "$BACKUPS/config.last-good.yaml" ]; then
    warn "Новый config.yaml не запустился; возвращаю последний рабочий"
    cp -f "$BACKUPS/config.last-good.yaml" "$CONFIG" || return 1
```

**Итог:** `gc restart` сначала отбрасывает заведомо плохой конфиг, затем останавливает старый runtime и поднимает новый. При неудаче пытается вернуться на `config.last-good.yaml`.

---

## `gc stop`

**Диспетчер:**

```sh
stop) stop;;
```

Флаг ручной остановки:

```sh
touch "$MANUAL_STOP"
```

Остановка:

```sh
watchdog_stop
stop_runtime
```

Внутри `stop_runtime()`:

```sh
if [ "$ROUTING_MODE" = auto ]; then
    kill_mihomo
    route_stop >/dev/null 2>&1 || true
else
    route_stop >/dev/null 2>&1 || true
    kill_mihomo
fi
```

Финал:

```sh
ok "Mihomo остановлен; обычный DIRECT восстановлен"
```

**Итог:** watchdog выключается, маршрутизация GoshaCrash снимается, Mihomo завершается. `manual-stop` запрещает автоматический запуск после reboot до следующего `gc restart`/внутреннего `start`.

---

## `gc logs`

Примеры:

```sh
gc logs
gc logs mihomo 100
gc logs system 200
gc logs install 100
gc logs boot 100
gc logs watchdog 100
gc logs packages 100
```

**Диспетчер:**

```sh
*) show_logs "${1:-mihomo}" "${2:-100}" ;;
```

Сопоставление имени с файлом выполняет `log_file_for_kind()`:

```sh
mihomo) printf '%s\n' "$MIHOMO_LOG";;
system|goshacrash) printf '%s\n' "$SYSTEM_LOG";;
install) printf '%s\n' "$INSTALL_LOG";;
boot) printf '%s\n' "$BOOT_LOG";;
watchdog) printf '%s\n' "$WATCHDOG_LOG";;
packages) printf '%s\n' "$PACKAGES_LOG";;
```

Сам вывод:

```sh
tail -n "$lines" "$file" 2>/dev/null || true
```

**Итог:** команда ничего не меняет, а только читает последние N строк выбранного файла.

---

## `gc logs live`

Примеры:

```sh
gc logs live
gc logs live mihomo 100
gc logs live system 100
```

**Диспетчер:**

```sh
live)
    shift
    follow_logs "${1:-mihomo}" "${2:-100}"
    ;;
```

Live-вывод:

```sh
tail -n "$lines" -f "$file"
```

**Итог:** сначала выводит последние N строк, затем остаётся подписанным на файл. Выход — `Ctrl+C`.

---

## `gc dashboard`

**Диспетчер:**

```sh
dashboard) dashboard_url;;
```

Базовый setup URL:

```sh
url="http://$ip:$port/ui/#/setup?hostname=$ip&port=$port"
```

Secret из `config.yaml`:

```sh
[ -n "$secret" ] && url="$url&secret=$secret"
```

Защита legacy ARMv5:

```sh
if [ "${MIHOMO_TARGET:-}" = armv5 ] || [ "${LEGACY:-0}" = 1 ]; then
    url="$url&disableUpgradeCore=1"
fi
```

Тип backend:

```sh
url="$url&type=clash"
```

**Итог:** команда печатает URL, который надо открыть на ПК/телефоне. Для legacy ARMv5 URL содержит `disableUpgradeCore=1`.

---

## `gc routing status`

**Диспетчер:**

```sh
status) routing_status;;
```

Основной вывод:

```sh
echo "Routing: $ROUTING_MODE"
echo "Mihomo target: $MIHOMO_TARGET"
```

ARMv5:

```sh
if [ "$MIHOMO_TARGET" = armv5 ]; then
    echo "Automatic: недоступен для ARMv5"
else
    echo "Automatic: доступен"
fi
```

**Итог:** только чтение текущего режима.

---

## `gc routing manual`

**Диспетчер:**

```sh
manual) set_routing_mode manual;;
```

До изменения создаются две резервные копии:

```sh
cp -f "$CONFIG" "$cfg_backup" || return 1
cp -f "$PLATFORM_FILE" "$state_backup" || return 1
```

Останавливается runtime:

```sh
watchdog_stop
stop_runtime
```

Manual-конфиг формируется этими строками:

```sh
yaml_set_section_key "$CONFIG" tun stack "$stack" || return 1
yaml_set_section_key "$CONFIG" tun auto-route false || return 1
yaml_set_section_key "$CONFIG" tun auto-redirect false || return 1
yaml_set_section_key "$CONFIG" tun auto-detect-interface false || return 1
yaml_set_top_key "$CONFIG" routing-mark "$OUTBOUND_MARK_DEC" || return 1
```

Для ARMv5 stack выбирается так:

```sh
stack="system"; [ "$MIHOMO_TARGET" = armv5 ] && stack="gvisor"
```

После переписывания выполняются проверка и запуск:

```sh
if check_config && with_start_lock start_runtime; then
```

Если запуск неудачен:

```sh
cp -f "$cfg_backup" "$CONFIG"
cp -f "$state_backup" "$PLATFORM_FILE"
```

**Итог:** переключение transactional — сначала backup, потом изменение, потом test/start; при ошибке возврат предыдущего состояния.

---

## `gc routing auto`

**Диспетчер:**

```sh
auto) set_routing_mode auto;;
```

Жёсткий запрет ARMv5:

```sh
[ "$mode" != auto ] || [ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5 поддерживает только manual routing"; return 1; }
```

И ещё одна защита непосредственно при переписывании конфига:

```sh
[ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5: automatic routing недоступен"; return 1; }
```

Включение native routing Mihomo:

```sh
yaml_set_section_key "$CONFIG" tun stack system || return 1
yaml_set_section_key "$CONFIG" tun auto-route true || return 1
yaml_set_section_key "$CONFIG" tun auto-redirect true || return 1
yaml_set_section_key "$CONFIG" tun auto-detect-interface true || return 1
yaml_remove_top_key "$CONFIG" routing-mark || return 1
```

**Итог:** работает только на modern-платформах. На legacy ARMv5 команда завершается до изменения рабочего состояния.

---

## `gc help`

**Диспетчер:**

```sh
help|-h|--help) usage;;
```

Функция `usage()` теперь сама является компактным словарём вида:

```text
команда
  вызов: функция -> вложенные функции
  код:   ключевые буквальные строки
  итог:  эффект
```

То есть README и `gc help` используют одну и ту же модель описания: **команда → реальный путь кода → результат**.

---

# Что не является публичной командой

В конце `goshacrash.sh` есть внутренние команды:

```sh
check) check_config;;
boot) boot;;
firewall-reload) firewall_reload;;
watchdog-loop) watchdog_loop;;
watchdog-check) watchdog_check;;
version) echo "$VERSION";;
```

Они нужны `install.sh`, hooks и watchdog. В обычной пользовательской справке они не предлагаются как операции управления.

---

# Как запускается Mihomo

Основной runtime находится в `start_runtime()`.

Сначала:

```sh
check_config || return 1
ensure_tun || { fail "/dev/net/tun недоступен"; return 1; }
```

Запуск процесса:

```sh
GOGC="${GOGC:-50}" nohup "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 &
```

После запуска обязательны три проверки:

```sh
running_pid >/dev/null 2>&1 || { ...; fail "Mihomo завершился при запуске"; return 1; }
wait_port "$DNS_PORT" || { ...; fail "DNS Mihomo не слушает порт $DNS_PORT"; return 1; }
wait_tun || { ...; fail "Mihomo не создал $TUN_DEVICE"; return 1; }
```

Затем маршрутизация:

```sh
route_start || { kill_mihomo; route_stop >/dev/null 2>&1 || true; fail "Маршрутизация не поднялась; оставлен DIRECT"; return 1; }
```

И только после полностью успешного запуска текущий конфиг становится last-good:

```sh
cp -f "$CONFIG" "$BACKUPS/config.last-good.yaml" 2>/dev/null || true
```

---

# Как работает watchdog

Запуск:

```sh
watchdog_start
```

Основная проверка:

```sh
if ! running_pid >/dev/null 2>&1; then
    ...
    with_start_lock start_runtime >> "$WATCHDOG_LOG" 2>&1 || true
    return 0
fi
```

Если процесс есть, но маршрутизация сломалась:

```sh
if ! route_status >/dev/null 2>&1; then
    ...
    route_start >> "$WATCHDOG_LOG" 2>&1 || {
        stop_runtime
        with_start_lock start_runtime >> "$WATCHDOG_LOG" 2>&1 || true
    }
fi
```

Цикл:

```sh
while :; do
    sleep "$WATCHDOG_INTERVAL"
    watchdog_check
    rotate_log "$WATCHDOG_LOG" 524288
done
```

---

# Автозапуск после reboot

Внутренняя функция `boot()` сначала уважает ручной stop:

```sh
[ -f "$MANUAL_STOP" ] && { say "Автозапуск пропущен после ручной остановки"; return 0; }
```

Потом ждёт default route:

```sh
while ! main_default_route; do
```

И только после появления сети:

```sh
sleep 5
start
```

---

# Файлы

При USB `SANDISK` база обычно:

```text
/tmp/mnt/SANDISK/goshacrash
```

Основные пути задаются прямо в начале `goshacrash.sh`:

```sh
BIN="$BASE/bin/mihomo"
UI="$BASE/ui"
CONFIG="$BASE/config.yaml"
RUN="$BASE/run"
LOGS="$BASE/logs"
STATE="$BASE/state"
BACKUPS="$BASE/backups"
```

---

# RT-AC68U / legacy ARMv5

На RT-AC68U со старым kernel 2.6 установщик использует legacy-профиль. В runtime это означает:

```text
MIHOMO_TARGET=armv5
ROUTING_MODE=manual
TUN_STACK=gvisor
```

Automatic routing блокируется кодом, приведённым выше. URL Zashboard получает `disableUpgradeCore=1`, потому что core для этой платформы закреплён на совместимой legacy-сборке.

---

# Быстрый словарь

| Команда | Главная функция | Основной эффект |
|---|---|---|
| `gc` | `menu()` | интерактивное меню / fallback |
| `gc status` | `status()` | только диагностика |
| `gc edit` | `edit_config()` | backup → nano → test → restart/rollback |
| `gc restart` | `restart()` | test → stop → start → watchdog / last-good fallback |
| `gc stop` | `stop()` | manual-stop → watchdog stop → route stop → Mihomo stop |
| `gc logs ...` | `show_logs()` | `tail -n` выбранного журнала |
| `gc logs live ...` | `follow_logs()` | `tail -f` выбранного журнала |
| `gc dashboard` | `dashboard_url()` | setup URL Zashboard |
| `gc routing status` | `routing_status()` | показать режим |
| `gc routing manual` | `set_routing_mode manual` | backup → rewrite → test/start → rollback при ошибке |
| `gc routing auto` | `set_routing_mode auto` | native auto-route; запрещено ARMv5 |
| `gc help` | `usage()` | встроенный словарь команд и строк кода |

## Проверка исходников перед релизом

Для shell-файлов:

```sh
sh -n install.sh
sh -n goshacrash.sh
```

Дополнительно полезно проверить справку:

```sh
sh goshacrash.sh help
```
