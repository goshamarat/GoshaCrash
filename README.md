# GoshaCrash

## 3.10.2-rc31 — миграция старого config.yaml и обязательный TUN

- Исправлена переустановка поверх старого пользовательского `config.yaml`: installer теперь гарантированно выставляет управляемые GoshaCrash поля `tun.enable: true`, `tun.device: tun0`, актуальный `tun.stack`, `dns.enable: true`, `dns.listen: 127.0.0.1:1053` и параметры выбранного routing.
- Исправлен `yaml_set_section_key`: если в старом конфиге вообще нет секции `tun:` или `dns:`, секция теперь создаётся вместо молчаливого пропуска.
- Пользовательские `proxies`, `proxy-groups`, `rules`, `nameserver` и прочие настройки installer не переписывает.
- `external-ui: ui` нормализуется, а `external-ui-url` добавляется только если отсутствует/пустой.
- Это закрывает ошибку первого запуска после upgrade: `[GoshaCrash:ERROR] tun.enable должен быть true`.


## 3.10.2-rc31 — диагностика TUN и упрощение меню

- Из TUI убрана строка `ROUTING: AUTO/MANUAL`: режим маршрутизации остаётся доступен в `gc status`, `gc routing status` и `gc doctor`, но больше не занимает место в шапке меню.
- `gc doctor` теперь различает kernel TUN (`/dev/net/tun`) и интерфейс Mihomo (`tun0`). Старое `TUN: FAIL` было неоднозначным: при остановленном Mihomo `tun0` закономерно отсутствует даже если модуль TUN полностью исправен.
- `gc doctor` показывает routing как `N/A (TUN down)`, если `tun0` отсутствует, чтобы не выдавать каскадный `FAIL` как отдельную первопричину.
- ASUS NVRAM WAN-status помечен как informational: на BT10 он может быть `DOWN` при реально работающем внешнем доступе через `br0`. Авторитетной проверкой остаётся `Internet probe`.
- Добавлена строка `manual stop`, чтобы сразу видеть, не отключён ли autostart самим `gc stop`.
- Внутренняя проверка kernel TUN вынесена в отдельную функцию и используется как runtime, так и doctor.
- После удаления строки ROUTING пересчитаны все координаты частичной перерисовки меню, чтобы снова не сломать вертикальные рамки и anti-flicker.
- Installer больше не стирает `boot.log`, `watchdog.log`, `coldboot.log` и `goshacrash.log` при обновлении: cold-boot диагностика должна переживать upgrade.

## 3.10.2-rc31 — полный повторный аудит rc28

- Исправлен реальный CLI-баг rc28: функция `start()` существовала, но команда `gc start` не была добавлена в dispatcher. Теперь `gc start` работает как публичная команда, а help ей соответствует.
- Zashboard больше не оставляет постоянный `ui.previous` или `ui.new`. Замена UI использует только скрытые временные каталоги на время атомарной подмены и удаляет их после успеха; при следующей установке также восстанавливается прерванная подмена.
- Исправлена противоречивая документация rc28 про backup config: постоянных backup-файлов нет; rollback во время `gc edit` использует только временную копию в `/tmp`.
- Нормализован случайно разорванный `printf` в проверке старого Mihomo.
- Метаданные modern-core приведены в соответствие с реальностью: `official-pinned`, потому что Mihomo закреплён на v1.19.30.
- `gc start` перед запуском делает проверку config; невалидный config не снимает `manual-stop` и не запускает runtime.
- При interrupted update Zashboard rc31 умеет восстановить предыдущий валидный UI из временного swap-каталога; после нормального завершения временных UI-каталогов не остаётся.
- `state/mihomo-version.txt` обновляется только после фактической активации и повторного запуска нового Mihomo.
- `gc version`, `gc help` и `gc base` теперь read-only: они не создают `bin/ui/logs/run/state` и не трогают runtime/logs.
- Повторно проверены shell-совместимость, UTF-8, отсутствие `find -type/-path` и `command -v` в runtime, структура ZIP и фиксированная ширина TUI.

## rc28: меню, безопасное редактирование config.yaml и чистая структура

- Верхняя строка меню теперь показывает `MIHOMO: ONLINE/OFFLINE` и `TUN: UP/DOWN`; двоеточия добавлены, `PROFILE MODERN` убран как неинформативный.
- Все 16 строк рамки меню имеют одинаковую видимую ширину 45 колонок; правые вертикальные границы больше не съезжают.
- Стрелки по-прежнему перерисовывают только старый и новый пункт без полного `clear`.
- `Edit config` больше **не перезапускает Mihomo**. После выхода из nano выполняется штатная проверка `mihomo -t -d <base> -f config.yaml`, затем меню возвращается автоматически. Применение — отдельным пунктом `Restart`.
- Если проверка не прошла, предыдущий `config.yaml` восстанавливается из временной копии в `/tmp`. Неудачная правка и постоянный backup не сохраняются.
- Базовый `config.yaml` создаётся как UTF-8 без BOM, комментарии переведены на русский; nano запускается со scoped UTF-8 locale и scoped Optware library path.
- Убран отдельный `/jffs/addons/goshacrash`: persistent state/логи остаются внутри каталога GoshaCrash. Снаружи остаются только стандартные ASUS hooks/wrappers в `/jffs/scripts` и PATH-строки в стандартных profile-файлах.
- Modern Mihomo остаётся закреплён на `v1.19.30` с ELF-проверкой архитектуры из rc26.


## rc25 lineage: consolidated cold-boot + installer build

rc31 собирает в одну версию исправления BT10, меню и структуры каталогов, а также закрывает несколько проблем обновления:

- lock-каталоги на USB теперь привязаны к **текущей загрузке Linux** через `/proc/sys/kernel/random/boot_id`; PID после полного power-cycle больше не может случайно сделать старый lock «живым»;
- watchdog запускается в самом начале boot worker и после завершения boot-пути берёт recovery на себя; пока boot worker активен, watchdog не гоняет параллельный start;
- USB hook и Download Master bridge при каждой установке перезаписываются актуальной версией;
- `gc autostart status` показывает реальную версию hook и MATCH/MISMATCH с controller;
- online installer проверяет версию `goshacrash.sh` **на каждом зеркале** и не принимает устаревший файл из CDN/cache;
- локальный release ZIP использует лежащие рядом `goshacrash.sh` и `assets/gcnet-armv5`, а не скачивает их повторно;
- `rulesets/` и `proxies/` не создаются; старые пустые каталоги удаляются безопасным `rmdir`;
- menu redraw без полного `clear` при стрелках сохранён.

### Рекомендуемый online install

На BT10 не нужно сначала сохранять `/tmp/install.sh` и потом делать `chmod`. Можно сразу передать полностью скачанный installer в `/bin/sh` через stdout — тогда исчезновение файла из `/tmp` между командами вообще исключено:

```sh
mkdir -p /tmp/goshacrash-wget
chmod 700 /tmp/goshacrash-wget
HOME=/tmp/goshacrash-wget /usr/sbin/wget --no-check-certificate -O - \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh' | /bin/sh
```

Перед online install в `main` должны быть одновременно загружены **оба** файла rc31: `install.sh` и `goshacrash.sh`. Если одно зеркало ещё отдаёт старый controller, installer попробует следующее; несовпадающая версия не устанавливается.

GoshaCrash — установщик и контроллер Mihomo для ASUSWRT с Zashboard, TUN-маршрутизацией, watchdog, автозапуском и вспомогательными утилитами.

Этот RC в первую очередь проверяется на **ASUS RT-AC68U** со старым ASUSWRT / Linux 2.6.36. Для legacy-профиля используется **Mihomo ARMv5 + gVisor**.

> **Тестовая версия:** 3.10.2-rc31  
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

Из распакованного release ZIP:

```sh
/bin/sh install.sh
```

Из GitHub рекомендуется потоковый запуск без промежуточного `/tmp/install.sh`:

```sh
mkdir -p /tmp/goshacrash-wget
chmod 700 /tmp/goshacrash-wget
HOME=/tmp/goshacrash-wget /usr/sbin/wget --no-check-certificate -O - \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh' | /bin/sh
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


### rc19: writable /opt namespace + BT10 boot hardening

Исправления основаны на полном дампе реального ZenWiFi BT10.

- На BT10 корень `/opt` находится в read-only squashfs и содержит только
  заранее созданные ASUS-ссылки (`bin`, `lib`, `share`, `etc`, ...). Поэтому
  `ipkg` не мог создать новые top-level каталоги вроде `/opt/libexec` и
  `/opt/man`, хотя затем ошибочно отмечал пакет как установленный.
- Если `/opt` уже целиком ведёт на Download Master (legacy RT-AC68U), ничего
  не меняется. Если `/opt` является read-only ASUS skeleton, GoshaCrash
  сохраняет штатный `/opt/scripts` и bind-mount'ит корень Download Master на
  `/opt`. После этого `ipkg` получает обычный writable `/opt` на USB и может
  создавать любые каталоги пакета естественным способом.
- При USB unmount созданный bind `/opt` снимается до отключения накопителя.
- `openssh-sftp-server` теперь переустанавливается уже после подготовки
  writable `/opt`, поэтому `/opt/libexec/sftp-server` должен реально попасть
  на USB, а не только в базу ipkg.
- Если terminfo отсутствует, установщик берёт `ncurses-base` именно из
  Optware-NG feed и делает штатный `ipkg -force-downgrade -force-reinstall`,
  затем проверяет реальную terminfo database через `infocmp xterm`.
- Для stock BT10 PATH теперь также записывается в `/jffs/etc/profile`, который
  реально подключается его `/etc/profile`. `/jffs/configs/profile.add`
  сохранён для совместимости с другими ASUSWRT/Merlin layout.
- Убрана зависимость от `command -v`: на исследованном BT10 эта команда
  отсутствует. Используются конкретные системные пути.
- Boot modern-профиля ждёт стабильный `ip route get` до старта Mihomo и
  заранее подготавливает TUN. Watchdog пишет причины recovery failure в
  `logs/watchdog.log`, а boot hook — в `logs/boot.log`.
- Runtime failure больше не считается автоматически ошибкой нового
  `config.yaml`: синтаксически корректный конфиг не откатывается только из-за
  временной проблемы TUN/uplink/маршрутизации.

На BT10 после установки особенно проверить:

```sh
which gc
gc status
mount | grep ' on /opt '
ls -ld /opt /opt/libexec /opt/man
find /opt/share/terminfo -name xterm -print
find /opt/share/terminfo -name xterm-256color -print
nano
gc sftp status
```

### rc20: terminfo без downgrade ASUS ncurses

Реальный BT10 показал ещё одну особенность смешанного Download Master feed:
`ncurses-base 5.7-8` остаётся зарегистрированным ASUS-пакетом, его утилиты
могут физически существовать, но не запускаться на современной прошивке
(`infocmp: not found` при существующем файле — признак несовместимого ELF
loader/runtime). Поэтому rc20 больше не пытается заменять этот пакет целиком.

- `ncurses-base` из Optware-NG скачивается по тому же индексу `ipkg`;
- `ipkg -o <offline-root>` распаковывает пакет в отдельный staging root;
- из staging в USB `/opt/share/terminfo` копируются только compiled terminal
  descriptions — архитектурно-независимые данные;
- пакетная база Download Master и ASUS `ncurses-base 5.7-8` не изменяются;
- готовность nano проверяется по физическому наличию `xterm` и
  `xterm-256color`, а не запуском несовместимого `infocmp`.


### rc21: ручная верификация BT10 package path

rc21 переносит в installer ровно ту последовательность, которая была проверена вручную на реальном ZenWiFi BT10.

- После bind-mount Download Master на `/opt` заранее создаются `/opt/libexec`, `/opt/man/man1` и `/opt/var`. Ручной тест подтвердил, что после этого обычный `ipkg install openssh-sftp-server` физически создаёт `/opt/libexec/sftp-server`.
- `ncurses-base 5.7-8` от ASUS не удаляется и не downgrade-ится. Из Optware-NG пакет `ncurses-base 5.7-7` распаковывается в приватный staging root командой `ipkg -o <root> -force-depends install <ipk>`.
- Из staging копируется только `opt/share/terminfo`. На реальном BT10 в нём подтверждены `x/xterm`, `x/xterm-256color` и `v/vt100`; после копирования обычный `nano` с `TERM=xterm-256color` запускается нормально.
- В terminfo-проверках больше нет `find -type`/`find -path`: BusyBox 1.24.1 на BT10 этих predicates не поддерживает. Проверяются конкретные compiled entries.
- Runtime после reboot создаёт тот же полный Optware layout, а `gc doctor` проверяет terminfo по файлам и не запускает несовместимый `infocmp`.


### rc22: меню без мерцания

Интерактивное меню больше не выполняет `ESC[2J` на каждое нажатие стрелки. При навигации перерисовываются только две строки: предыдущий и новый выбранный пункт. Полная перерисовка остаётся при первом входе в меню и после выполнения действия. Курсор скрывается на время навигации и обязательно восстанавливается перед запуском редактора/команды и при выходе.

### rc23: cold-boot автозапуск и watchdog

rc23 закрывает класс ошибок, которые проявляются именно после полного обесточивания роутера, когда файлы в `goshacrash/run` переживают старые процессы.

- `watchdog.pid`, `mihomo.pid` и `boot.pid` больше не считаются валидными только по `kill -0`: PID сверяется с `/proc/<pid>/cmdline`. Повторное использование номера PID другим процессом после power-cycle не даёт ложный статус `Watchdog: работает`.
- `boot` сериализован через `run/boot.lock`; owner PID проверяется, stale lock после жёсткого выключения удаляется, а параллельные USB hooks не запускают два boot worker одновременно.
- `start.lock` и `control.lock` теперь содержат PID владельца. Watchdog автоматически выбрасывает stale lock вместо вечного пропуска recovery.
- Watchdog пишет `launch requested`, `loop entered`, `started` и сразу выполняет первый health/recovery check, не ожидая первый 10-секундный интервал.
- Для запуска фоновых процессов сначала используются firmware `nohup` (`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`), и только затем Optware.
- Cold-boot trace хранится внутри установки: `goshacrash/logs/coldboot.log`. Download Master bridge сначала пишет раннюю отметку в `/tmp`, а USB hook переносит её в постоянный лог на USB.
- `logs/boot.log` теперь показывает этапы `/opt`, default route, `/dev/net/tun`, стабильного физического uplink и результат запуска runtime.
- Installer каждый раз перезаписывает актуальные hooks и проверяет, что версия скачанного `goshacrash.sh` точно совпадает с `install.sh`; смешанная установка разных версий останавливается с ошибкой.
- Исправление меню без мерцания из rc22 сохранено.


## rc28: без постоянных backup-файлов

GoshaCrash больше не создаёт `backups/`. Для безопасного отката во время проверки config/routing используется только временная копия в `/tmp`, которая удаляется сразу после операции. Пустой старый `backups/` от предыдущих RC удаляется при установке; непустой каталог автоматически не удаляется.
