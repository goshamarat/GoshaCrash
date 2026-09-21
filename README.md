# GoshaCrash

**Mihomo + Zashboard для ASUSWRT-роутеров.**  
Установка, TUN-маршрутизация, автозапуск, watchdog, диагностика и управление из одного `gc`.

> Текущая публичная сборка: **GoshaCrash 4.0.0 production**

> Hotfix 2026-09-21: modern-профиль определяет стабильный MetaCubeX/mihomo `releases/latest` во время установки; cache-lock WARN от параллельного `mihomo -t` очищен без скрытия реальных runtime-ошибок.

## Поддерживаемые роутеры

| Роутер | Архитектура | Mihomo | Routing | TUN stack | USB |
|---|---|---|---|---|---|
| ASUS RT-AC68U и совместимые legacy-модели | ARMv5 profile | legacy build with gVisor | manual | gVisor | EXT3 |
| ASUS ZenWiFi BT10 | ARMv7 | official ARMv7 build | native auto-route / auto-redirect | system | EXT4 |

Для других ASUSWRT-устройств установщик определяет архитектуру автоматически, но основные проверенные профили проекта — RT-AC68U и BT10.

## Что делает GoshaCrash

- устанавливает и запускает Mihomo;
- устанавливает Zashboard;
- поднимает TUN и нужную маршрутизацию;
- восстанавливает runtime после reboot через штатные ASUS USB hooks;
- следит за Mihomo через watchdog;
- динамически определяет USB после каждого монтирования;
- поддерживает Optware / Download Master;
- ставит UTF-8 окружение для `nano`;
- даёт меню `gc` со стрелками, `Enter` и `Esc`;
- содержит `gc status`, `gc doctor`, `gc storage`, RAM-логи, редактор конфига и диагностику автозапуска.

## Важные принципы текущей сборки

### USB не форматируется установщиком

`install.sh` **не форматирует флешку**. Подготовка USB выполняется отдельно.

Установщик должен лежать в корне текущего USB mountpoint:

```text
/tmp/mnt/<mount>/install.sh
```

Имя устройства не считается постоянным. Одна и та же флешка после reboot может быть, например:

```text
/dev/sdb1 -> /tmp/mnt/Sandisk
/dev/sda1 -> /tmp/mnt/sda1
```

GoshaCrash заново определяет реальный USB device и mountpoint во время работы.

### `config.yaml` принадлежит пользователю

Если `config.yaml` отсутствует, установщик создаёт базовый файл один раз. При обычной переустановке существующий конфиг не заменяется и не восстанавливается автоматически.

`gc edit` создаёт только пассивную резервную копию, открывает конфиг в `nano` и после сохранения запускает проверку `mihomo -t`. Если конфиг невалиден, файл остаётся как есть — автоматического rollback нет.

Исключение: команды `gc routing auto` и `gc routing manual` изменяют только поля, связанные с режимом маршрутизации.

Явный сброс конфига выполняется только вручную:

```sh
/bin/sh install.sh --reset-config
```

### MPTCP

GoshaCrash **не включает и не выключает MPTCP автоматически**. Состояние sysctl остаётся таким, каким его выставило ядро или пользователь.

Проверить состояние:

```sh
cat /proc/sys/net/mptcp/mptcp_enabled
```

Включить до следующей перезагрузки:

```sh
echo 1 > /proc/sys/net/mptcp/mptcp_enabled
```

Выключить до следующей перезагрузки:

```sh
echo 0 > /proc/sys/net/mptcp/mptcp_enabled
```


### Mihomo `cache.db`: live в RAM, snapshot на USB раз в 3 часа

Mihomo часто обновляет `cache.db` (в том числе runtime/profile/fake-IP state). Живой файл находится в `/tmp/goshacrash/cache.db`; `goshacrash/cache.db` на USB — только symlink на RAM. Поэтому обычные частые записи Mihomo не идут на флешку.

Раз в 3 часа watchdog делает один rolling snapshot RAM-базы в `goshacrash/state/cache.db.snapshot`. Копия берётся в RAM с краткой приостановкой процесса Mihomo только на время RAM→RAM copy, после чего USB-запись выполняется уже при работающем Mihomo. После reboot RAM-cache восстанавливается из последнего snapshot, поэтому теряется максимум примерно 3 часа cache-state при внезапном отключении питания. При обновлении со старой сборки существующий обычный `goshacrash/cache.db` используется как начальный snapshot, а не выбрасывается.

`gc doctor` показывает live RAM path и состояние 3-часового snapshot. Ручной snapshot: `gc cache-save`.

Главный интерактивный экран также обновляет `MIHOMO`/`TUN` примерно раз в секунду, даже если пользователь не нажимает клавиши. Если RAM pidfile потерян, контроллер пытается заново найти именно свой процесс Mihomo по командной строке.

### Runtime-логи только в RAM, максимум 10 MiB на файл

Все часто изменяемые данные перенесены в RAM (`/tmp`):

```text
/tmp/goshacrash/
├── logs/        # mihomo/install/packages/watchdog/boot/coldboot
├── run/         # PID и lock-файлы
└── state/       # heartbeat, WAN counters, runtime routing state
```

Рабочие логи пишутся в RAM. Каждый отдельный `.log` ограничен 10 MiB. Раз в 3 часа watchdog сохраняет один rolling snapshot логов на USB (`state/logs-last-3h.txt.gz`, либо plain fallback) и после успешного snapshot очищает текущие RAM-логи, начиная следующий 3-часовой интервал. Heartbeat/PID/lock по-прежнему остаются только в RAM и не пишутся на USB каждые 10 секунд. Если доступной RAM становится меньше 32 MiB, RAM-логи очищаются досрочно.

`gc logs` читает текущие RAM-логи. `gc logs clear` очищает их вручную, `gc logs flush` принудительно делает rolling USB snapshot. Лимит можно переопределить переменной `GOSHACRASH_LOG_MAX_BYTES`, production-default — 10485760 байт (10 MiB) на каждый лог.

Фоновый runtime GoshaCrash не должен создавать, `touch`-ить, ротировать или обновлять файлы на USB. При монтировании GoshaCrash best-effort включает `noatime,nodiratime`, чтобы даже чтение файлов не порождало лишние atime metadata writes. Persistent USB используется как read-mostly хранилище бинарников, UI, `config.yaml` и install-time state. Исключения только явные действия пользователя: установка/обновление GoshaCrash, `gc edit` (сам `config.yaml`) и операции установки/ремонта Optware-пакетов. `manual-stop` перенесён в `/jffs/goshacrash/manual-stop`, а временный backup перед `gc edit` — в `/tmp/goshacrash/backups`.

Важно: ASUS Download Master и другие сервисы прошивки — отдельные процессы и могут писать в свой `asusware.*` независимо от GoshaCrash. Media Server/MiniDLNA тоже должен быть выключен, если он не используется.

### GitHub fallback через ghproxy.net

Сначала установщик всегда пробует прямой GitHub. Если URL вида `https://github.com/...` недоступен, тот же файл автоматически запрашивается через `ghproxy.net`. Например:

```text
https://github.com/MetaCubeX/mihomo/releases/download/<VERSION>/mihomo-linux-armv7-<VERSION>.gz
```

автоматически получает fallback:

```text
https://ghproxy.net/github.com/MetaCubeX/mihomo/releases/download/<VERSION>/mihomo-linux-armv7-<VERSION>.gz
```

Это применяется к Mihomo, Zashboard и GitHub release-файлам проекта. Для файлов самой ветки дополнительно остаются raw GitHub и jsDelivr источники.

### Защита USB / filesystem

Перед стартом runtime GoshaCrash проверяет свободное место и текущий kernel log. При заполнении USB на 95% и выше, остатке меньше 32 MiB либо уже зафиксированных EXT/I/O errors запуск блокируется, чтобы не работать с явно повреждённой файловой системой.

`gc doctor` и `gc storage` показывают заполнение USB, наличие крупного `.minidlna`, состояние `noatime`, доступную RAM и ошибки EXT2/3/4 или I/O из текущего kernel log. Установщик отказывается продолжать запись, если ядро уже зафиксировало ошибки файловой системы на выбранном USB-разделе.

Важно: GoshaCrash не запускает `e2fsck` по смонтированной флешке. Уже повреждённую файловую систему нужно чинить offline; если второй последовательный `e2fsck -f` на всё ещё размонтированном разделе снова находит множество новых ошибок, флешку/файловую систему надо переформатировать, а при повторении на свежей ФС — заменить носитель.

### Родительский контроль ASUS (`PControls`)

На stock ASUSWRT родительский контроль создаёт цепочку `PControls` динамически: если клиентов нет, цепочки может не быть вообще. GoshaCrash не создаёт и не переписывает её.

Когда ASUS добавляет правила вида `FORWARD ... -j PControls`, GoshaCrash автоматически:

- оставляет штатные правила ASUS владельцем всей логики блокировки;
- держит `mihomo-forward` и собственный manual FORWARD hook **после** последнего `PControls`;
- для клиентов, которых ASUS направил в PControls, добавляет ранний `RETURN` в `mihomo-prerouting`, чтобы `auto-redirect` не уводил их TCP/DNS в локальный Mihomo раньше штатного `FORWARD`;
- watchdog повторяет проверку после старта, рестарта Mihomo и последующих изменений firewall;
- при изменении списка PControls-клиентов один раз перезапускает Mihomo, чтобы закрыть уже существующие long-lived redirect-сессии.

Проверка вручную:

```sh
gc pcontrols
```

В норме при активном родительском контроле вывод содержит `PControls FORWARD priority: OK (before Mihomo)` и, при native auto-redirect, `PControls auto-redirect bypass: OK`. Если ASUS ещё не создал цепочку, `NOT PRESENT/NO CLIENTS` является нормальным состоянием.

### Native AUTO на BT10

На BT10 режим `auto` использует штатные механизмы Mihomo:

```yaml
tun:
  enable: true
  stack: system
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53
```

`gc doctor` проверяет TUN, policy routing, TCP redirect и DNS hijack отдельно.

## Требования перед установкой

1. ASUSWRT с включённым SSH.
2. Подготовленная USB-флешка.
3. Установленный на эту флешку ASUS Download Master / Optware.
4. `install.sh` в корне текущего USB mountpoint.

Для RT-AC68U legacy-профиль требует EXT3. Для BT10 используется EXT4.

## Установка

Сначала посмотреть текущий USB mountpoint:

```sh
mount | grep '/dev/sd'
```

Определить его автоматически:

```sh
USB_MOUNT="$(awk '$1 ~ /^\/dev\/sd[a-z][0-9]+$/ && $2 ~ /^\/tmp\/mnt\// {print $2; exit}' /proc/mounts)"
```

Скачать установщик из `production`:

```sh
/usr/sbin/wget --no-check-certificate -O "$USB_MOUNT/install.sh" 'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/production/install.sh'
```

Запустить:

```sh
chmod 700 "$USB_MOUNT/install.sh"
```

```sh
/bin/sh "$USB_MOUNT/install.sh"
```

Если рядом с `install.sh` лежит совместимый `goshacrash.sh` из этой же сборки, установщик использует локальный файл и не скачивает controller повторно.

## Управление

Открыть интерактивное меню:

```sh
gc
```

В полноэкранном меню:

```text
↑ / ↓   выбор
Enter   открыть
Esc     назад / выход
```

Раздел **Logs** также управляется стрелками; `Esc` возвращает в главное меню.

Основные команды:

| Команда | Назначение |
|---|---|
| `gc status` | краткий статус |
| `gc doctor` | полная диагностика |
| `gc storage` | место на USB, `.minidlna`, kernel FS errors |
| `gc edit` | редактировать `config.yaml` |
| `gc start` | запустить runtime |
| `gc restart` | перезапустить runtime |
| `gc stop` | остановить runtime и поставить manual-stop |
| `gc routing status` | текущий режим маршрутизации |
| `gc routing auto` | native AUTO на поддерживаемых modern-профилях |
| `gc routing manual` | manual routing |
| `gc logs` | последние строки Mihomo |
| `gc logs watchdog 100` | watchdog из RAM |
| `gc logs boot 100` / `gc logs coldboot 100` | boot/coldboot из RAM |
| `gc logs install 200` / `gc logs packages 200` | installer/Optware из RAM |
| `gc logs live mihomo 100` | live log Mihomo |
| `gc logs clear` | вручную очистить текущие RAM-логи |
| `gc dashboard` | адрес Zashboard |
| `gc autostart status` | диагностика автозапуска |

## Zashboard

Базовый controller:

```yaml
external-controller: 0.0.0.0:9090
external-ui: ui
```

`secret:` в базовом профиле не используется.

Открыть адрес панели:

```sh
gc dashboard
```

## После reboot

Проверить, куда ASUS смонтировал USB:

```sh
mount | grep '/dev/sd'
```

Проверить весь runtime:

```sh
gc doctor
```

Проверить автозапуск:

```sh
gc autostart status
```

## Persistent layout

USB содержит только постоянные данные:

```text
/tmp/mnt/<current>/
├── install.sh
├── asusware.arm/            # или другой layout Download Master
└── goshacrash/
    ├── goshacrash.sh
    ├── config.yaml
    ├── bin/
    ├── ui/
    └── state/               # platform/manual-stop и редкие persistent данные
```

Часто изменяемый runtime находится только в RAM. Каждый лог ограничен 10 MiB и на USB не сохраняется:

```text
/tmp/goshacrash/
├── logs/
├── run/
└── state/
```

В JFFS остаются только необходимые hooks/wrappers:

```text
/jffs/scripts/gc
/jffs/scripts/nano
/jffs/scripts/usb-mount-script
/jffs/scripts/usb-umount-script
```

В них не должен храниться постоянный `/tmp/mnt/<имя>` как источник истины.

## Если USB внезапно заполнен на 100%

Сначала сравнить `df` и `du`:

```sh
df -h | grep '/dev/sd'
```

```sh
du -sh /tmp/mnt/*/* /tmp/mnt/*/.[!.]* 2>/dev/null
```

На ASUS скрытая папка `.minidlna` может занимать почти всю флешку, если включался Media Server / DLNA. Если DLNA не используется, его следует отключить в ASUS и удалить ненужный кэш.

Если `df` показывает занятое место, которого нет в `du`, либо ядро пишет ошибки EXT4/I/O, файловую систему нужно проверять `e2fsck` **только на размонтированном разделе**.

## Ветки репозитория

Публичный канал установки и обновлений этой сборки — `production`. `install.sh` по умолчанию скачивает связанные файлы именно из `production`.

`main` остаётся веткой разработки и тестов. Для явного запуска installer против `main` можно передать `BRANCH=main`. Схема работы с ветками описана в [docs/BRANCHES.md](docs/BRANCHES.md).

## Файлы проекта

```text
README.md
CHANGELOG.md
install.sh
goshacrash.sh
assets/
└── gcnet-armv5
docs/
└── BRANCHES.md
```
