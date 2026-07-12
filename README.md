# GoshaCrash 0.4.0 — DNS forward + manual TUN

Сборка для ASUS RT-AC68U / старого ASUSWRT, где Mihomo создаёт TUN-интерфейс,
но его `auto-route` завершается ошибкой `add rule ... invalid argument`.

## Рабочая схема

```text
LAN-клиенты
  ├─ DNS -> dnsmasq ASUS :53 -> Mihomo DNS 127.0.0.1:1053
  └─ TCP/UDP -> br0 -> iptables MARK 0x2333
                         -> ip rule table 2022
                         -> mihomo0
                         -> правила Mihomo: DIRECT / RU-PROXY / GLOBAL-PROXY
```

Mihomo запускается с:

```yaml
tun:
  enable: true
  stack: system
  device: mihomo0
  mtu: 1500
  auto-route: false
  auto-redirect: false
  auto-detect-interface: false
  strict-route: false
```

Личный `config.yaml` не переписывается. Эти изменения вносятся только в
`runtime.yaml`.

## Важные особенности

- `dnsmasq` остаётся на порту 53 и продолжает обслуживать DHCP/локальную сеть.
- Mihomo DNS слушает `127.0.0.1:1053`.
- Обычные DNS-запросы клиентов на сторонние серверы перенаправляются на
  штатный `dnsmasq` (best effort, если модуль `REDIRECT` доступен).
- Маркируется только трафик, пришедший с LAN-интерфейса (`br0` по умолчанию).
  Поэтому исходящие соединения самого Mihomo не зацикливаются.
- Локальные, private, multicast и broadcast-адреса не отправляются в TUN.
- Диапазон Fake-IP `198.18.0.0/16` не исключается и попадает в Mihomo.
- Перед тяжёлой проверкой GeoSite/GeoIP старый процесс Mihomo останавливается,
  чтобы два загрузчика не вызвали OOM.
- После `firewall-start` правила TUN восстанавливаются без перезапуска Mihomo.

## Установка с GitHub

```sh
wget -O /tmp/goshacrash-install.sh \
  https://raw.githubusercontent.com/goshamarat/GoshaCrash/main/install.sh
sh /tmp/goshacrash-install.sh
```

Необязательные пакеты Optware/Entware по умолчанию не устанавливаются. Для их
установки:

```sh
INSTALL_OPTIONAL_TOOLS=1 sh /tmp/goshacrash-install.sh
```

## Применение личного конфига

```sh
goshacrash setup
```

После выхода из редактора конфиг автоматически проверяется и применяется.
Прокси в блоке `proxies:` должен быть раскомментирован.

## Проверка

```sh
goshacrash doctor
```

Ожидается:

```text
dnsmasq -> :53
mihomo  -> 127.0.0.1:1053
mihomo0 -> UP
ip rule -> fwmark 0x2333 lookup 2022
route   -> default dev mihomo0 table 2022
```

## Управление

```sh
goshacrash status
goshacrash restart
goshacrash tun-disable
goshacrash tun-enable
goshacrash stop
goshacrash logs 100
```

`tun-disable` удаляет ручные маршруты, но оставляет Mihomo запущенным.

## Полная очистка роутера перед новой установкой

Скрипт сохраняет личный конфиг рядом с каталогом установки:

```sh
sh clean-router.sh
```

После очистки резервная копия будет иметь вид:

```text
/tmp/mnt/GOSHACRASH/config-backup-YYYYMMDD-HHMMSS.yaml
```

## Ограничение

Сам TUN, `iptables MARK` и `ip rule fwmark` уже отдельно подтверждены на этом
роутере. Эта сборка объединяет их в один контроллер; первый полный запуск всё
равно нужно проверить командой `goshacrash doctor` и тестом внешнего IP.
