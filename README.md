# GoshaCrash 3.5.3

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

The arrow-key menu is intentionally minimal but styled as a compact terminal dashboard. It shows live Mihomo/TUN state, profile and routing mode, with only Status, Restart, Stop, Logs and Exit. All advanced functions remain available through `goshacrash help`.

Справка без меню:

```sh
goshacrash help
```

## Конфиги в публичном репозитории

`config.yaml` и `config-legacy.yaml` — только DIRECT-заглушки без подписок, UUID и приватных серверов.

- ARMv5/RT-AC68U → `config-legacy.yaml`.
- остальные архитектуры → `config.yaml`.

Установщик подстраивает routing-параметры заглушки под выбранный режим. Реальный конфиг загружается отдельно.

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

Zashboard устанавливается `install.sh`. Обновление панели выполняется кнопкой внутри Zashboard. На legacy ссылка скрывает обновление ядра Mihomo.
