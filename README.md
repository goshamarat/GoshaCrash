# GoshaCrash

**Mihomo + Zashboard для ASUSWRT-роутеров.**  
Установка, TUN-маршрутизация, автозапуск, watchdog, диагностика и управление из одного `gc`.

> Текущая публичная сборка: **GoshaCrash 4.0.0 production**

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
- содержит `gc status`, `gc doctor`, логи, редактор конфига и диагностику автозапуска.

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
| `gc edit` | редактировать `config.yaml` |
| `gc start` | запустить runtime |
| `gc restart` | перезапустить runtime |
| `gc stop` | остановить runtime и поставить manual-stop |
| `gc routing status` | текущий режим маршрутизации |
| `gc routing auto` | native AUTO на поддерживаемых modern-профилях |
| `gc routing manual` | manual routing |
| `gc logs` | последние строки Mihomo |
| `gc logs live mihomo 100` | live log Mihomo |
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

```text
/tmp/mnt/<current>/
├── install.sh
├── asusware.arm/            # или другой layout Download Master
└── goshacrash/
    ├── goshacrash.sh
    ├── config.yaml
    ├── bin/
    ├── ui/
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
