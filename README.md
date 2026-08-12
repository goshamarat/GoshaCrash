# GoshaCrash 3.7.3

Минимальная онлайн-сборка для ASUSWRT. Пользователь копирует только `install.sh`; всё остальное установщик получает из GitHub.

## Архитектура

- `install.sh` — вся первоначальная установка: USB/Download Master, `ipkg`/`opkg`, выбор ядра Mihomo по архитектуре, выбор режима маршрутизации, конфиг, Zashboard, автозапуск и глобальные команды.
- `goshacrash.sh` — только управление уже установленной системой: start/stop/restart, маршрутизация, конфиг, логи, пакеты, watchdog, dashboard и диагностика.

`goshacrash.sh` больше не содержит установщик hooks.

## Маршрутизация

На ARMv5 доступен только `manual`.

На остальных поддерживаемых архитектурах при первой установке можно выбрать:

1. `automatic` — Mihomo управляет маршрутизацией через `tun.auto-route: true` и `tun.auto-redirect: true`.
2. `manual` — GoshaCrash создаёт policy routing и `iptables`: mark `0x2333` → table `2022` → `tun0`, а `routing-mark: 9012` исключает исходящие соединения Mihomo из повторного захвата.

Выбор сохраняется в `state/platform.env`.

После установки режим можно менять:

```sh
goshacrash routing status
goshacrash routing manual
goshacrash routing auto
```

При переключении GoshaCrash делает backup конфига, изменяет только параметры TUN/`routing-mark`, перезапускает Mihomo и откатывает изменения при ошибке.

## Интерактивное меню

Запуск без аргументов:

```sh
goshacrash
```

Интерактивное меню минимальное: Status, Restart, Stop, Logs и Exit. На прошивках, где raw-TTY/`stty` недоступны или несовместимы, `gc` автоматически переключается на переносимое нумерованное меню через `read`, а не завершается ошибкой `Interactive terminal is unavailable`. Все расширенные функции остаются доступны через `gc help`.

Справка без меню:

```sh
goshacrash help
```

## Базовый конфиг

`install.sh` сам создаёт единый `config.yaml` при первой установке. Готовые `config.yaml`/`config-legacy.yaml` из репозитория больше не нужны.

- ARMv5/RT-AC68U → `tun.stack: gvisor`, только `manual`.
- остальные архитектуры → `tun.stack: system`, выбранный `automatic` или `manual`.
- `manual` → `auto-route/auto-redirect/auto-detect-interface: false` + `routing-mark: 9012`.
- `automatic` → эти TUN-параметры включены, `routing-mark` удалён.

Если пользовательский `config.yaml` уже существует, установщик сохраняет его и меняет только параметры маршрутизации. Старый `config-legacy.yaml` из GoshaCrash 3.5.x автоматически переносится в единый `config.yaml` с backup.

## Установка

Сначала установи Download Master через веб-интерфейс ASUS.

Затем:

```sh
/usr/sbin/wget --no-check-certificate -O /tmp/install.sh 'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'
```

Для флешки `SANDISK`:

```sh
INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

На ARMv5 установщик автоматически выберет manual. На остальных архитектурах предложит automatic/manual.

Неинтерактивный выбор:

```sh
GOSHACRASH_ROUTING=manual INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

или:

```sh
GOSHACRASH_ROUTING=auto INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

`auto` на ARMv5 будет отклонён.

## Mihomo

Установщик скачивает только один бинарник, подходящий текущему роутеру. Для RT-AC68U используется закреплённый ARMv5 + gVisor build. Для современных архитектур берётся официальный релиз Mihomo под `arm64`, `armv7`, `armv6`, `amd64-compatible`, `386`, `mips*`, `riscv64`, `ppc64le` или `s390x`.

## Основные команды

```sh
goshacrash
goshacrash help
goshacrash status
goshacrash start
goshacrash stop
goshacrash restart
goshacrash edit
goshacrash apply
goshacrash logs mihomo 100
goshacrash logs system 100
goshacrash logs live mihomo 100
goshacrash logs live system 100
goshacrash dashboard
goshacrash doctor
```

Пакеты Download Master:

```sh
goshacrash pkg repair
goshacrash pkg update
goshacrash pkg install nano
```

## Zashboard

Zashboard устанавливается `install.sh`. На старом ASUSWRT встроенный BusyBox `unzip` не считается полноценной зависимостью: установщик автоматически ставит совместимый Info-ZIP `unzip` через Download Master и проверяет архив фактической распаковкой.

Для `legacy-armv5-gvisor` Mihomo закреплён на совместимой ARMv5 + gVisor сборке. Все ссылки на Zashboard, которые выдаёт GoshaCrash, передают `disableUpgradeCore=1`, поэтому действие обновления ядра скрыто.

`nano` и SFTP не блокируют первоначальную установку VPN. `gc edit` может установить `nano` по требованию; отсутствие SFTP выводится только как предупреждение.


## 3.7.3

- Исправлена установка Zashboard на legacy ASUSWRT: BusyBox `unzip` больше не принимается за полноценный Info-ZIP; совместимый `unzip` автоматически устанавливается через Download Master.
- Проверка Zashboard выполняется фактической распаковкой, без несовместимого с BusyBox `unzip -tqq`.
- `nano` и SFTP больше не являются блокирующими зависимостями первоначальной установки.
- `gc` получил line-oriented fallback-меню для SSH/BusyBox окружений без рабочего raw-TTY/`stty`.
- Для `legacy-armv5-gvisor` Zashboard всегда открывается с `disableUpgradeCore=1`; в `gc status` явно указано, что ARMv5-ядро закреплено и его обновление отключено.
- RT-AC68U с kernel 2.6 остаётся на `manual` routing + `tun.stack: gvisor` и pinned Mihomo ARMv5.


### 3.6.1-tty-sftp

- Исправлено интерактивное меню на ASUSWRT, где `stty` отсутствует как отдельная команда, но доступен как applet `busybox stty`.
- `install.sh` проверяет SFTP subsystem, но его отсутствие не блокирует установку VPN; при необходимости пакет можно поставить через `gc pkg install openssh-sftp-server`.
- Никаких новых пунктов в меню `gc` не добавлено. SFTP используется штатным Dropbear ASUS, если его сборка ссылается на установленный `sftp-server`.

### 3.6.0-configgen
`install.sh` теперь сам генерирует базовый `config.yaml` под архитектуру и выбранный routing. Добавлена миграция legacy `config-legacy.yaml` без потери пользовательского конфига. Меню `gc` не расширялось.

### 3.5.4
Interactive menu terminal detection now falls back from `/dev/tty` to the current SSH stdin for older ASUSWRT environments.


### 3.6.2-live-logs-sftp

- Пункт `Logs` теперь позволяет смотреть последние 100 строк либо включать LIVE-поток Mihomo/GoshaCrash.
- CLI: `gc logs live mihomo 100` и `gc logs live system 100`; старый alias `follow` сохранён.
- `install.sh` автоматически устанавливает `openssh-sftp-server` через Download Master `ipkg/opkg`, если SFTP subsystem отсутствует.
