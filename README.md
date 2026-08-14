# GoshaCrash

GoshaCrash — установщик и менеджер Mihomo для ASUSWRT.

Этот README — **SSH-шпаргалка администратора**. Здесь не описываются внутренние функции shell-скрипта. Здесь показано, **что GoshaCrash автоматизирует и как то же базовое действие выполнить вручную через SSH**.

Версия: **3.7.5**

## Установка

На роутере должны быть USB-накопитель, ASUS Download Master, SSH и интернет.

```sh
wget --no-check-certificate \
  -O /tmp/install.sh \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'

sh /tmp/install.sh
```

Для RT-AC68U установщик сам выбирает legacy ARMv5 + gVisor и manual routing.

## Каталог GoshaCrash

Во всех примерах ниже сначала можно определить каталог установки:

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
echo "$BASE"
```

На тестовом RT-AC68U это:

```text
/tmp/mnt/SANDISK/goshacrash
```

Основные файлы:

```text
$BASE/bin/mihomo
$BASE/config.yaml
$BASE/run/mihomo.pid
$BASE/logs/mihomo.log
$BASE/logs/goshacrash.log
$BASE/logs/install.log
$BASE/logs/boot.log
$BASE/logs/watchdog.log
$BASE/logs/packages.log
```

---

## Как проверить, работает ли Mihomo

Через GoshaCrash:

```sh
gc status
```

Вручную:

```sh
ps | grep '[m]ihomo'
```

Посмотреть сохранённый PID:

```sh
cat "$BASE/run/mihomo.pid"
```

Проверить, существует ли процесс с этим PID:

```sh
PID="$(cat "$BASE/run/mihomo.pid" 2>/dev/null)"
[ -n "$PID" ] && kill -0 "$PID" && echo "Mihomo работает"
```

Проверить TUN:

```sh
ifconfig tun0
```

Проверить обычные маршруты:

```sh
route -n
```

---

## Как отредактировать config.yaml

Через GoshaCrash:

```sh
gc edit
```

`gc edit` удобнее, потому что делает backup, открывает nano, проверяет конфиг Mihomo и только после успешной проверки перезапускает VPN.

### Вручную

Сначала backup:

```sh
cp "$BASE/config.yaml" "$BASE/backups/config-manual.yaml"
```

Открыть:

```sh
/opt/bin/nano "$BASE/config.yaml"
```

Если `nano` доступен через PATH:

```sh
nano "$BASE/config.yaml"
```

Сохранение в nano:

```text
Ctrl+O
Enter
Ctrl+X
```

После редактирования **до перезапуска** проверить конфиг:

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

Успешная проверка заканчивается сообщением о том, что configuration test successful.

Если конфиг сломан, вернуть backup:

```sh
cp "$BASE/backups/config-manual.yaml" "$BASE/config.yaml"
```

После успешной проверки применить:

```sh
gc restart
```

---

## Как перезапустить Mihomo

### Правильный способ

```sh
gc restart
```

Это перезапускает не только процесс. GoshaCrash также проверяет конфиг, останавливает watchdog, очищает старую маршрутизацию, запускает Mihomo, ждёт DNS и `tun0`, поднимает routing и снова запускает watchdog.

### Только процесс Mihomo вручную

Остановить текущий PID:

```sh
PID="$(cat "$BASE/run/mihomo.pid" 2>/dev/null)"
[ -n "$PID" ] && kill "$PID"
```

Удалить старый PID-файл:

```sh
rm -f "$BASE/run/mihomo.pid"
```

Запустить Mihomo той же базовой командой, которую использует GoshaCrash:

```sh
GOGC=50 nohup "$BASE/bin/mihomo" \
  -d "$BASE" \
  -f "$BASE/config.yaml" \
  </dev/null >>"$BASE/logs/mihomo.log" 2>&1 &
```

Записать новый PID:

```sh
echo $! > "$BASE/run/mihomo.pid"
```

Проверить:

```sh
ps | grep '[m]ihomo'
```

```sh
tail -n 50 "$BASE/logs/mihomo.log"
```

**Важно:** это перезапускает только процесс Mihomo. Manual policy routing, iptables и watchdog так полностью не восстанавливаются. После ручной диагностики для возврата системы в штатное состояние:

```sh
gc restart
```

---

## Как остановить VPN

Штатно:

```sh
gc stop
```

Это правильная команда, потому что она:

- останавливает watchdog;
- убирает маршрутизацию GoshaCrash;
- останавливает Mihomo;
- возвращает обычный DIRECT;
- ставит флаг ручной остановки.

### Остановить только Mihomo вручную

```sh
PID="$(cat "$BASE/run/mihomo.pid" 2>/dev/null)"
[ -n "$PID" ] && kill "$PID"
```

Проверить:

```sh
ps | grep '[m]ihomo'
```

Но watchdog может запустить процесс снова. Поэтому для настоящей остановки VPN используется:

```sh
gc stop
```

---

## Как посмотреть лог Mihomo

Последние 100 строк вручную:

```sh
tail -n 100 "$BASE/logs/mihomo.log"
```

Последние 300:

```sh
tail -n 300 "$BASE/logs/mihomo.log"
```

Следить в реальном времени:

```sh
tail -f "$BASE/logs/mihomo.log"
```

Выход:

```text
Ctrl+C
```

Через GoshaCrash:

```sh
gc logs mihomo 100
```

Live:

```sh
gc logs live mihomo 100
```

---

## Какие ещё есть логи

Основной лог GoshaCrash:

```sh
tail -n 100 "$BASE/logs/goshacrash.log"
```

Установка:

```sh
tail -n 100 "$BASE/logs/install.log"
```

Автозапуск:

```sh
tail -n 100 "$BASE/logs/boot.log"
```

Watchdog:

```sh
tail -n 100 "$BASE/logs/watchdog.log"
```

Установка пакетов `ipkg` / `opkg`:

```sh
tail -n 100 "$BASE/logs/packages.log"
```

То же через `gc`:

```sh
gc logs system 100
gc logs install 100
gc logs boot 100
gc logs watchdog 100
gc logs packages 100
```

---

## Как проверить TUN

```sh
ifconfig tun0
```

Если `tun0` существует и поднят, интерфейс будет показан.

Проверить устройство TUN:

```sh
ls -l /dev/net/tun
```

---

## Как посмотреть маршруты

Стандартная таблица:

```sh
route -n
```

Если в системе установлен полноценный `ip`:

```sh
ip route show
```

Policy rules:

```sh
ip rule show
```

Таблица GoshaCrash manual routing:

```sh
ip route show table 2022
```

На старом RT-AC68U `ip` может отсутствовать. GoshaCrash для этого использует свой legacy helper `gcnet`, поэтому отсутствие команды `ip` само по себе не означает неисправность VPN.

Проверка средствами GoshaCrash:

```sh
gc routing status
```

---

## Как посмотреть iptables

Mangle:

```sh
iptables -t mangle -L -n -v
```

NAT:

```sh
iptables -t nat -L -n -v
```

FORWARD:

```sh
iptables -t filter -L FORWARD -n -v
```

На manual routing GoshaCrash создаёт собственные цепочки. В выводе можно искать:

```text
GOSHACRASH_TUN_LAN
GOSHACRASH_TUN_ROUTER
GOSHACRASH_TUN_FORWARD
GOSHACRASH_DNS_LAN
GOSHACRASH_DNS_OUT
```

Например:

```sh
iptables -t mangle -L GOSHACRASH_TUN_LAN -n -v
```

---

## Как проверить DNS Mihomo

GoshaCrash по умолчанию ждёт DNS Mihomo на порту `1053`.

Посмотреть слушающие порты:

```sh
netstat -ln | grep ':1053'
```

Если ничего нет, посмотреть лог:

```sh
tail -n 100 "$BASE/logs/mihomo.log"
```

---

## Как проверить config.yaml без запуска

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

Это одна из самых полезных команд при ручной диагностике.

Она позволяет проверить YAML/Mihomo-конфигурацию **до** остановки работающего VPN.

---

## Как сделать backup config.yaml

Простой backup:

```sh
cp "$BASE/config.yaml" "$BASE/config.yaml.bak"
```

В каталог backups:

```sh
cp "$BASE/config.yaml" "$BASE/backups/config-manual.yaml"
```

Вернуть:

```sh
cp "$BASE/backups/config-manual.yaml" "$BASE/config.yaml"
```

Проверить после восстановления:

```sh
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
```

Применить:

```sh
gc restart
```

---

## Как открыть Zashboard

Самый надёжный вариант:

```sh
gc dashboard
```

Команда выведет готовый URL.

Посмотреть controller вручную:

```sh
grep '^external-controller:' "$BASE/config.yaml"
```

Посмотреть secret:

```sh
grep '^secret:' "$BASE/config.yaml"
```

На legacy ARMv5 GoshaCrash добавляет в setup URL:

```text
disableUpgradeCore=1
```

потому что используемая legacy-сборка Mihomo закреплена для совместимости со старым kernel.

---

## Routing: manual и auto

Посмотреть режим:

```sh
gc routing status
```

Переключить на manual:

```sh
gc routing manual
```

Переключить на automatic:

```sh
gc routing auto
```

Для RT-AC68U / legacy ARMv5 доступен только:

```text
manual
```

`gc routing manual/auto` лучше не заменять набором ручных `ip rule`/`iptables` команд: GoshaCrash создаёт несколько связанных policy-routing, mangle, NAT, DNS и FORWARD правил и сохраняет состояние для корректной очистки/восстановления.

Для изучения текущего результата используются диагностические команды:

```sh
route -n
iptables -t mangle -L -n -v
iptables -t nat -L -n -v
```

и, если есть `ip`:

```sh
ip rule show
ip route show table 2022
```

---

## Watchdog

Посмотреть:

```sh
cat "$BASE/run/watchdog.pid"
```

Проверить процесс:

```sh
PID="$(cat "$BASE/run/watchdog.pid" 2>/dev/null)"
[ -n "$PID" ] && kill -0 "$PID" && echo "Watchdog работает"
```

Лог:

```sh
tail -n 100 "$BASE/logs/watchdog.log"
```

Watchdog проверяет Mihomo и routing. Поэтому простое ручное `kill` Mihomo не равно `gc stop`: watchdog может его восстановить.

---

## Полезная последовательность после изменения конфига

```sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
cp "$BASE/config.yaml" "$BASE/backups/config-manual.yaml"
nano "$BASE/config.yaml"
"$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"
gc restart
gc status
tail -n 50 "$BASE/logs/mihomo.log"
```

---

## Если VPN не работает

Проверять по порядку:

```sh
gc status
```

```sh
ps | grep '[m]ihomo'
```

```sh
ifconfig tun0
```

```sh
netstat -ln | grep ':1053'
```

```sh
tail -n 100 "$BASE/logs/mihomo.log"
```

```sh
tail -n 100 "$BASE/logs/goshacrash.log"
```

```sh
gc routing status
```

```sh
route -n
```

```sh
iptables -t mangle -L -n -v
```

Так видно, на каком уровне проблема: процесс → конфиг → DNS → TUN → routing → iptables.

---

## Краткий словарь `gc`

| Команда | Что делает | Базовый ручной аналог |
|---|---|---|
| `gc status` | Показывает Mihomo, TUN и routing | `ps`, `ifconfig tun0`, `route -n` |
| `gc edit` | Backup, nano, проверка, restart/rollback | `cp`, `nano`, `mihomo -t`, `gc restart` |
| `gc restart` | Безопасно пересобирает весь VPN runtime | `kill` + запуск Mihomo; routing/watchdog лучше вернуть через `gc restart` |
| `gc stop` | Останавливает весь VPN и возвращает DIRECT | Одного `kill` недостаточно из-за routing/watchdog |
| `gc logs` | Читает журналы | `tail -n` |
| `gc logs live` | Live-журнал | `tail -f` |
| `gc dashboard` | Выводит URL панели | `grep external-controller/secret` |
| `gc routing status` | Проверяет routing | `route`, `ip rule`, `iptables` |
| `gc routing manual` | Включает manual routing | Автоматизирует policy routing + iptables |
| `gc routing auto` | Включает native auto routing | Изменяет TUN-конфиг и перезапускает runtime |

## Главное

GoshaCrash не заменяет SSH и стандартные Linux-команды. Он автоматизирует связанные операции, которые вручную нужно выполнять в правильном порядке.

Для диагностики полезно знать:

```sh
ps
kill
nano
cp
tail
ifconfig
route
netstat
iptables
```

Для штатного включения/выключения VPN лучше использовать:

```sh
gc restart
gc stop
```

потому что кроме процесса Mihomo GoshaCrash управляет TUN, DNS, policy routing, iptables и watchdog.
