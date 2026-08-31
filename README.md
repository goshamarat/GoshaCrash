# GoshaCrash

GoshaCrash — установщик и контроллер Mihomo для ASUSWRT с Zashboard, TUN-маршрутизацией, watchdog, автозапуском и вспомогательными утилитами.

Этот RC в первую очередь проверяется на **ASUS RT-AC68U** со старым ASUSWRT / Linux 2.6.36. Для legacy-профиля используется **Mihomo ARMv5 + gVisor**.

> **Тестовая версия:** 3.10.2-rc18  
> Не публикуйте её как универсально стабильную для всех ASUS до проверки новых ARM64-моделей.

## Что уже проверено на RT-AC68U

На тестовом RT-AC68U подтверждены:

- EXT3 USB и корректные Unix symlink;
- ASUS Download Master / Optware;
- `ipkg`, `nano`, `openssh-sftp-server`;
- Mihomo legacy ARMv5 + gVisor;
- TUN `tun0`;
- режим маршрутизации `manual`;
- DNS Fake-IP;
- watchdog;
- восстановление Mihomo после принудительного `kill`;
- WAN loss → `offline` → остановка Mihomo;
- WAN recovery → автоматический запуск Mihomo/TUN/routing;
- `gc stop` / `gc start`;
- автозапуск после reboot;
- SFTP через штатный ASUS Dropbear: upload/download/rename/delete.

## Быстрый путь для RT-AC68U

Правильная последовательность установки:

```text
USB
 ↓
EXT3
 ↓
ASUS Download Master
 ↓
GoshaCrash
 ↓
выбор маршрутизации
 ↓
Mihomo + Zashboard + watchdog
```

Для старого Download Master **не используйте TFAT/FAT как базу Optware**. Optware требует Unix symlink. На TFAT установка пакетов может внешне завершаться успешно, но библиотеки вида `libipkg.so.0 -> libipkg.so.0.0.0` не создаются, после чего ломаются `ipkg`, `nano` и SFTP.

---

# 1. Подготовка USB

Обычный `sh install.sh` сначала проверяет файловую систему USB на legacy RT-AC68U — **ещё до проверки Download Master**.

Если флешка уже EXT3, установщик продолжает и только затем проверяет наличие Download Master:

```text
[GoshaCrash:OK] USB filesystem: EXT3 (/tmp/mnt/...)
```

Если обнаружена TFAT/FAT/NTFS или другая неподходящая ФС, установщик **останавливается до изменения системы**, показывает текущую файловую систему и объясняет, что для проверенной legacy-схемы требуется EXT3.

Он сразу предложит:

```sh
sh install.sh --prepare-usb
```

То есть пользователю не нужно заранее вручную смотреть `mount` или `fdisk`.

## Встроенный мастер форматирования

Запустите:

```sh
sh install.sh --prepare-usb
```

Мастер:

1. покажет найденные `/dev/sdX`;
2. покажет модель и размер;
3. ничего не форматирует без явного выбора;
4. потребует точную строку подтверждения вида:

```text
FORMAT /dev/sda
```

5. создаст DOS/MBR;
6. создаст один primary Linux-раздел;
7. отформатирует его в EXT3;
8. присвоит label `GOSHACRASH`;
9. тестово смонтирует раздел;
10. проверит создание symlink.

**Все данные на выбранном USB-диске будут удалены.**

После успешного завершения:

```text
USB подготовлен: /dev/sda1, EXT3, label=GOSHACRASH, symlink=OK
```

Выньте и снова вставьте флешку или перезагрузите роутер, чтобы штатный ASUSWRT автомонтировал её в `/tmp/mnt/...`.


### Как работает `--prepare-usb` на старом ASUSWRT

Мастер **не переписывает MBR без необходимости**.

- Если уже существует один обычный `/dev/sda1`, он останавливает USB-приложения, размонтирует раздел и форматирует именно его в EXT3.
- `fdisk` используется только если нормального одиночного раздела нет.
- Если старое ядро ASUSWRT после записи MBR не может перечитать таблицу (`BLKRRPART busy`), мастер **не форматирует устаревшее отображение раздела**. Он просит один reboot. После загрузки повторный запуск увидит готовый `/dev/sda1` и продолжит с EXT3.
- Перед `mkfs.ext3` мастер повторно убеждается, что раздел не смонтирован.



### Подготовка USB на старом ASUSWRT

Для RT-AC68U используется фактически проверенный сценарий. Исходная файловая система
и разметка Rufus не считаются конечной разметкой: `--prepare-usb` после явного
подтверждения полностью создаёт заново **DOS/MBR + один primary-раздел + EXT3**.

На Windows Rufus можно использовать просто как удобный способ очистить флешку:

- Метод загрузки: **Незагрузочный**
- Схема раздела: **MBR**
- Файловая система: **Large FAT32**

После подключения к ASUS:

```sh
sh /tmp/install.sh --prepare-usb
```

Мастер требует точное подтверждение `FORMAT /dev/sdX`, размонтирует USB, создаёт MBR
через штатный `fdisk`, создаёт один `/dev/sdX1`, затем выполняет:

```sh
mkfs.ext3 -L SANDISK /dev/sdX1
```

После успешного `mkfs` мастер **не делает тестовый mount/unmount и не предлагает
вынимать/вставлять флешку**. Для старого stock ASUSWRT проверенный финальный шаг — один
`reboot`, после которого ASUSWRT сам монтирует раздел как `/tmp/mnt/SANDISK`.

### Почему мастер пересоздаёт MBR

На тестовом RT-AC68U с ядром `2.6.36.4brcmarm` вариант «сохранить Rufus-раздел и только
сделать `mkfs.ext3`» оказался невоспроизводим после reboot. Проверенный вручную вариант:

```text
fdisk: o -> n -> p -> 1 -> default -> default -> w
mkfs.ext3 -L SANDISK /dev/sda1
reboot
```

после загрузки штатно дал:

```text
/dev/sda1 on /tmp/mnt/SANDISK type ext3 (...)
```

и Unix symlink прошёл успешно.

Если старое ядро после записи MBR не перечитало таблицу (`BLKRRPART busy`), installer
проверяет таблицу на диске и геометрию, **не запускает `mkfs` на stale mapping** и просит
reboot/повторный запуск.


### Resume после `BLKRRPART busy`

На старом ядре RT-AC68U после записи новой MBR `fdisk` может физически записать таблицу,
но kernel до reboot продолжает показывать старую геометрию `/dev/sdX1`.

rc8 обрабатывает это в два прохода:

```text
первый запуск --prepare-usb
  -> MBR записана
  -> kernel geometry stale
  -> mkfs НЕ запускается
  -> reboot

второй запуск --prepare-usb
  -> type 83 + один полноразмерный раздел
  -> fdisk blocks == /proc/partitions blocks
  -> fdisk ПРОПУСКАЕТСЯ
  -> mkfs.ext3 -L SANDISK /dev/sdX1
  -> reboot
  -> ASUSWRT automount
```

Повторный запуск больше не перезаписывает MBR и не зацикливается.


### Исправление rc9 для 32-bit BusyBox ash

В rc8 проверка «раздел занимает >=98% диска» считалась в блоках:

```sh
disk_blocks * 98 / 100
```

На старом 32-bit ASUSWRT значение для 120+ млн блоков переполняет целочисленную
арифметику shell. Из-за этого валидный post-reboot `/dev/sda1` не распознавался как
resume-ready и installer снова запускал `fdisk`.

rc9 сначала переводит размеры в MiB, и только затем считает 98%, поэтому промежуточные
значения безопасны для 32-bit shell. Также выводится диагностическая строка `Resume check`.


### Исправление rc10: разбор `fdisk -l`

На RT-AC68U строка `fdisk -l` имеет вид:

```text
/dev/sda1  1  14959  120158136  83  Linux
```

Здесь размер раздела в блоках — **поле 4**, а поле 5 — это partition Id `83`.
В rc8/rc9 installer ошибочно читал поле 5 как размер, поэтому диагностировал:

```text
fdisk_blocks=83
```

и всегда считал геометрию stale. rc10 читает blocks из поля 4 во всех
resume/stale-проверках.


### Исправление rc11: Optware без утечки `LD_LIBRARY_PATH`

На рабочем EXT3 `ipkg list_installed` запускается штатно без подмены библиотек.
В rc10 installer всё равно принудительно запускал `ipkg` через старые Optware-библиотеки.
`ipkg` наследовал этот `LD_LIBRARY_PATH` в дочерний `/bin/sh`/`wget`, из-за чего firmware
shell падал с:

```text
sh: can't resolve symbol '__aeabi_uidivmod'
```

rc11 сначала проверяет **clean runtime** (`LD_LIBRARY_PATH` unset). Если он работает,
все `ipkg update/install/remove` выполняются в clean environment. ABI overlay оставлен
только как fallback для старых повреждённых раскладок.

Также исправлено повторное определение filesystem: `/tmp/mnt/SANDISK` больше не
ошибочно определяется как `rootfs`; должен возвращаться `ext3`.


### RT-AC68U / ARMv5 routing

Для legacy-профиля **ARMv5 + gVisor используется только `manual` routing**.
`auto` для этого профиля не предлагается и не считается поддерживаемым режимом.
На более новых архитектурах выбор routing определяется отдельным профилем платформы.


### Исправления rc12

- installer сам очищает унаследованный `LD_LIBRARY_PATH` в самом начале, поэтому перед
  запуском больше не требуется вручную выполнять `unset LD_LIBRARY_PATH`;
- Optware-библиотеки по-прежнему применяются только локально к конкретной команде,
  если clean runtime действительно недоступен;
- повторная проверка filesystem выбирает самый длинный подходящий mountpoint.
  Для `/tmp/mnt/SANDISK/...` это `/tmp/mnt/SANDISK` (`ext3`), а не `/tmp` (`tmpfs`)
  и не `/` (`rootfs`);
- legacy ARMv5 остаётся строго `manual` routing + `gvisor`.


### rc13: подготовка modern/ZenWiFi BT10

- ARMv5 legacy остаётся строго `manual + gVisor`.
- Modern-профиль больше не зависит от старого Optware для самой установки:
  обязательны только `unzip`, `gzip`, `wget/curl`; `nano`, SFTP и ipkg/opkg являются optional.
- Для stock ASUSWRT теперь реально устанавливаются NVRAM `script_usbmount/script_usbumount`
  hooks; в предыдущем коде функция существовала, но не вызывалась.
- Старый Download Master `lib/ipkg` USB bridge создаётся только для legacy или когда
  соответствующая ipkg-база реально существует.
- `tun.auto-detect-interface` включается только если доступен `nft`, поскольку эта
  функция Mihomo требует nftables; без `nft` остаются `auto-route + auto-redirect`.
- `wget` получает отдельный writable HOME в `/tmp`, чтобы не засорять лог ошибкой
  `/root/.wget-hsts`.
- Для модели BT10 installer печатает обнаруженные `uname -m` и выбранный Mihomo target.


### rc14: исправления по реальному ZenWiFi BT10

На живом BT10 подтверждено: `armv7l`, kernel `4.19.294`, classic
`iptables 1.4.12.2`, `nft` отсутствует.

Исправлено:

- BusyBox `fdisk` на BT10 печатает размер вроде `7566583+`; `+` теперь удаляется
  перед сравнением с `/proc/partitions`, поэтому resume после reboot не зацикливается.
- `armv7l` для BT10 считается штатной архитектурой и выбирает Mihomo `armv7`.
- Диагностический вывод `wget_fetch`/`curl_fetch` отправляется в stderr и больше не
  попадает внутрь URL через command substitution.
- Firmware `curl`/`wget` имеют приоритет над древними Optware-вариантами.
- PATH больше не позволяет `/opt/bin/sh`/`test` затенять системные команды ASUSWRT.
- Проверка `sh -n` выполняется только через `/bin/sh` и только если firmware shell
  действительно поддерживает этот флаг.
- `.wget-hsts` создаётся как private `0600`, чтобы убрать HSTS warning.
- Для automatic routing `auto-detect-interface` снова включён независимо от наличия
  `nft`: Mihomo `auto-redirect` на Linux умеет работать через iptables или nftables.
- Modern install заранее проверяет `/dev/net/tun` и наличие `iptables`/`nft`.

## Ручной способ

Если мастер не подходит:

```sh
fdisk /dev/sda
```

В старом `fdisk` последовательно:

```text
o
n
p
1
<Enter>
<Enter>
w
```

Проверьте появление раздела:

```sh
cat /proc/partitions
fdisk -l /dev/sda
```

Затем:

```sh
mkfs.ext3 -L GOSHACRASH /dev/sda1
```

После переподключения:

```sh
mount | grep /dev/sd
```

Ожидается примерно:

```text
/dev/sda1 on /tmp/mnt/GOSHACRASH type ext3 (...)
```

---

# 2. Установите ASUS Download Master

Для legacy RT-AC68U сначала установите **Download Master** через веб-интерфейс ASUS:

**USB-приложения → Download Master → Install**

Выберите подготовленную EXT3-флешку.

Проверка по SSH:

```sh
ls -ld /opt /tmp/opt
readlink /tmp/opt
ls -l /tmp/opt/bin/ipkg
/tmp/opt/bin/ipkg list_installed | head
```

Для исправной EXT3-установки должны существовать symlink библиотеки:

```sh
ls -l /tmp/opt/lib/libipkg.so*
```

Пример:

```text
libipkg.so   -> libipkg.so.0.0.0
libipkg.so.0 -> libipkg.so.0.0.0
libipkg.so.0.0.0
```

---

# 3. Установка GoshaCrash

Запуск:

```sh
sh install.sh
```

Установщик:

- определяет модель, архитектуру и ядро;
- на legacy ASUS выбирает ARMv5/gVisor core;
- находит Download Master;
- подготавливает Optware environment;
- ставит необходимые пакеты;
- устанавливает `goshacrash.sh`;
- устанавливает `gcnet` для legacy/manual;
- устанавливает Mihomo;
- устанавливает Zashboard;
- создаёт конфигурацию;
- настраивает автозапуск;
- запускает runtime и выполняет первичную проверку.

## Маршрутизация

Выбор маршрутизации остаётся за пользователем.

```text
auto
manual
```

`manual` использует собственную policy routing / iptables-логику GoshaCrash.

`auto` использует возможности Mihomo, когда они допустимы для выбранной платформы и конфигурации.

Legacy-профиль и routing mode — **разные вещи**. На RT-AC68U core остаётся ARMv5 + gVisor независимо от пользовательского выбора маршрутизации.

---

# 4. После установки

Главная команда:

```sh
gc
```

Статус:

```sh
gc status
```

Полная диагностика:

```sh
gc doctor
```

Ожидаемый healthy-state:

```text
Mihomo: работает
Интернет: online
Watchdog: работает
Профиль: legacy
Ядро: закреплено для legacy ARMv5
TUN: tun0 работает
Runtime: OK
```

Редактирование конфигурации:

```sh
gc edit
```

Проверка nano:

```sh
nano --version
```

---

# 5. Zashboard

URL выводится после установки и в:

```sh
gc status
```

Также:

```sh
gc dashboard
```

---

# 6. Watchdog и WAN recovery

Watchdog постоянно проверяет состояние WAN/runtime.

Проверка:

```sh
gc status
```

или:

```sh
WPID="$(cat /tmp/mnt/*/goshacrash/run/watchdog.pid 2>/dev/null)"
echo "$WPID"
```

На старом BusyBox `ps | grep watchdog-loop` может не совпасть с отображаемой командой. Надёжнее проверять конкретный PID:

```sh
kill -0 "$WPID" 2>/dev/null && echo WATCHDOG_ALIVE
```

Проверенный сценарий:

```text
WAN online
   ↓
кабель WAN отключён
   ↓
external probe FAIL
   ↓
internet.state=offline
   ↓
Mihomo остановлен
   ↓
watchdog остаётся жив
   ↓
WAN возвращается
   ↓
internet.state=online
   ↓
Mihomo + DNS + TUN + routing восстановлены
```

Счётчики:

```sh
cat /tmp/mnt/*/goshacrash/state/internet.state
cat /tmp/mnt/*/goshacrash/state/wan-fail-count
cat /tmp/mnt/*/goshacrash/state/wan-ok-count
```

---

# 7. SFTP

GoshaCrash не заменяет штатный ASUS Dropbear.

На legacy Optware устанавливается:

```text
openssh-sftp-server
```

Проверка:

```sh
gc sftp status
```

С ПК:

```sh
sftp admin@10.10.10.100
```

Проверенный тест:

```text
cd /tmp/mnt/GOSHACRASH
put test.txt
get test.txt
rename test.txt test2.txt
rm test2.txt
```

---

# 8. Stop / Start / Restart

Остановить Mihomo и вернуть обычный DIRECT:

```sh
gc stop
```

Запустить:

```sh
gc start
```

Перезапустить:

```sh
gc restart
```

---

# 9. Autostart

Проверка:

```sh
gc autostart status
```

На stock ASUSWRT используются JFFS hooks и USB mount bridge. После reboot USB должен сначала смонтироваться, после чего GoshaCrash восстанавливает runtime.

---

# 10. Диагностика

Минимальный набор:

```sh
gc status
gc doctor
gc autostart status
gc sftp status
```

Сеть:

```sh
ifconfig tun0
route -n
iptables -t nat -L -n
iptables -t mangle -L -n
```

WAN:

```sh
nvram get wan0_state_t
nvram get wan0_sbstate_t
nvram get wan0_auxstate_t
/bin/ping -c 3 1.1.1.1
```

DNS:

```sh
nslookup ya.ru 127.0.0.1
```

Логи находятся в:

```text
<USB>/goshacrash/logs/
```

---

# 11. Файловая система USB

Для legacy Download Master / Optware рекомендуются:

- EXT3 — основной проверенный вариант для RT-AC68U;
- EXT2/EXT4 могут поддерживаться прошивкой, но этот RC валидировался именно на EXT3.

Не рекомендуется использовать TFAT/FAT для Optware.

Причина — отсутствие Unix symlink.

---

# 12. Источники компонентов

Текущий RC всё ещё использует:

```sh
REPO=goshamarat/GoshaCrash
BRANCH=main
```

для внутренних загрузок/release assets. Перед публичным стабильным релизом необходимо разделить:

- источник runtime-файлов;
- immutable release ref/tag;
- источник legacy Mihomo release asset.

Это нужно, чтобы старый release installer никогда не подтягивал будущий `main`.

---

# 13. Статус платформ

## Проверено

**ASUS RT-AC68U**

- Linux 2.6.36.4brcmarm
- `armv7l`
- legacy ARMv5 + gVisor core
- EXT3
- Download Master / Optware
- manual routing

## Планируется

Современные ASUS ARM64, включая ZenWiFi BT10, требуют отдельного полного acceptance-test. Не считайте legacy-тест подтверждением ARM64.

---

# Release checklist

Перед stable release:

```text
[ ] чистая EXT3
[ ] Download Master
[ ] install
[ ] gc doctor
[ ] reboot
[ ] gc stop/start
[ ] kill Mihomo → watchdog recovery
[ ] WAN unplug → offline
[ ] WAN plug → recovery
[ ] nano
[ ] SFTP upload/download/rename/delete
[ ] manual routing
[ ] auto routing
[ ] runtime pinned to release tag, не main
```


### rc15: BT10 PATH/preflight fix

На реальном BT10 `/usr/sbin/iptables` существовал, но rc14 запускал modern
preflight до `prepare_path`, поэтому `command -v iptables` ложно сообщал, что
iptables отсутствует.

rc15:
- запускает `prepare_path` до modern preflight;
- ищет `modprobe`, `iptables` и `nft` также по абсолютным системным путям;
- runtime `ensure_tun` тоже не зависит от PATH и грузит `/sbin/modprobe tun`.


### rc16: BT10 bugfix pass

Исправления по реальному BT10:

- `gc` wrapper теперь проверяется после установки и контроллер запускается через `/bin/sh`;
- инструкции используют `/bin/sh`, потому что bare `sh` на BT10 может резолвиться не в системный shell;
- modern runtime PATH ставит firmware `/usr/sbin:/usr/bin:/sbin:/bin` раньше древнего DM/Optware;
- `gc edit` автоматически переводит `xterm-256color` в совместимый `xterm` для старого nano;
- modern-профиль через Download Master поддерживает payload `nano`, `unzip`, `openssh-sftp-server`;
- индекс DM обновляется один раз перед проверкой пользовательских пакетов;
- SFTP installer повторно проверяет пакет после refresh индекса;
- `gc sftp status` ищет бинарник также по физическому `DM_ROOT` и `/tmp/opt`, а не только `/opt`.


### rc17: естественный Download Master / Optware

На modern ASUSWRT обычные пакеты больше не оборачиваются compatibility-слоем.

- Download Master / `ipkg` обязателен и является основным источником пользовательских пакетов.
- Installer выполняет обычные `ipkg update` и `ipkg install`.
- Через DM ставятся `nano`, `unzip`, `openssh-sftp-server`.
- Для modern убраны ABI overlay, SONAME repair, SFTP wrapper и подмена `TERM`.
- `gc edit` запускает настоящий `nano` из Download Master как есть.
- Системные компоненты ASUSWRT (`/bin/sh`, `iptables`, `modprobe`, firmware wget/curl) не заменяются пакетами.
- Legacy RT-AC68U в этом RC не меняется, чтобы не ломать уже проверенную установку.


### rc18: один Download Master / Optware путь для всех ASUS

В этой версии modern-профиль больше не имеет отдельной логики установки
`nano`, `unzip`, SFTP и обычных Optware-пакетов.

Для RT-AC68U и BT10 используется один и тот же проверенный путь Download Master:
`/opt` -> `ipkg` -> пакеты -> CLI/hooks.

Разница modern-профиля теперь только там, где она реально нужна:
- архитектура Mihomo (`armv7` на BT10);
- `tun.stack: system`;
- automatic routing (`auto-route + auto-redirect`) либо manual;
- modern TUN/firewall capability checks.

Никаких специальных xterm/TERM-подмен для BT10 в package path нет.
