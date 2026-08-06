# GoshaCrash 3.0.0-online

Сетевая установка Mihomo с TUN, собственного DNS, ручной маршрутизации и Zashboard на legacy ASUSWRT через Download Master.

## Состав репозитория

- `install.sh` — единственный установщик. Находит USB и Download Master, поднимает `/opt`, устанавливает пакеты через `ipkg/opkg`, скачивает Mihomo и Zashboard с GitHub, создаёт конфиг и автозапуск.
- `goshacrash.sh` — единый основной скрипт: запуск, остановка, TUN/DNS/iptables, логи, редактирование конфига, пакеты и обновление Zashboard.
- `config.example.yaml` — минимальный рабочий конфиг. При первой установке копируется в `config.yaml`; существующий пользовательский конфиг не перезаписывается.

## Что требуется на роутере

1. USB-накопитель, подключённый к ASUS.
2. Установленный и хотя бы один раз запущенный Download Master.
3. Включённый SSH.

Установщик ищет `asusware.arm`, `asusware.arm64` или `asusware` на всех `/tmp/mnt/*`. Название флешки не фиксировано.

## Установка

Подключись к роутеру по SSH и выполни:

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh
sh /tmp/install.sh
```

Если подключено несколько накопителей с Download Master:

```sh
INSTALL_ROOT=/tmp/mnt/ИМЯ_ФЛЕШКИ sh /tmp/install.sh
```

После установки:

```sh
goshacrash
```

## Основные команды

```sh
goshacrash status
goshacrash restart
goshacrash stop
goshacrash edit
goshacrash apply
goshacrash logs mihomo 100
goshacrash logs system 100
goshacrash doctor
```

Установить дополнительный пакет через средства Download Master:

```sh
goshacrash pkg update
goshacrash pkg install ИМЯ_ПАКЕТА
```

## Обновление

```sh
goshacrash update
```

В legacy-сборке эта команда обновляет **только Zashboard**. Mihomo, основной скрипт и правила маршрутизации не заменяются.

Полная переустановка или восстановление компонентов выполняется повторным запуском установщика:

```sh
sh /tmp/install.sh repair
```

Перед заменой установщик сохраняет прежний основной скрипт и Mihomo в `backups/`. Существующий `config.yaml` сохраняется.

## Конфиг

Рабочий файл находится в автоматически найденном каталоге:

```text
/tmp/mnt/<USB>/goshacrash/config.yaml
```

Редактирование непосредственно на роутере:

```sh
goshacrash edit
```

Перед редактированием создаётся резервная копия. Конфиг проверяется командой Mihomo `-t`; при ошибке возвращается предыдущий файл. После успешного запуска сохраняется `backups/config.last-good.yaml`.

## Логи

```text
logs/install.log
logs/goshacrash.log
logs/mihomo.log
logs/boot.log
```

Просмотр:

```sh
goshacrash logs install 100
goshacrash logs system 100
goshacrash logs mihomo 100
goshacrash logs follow
```

## SCP с Windows

Старый SSH-сервер ASUS может не поддерживать SFTP. В таком случае используй legacy SCP-режим `-O`:

```powershell
scp -O .\config.yaml admin@10.10.10.100:/tmp/config.yaml
```

Затем на роутере:

```sh
cp /tmp/config.yaml "$(cat /jffs/addons/goshacrash/base)/config.yaml"
goshacrash apply
```

В WinSCP следует выбрать протокол **SCP**, порт `22`.

## Принцип маршрутизации legacy

- TUN-интерфейс: `tun0`.
- Метка трафика: `0x2333`.
- Таблица маршрутизации: `2022`.
- Метка исходящих соединений Mihomo: `9012` (`0x2334`) — исключается из повторного захвата.
- DNS клиентов перенаправляется на `dnsmasq:53`, а исходящие запросы роутера — на DNS Mihomo `127.0.0.1:1053`.
- `tun.auto-route` и `tun.auto-redirect` выключены: правила создаёт `goshacrash.sh`.

## Удаление

```sh
sh /tmp/install.sh remove
```

Перед удалением `config.yaml` копируется в корень USB как `goshacrash-config.yaml`.
