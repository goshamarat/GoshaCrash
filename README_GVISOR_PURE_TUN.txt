GoshaCrash 0.9.0-rc6
Controller BUILD: 2026-07-16-pure-tun-gvisor-armv5-090rc6
Routing helper BUILD: 2026-07-16-pure-tun-gvisor-routing-helper-090rc6

ЦЕЛЬ

Чистый TUN без redir-port, tproxy-port и mixed-port:

  TCP + UDP
      -> iptables MARK 0x2333
      -> ip rule pref 10010
      -> table 2022
      -> goshatun
      -> Mihomo stack: gvisor
      -> DIRECT или PROXY

Почему gVisor:
  текущий system stack на роутере увидел UDP, но не принял клиентский TCP;
  gVisor реализует TCP и UDP внутри userspace Mihomo и не использует
  проблемный внутренний TCP listener старого ядра.

ФАЗА 1 — СБОРКА ЯДРА НА GITHUB

Добавить в репозиторий:
  .github/workflows/build-mihomo-armv5-gvisor.yml

GitHub:
  Actions
  -> Build Mihomo ARMv5 gVisor
  -> Run workflow
  -> mihomo_ref: v1.19.28

Workflow:
  - клонирует официальный MetaCubeX/mihomo v1.19.28
  - собирает GOOS=linux GOARCH=arm GOARM=5
  - использует официальный build tag with_gvisor
  - проверяет бинарник через qemu-arm
  - требует строку Use tags: with_gvisor
  - публикует prerelease:
    mihomo-gvisor-armv5-v1.19.28

Asset:
  mihomo-linux-armv5-gvisor-v1.19.28.gz

ФАЗА 2 — УСТАНОВКА

После успешного GitHub Actions release:

  goshacrash stop

  /usr/sbin/wget --no-check-certificate -O /tmp/install.sh   "https://raw.githubusercontent.com/goshamarat/GoshaCrash/main/install.sh?$(date +%s)"

  grep 'EXPECTED_.*BUILD=' /tmp/install.sh
  sh /tmp/install.sh install

Проверка core:
  BASE=$(cat /jffs/addons/goshacrash/base)
  "$BASE/bin/mihomo" -v

Обязательно должна быть строка:
  Use tags: with_gvisor

Runtime:
  goshacrash runtime-audit

Ожидается:
  tun:
    enable: true
    stack: gvisor
    device: goshatun
    mtu: 1500
    auto-route: false
    auto-redirect: false
    auto-detect-interface: false

ЗАПУСК И ТЕСТ

  goshacrash apply
  goshacrash status
  goshacrash route-status

На компьютере:
  curl.exe -4 -v --connect-timeout 15 https://api.ipify.org

На роутере:
  tail -n 100 "$BASE/logs/mihomo.log"
  iptables -t filter -L GOSHACRASH_TUN_FORWARD -n -v
  free
  top

Критерий успеха:
  - в логе появляется [TCP] 10.10.10.x -> api.ipify.org:443
  - curl возвращает IP, а не timeout
  - UDP по NTP также появляется в логе
  - нет redir-port/tproxy-port
  - CPU/RAM остаются приемлемыми

ОТКАТ

  goshacrash stop
  cp "$BASE/bin/mihomo.previous" "$BASE/bin/mihomo"
  chmod 755 "$BASE/bin/mihomo"

Это экспериментальная сборка. Она проверена синтаксически и по генерации
runtime, но настоящий ARMv5 gVisor core и производительность проверяются
только после выполнения GitHub Actions и запуска на RT-AC68U.


RC6.1 FIX
---------
Controller BUILD: 2026-07-16-pure-tun-gvisor-sha256-fallback-090rc61

Исправлена проверка SHA256 на старом ASUSWRT:
- sha256sum из PATH;
- /opt/bin/sha256sum;
- BusyBox sha256sum;
- OpenSSL dgst -sha256.

RC6 ошибочно считал actual пустым, если на прошивке отсутствовала команда
sha256sum, и сообщал о несовпадении хэша.


FAIL-OPEN DIRECT — RC6.2
========================

Controller BUILD:
  2026-07-16-pure-tun-gvisor-failopen-direct-090rc62

Политика работы:

1. goshacrash start:
   вручную поднимает Mihomo, goshatun, iptables, ip rule/table 2022 и watchdog.

2. goshacrash stop/direct:
   сначала удаляет GoshaCrash iptables/ip-rule/routes, затем завершает Mihomo.
   LAN возвращается к штатному ASUS routing/NAT через eth0.

3. Перезагрузка или потеря питания:
   после новой загрузки init-hook выполняет cleanup, но НЕ запускает VPN.
   Роутер работает в DIRECT до ручного goshacrash start/apply.

4. Отключение WAN-кабеля:
   пока кабель отключён, физического доступа в Интернет нет.
   Watchdog обнаруживает carrier/default-route loss, удаляет TUN-схему и
   завершает Mihomo. После подключения кабеля штатный DIRECT восстанавливается;
   VPN автоматически не запускается.

5. Crash Mihomo/TUN/routing:
   после двух локальных неудачных проверок выполняется fail-open DIRECT.
   Автоматического restart Mihomo нет.

6. WAN есть, но Интернет через Mihomo не работает:
   проверка выполняется каждые 60 секунд. После двух провалов выполняется DIRECT.

Проверка режима DIRECT:

  goshacrash status
  ip link show goshatun
  ip rule show
  ip route show table 2022
  iptables-save | grep GOSHACRASH
