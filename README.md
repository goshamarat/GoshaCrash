# rc40-test2 — simplified config/native auto build

В этой сборке config.yaml не восстанавливается и не переписывается автоматически. install.sh создаёт базовый файл только при отсутствии config.yaml; дальше пользователь владеет файлом. AUTO использует только native Mihomo auto-route/auto-redirect/dns-hijack. Nano на USB обёрнут постоянным UTF-8 wrapper.

Подробности: `FIX-SIMPLE-CONFIG-AUTO.txt`.

---

# GoshaCrash 3.10.2-rc40-test2

Текущая схема для ASUS RT-AC68U и ZenWiFi BT10.

## Главное

`install.sh` больше **не форматирует USB**. Подготовка/форматирование флешки выполняется отдельной программой.

Установщик должен называться строго:

```text
install.sh
```

и лежать строго в корне текущего USB mountpoint:

```text
/tmp/mnt/<текущее_имя>/install.sh
```

Ни `SANDISK`, ни `/dev/sda1`, ни `/dev/sdb1` нигде не считаются постоянными значениями.

ASUSWRT может после reboot изменить одновременно и устройство, и mountpoint, например:

```text
до reboot:    /dev/sdb1 -> /tmp/mnt/Sandisk
после reboot: /dev/sda1 -> /tmp/mnt/sda1
```

Это штатно для новой логики GoshaCrash.

## Какие значения определяются автоматически

При каждом запуске install/runtime определяются заново:

```text
USB_DEVICE   /dev/sdXN
USB_DISK     /dev/sdX
USB_MOUNT    /tmp/mnt/<текущее_имя>
USB_NAME     <текущее_имя>
USB_FS       ext3/ext4/...
DM_ROOT      <USB_MOUNT>/asusware.arm|asusware.arm64|asusware
BASE         <USB_MOUNT>/goshacrash
CONFIG       <BASE>/config.yaml
```

Абсолютные `/tmp/mnt/...` пути больше не сохраняются как источник истины в `platform.env`.
В `platform.env` сохраняются только относительные значения (`CONFIG_REL`, `GCNET_REL`, `DM_LAYOUT`).

Текущая база дополнительно публикуется в RAM:

```text
/tmp/goshacrash-base
```

`gc`, USB hooks и nano wrapper сначала используют текущую базу из RAM, а при необходимости находят единственный `/tmp/mnt/*/goshacrash` заново.

## Установка на уже подготовленную флешку

После того как ASUS смонтировал флешку и на ней установлен Download Master:

```sh
USB_MOUNT="$(mount | awk '$1 ~ "^/dev/sd" && $3 ~ "^/tmp/mnt/" {print $3; exit}')"

echo "USB_MOUNT=$USB_MOUNT"
mount | grep '/dev/sd'

rm -f "$USB_MOUNT/install.sh"
/usr/sbin/wget --no-check-certificate \
  -O "$USB_MOUNT/install.sh" \
  'https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/main/install.sh'

grep '^INSTALLER_VERSION=' "$USB_MOUNT/install.sh"
chmod 700 "$USB_MOUNT/install.sh"
/bin/sh "$USB_MOUNT/install.sh"
```

Если используется схема от внешнего formatter/installer и он уже вычисляет имя каталога через `df`, это тоже нормально. Важно только, чтобы итоговый путь был реальным текущим mountpoint и файл назывался `install.sh`.

## USB filesystem

Форматированием занимается отдельная программа. Сам `install.sh` только проверяет уже смонтированную файловую систему.

Для legacy RT-AC68U проверенная схема остаётся EXT3.
Для BT10 поддерживается современный Linux filesystem, в текущей тестовой схеме — EXT4.

## Почему после reboot больше не должен ломаться путь

Старые сборки могли сохранить, например:

```text
CONFIG_FILE=/tmp/mnt/Sandisk/goshacrash/config.yaml
DM_ROOT=/tmp/mnt/Sandisk/asusware.arm
```

После reboot ASUS мог смонтировать ту же флешку как `/tmp/mnt/sda1`, и controller продолжал смотреть в старый путь. Типичный результат: watchdog жив, а Mihomo не стартует.

В этой ревизии runtime каждый раз строит пути от фактического местоположения `goshacrash.sh`, поэтому текущий путь становится:

```text
BASE=/tmp/mnt/sda1/goshacrash
CONFIG=/tmp/mnt/sda1/goshacrash/config.yaml
DM_ROOT=/tmp/mnt/sda1/asusware.arm
```

без переустановки из-за смены `sda/sdb` или имени mountpoint.

## Nano и config.yaml

На BT10 экспериментально подтверждён рабочий фикс для Optware nano 3.1:

```sh
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

Эта ревизия закрепляет его в трёх местах:

- `/jffs/etc/profile` — постоянные переменные после reboot/нового SSH login;
- `/jffs/configs/profile.add` — дополнительный ASUSWRT profile hook;
- `/jffs/scripts/nano` и `gc edit` — nano получает UTF-8 locale явно даже в текущей сессии.

`config.yaml` больше не переводится в ASCII и русские комментарии не удаляются. При install/upgrade сохраняются UTF-8 комментарии и YAML-данные пользователя; нормализуется только CRLF -> LF. После `gc edit` конфиг по-прежнему проходит `mihomo -t`, а невалидная правка откатывается.

После установки можно проверить:

```sh
gc doctor
grep 'UTF-8' /jffs/etc/profile /jffs/configs/profile.add
```

Ожидается:

```text
nano UTF-8 locale: en_US.UTF-8
shell UTF-8 locale /jffs/etc/profile: OK
shell UTF-8 locale profile.add: OK
config UTF-8: OK
```

Для уже открытой SSH-сессии profile сам по себе не перечитывается, но `nano`/`gc edit` уже работают правильно через wrapper. Для глобальных `$LANG`/`$LC_ALL` в shell нужно открыть новую SSH-сессию или выполнить:

```sh
. /jffs/etc/profile
```

## Zashboard

Mihomo API остаётся:

```yaml
external-controller: 0.0.0.0:9090
external-ui: ui
```

`secret` в текущем профиле GoshaCrash удалён полностью. При upgrade существующий top-level `secret:` также удаляется.

URL:

```sh
gc dashboard
```

## После установки

```sh
gc version
gc status
gc doctor
gc dashboard
```

После reboot особенно полезно проверить:

```sh
mount | grep '/dev/sd'
gc doctor
gc logs mihomo 100
gc logs watchdog 100
```

В `gc doctor` должны отражаться **текущие**, а не install-time значения USB device/mount/name.

## Persistent layout

На флешке:

```text
/tmp/mnt/<current>/
├── install.sh
├── asusware.arm/        # или другой штатный layout Download Master
└── goshacrash/
    ├── goshacrash.sh
    ├── config.yaml
    ├── bin/
    ├── ui/
    ├── logs/
    ├── run/
    └── state/
```

В JFFS остаются только ASUS hooks/wrappers, которые нужны firmware:

```text
/jffs/scripts/gc
/jffs/scripts/nano
/jffs/scripts/usb-mount-script
/jffs/scripts/usb-umount-script
```

Они не содержат постоянного `/tmp/mnt/<имя>` пути.


## Coldboot v2 (same public version rc40-test2)

- cold boot no longer calls public `start()` after an initial successful WAN probe; this removes the second transient WAN probe that could leave Mihomo down after reboot;
- transient WAN/offline counters are reset on each new router boot;
- watchdog writes a heartbeat and receives an immediate recovery pass after the boot lock is released;
- `/jffs/configs/profile.add` is the persistent shell locale source; `/jffs/etc/profile` is treated as optional because ASUS may recreate/remove it.


## rc40-test2 edit pause

После выхода из `Edit config` интерактивное меню больше не перерисовывается автоматически через 2 секунды. В полноэкранном меню вывод проверки конфигурации остаётся на экране до нажатия любой клавиши. В fallback line-menu — до Enter. CLI-команда `gc edit` не получает обязательную паузу и остаётся пригодной для прямого вызова.
