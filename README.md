# GoshaCrash 3.7.9 — RT-AC68U: установка руками через SSH

Это инструкция именно для того RT-AC68U, на котором всё это проверялось:

```text
ASUS RT-AC68U
CPU: armv7l
Linux: 2.6.36.4brcmarm
USB: /tmp/mnt/SANDISK
Download Master: /tmp/mnt/SANDISK/asusware.arm
package manager: ipkg
Mihomo profile: legacy-armv5-gvisor
routing: manual
TUN stack: gvisor
```

Здесь без лишней теории: сначала обычная установка, потом те же вещи руками через SSH. Это пригодится, если надо понять, что именно сломалось, или вообще обойтись без `gc`.

> Важно: на этом RT-AC68U оставляем legacy Mihomo `v1.19.28` ARMv5 + gVisor. Обычное обновление core здесь не нужно.

## 1. Если надо просто поставить

```sh
cd /tmp
rm -f /tmp/install.sh
wget --no-check-certificate -O /tmp/install.sh \
'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'
grep 'INSTALLER_VERSION' /tmp/install.sh | head
sh /tmp/install.sh
```

После установки:

```sh
gc status
gc help
```

---

# 2. Если ставим руками

Дальше всё выполняется по SSH под `admin`.

## Переменные

```sh
USB=/tmp/mnt/SANDISK
OPT=/tmp/mnt/SANDISK/asusware.arm
BASE=/tmp/mnt/SANDISK/goshacrash
IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
export PATH=/opt/bin:/opt/sbin:$OPT/bin:$OPT/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
```

Проверка:

```sh
uname -a
uname -m
nvram get productid
df -h
```

Ожидаем RT-AC68U, `armv7l`, kernel 2.6.36 и USB `/tmp/mnt/SANDISK`.

## Каталоги

```sh
mkdir -p "$BASE/bin" "$BASE/logs" "$BASE/run" "$BASE/backups" "$BASE/ui"
```

## Ставим нужные утилиты

```sh
"$IPKG" update
"$IPKG" install nano
"$IPKG" install unzip
```

Проверить nano:

```sh
ls -l /opt/bin/nano
/opt/bin/nano --version | head
```

На этом старом Optware Info-ZIP устанавливается как:

```text
/opt/bin/unzip-unzip
```

Проверить:

```sh
"$IPKG" files unzip
ls -l /opt/bin/unzip-unzip
/opt/bin/unzip-unzip -v | head
```

Встроенный `/usr/bin/unzip` — BusyBox. Для Zashboard используем `/opt/bin/unzip-unzip`.

---

# 3. Ставим gcnet

```sh
wget --no-check-certificate \
  -O "$BASE/bin/gcnet" \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/assets/gcnet-armv5'
chmod 755 "$BASE/bin/gcnet"
```

Сразу проверяем, что helper вообще запускается:

```sh
"$BASE/bin/gcnet" link-exists lo
echo $?
```

`0` означает успех.

---

# 4. Ставим Mihomo

Для этого роутера берём вот этот Mihomo:

```sh
cd /tmp
rm -f /tmp/mihomo.gz
wget --no-check-certificate \
  -O /tmp/mihomo.gz \
  'https://github.com/goshamarat/GoshaCrash/releases/download/mihomo-gvisor-armv5-v1.19.28/mihomo-linux-armv5-gvisor-v1.19.28.gz'
gzip -dc /tmp/mihomo.gz > "$BASE/bin/mihomo"
chmod 755 "$BASE/bin/mihomo"
rm -f /tmp/mihomo.gz
```

Проверить:

```sh
"$BASE/bin/mihomo" -v
```

Если команда отработала без `not found`/`illegal instruction`, с бинарником всё нормально.

---

# 5. Делаем config.yaml

Для начала можно положить простой DIRECT-конфиг и проверить сам Mihomo:

```sh
cat > "$BASE/config.yaml" <<'YAML'
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false

external-controller: 0.0.0.0:9090
secret: ""

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

tun:
  enable: true
  device: tun0
  stack: gvisor
  auto-route: false
  auto-redirect: false
  auto-detect-interface: false
  routing-mark: 9012

proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
YAML
```

Это только проверочный конфиг: весь трафик идёт DIRECT. Свои прокси и правила добавишь уже после того, как убедишься, что Mihomo нормально стартует.

Проверить **до запуска**:

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

---

# 6. Запускаем Mihomo

```sh
GOGC=50 nohup "$BASE/bin/mihomo" \
  -d "$BASE" \
  -f "$BASE/config.yaml" \
  </dev/null >>"$BASE/logs/mihomo.log" 2>&1 &
echo $! > "$BASE/run/mihomo.pid"
sleep 3
```

Проверки:

```sh
ps | grep '[m]ihomo'
cat "$BASE/run/mihomo.pid"
ifconfig tun0
netstat -ln | grep ':1053'
tail -n 50 "$BASE/logs/mihomo.log"
```

Если `tun0` появился и порт 1053 слушается, сам Mihomo поднялся. Теперь надо завернуть в него трафик.

---

# 7. Настраиваем маршрутизацию

Те же значения, которые использует GoshaCrash:

```sh
GCNET="$BASE/bin/gcnet"
TUN=tun0
TABLE=2022
PREF=10010
MARK=0x2333
OUTMARK=0x2334
LAN=br0
```

Проверить LAN-интерфейс:

```sh
ifconfig br0
```

Разрешить forwarding и отключить reverse-path filtering:

```sh
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/default/rp_filter
[ -w /proc/sys/net/ipv4/conf/br0/rp_filter ] && echo 0 > /proc/sys/net/ipv4/conf/br0/rp_filter
[ -w /proc/sys/net/ipv4/conf/tun0/rp_filter ] && echo 0 > /proc/sys/net/ipv4/conf/tun0/rp_filter
```

Создать таблицу и policy rule через legacy `gcnet`:

```sh
"$GCNET" route-add-default "$TUN" "$TABLE"
"$GCNET" rule-add "$MARK" "$TABLE" "$PREF"
```

Проверить:

```sh
"$GCNET" route-default-exists "$TUN" "$TABLE"; echo $?
"$GCNET" rule-exists "$MARK" "$TABLE"; echo $?
```

## LAN → TUN

```sh
iptables -t mangle -N GOSHACRASH_TUN_LAN 2>/dev/null
iptables -t mangle -F GOSHACRASH_TUN_LAN

iptables -t mangle -A GOSHACRASH_TUN_LAN -m mark --mark "$OUTMARK" -j RETURN
iptables -t mangle -A GOSHACRASH_TUN_LAN -p udp --dport 53 -j RETURN
iptables -t mangle -A GOSHACRASH_TUN_LAN -p tcp --dport 53 -j RETURN

for NET in \
  0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
  169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
  224.0.0.0/4 240.0.0.0/4 255.255.255.255/32
do
  iptables -t mangle -A GOSHACRASH_TUN_LAN -d "$NET" -j RETURN
done

iptables -t mangle -A GOSHACRASH_TUN_LAN -j MARK --set-mark "$MARK"
iptables -t mangle -I PREROUTING 1 -i "$LAN" -j GOSHACRASH_TUN_LAN
```

## Трафик самого роутера → TUN

```sh
iptables -t mangle -N GOSHACRASH_TUN_ROUTER 2>/dev/null
iptables -t mangle -F GOSHACRASH_TUN_ROUTER

iptables -t mangle -A GOSHACRASH_TUN_ROUTER -m mark --mark "$OUTMARK" -j RETURN
iptables -t mangle -A GOSHACRASH_TUN_ROUTER -p udp --dport 53 -j RETURN
iptables -t mangle -A GOSHACRASH_TUN_ROUTER -p tcp --dport 53 -j RETURN

for NET in \
  0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
  169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
  224.0.0.0/4 240.0.0.0/4 255.255.255.255/32
do
  iptables -t mangle -A GOSHACRASH_TUN_ROUTER -d "$NET" -j RETURN
done

iptables -t mangle -A GOSHACRASH_TUN_ROUTER -j MARK --set-mark "$MARK"
iptables -t mangle -I OUTPUT 1 -j GOSHACRASH_TUN_ROUTER
```

## DNS клиентов

ASUS dnsmasq слушает порт 53. Клиентский DNS перенаправляется на локальный DNS роутера:

```sh
iptables -t nat -N GOSHACRASH_DNS_LAN 2>/dev/null
iptables -t nat -F GOSHACRASH_DNS_LAN
iptables -t nat -A GOSHACRASH_DNS_LAN -p udp -j REDIRECT --to-ports 53
iptables -t nat -A GOSHACRASH_DNS_LAN -p tcp -j REDIRECT --to-ports 53
iptables -t nat -I PREROUTING 1 -i "$LAN" -p udp --dport 53 -j GOSHACRASH_DNS_LAN
iptables -t nat -I PREROUTING 1 -i "$LAN" -p tcp --dport 53 -j GOSHACRASH_DNS_LAN
```

## DNS самого роутера → Mihomo 1053

```sh
iptables -t nat -N GOSHACRASH_DNS_OUT 2>/dev/null
iptables -t nat -F GOSHACRASH_DNS_OUT
iptables -t nat -A GOSHACRASH_DNS_OUT -m mark --mark "$OUTMARK" -j RETURN
iptables -t nat -A GOSHACRASH_DNS_OUT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A GOSHACRASH_DNS_OUT -p udp -j REDIRECT --to-ports 1053
iptables -t nat -A GOSHACRASH_DNS_OUT -p tcp -j REDIRECT --to-ports 1053
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j GOSHACRASH_DNS_OUT
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j GOSHACRASH_DNS_OUT
```

## FORWARD

```sh
iptables -t filter -N GOSHACRASH_TUN_FORWARD 2>/dev/null
iptables -t filter -F GOSHACRASH_TUN_FORWARD
iptables -t filter -A GOSHACRASH_TUN_FORWARD -i "$LAN" -o "$TUN" -j ACCEPT
iptables -t filter -A GOSHACRASH_TUN_FORWARD -i "$TUN" -o "$LAN" -j ACCEPT
iptables -t filter -I FORWARD 1 -j GOSHACRASH_TUN_FORWARD
```

Сбросить route cache:

```sh
echo -1 > /proc/sys/net/ipv4/route/flush
```

Проверить:

```sh
"$GCNET" rule-exists "$MARK" "$TABLE"; echo $?
"$GCNET" route-default-exists "$TUN" "$TABLE"; echo $?
iptables -t mangle -L GOSHACRASH_TUN_LAN -n -v
iptables -t mangle -L GOSHACRASH_TUN_ROUTER -n -v
iptables -t nat -L GOSHACRASH_DNS_OUT -n -v
iptables -t filter -L GOSHACRASH_TUN_FORWARD -n -v
```

> Здесь показан вариант для нашего `br0`. Скрипт делает чуть больше: чистит старые правила, сохраняет sysctl, умеет откатиться и учитывает дополнительные bridge-интерфейсы.

---

# 8. Ставим Zashboard

```sh
cd /tmp
rm -f /tmp/zashboard.zip
wget --no-check-certificate \
  -O /tmp/zashboard.zip \
  'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip'
rm -rf "$BASE/ui"
mkdir -p "$BASE/ui"
/opt/bin/unzip-unzip -o /tmp/zashboard.zip -d "$BASE/ui"
rm -f /tmp/zashboard.zip
```

Проверить:

```sh
find "$BASE/ui" -maxdepth 2 -type f | head
```

Mihomo controller:

```text
http://10.10.10.100:9090
```

UI:

```text
http://10.10.10.100:9090/ui/
```

Для legacy ARMv5 используй setup URL GoshaCrash с `disableUpgradeCore=1`, чтобы не предлагать несовместимое обновление core:

```sh
gc dashboard
```

---

# 9. Как руками поправить config.yaml

Backup:

```sh
cp "$BASE/config.yaml" "$BASE/backups/config-manual.yaml"
```

Редактор:

```sh
/opt/bin/nano "$BASE/config.yaml"
```

Проверка:

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

Если ошибка:

```sh
cp "$BASE/backups/config-manual.yaml" "$BASE/config.yaml"
```

Если всё нормально и GoshaCrash уже установлен:

```sh
gc restart
```

---

# 10. Как руками перезапустить Mihomo

Только процесс:

```sh
PID="$(cat "$BASE/run/mihomo.pid" 2>/dev/null)"
[ -n "$PID" ] && kill "$PID"
rm -f "$BASE/run/mihomo.pid"

GOGC=50 nohup "$BASE/bin/mihomo" \
  -d "$BASE" \
  -f "$BASE/config.yaml" \
  </dev/null >>"$BASE/logs/mihomo.log" 2>&1 &
echo $! > "$BASE/run/mihomo.pid"
```

Проверить:

```sh
ps | grep '[m]ihomo'
ifconfig tun0
tail -n 50 "$BASE/logs/mihomo.log"
```

Если GoshaCrash установлен, штатный полный перезапуск:

```sh
gc restart
```

Он дополнительно восстанавливает routing и watchdog.

---

# 11. Логи

Mihomo:

```sh
tail -n 100 "$BASE/logs/mihomo.log"
```

Live:

```sh
tail -f "$BASE/logs/mihomo.log"
```

GoshaCrash:

```sh
tail -n 100 "$BASE/logs/goshacrash.log"
```

Установка:

```sh
tail -n 100 "$BASE/logs/install.log"
```

Boot:

```sh
tail -n 100 "$BASE/logs/boot.log"
```

Watchdog:

```sh
tail -n 100 "$BASE/logs/watchdog.log"
```

Пакеты:

```sh
tail -n 100 "$BASE/logs/packages.log"
```

---

# 12. Что проверить, если не работает

Процесс:

```sh
ps | grep '[m]ihomo'
```

Конфиг:

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

TUN:

```sh
ifconfig tun0
```

DNS Mihomo:

```sh
netstat -ln | grep ':1053'
```

Обычные маршруты:

```sh
route -n
```

Legacy policy routing:

```sh
"$BASE/bin/gcnet" rule-exists 0x2333 2022; echo $?
"$BASE/bin/gcnet" route-default-exists tun0 2022; echo $?
```

iptables:

```sh
iptables -t mangle -L -n -v
iptables -t nat -L -n -v
iptables -t filter -L FORWARD -n -v
```

---

# 13. То же самое через `gc`

| Нужно сделать | Руками | GoshaCrash |
|---|---|---|
| Проверить процесс/TUN/routing | `ps`, `ifconfig`, `gcnet`, `iptables` | `gc status` |
| Изменить конфиг | `cp`, `nano`, `mihomo -t` | `gc edit` |
| Перезапустить весь VPN | kill/start + policy routing + iptables | `gc restart` |
| Полностью остановить VPN | очистить routing/iptables + kill | `gc stop` |
| Читать лог | `tail -n` | `gc logs` |
| Live лог | `tail -f` | `gc logs live` |
| Проверить routing | `gcnet` + `iptables` | `gc routing status` |
| Получить URL UI | читать controller/secret | `gc dashboard` |

## Если коротко

`gc` просто собирает в команды те действия, которые выше мы делали руками:

```text
скачать бинарники
создать config.yaml
проверить mihomo -t
запустить процесс
дождаться tun0
создать policy rule
создать route table 2022
поставить fwmark 0x2333
создать iptables chains
перехватить DNS
разрешить FORWARD
следить за процессом watchdog'ом
восстановить всё после reboot/firewall restart
```

Если что-то не работает, не обязательно гадать, что делает скрипт: можно пройтись по этим командам и отдельно проверить Mihomo, TUN, DNS, routing и iptables.
\n\n# Автозапуск на stock RT-AC68U\n\nНа официальном ASUSWRT не стоит рассчитывать только на `/jffs/scripts/services-start`: этот hook характерен для Merlin. Также новые официальные прошивки могут чистить `script_usbmount` из NVRAM. Поэтому GoshaCrash 3.7.9 ставит основной hook прямо туда, откуда запускается Download Master на этом роутере:\n\n```text\n/tmp/mnt/SANDISK/asusware.arm/S99goshacrash.1\n```\n\nПлюс остаются резервные hooks в JFFS и `etc/init.d`. `start.sh` теперь ждёт USB до 300 секунд, а не выходит, если `/tmp/mnt/SANDISK` ещё не успел смонтироваться.\n\nПроверить всё одной командой:\n\n```sh\ngc autostart status\n```\n\nЕсли там написано:\n\n```text\nmanual-stop: ДА\n```\n\nто автозапуск выключен намеренно после `gc stop`. Включить обратно:\n\n```sh\ngc restart\n```\n\nПроверить вручную после reboot:\n\n```sh\ncat /tmp/mnt/SANDISK/goshacrash/logs/boot.log\nls -l /tmp/mnt/SANDISK/asusware.arm/S99goshacrash.1\nps | grep '[m]ihomo'\n```\n

# Что исправлено в 3.7.8

На чистой флешке старый Download Master иногда оставляет `ipkg` рабочим, а `/opt` ещё не до конца готов. Из-за этого `nano` мог числиться установленным, но `install.sh` его не находил. Теперь установщик:

```text
проверяет nano
→ пробует восстановить окружение Download Master
→ проверяет пакетную базу
→ при необходимости переустанавливает nano
→ только потом продолжает установку
```

При восстановлении Download Master учитывается реальный startup-файл stock RT-AC68U:

```text
/tmp/mnt/SANDISK/asusware.arm/S50downloadmaster.1
```

Ещё исправлен важный момент автозапуска. Раньше USB-unmount и остановка Download Master могли вызвать обычный:

```sh
gc stop
```

а он создаёт:

```text
state/manual-stop
```

Из-за этого после reboot Mihomo мог не запуститься. Теперь системные stop/unmount hooks вызывают внутренний `service-stop`: он останавливает Mihomo, routing и watchdog, но **не выключает следующий автозапуск**.

`manual-stop` создаётся только когда пользователь сам выполняет:

```sh
gc stop
```

Проверить автозапуск:

```sh
gc autostart status
```

# Автозапуск на stock ASUSWRT

В 3.7.9 автозапуск переделан под официальную ASUSWRT. Merlin `services-start` и NVRAM `script_usbmount` больше не используются.

Цепочка:

```text
USB смонтирован
→ ASUS USB Applications запускает S50usb-mount-script
→ /jffs/scripts/usb-mount-script
→ /jffs/addons/goshacrash/start.sh
→ goshacrash.sh boot
→ Mihomo + TUN + routing + watchdog
```

Проверка:

```sh
gc autostart status
```

До первого reboot должны быть `OK` у `start.sh`, `usb-mount-script`, `S50usb-mount-script` и package metadata. После reboot появится время последнего вызова hook.

`gc stop` намеренно выключает следующий автозапуск через `manual-stop`. Системный USB unmount вызывает `service-stop` и `manual-stop` не создаёт.

Stock USB-mount bridge использует механизм проекта `jacklul/asuswrt-scripts`.

