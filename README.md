# GoshaCrash

Установщик Mihomo и Zashboard для роутеров ASUSWRT.

Проект рассчитан на установку **на реальный ASUSWRT-роутер**, а не в WSL и не в обычный Linux. Для системных утилит используется окружение, созданное штатным приложением ASUS Download Master: `ipkg` или `opkg`, `/opt`, `nano`, `wget`, `unzip` и `gzip`.

Установка выполняется одним файлом `install.sh`. После установки управление выполняется одной командой:

```sh
goshacrash help
```

Интерактивного меню нет.

---

## Конфиги в публичном репозитории

Файлы `config.yaml` и `config-legacy.yaml` в репозитории являются безопасными заглушками. В них нет подписок, UUID, адресов личных прокси и настоящих секретов. Они нужны только для того, чтобы проверить запуск Mihomo, TUN, DNS и Zashboard. В заглушках действует правило `MATCH,DIRECT`, поэтому VPN после чистой установки ещё не включён.

При первой установке `install.sh` выбирает нужную заглушку по профилю роутера и автоматически заменяет `CHANGE_ME` на уникальный локальный secret. При повторной установке уже существующий рабочий конфиг не перезаписывается.

Настоящий конфиг передаётся отдельно через SCP/WinSCP, после чего применяется командой:

```sh
goshacrash apply
```

Не коммить личный конфиг обратно в публичный GitHub.

## Исправление 3.4.3

В этой версии исправлена загрузка на медленном соединении. У `curl` полностью убраны `--connect-timeout` и `--max-time`, прогресс больше не скрывается, а установщик не запускает несколько повторяющихся циклов загрузки. Одновременно может работать только один `install.sh`. Если пакеты `nano`, `unzip`, `wget` и `gzip` уже стоят, долгий `ipkg/opkg update` пропускается. На legacy повторная установка не скачивает совместимое ядро Mihomo заново. Проверка `nvram` остаётся необязательной.

## Возможности

- установка одной командой через `install.sh`;
- автоматическое определение USB-накопителя и Download Master;
- использование штатного `ipkg`/`opkg`, уже установленного средствами ASUS;
- автоматический выбор Mihomo под архитектуру роутера;
- отдельный legacy-профиль для ASUSWRT с ядром Linux 2.6;
- установка Zashboard из GitHub Releases;
- TUN-интерфейс `tun0`;
- DNS через Mihomo;
- автоматический запуск после перезагрузки роутера;
- восстановление маршрутизации после перезапуска firewall;
- watchdog для Mihomo;
- редактирование `config.yaml` через `nano`;
- проверка конфига перед применением;
- резервное копирование конфига;
- журналы установки, Mihomo, автозапуска, watchdog и пакетов;
- запуск команд из любого каталога;
- обновление Zashboard штатной кнопкой внутри панели.

---

## Структура репозитория

В корне репозитория находятся только необходимые файлы:

```text
GoshaCrash/
├── install.sh
├── goshacrash.sh
├── config.yaml
├── config-legacy.yaml
├── README.md
└── assets/
    └── gcnet-armv5
```

Назначение файлов:

| Файл | Назначение |
|---|---|
| `install.sh` | Первоначальная установка и явная повторная установка проекта |
| `goshacrash.sh` | Управление Mihomo, маршрутизацией, конфигом, логами и пакетами |
| `config.yaml` | Основной конфиг для современных роутеров |
| `config-legacy.yaml` | Конфиг для старых ASUSWRT-роутеров с legacy-профилем |
| `assets/gcnet-armv5` | Сетевой helper для ручной маршрутизации на старом ASUSWRT |

После установки рабочий конфиг на роутере всегда называется:

```text
config.yaml
```

На modern-профиле он создаётся из репозиторного `config.yaml`, а на legacy-профиле — из `config-legacy.yaml`.

---

## Важное предупреждение о конфиге

Конфиги могут содержать:

- ссылки подписок;
- адреса прокси-серверов;
- UUID;
- пароли;
- секрет Zashboard/Mihomo API;
- другие приватные данные.

В этой сборке репозиторные конфиги уже очищены и являются заглушками. Настоящий личный конфиг передавай на роутер отдельно и не публикуй.

---

## Поддерживаемые режимы

### Legacy ASUSWRT

Legacy-профиль выбирается для старых ARM-роутеров с ядром Linux 2.6 и известных моделей семейства RT-AC68U.

Для него используются:

```text
Mihomo: проверенная ARMv5-сборка with_gvisor
TUN stack: gvisor
TUN interface: tun0
Routing: ручная маршрутизация
Routing table: 2022
Traffic mark: 0x2333
Mihomo outbound mark: 0x2334 / routing-mark 9012
Mihomo DNS: 127.0.0.1:1053
Network helper: gcnet
```

В `config-legacy.yaml` должны оставаться:

```yaml
tun:
  enable: true
  stack: gvisor
  device: tun0
  auto-route: false
  auto-redirect: false
```

Для legacy-профиля автоматическое обновление Mihomo не предлагается. В Zashboard скрывается обновление ядра, а обновлять можно только саму панель.

### Modern ASUSWRT

Для современных платформ установщик выбирает официальный Linux-бинарник Mihomo по архитектуре, например:

- `arm64`;
- `armv7`;
- `armv6`;
- `armv5`;
- `amd64-compatible`;
- `386`;
- `mips`/`mipsle`;
- `mips64`/`mips64le`;
- `riscv64`;
- `ppc64le`;
- `s390x`.

В modern-конфиге используется:

```yaml
tun:
  enable: true
  stack: system
  device: tun0
  auto-route: true
  auto-redirect: true
```

---

## Как теперь работает скачивание

- прогресс `wget` или `curl` виден прямо в SSH;
- у `curl` нет принудительного тайм-аута соединения и общего лимита времени;
- сначала используется системный `wget`, затем `curl` как резервный вариант;
- один адрес пробуется один раз каждым доступным загрузчиком, без тройного вложенного цикла;
- одновременно разрешён только один процесс установки;
- уже установленные пакеты не вызывают повторный `ipkg/opkg update`;
- на legacy уже установленная совместимая Mihomo `with_gvisor` не скачивается повторно.

Чтобы принудительно переустановить legacy-ядро, можно явно запустить:

```sh
FORCE_CORE_REINSTALL=1 INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

# Чистая установка

## 1. Требования

Перед установкой нужны:

1. Роутер ASUS с работающим ASUSWRT.
2. Включённый SSH-доступ.
3. Включённые JFFS-скрипты.
4. Подключённый USB-накопитель.
5. Установленный на этот USB-накопитель **Download Master**.
6. Доступ роутера к GitHub или одному из предусмотренных зеркал.

Для ASUS RT-AC68U в примерах используются:

```text
Адрес роутера: 10.10.10.100
Пользователь SSH: admin
USB: /tmp/mnt/SANDISK
```

У тебя имя USB может быть другим.

---

## 2. Установка Download Master

После форматирования флешки сначала установи Download Master через веб-интерфейс ASUS:

```text
USB-приложение → Download Master → Установить
```

Выбери нужную флешку и дождись завершения установки. После этого на USB должна появиться папка вида:

```text
/tmp/mnt/SANDISK/asusware.arm
```

На других моделях она может называться:

```text
asusware.arm64
asusware
```

Download Master создаёт окружение `/opt` и устанавливает пакетный менеджер `ipkg` или `opkg`.

---

## 3. Подключение по SSH

Из Windows PowerShell:

```powershell
ssh admin@10.10.10.100
```

Проверь подключённые накопители:

```sh
ls -la /tmp/mnt
```

Проверь папку Download Master:

```sh
find /tmp/mnt -maxdepth 2 -type d \( -name asusware.arm -o -name asusware.arm64 -o -name asusware \) 2>/dev/null
```

Пример нормального результата:

```text
/tmp/mnt/SANDISK/asusware.arm
```

Проверь пакетный менеджер:

```sh
find /tmp/mnt -path '*/asusware*/bin/ipkg' -o -path '*/asusware*/bin/opkg' 2>/dev/null
```

---

## 4. Загрузка `install.sh`

Скачай установщик во временный каталог роутера:

```sh
/usr/sbin/wget --no-check-certificate -O /tmp/install.sh 'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'
```

Проверь, что скачался shell-скрипт, а не HTML-страница ошибки:

```sh
head -n 5 /tmp/install.sh
```

Первая строка должна быть:

```sh
#!/bin/sh
```

Проверь версию:

```sh
grep 'INSTALLER_VERSION=' /tmp/install.sh
```

Для этой сборки ожидается:

```text
INSTALLER_VERSION="3.4.4-config-dashboard-fix"
```

---

## 5. Запуск установки

Когда USB называется `SANDISK`:

```sh
INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

Подставь собственное имя накопителя при необходимости:

```sh
INSTALL_ROOT=/tmp/mnt/ИМЯ_ФЛЕШКИ sh /tmp/install.sh
```

Если к роутеру подключена ровно одна флешка с Download Master, установщик может определить её сам:

```sh
sh /tmp/install.sh
```

Явное указание `INSTALL_ROOT` надёжнее.

`install.sh` запускается без обычных аргументов. Эта команда неправильная:

```sh
sh /tmp/install.sh install
```

---

## Что делает установщик

Во время установки скрипт:

1. Проверяет, что запущен на реальном ASUSWRT.
2. Проверяет наличие `/jffs` и `/tmp/mnt`.
3. Находит нужный USB-накопитель.
4. Находит окружение Download Master.
5. Находит его `ipkg` или `opkg`.
6. Обновляет индекс пакетов.
7. Доустанавливает `nano`, `wget`, `unzip` и `gzip`.
8. Определяет модель, архитектуру и версию ядра.
9. Выбирает legacy- или modern-профиль.
10. Скачивает актуальный `goshacrash.sh` из репозитория.
11. Для legacy скачивает `assets/gcnet-armv5`.
12. Загружает подходящий конфиг.
13. Загружает и проверяет Mihomo.
14. Загружает и распаковывает Zashboard.
15. Создаёт рабочие каталоги.
16. Записывает состояние платформы.
17. Создаёт глобальные команды `goshacrash` и `nano`.
18. Устанавливает автозапуск через JFFS, Download Master и stock ASUS USB hooks.
19. Проверяет конфиг через Mihomo.
20. Запускает Mihomo и маршрутизацию.

При повторной установке существующий рабочий `config.yaml` сохраняется и не заменяется шаблоном из репозитория.

---

# Проверка после установки

## Справка

```sh
goshacrash help
```

## Общее состояние

```sh
goshacrash status
```

Нормальный результат должен показывать:

- Mihomo запущен;
- `tun0` существует;
- маршрутизация работает;
- Download Master найден;
- `ipkg` или `opkg` найден;
- watchdog работает;
- путь `BASE` указывает на USB.

## Полная диагностика

```sh
goshacrash doctor
```

## Проверка TUN вручную

```sh
ip addr show tun0
```

На старом роутере, где системная команда `ip` ограничена, основную информацию покажет `goshacrash status` и встроенный helper.

## Проверка процесса

```sh
ps | grep '[m]ihomo'
```

## Проверка после перезагрузки

Перезагрузи роутер:

```sh
reboot
```

После полного запуска ASUSWRT и Download Master снова подключись по SSH:

```sh
goshacrash status
```

Также проверь:

```sh
goshacrash logs boot 100
```

```sh
goshacrash logs watchdog 100
```

---

# Команды GoshaCrash

Полный список:

```text
goshacrash help
goshacrash status
goshacrash start
goshacrash restart
goshacrash stop
goshacrash check
goshacrash apply
goshacrash edit
goshacrash dashboard
goshacrash logs [ТИП] [N]
goshacrash pkg repair
goshacrash pkg update
goshacrash pkg install ИМЯ
goshacrash doctor
```

## `goshacrash help`

Показывает встроенную справку:

```sh
goshacrash help
```

Команда без аргументов делает то же самое:

```sh
goshacrash
```

## `goshacrash status`

Показывает:

- PID Mihomo;
- версию GoshaCrash;
- каталог установки;
- выбранную платформу;
- модель, архитектуру и ядро роутера;
- состояние `tun0`;
- состояние маршрутизации;
- Download Master;
- пакетный менеджер;
- автозапуск;
- watchdog;
- адрес Zashboard.

```sh
goshacrash status
```

## `goshacrash start`

Запускает Mihomo и применяет маршрутизацию:

```sh
goshacrash start
```

## `goshacrash restart`

Корректно перезапускает Mihomo и правила:

```sh
goshacrash restart
```

## `goshacrash stop`

Останавливает Mihomo, watchdog и удаляет правила GoshaCrash:

```sh
goshacrash stop
```

После ручной остановки watchdog не должен немедленно запускать Mihomo снова.

## `goshacrash check`

Проверяет `config.yaml`, не применяя изменения:

```sh
goshacrash check
```

## `goshacrash apply`

Проверяет текущий `config.yaml`, создаёт резервную копию и перезапускает Mihomo:

```sh
goshacrash apply
```

Если новый конфиг не запускается, скрипт пытается вернуть последний рабочий конфиг.

## `goshacrash edit`

Открывает рабочий конфиг через `nano`:

```sh
goshacrash edit
```

Перед редактированием создаётся резервная копия. После выхода из `nano` конфиг проверяется и применяется. При ошибке возвращается предыдущая версия.

Можно использовать псевдоним:

```sh
goshacrash nano
```

## `goshacrash dashboard`

Печатает готовую ссылку для входа в Zashboard:

```sh
goshacrash dashboard
```

Ссылка автоматически содержит:

- LAN-адрес роутера;
- порт `external-controller`;
- секрет из конфига;
- ограничение `disableUpgradeCore=1` на legacy.

Не публикуй эту ссылку: в ней может находиться секрет доступа.

## `goshacrash doctor`

Собирает расширенный диагностический отчёт:

```sh
goshacrash doctor
```

В него входят:

- системная информация;
- конфигурация платформы;
- проверка файлов;
- package environment;
- состояние Mihomo;
- маршруты;
- правила `iptables`;
- последние строки лога Mihomo.

---

# Zashboard

После установки получи точную ссылку:

```sh
goshacrash dashboard
```

Обычно панель доступна по адресу:

```text
http://10.10.10.100:9090/ui/
```

Точная ссылка зависит от `external-controller` и `secret` в `config.yaml`.

## Обновление Zashboard

Zashboard обновляется **штатной кнопкой внутри самой панели**.

В конфиге должен присутствовать параметр:

```yaml
external-ui: ui
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
```

На legacy-профиле GoshaCrash добавляет к ссылке панели:

```text
disableUpgradeCore=1
```

Поэтому в обычной работе:

- Zashboard можно обновлять из самой панели;
- обновление Mihomo на legacy не предлагается;
- основной управляющий скрипт не обновляется кнопкой панели;
- конфиг не обновляется кнопкой панели.

---

# Редактирование и загрузка конфига

## Встроенный редактор

```sh
goshacrash edit
```

## Проверка без применения

```sh
goshacrash check
```

## Применение уже загруженного файла

```sh
goshacrash apply
```

## Передача конфига через SCP

Современный `scp` в Windows по умолчанию пытается использовать SFTP. Старый SSH-сервер ASUSWRT часто не поддерживает SFTP, поэтому нужен параметр `-O`.

С компьютера Windows:

```powershell
scp -O .\config.yaml admin@10.10.10.100:/tmp/config.yaml
```

На роутере найди каталог установки:

```sh
cat /jffs/addons/goshacrash/base
```

Скопируй конфиг:

```sh
BASE="$(cat /jffs/addons/goshacrash/base)"
cp /tmp/config.yaml "$BASE/config.yaml"
```

Проверь и примени:

```sh
goshacrash apply
```

## WinSCP

Для графической работы с файлами можно использовать WinSCP:

```text
Протокол: SCP
Хост: 10.10.10.100
Порт: 22
Пользователь: admin
```

Рабочий каталог можно узнать командой:

```sh
cat /jffs/addons/goshacrash/base
```

---

# `ipkg` / `opkg` и Download Master

GoshaCrash не устанавливает второй Entware/Optware поверх окружения ASUS. Используется пакетный менеджер существующего Download Master.

Он ищется в таких местах:

```text
<USB>/asusware.arm/bin/ipkg
<USB>/asusware.arm64/bin/opkg
<USB>/asusware/bin/ipkg
/opt/bin/ipkg
/opt/bin/opkg
/tmp/opt/bin/ipkg
/tmp/opt/bin/opkg
```

## Проверка и восстановление окружения

```sh
goshacrash pkg repair
```

Команда:

- заново находит Download Master;
- обновляет `PATH`;
- проверяет `ipkg`/`opkg`;
- при необходимости пытается штатно перезапустить Download Master.

## Обновление индекса пакетов

```sh
goshacrash pkg update
```

Обновляется только индекс репозитория. Массовый `upgrade` всех установленных пакетов не выполняется.

## Установка отдельного пакета

```sh
goshacrash pkg install nano
```

Другие примеры:

```sh
goshacrash pkg install wget
```

```sh
goshacrash pkg install unzip
```

```sh
goshacrash pkg install gzip
```

Имена пакетов фильтруются. Произвольные shell-команды вместо имени пакета не выполняются.

## Почему команда `nano` работает из любого места

Установщик создаёт wrapper:

```text
/jffs/scripts/nano
```

Он находит настоящий `nano` в `/opt`, `/tmp/opt` или каталоге Download Master. Поэтому не нужно каждый раз вводить полный путь.

---

# Логи

Все основные логи хранятся на USB в каталоге:

```text
<BASE>/logs/
```

Где `<BASE>` можно узнать так:

```sh
cat /jffs/addons/goshacrash/base
```

Файлы логов:

```text
install.log      установка
mihomo.log       вывод Mihomo
goshacrash.log   основные действия контроллера
boot.log         автозапуск после загрузки
watchdog.log     работа watchdog
packages.log     ipkg/opkg
```

## Последние 100 строк Mihomo

```sh
goshacrash logs mihomo 100
```

## Основной журнал

```sh
goshacrash logs system 100
```

## Установка

```sh
goshacrash logs install 150
```

## Автозапуск

```sh
goshacrash logs boot 100
```

## Watchdog

```sh
goshacrash logs watchdog 100
```

## Пакеты

```sh
goshacrash logs packages 150
```

## Просмотр Mihomo в реальном времени

```sh
goshacrash logs follow
```

Выход из режима `follow`:

```text
Ctrl+C
```

Логи автоматически ротируются при увеличении размера.

---

# Автозапуск

Установщик создаёт несколько взаимодополняющих механизмов запуска:

```text
/jffs/addons/goshacrash/start.sh
/jffs/addons/goshacrash/firewall.sh
/jffs/scripts/services-start
/jffs/scripts/firewall-start
<Download Master>/etc/init.d/S99goshacrash
stock ASUS script_usbmount/script_usbumount
```

Также создаётся файл с реальным путём установки:

```text
/jffs/addons/goshacrash/base
```

Благодаря этому команды не зависят от текущего каталога и не требуют жёстко прописывать имя флешки.

Если флешка называется иначе после замены или форматирования, нужно заново выполнить `install.sh`, чтобы записать новый путь.

---

# Каталоги на роутере

Пример установки на `/tmp/mnt/SANDISK`:

```text
/tmp/mnt/SANDISK/goshacrash/
├── goshacrash.sh
├── config.yaml
├── bin/
│   ├── mihomo
│   └── gcnet          # только legacy
├── ui/
│   └── index.html
├── logs/
├── run/
├── state/
├── backups/
├── proxies/
└── rulesets/
```

Назначение:

| Каталог | Назначение |
|---|---|
| `bin` | Mihomo и legacy helper |
| `ui` | Zashboard |
| `logs` | журналы |
| `run` | PID-файлы и временные блокировки |
| `state` | информация о платформе и состоянии |
| `backups` | резервные копии конфига и бинарника |
| `proxies` | локальные файлы proxy providers |
| `rulesets` | локальные rule providers |

---

# Повторная установка

Повторный запуск `install.sh` используется только как **явная переустановка**, а не как фоновое автоматическое обновление.

Снова скачай установщик:

```sh
/usr/sbin/wget --no-check-certificate -O /tmp/install.sh 'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'
```

Запусти:

```sh
INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

При повторной установке:

- существующий `config.yaml` сохраняется;
- скачивается текущий `goshacrash.sh` из репозитория;
- на legacy устанавливается проверенная закреплённая ARMv5+gVisor-сборка;
- Zashboard устанавливается заново;
- hooks и wrappers восстанавливаются;
- новый комплект проверяется перед окончательным переключением.

Обычное кнопочное обновление на legacy остаётся только для Zashboard.

---

# Полная чистая переустановка

Download Master и его `asusware.arm` удалять не нужно.

Останови GoshaCrash:

```sh
goshacrash stop 2>/dev/null || true
```

Узнай старый путь:

```sh
cat /jffs/addons/goshacrash/base 2>/dev/null
```

Удаление старой установки для USB `SANDISK`:

```sh
rm -rf /tmp/mnt/SANDISK/goshacrash
```

Удаление служебных файлов:

```sh
rm -rf /jffs/addons/goshacrash
```

```sh
rm -f /jffs/scripts/goshacrash /jffs/scripts/nano
```

Удали только строки GoshaCrash из hooks:

```sh
[ -f /jffs/scripts/services-start ] && sed -i '/[Gg]osha[Cc]rash/d' /jffs/scripts/services-start
```

```sh
[ -f /jffs/scripts/firewall-start ] && sed -i '/[Gg]osha[Cc]rash/d' /jffs/scripts/firewall-start
```

После этого снова выполни чистую установку через `install.sh`.

---

# Типовые ошибки

## `Download Master не найден`

Проверка:

```sh
find /tmp/mnt -maxdepth 2 -type d \( -name asusware.arm -o -name asusware.arm64 -o -name asusware \) 2>/dev/null
```

Если ничего не найдено:

1. открой веб-интерфейс ASUS;
2. удали старое состояние Download Master, если оно сохранилось после форматирования;
3. установи Download Master заново на нужную флешку;
4. дождись полного запуска;
5. повтори установку GoshaCrash.

## `/opt/bin/wget: not found`

Используй встроенный ASUS `wget`:

```sh
/usr/sbin/wget --no-check-certificate -O /tmp/install.sh 'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'
```

После установки GoshaCrash и пакетов путь будет восстановлен через Download Master.

## `unzip не найден после установки`

Проверь:

```sh
/opt/bin/unzip -v | head
```

```sh
ls -l /tmp/opt/bin/unzip
```

Затем:

```sh
goshacrash pkg repair
```

```sh
goshacrash pkg install unzip
```

Лог:

```sh
goshacrash logs packages 200
```

## GitHub не скачивается

Установщик пробует несколько источников для файлов репозитория:

```text
raw.githubusercontent.com
github.com/.../raw
testingcf.jsdelivr.net
cdn.jsdelivr.net
```

Для Mihomo и Zashboard используются GitHub Releases.

Если доступ к GitHub полностью отсутствует, `install.sh` можно передать через SCP:

```powershell
scp -O .\install.sh admin@10.10.10.100:/tmp/install.sh
```

После этого:

```sh
INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

Остальные компоненты всё равно должны быть доступны по сети либо через настроенные зеркала.

## `В архиве Zashboard нет index.html`

Текущий установщик проверяет несколько вариантов архива и ищет `index.html` как в корне, так и во вложенной директории.

Посмотри лог:

```sh
goshacrash logs install 200
```

Если проблема повторяется, проверь доступ к GitHub Releases и свободное место на USB.

## Mihomo не запускается

Проверка конфига:

```sh
goshacrash check
```

Лог:

```sh
goshacrash logs mihomo 200
```

Диагностика:

```sh
goshacrash doctor
```

Проверь версию бинарника:

```sh
BASE="$(cat /jffs/addons/goshacrash/base)"
"$BASE/bin/mihomo" -v
```

Для legacy в выводе должна присутствовать сборка `with_gvisor`.

## `tun0` не появился

Проверь:

```sh
goshacrash status
```

```sh
goshacrash logs mihomo 200
```

```sh
ls -l /dev/net/tun
```

Убедись, что в конфиге:

```yaml
tun:
  enable: true
  device: tun0
```

Для legacy также требуется:

```yaml
  stack: gvisor
  auto-route: false
  auto-redirect: false
```

## После перезагрузки Mihomo не поднялся

Проверь Download Master и USB:

```sh
ls -la /tmp/mnt
```

```sh
goshacrash pkg repair
```

Логи:

```sh
goshacrash logs boot 200
```

```sh
goshacrash logs watchdog 200
```

Проверь hooks:

```sh
grep -n goshacrash /jffs/scripts/services-start /jffs/scripts/firewall-start 2>/dev/null
```

Переустанови hooks повторным запуском `install.sh`.

## Команда `goshacrash` не найдена

Попробуй прямой wrapper:

```sh
/jffs/scripts/goshacrash help
```

Проверь:

```sh
ls -l /jffs/scripts/goshacrash
```

Узнай базовый путь и запусти напрямую:

```sh
BASE="$(cat /jffs/addons/goshacrash/base)"
GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" help
```

Обычно достаточно переподключиться по SSH, чтобы обновился `PATH`, либо повторно выполнить `install.sh`.

---

# Переменные для продвинутой установки

## Явный USB-накопитель

```sh
INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

## Другой каталог установки

```sh
INSTALL_ROOT=/tmp/mnt/SANDISK INSTALL_DIR=/tmp/mnt/SANDISK/my-goshacrash sh /tmp/install.sh
```

## Другой репозиторий или ветка

```sh
REPO=ПОЛЬЗОВАТЕЛЬ/РЕПОЗИТОРИЙ BRANCH=main INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

## Другой URL Zashboard

```sh
ZASHBOARD_URL='https://example.com/zashboard.zip' INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

Эти параметры нужны только для разработки и тестирования. Для обычной установки их использовать не требуется.

---

# Краткая памятка

Чистая установка:

```sh
/usr/sbin/wget --no-check-certificate -O /tmp/install.sh 'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'
INSTALL_ROOT=/tmp/mnt/SANDISK sh /tmp/install.sh
```

Справка:

```sh
goshacrash help
```

Состояние:

```sh
goshacrash status
```

Редактирование конфига:

```sh
goshacrash edit
```

Перезапуск:

```sh
goshacrash restart
```

Логи Mihomo:

```sh
goshacrash logs mihomo 100
```

Полная диагностика:

```sh
goshacrash doctor
```

Ссылка на Zashboard:

```sh
goshacrash dashboard
```

Обновление Zashboard выполняется кнопкой внутри самой панели.

## Имена конфигов

- Legacy: рабочий файл `config-legacy.yaml`.
- Modern: рабочий файл `config.yaml`.
- Legacy-конфиг больше не переименовывается.

`goshacrash status` показывает короткий адрес панели. `goshacrash dashboard` печатает полную ссылку подключения; на legacy она скрывает кнопку обновления ядра.
