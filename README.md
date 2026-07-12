# GoshaCrash 0.3.0 DNS test

Архив предназначен для установки поверх уже существующего каталога:

```text
/tmp/mnt/GOSHACRASH/goshacrash
```

Личный `config.yaml`, установленный `bin/mihomo`, Zashboard и правила не удаляются.

## Установка из распакованного архива

```sh
sh install-local.sh
```

## Безопасный тест DNS на порту 53

```sh
sh /tmp/mnt/GOSHACRASH/goshacrash/dns-test.sh
```

Скрипт:

- сохраняет резервные копии;
- создаёт `runtime.yaml`;
- временно отключает TUN только в runtime;
- добавляет `port=0` в `/jffs/configs/dnsmasq.conf.add`;
- оставляет DHCP dnsmasq включённым;
- перезапускает dnsmasq;
- проверяет, освободился ли порт 53;
- запускает Mihomo;
- проверяет, что порт 53 слушает Mihomo;
- автоматически возвращает прежние настройки при ошибке.

Исходный `config.yaml` не меняется.

## Возврат штатного DNS ASUS

```sh
sh /tmp/mnt/GOSHACRASH/goshacrash/restore-dns.sh
```

TUN в этой версии намеренно не настраивается: сначала отдельно проверяется DNS.
