# GoshaCrash 0.9.0-rc1

GoshaCrash — установщик и контроллер **Mihomo + Zashboard** для ASUS RT-AC68U со старым stock ASUSWRT и Download Master.

В репозитории только два рабочих shell-файла:

```text
install.sh   — установка и обновление
goshacrash   — всё управление Mihomo, DNS, TUN, iptables и автозапуск
```

`README.md` — документация. Личный `config.yaml` в GitHub не хранится.

> Это release candidate. Схема LAN уже проверена на реальном RT-AC68U, включая обычную программную перезагрузку. Физическое отключение питания, новый перехват TCP самого роутера и DNS-цепочка через dnsmasq должны быть проверены на железе перед стабильным тегом `v0.9.0`.

## Рабочая схема

```text
LAN-клиенты
  ├─ DNS -> dnsmasq ASUS :53
  │            └─ upstream DNS -> iptables OUTPUT -> Mihomo DNS 127.0.0.1:1053
  ├─ TCP -> iptables REDIRECT -> Mihomo redir-port 7893
  └─ UDP/прочее -> fwmark 0x2333 -> table 2022 -> mihomo0

Сам роутер
  ├─ DNS -> dnsmasq :53 -> Mihomo :1053
  └─ TCP -> iptables OUTPUT -> Mihomo redir-port 7893

Mihomo outbound
  └─ routing-mark 9012 / 0x2334 -> обход собственного перехвата
```

Почему гибрид: на этом старом ARMv5/ASUSWRT TCP-пакеты доходили до `mihomo0`, но Mihomo `stack: system` не создавал клиентские TCP-соединения. После перевода TCP на `redir-port` запросы сразу появились в логах и заработали. UDP остаётся в TUN.

## DNS: dnsmasq остаётся главным портом 53

GoshaCrash не заставляет Mihomo занимать порт 53. На роутере:

- `dnsmasq` слушает `:53`, обслуживает DHCP и локальные имена;
- Mihomo DNS слушает только `127.0.0.1:1053`;
- исходящие DNS-запросы dnsmasq перенаправляются на 1053 через `iptables OUTPUT`;
- DNS-сокеты самого Mihomo имеют mark `0x2334` и не попадают в петлю.

Клиентский конфиг с `dns.listen: 0.0.0.0:53` можно использовать: GoshaCrash не меняет личный файл, а в `runtime.yaml` принудительно ставит `127.0.0.1:1053`.

## Установка

Требуется:

- включённый SSH;
- установленный Download Master;
- USB-флешка с каталогом `/tmp/mnt/<МЕТКА>/asusware.arm`.

```sh
wget --no-check-certificate -O /tmp/goshacrash-install.sh \
  https://raw.githubusercontent.com/goshamarat/GoshaCrash/main/install.sh
sh /tmp/goshacrash-install.sh install
```

Проверка:

```sh
goshacrash status
goshacrash doctor
```

## Личный config.yaml

Путь:

```text
/tmp/mnt/GOSHACRASH/goshacrash/config.yaml
```

Редактирование и применение:

```sh
goshacrash edit
goshacrash apply
```

Личный конфиг может быть другим. GoshaCrash сохраняет:

- `proxies` и `proxy-providers`;
- `proxy-groups`;
- `rule-providers`;
- `rules`;
- sniffer;
- пользовательские DNS upstream и `nameserver-policy`.

Только в `runtime.yaml` задаются параметры совместимости роутера:

```yaml
redir-port: 7893
routing-mark: 9012
external-controller: 0.0.0.0:9090
find-process-mode: off
ipv6: false

dns:
  listen: 127.0.0.1:1053
  ipv6: false

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

`system` внутри DNS upstream опасен: после включения моста получится петля `dnsmasq -> Mihomo -> system/dnsmasq`. Поэтому в runtime такое значение заменяется первым `default-nameserver` из личного конфига, а при его отсутствии — текущим bootstrap DNS роутера.

Если `proxy-server-nameserver` отсутствует или оставлен пустым, GoshaCrash заполняет его только в `runtime.yaml`: сначала первым `default-nameserver`, затем доступными bootstrap-вариантами. Основной `nameserver` при этом не подменяется — запасные DoH/DoT для обычных запросов нужно явно указать в личном конфиге.

## Правила

Mihomo проверяет правила сверху вниз. Узкие правила размещаются выше широких, `MATCH` — последним.

```yaml
rules:
  - DOMAIN-SUFFIX,github.com,GLOBAL-PROXY
  - RULE-SET,domain_ru,RU-PROXY
  - RULE-SET,domain_global,GLOBAL-PROXY
  - MATCH,DIRECT
```

Проверка:

```sh
goshacrash logs 100 | grep -Ei 'github|youtube|chatgpt|using'
```

Поле `proxy:` внутри `proxy-providers` или `rule-providers` задаёт маршрут **скачивания provider-файла**, а не маршрут сайтов из него.

## DNS в жёстко фильтруемой сети

Одного «рабочего DNS» недостаточно. Если он будет заблокирован, а прокси-узел задан доменом, возникает замкнутый круг: для запуска прокси нужен DNS, а защищённый DNS доступен только через прокси.

Надёжная схема первого запуска:

1. хотя бы один bootstrap-прокси в `proxies:` должен иметь `server` как буквальный IPv4-адрес;
2. этот узел включается в отдельную группу, например `BOOTSTRAP-PROXY`;
3. удалённые `proxy-providers` и `rule-providers` скачиваются через `proxy: BOOTSTRAP-PROXY`;
4. `proxy-server-nameserver` содержит несколько реально доступных bootstrap DNS, а не один;
5. после подъёма прокси основной DoH/DoT запускается через прокси:

```yaml
dns:
  respect-rules: true
  proxy-server-nameserver:
    - 1.1.1.1
    - 9.9.9.9
  nameserver:
    - "https://1.1.1.1/dns-query#GLOBAL-PROXY"
    - "https://8.8.8.8/dns-query#GLOBAL-PROXY"
```

Адреса выше — пример, а не гарантия доступности в конкретной сети. Самая важная страховка — proxy node с IP и сохранённые provider-файлы на USB. Ни один скрипт не сможет автоматически обойти ситуацию, когда одновременно недоступны все bootstrap DNS и все proxy node заданы только доменами.

## Команды

```sh
goshacrash status
goshacrash start
goshacrash stop
goshacrash restart
goshacrash apply
goshacrash logs 100
goshacrash doctor
goshacrash test
goshacrash dns-report
goshacrash router-proxy-enable
goshacrash router-proxy-disable
goshacrash update
```

## Проверка после перезагрузки

```sh
sync
reboot
```

После загрузки:

```sh
goshacrash status
wget --spider --no-check-certificate https://github.com
goshacrash logs 100 | grep -Ei 'github|example.com|chatgpt.com|youtube|error|timeout'
```

Windows:

```powershell
ipconfig /flushdns
nslookup example.com 10.10.10.100
curl.exe -I --http1.1 --connect-timeout 15 https://example.com
curl.exe -I --http1.1 --connect-timeout 15 https://chatgpt.com
```

Для `chatgpt.com` ответ Cloudflare `403 challenge` от `curl` также подтверждает рабочие TCP и TLS; браузер проходит интерактивную проверку.