# GoshaCrash

Минимальный установщик Mihomo + Zashboard для ASUSWRT/Asuswrt-Merlin.

## Что хранится на GitHub

Только публичные скрипты и безопасный шаблон. Настоящий `config.yaml` с серверами,
паролями и правилами хранится только на USB роутера.

## Установка

```sh
wget --no-check-certificate \
  -O /tmp/goshacrash-install.sh \
  https://raw.githubusercontent.com/goshamarat/GoshaCrash/main/install.sh \
  && sh /tmp/goshacrash-install.sh
```

## Вставка личного конфига

```sh
goshacrash edit
goshacrash apply
```

`apply`:

- сохраняет резервную копию `config.yaml`;
- создаёт отдельный `runtime.yaml`;
- открывает API Zashboard в LAN;
- убирает устаревший `global-client-fingerprint` только из runtime;
- добавляет `geo-auto-update: false`, не удаляя пользовательские GEO-правила;
- освобождает порт 53 у dnsmasq, если DNS Mihomo слушает порт 53;
- сохраняет DHCP ASUS;
- проверяет `/dev/net/tun`;
- запускает TUN из пользовательского конфига;
- устанавливает хуки `post-mount`, `services-start`, `firewall-start` и
  `dnsmasq.postconf`;
- откатывается к предыдущему runtime при ошибке.

## Команды

```sh
goshacrash status
goshacrash doctor
goshacrash logs 100
goshacrash ui
goshacrash backup
goshacrash restore
goshacrash update
```

## Файлы на роутере

```text
/tmp/mnt/GOSHACRASH/goshacrash/
├── bin/mihomo
├── config.yaml          # личный исходный конфиг
├── runtime.yaml         # версия, подготовленная для ASUS
├── ui/
├── rulesets/
├── backups/
├── logs/
└── goshacrash
```
