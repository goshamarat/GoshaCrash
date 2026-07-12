# GoshaCrash 0.3.2 DNS forward

Версия для ASUSWRT / Asuswrt-Merlin с правильной DNS-схемой для роутера.

## Как работает DNS

```text
клиенты LAN -> dnsmasq ASUS:53 -> Mihomo DNS 127.0.0.1:1053 -> внешние DNS
```

- Штатный `dnsmasq` остаётся на порту `53`.
- DHCP и локальные имена ASUS продолжают работать.
- Mihomo DNS слушает только `127.0.0.1:1053`.
- GoshaCrash добавляет в `dnsmasq`:
  - `no-resolv`
  - `server=127.0.0.1#1053`
- Сначала запускается Mihomo и проверяется порт `1053`.
- Только после успешного запуска `dnsmasq` переключается на Mihomo.
- При остановке или ошибке GoshaCrash удаляет свой блок и возвращает штатные DNS ASUS.
- Личный `config.yaml` не изменяется. Даже если там указано `0.0.0.0:53`, в `runtime.yaml` будет `127.0.0.1:1053`.
- Значения `system` внутри DNS-раздела заменяются только в `runtime.yaml`, чтобы не создать цикл `Mihomo -> dnsmasq -> Mihomo`.

## Обновление с GitHub

```sh
wget --no-check-certificate -O /tmp/goshacrash-install.sh \
  https://raw.githubusercontent.com/goshamarat/GoshaCrash/main/install.sh
sh /tmp/goshacrash-install.sh
```

Личный `config.yaml` сохраняется.

## Применение

```sh
/tmp/mnt/GOSHACRASH/goshacrash/goshacrash apply
```

## Проверка

```sh
/tmp/mnt/GOSHACRASH/goshacrash/goshacrash doctor
```

Ожидаемая схема портов:

```text
dnsmasq -> 0.0.0.0:53
mihomo  -> 127.0.0.1:1053
mihomo  -> 0.0.0.0:7892
mihomo  -> 0.0.0.0:9090
```

Управляемый блок:

```text
# GOSHACRASH_DNS_BEGIN
no-resolv
server=127.0.0.1#1053
# GOSHACRASH_DNS_END
```

## TUN

На текущем RT-AC68U автоматические policy-routing правила Mihomo завершаются ошибкой `invalid argument`. Поэтому по умолчанию TUN отключается только в `runtime.yaml`, пока не будет добавлена отдельная маршрутизация для старого ASUS.
