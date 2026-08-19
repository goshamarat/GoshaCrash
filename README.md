# GoshaCrash 3.8.6

Здесь нет описания shell-функций. Ниже — команды, которые можно **буквально вставлять в SSH**.

## Установка

```sh
rm -f /tmp/install.sh

wget --no-check-certificate \
  -O /tmp/install.sh \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'

grep INSTALLER_VERSION /tmp/install.sh
sh /tmp/install.sh
```

Проверка:

```sh
gc doctor
gc autostart status
gc status
```

## Меню

```sh
gc
```

В меню: `Status`, `Edit config`, `Restart`, `Stop`, `Logs`, `Exit`.

## Узнать каталог установки

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
echo "$BASE"
```

## Статус

```sh
gc status
```

Полная диагностика:

```sh
gc doctor
```

## Изменить config.yaml

```sh
gc edit
```

Вручную:

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

cp "$BASE/config.yaml" "$BASE/backups/config-manual.yaml"
/jffs/scripts/nano "$BASE/config.yaml"
```

Проверить:

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

Применить:

```sh
gc restart
```

Откатить:

```sh
cp "$BASE/backups/config-manual.yaml" "$BASE/config.yaml"
gc restart
```

## Restart / Stop

```sh
gc restart
```

```sh
gc stop
```

После `gc stop` снова включить:

```sh
gc restart
```

## Лог Mihomo

```sh
gc logs
```

```sh
gc logs mihomo 200
```

```sh
gc logs live mihomo 100
```

Без `gc`:

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

tail -n 100 "$BASE/logs/mihomo.log"
```

Live:

```sh
tail -f "$BASE/logs/mihomo.log"
```

## Логи установки

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

tail -n 200 "$BASE/logs/install.log"
tail -n 200 "$BASE/logs/packages.log"
```

## Проверить Mihomo

```sh
ps | grep '[m]ihomo'
```

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
cat "$BASE/run/mihomo.pid" 2>/dev/null
```

## Проверить TUN / DNS / маршруты

```sh
ifconfig tun0
```

```sh
netstat -ln | grep ':1053'
```

```sh
route -n
```

```sh
iptables -t mangle -L -n -v
iptables -t nat -L -n -v
```

## Routing

```sh
gc routing status
```

```sh
gc routing manual
```

```sh
gc routing auto
```

Для RT-AC68U:

```sh
gc routing manual
```

## Watchdog

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

cat "$BASE/run/watchdog.pid" 2>/dev/null

PID="$(cat "$BASE/run/watchdog.pid" 2>/dev/null)"
[ -n "$PID" ] && kill -0 "$PID" && echo "watchdog OK"
```

Состояние интернета:

```sh
cat "$BASE/state/internet.state" 2>/dev/null
ls -l "$BASE/state/wan-offline" 2>/dev/null
```

## Проверить автозапуск

```sh
gc autostart status
```

```sh
ls -l /jffs/scripts/usb-mount-script
ls -l /jffs/addons/goshacrash/start.sh
```

После reboot:

```sh
gc doctor
gc autostart status
gc status
```

Проверить время срабатывания:

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

cat "$BASE/state/autostart-hook-ran" 2>/dev/null
```

## Проверить `/opt` после reboot

```sh
ls -ld /opt /tmp/opt
readlink /tmp/opt 2>/dev/null
mount | grep -E '/opt|asusware|SANDISK'
```

## Nano

```sh
which nano
ls -l /opt/bin/nano /tmp/opt/bin/nano 2>/dev/null
```

На RT-AC68U через Download Master:

```sh
IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg

"$IPKG" list_installed | grep '^nano '
"$IPKG" files nano
```

Переустановить:

```sh
"$IPKG" update
"$IPKG" remove nano
"$IPKG" install nano
```

## Unzip

```sh
which unzip
ls -l /opt/bin/unzip /opt/bin/unzip-unzip /tmp/opt/bin/unzip-unzip 2>/dev/null
```

```sh
IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg

"$IPKG" list_installed | grep '^unzip '
"$IPKG" files unzip
```

Переустановить:

```sh
"$IPKG" update
"$IPKG" remove unzip
"$IPKG" install unzip
```

На старом Optware рабочий бинарник может быть:

```text
/opt/bin/unzip-unzip
```

## SFTP

```sh
gc sftp status
```

```sh
IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg

"$IPKG" list | grep '^openssh-sftp-server '
"$IPKG" list_installed | grep '^openssh-sftp-server '
"$IPKG" files openssh-sftp-server
```

Установить:

```sh
"$IPKG" update
"$IPKG" install openssh-sftp-server
```

С Windows:

```powershell
sftp admin@10.10.10.100
```

## Zashboard

```sh
gc dashboard
```

Посмотреть controller и secret:

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

grep '^external-controller:' "$BASE/config.yaml"
grep '^secret:' "$BASE/config.yaml"
```

## Ручной restart только процесса Mihomo

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

PID="$(cat "$BASE/run/mihomo.pid" 2>/dev/null)"
[ -n "$PID" ] && kill "$PID"

rm -f "$BASE/run/mihomo.pid"

GOGC=50 nohup "$BASE/bin/mihomo" \
  -d "$BASE" \
  -f "$BASE/config.yaml" \
  </dev/null >>"$BASE/logs/mihomo.log" 2>&1 &

echo $! > "$BASE/run/mihomo.pid"
```

После этого лучше выполнить:

```sh
gc restart
```

## Тест потери интернета

До отключения WAN:

```sh
gc status
ps | grep '[m]ihomo'
```

Отключить WAN примерно на 40 секунд.

Проверить:

```sh
gc status
ps | grep '[m]ihomo'
```

Вернуть WAN, подождать примерно 30 секунд.

Проверить:

```sh
gc status
ps | grep '[m]ihomo'
```

## Короткая шпаргалка

```sh
gc
gc status
gc doctor
gc edit
gc restart
gc stop
gc logs
gc logs live
gc dashboard
gc routing status
gc autostart status
gc sftp status
gc help
```


## Проверка internet probe

Если GoshaCrash пишет, что интернета нет:

```sh
gc internet-probe
```

Ручная проверка:

```sh
ping -c 2 -W 2 1.1.1.1
ping -c 2 -W 2 8.8.8.8
route -n
```

В 3.8.2 исправлен legacy-баг: наличие старого Optware `ip` больше не может само по себе объявить WAN offline. Сначала выполняются реальные внешние probes.


## 3.8.3 — исправление ложного OFFLINE

WAN probe больше не зависит от Optware PATH. Используется системный BusyBox:

```sh
/bin/ping -c 2 -W 2 1.1.1.1
```

Проверка GoshaCrash:

```sh
gc internet-probe
```

`gc restart` теперь не оставляет Mihomo выключенным после одного неудачного внешнего probe, если stock ASUSWRT одновременно сообщает:

```text
wan0_state_t = 2
wan0_auxstate_t = 0
WAN IP есть
gateway есть
default route есть
```

Решение об остановке работающего runtime принимает watchdog только после нескольких последовательных неудачных probes.

Если от старой версии остался ложный offline:

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash

rm -f "$BASE/state/wan-offline"
rm -f "$BASE/state/wan-fail-count"
rm -f "$BASE/state/wan-ok-count"
echo online > "$BASE/state/internet.state"

gc restart
```


## 3.8.4 — routing/PATH fix

Исправлены два дефекта 3.8.3:

```text
manual_route_start: not found
[: not found
```

Проверить routing-функцию:

```sh
grep -n '^manual_route_start()' /tmp/mnt/SANDISK/goshacrash/goshacrash.sh
```

Должна быть одна строка с определением функции.

Проверить PATH:

```sh
gc doctor
```

В начале `goshacrash.sh` теперь сразу устанавливаются системные каталоги:

```text
/usr/sbin:/usr/bin:/sbin:/bin
```

ещё до первого `[`, `mkdir`, `dirname` или другой BusyBox-команды.


## 3.8.5 — исправление `[: not found`

На некоторых stock ASUSWRT BusyBox содержит applet `[`, но прошивка не предоставляет отдельную команду `/bin/[`.

3.8.5 больше от этого не зависит.

До первого `[ ... ]` GoshaCrash создаёт:

```text
/tmp/goshacrash-compat/[
```

который выполняет:

```sh
/bin/busybox '[' "$@"
```

При установке дополнительно создаётся постоянный wrapper:

```text
/jffs/scripts/[
```

Проверить:

```sh
command -v '['
/bin/busybox '[' -n "ok" ']'
echo "BRACKET_RC=$?"
```

Диагностика:

```sh
gc doctor
```

должна показать:

```text
shell [: OK
```


## 3.8.6 — исправление shell compatibility

В 3.8.5 preflight ошибочно проверял `command -v '['`. На старом stock ASUSWRT/ash
это не является надёжной проверкой внешнего wrapper-файла. Кроме того, сам installer
успевал использовать `[ ... ]` до установки wrapper.

В 3.8.6 installer использует builtin `test` для собственных проверок, а совместимость
проверяется прямым запуском:

```sh
/bin/busybox '[' -n "goshacrash" ']'
/jffs/scripts/'[' -n "goshacrash" ']'
```

Проверка после установки:

```sh
gc version
/bin/busybox '[' -n "ok" ']'; echo "BUSYBOX=$?"
/jffs/scripts/'[' -n "ok" ']'; echo "WRAPPER=$?"
gc doctor
gc status
```
