# GoshaCrash 0.3.1 DNS stable

Версия для ASUSWRT / Asuswrt-Merlin, в которой DNS Mihomo работает непосредственно на порту `53`.

## Как работает DNS

- `dnsmasq` остаётся запущенным и продолжает выдавать DHCP.
- GoshaCrash добавляет управляемый блок `port=0` в `/jffs/configs/dnsmasq.conf.add`.
- DNS-функция `dnsmasq` отключается, после чего порт `53` занимает Mihomo.
- При остановке Mihomo или ошибке запуска GoshaCrash удаляет свой блок и возвращает штатный DNS ASUS.
- Личный `config.yaml` не переписывается: изменения делаются только в `runtime.yaml`.

## Установка из GitHub

```sh
wget --no-check-certificate -O /tmp/goshacrash-install.sh \
  https://raw.githubusercontent.com/goshamarat/GoshaCrash/main/install.sh
sh /tmp/goshacrash-install.sh
```

Если GoshaCrash уже установлен, тот же установщик обновит управляющий скрипт и сохранит личный `config.yaml`.

## Применение конфига

```sh
/tmp/mnt/GOSHACRASH/goshacrash/goshacrash apply
```

## Проверка

```sh
/tmp/mnt/GOSHACRASH/goshacrash/goshacrash doctor
```

На порту `53` должен отображаться процесс `mihomo`, а в `/jffs/configs/dnsmasq.conf.add` — блок:

```text
# GOSHACRASH_DNS_BEGIN
port=0
# GOSHACRASH_DNS_END
```

## Остановка

```sh
/tmp/mnt/GOSHACRASH/goshacrash/goshacrash stop
```

Команда останавливает Mihomo и автоматически возвращает штатный DNS ASUS.

## TUN

На текущем RT-AC68U автоматические policy-routing правила Mihomo завершаются ошибкой `invalid argument`. Поэтому эта версия запускается в режиме `dns-only`: исходный `config.yaml` сохраняется, но в `runtime.yaml` TUN временно отключается. Это сделано специально, чтобы Mihomo, DNS, правила и Zashboard уже работали без отката.

Для экспериментального запуска без этой защиты можно передать:

```sh
GOSHACRASH_TUN_MODE=native /tmp/mnt/GOSHACRASH/goshacrash/goshacrash apply
```

На данном роутере такой режим пока, вероятнее всего, снова упрётся в ошибку автоматической маршрутизации.
