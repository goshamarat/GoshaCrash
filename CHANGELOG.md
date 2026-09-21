## 4.0.0 production hotfix — 2026-09-21 PControls live block

- ASUS' original `FORWARD -> PControls` rules are promoted unchanged to the first FORWARD positions, before generic `RELATED,ESTABLISHED` accepts and before Mihomo hooks.
- The watchdog now tracks the PControls policy/rule snapshot as well as client membership, so toggling a block for an already-managed client is detected.
- On an actual PControls policy change, GoshaCrash flushes Broadcom flow-cache once (per MAC where supported, global fallback otherwise) and restarts Mihomo once; hardware acceleration is not disabled persistently.
- RT-AC68U source-IP selectors (`-s <client>/32`) are preserved. This fixes the previous widening of an IP-only selector into an unconditional `-i br0 -j RETURN`, which could bypass Mihomo for the whole LAN.
- Native auto-redirect bypass remains limited to selectors ASUS actually sends to PControls.

## 4.0.0 production hotfix — 2026-09-21 Logs menu flicker

- Fixed SSH terminal flicker in the Logs submenu: Up/Down now repaints only the old and new selection rows instead of clearing and redrawing the whole screen.
- Full-screen redraw remains only when entering Logs or returning from an opened log view.
- Mihomo latest-resolution, cache-lock cleanup and all routing/PControls logic are unchanged.

## 4.0.0 production hotfix — 2026-09-21 latest Mihomo + cache lock cleanup

- Modern installs now resolve MetaCubeX/mihomo `releases/latest` at install time instead of pinning v1.19.30; current stable is v1.19.31.
- `gc start` no longer runs the same `mihomo -t` validation twice.
- A cache lock timeout produced only by `mihomo -t` while the live core already owns `cache.db` is filtered from the validation output; real startup cache lock warnings remain visible.
- `kill_mihomo` now waits for orphan/manual Mihomo instances to exit before starting a replacement, preventing a real cache.db lock race.


## 2026-09-21 — installer/controller build sync fix

- Fixed release packaging bug: `install.sh` now expects controller build `2026-09-21-pcontrols-cache-3h-snapshots-menu-v4-enterfix`.
- Previous archive could reject its own updated `goshacrash.sh` and fetch/install the older v3 controller, so the Enter fix was not actually deployed.
## 2026-09-21 — menu Enter hotfix

- Fixed interactive `gc` menu regression where Up/Down worked but Enter could be ignored on ASUSWRT/BusyBox terminals.
- Reverted the main menu input path to the proven blocking byte reader; status is refreshed on every navigation key and after returning from an action.
- Cache/log 3-hour RAM snapshot logic and PControls guard are unchanged.

# Changelog

### RAM cache + live menu status

- `cache.db` Mihomo больше не хранится как обычный файл на USB: `goshacrash/cache.db` становится symlink на `/tmp/goshacrash/cache.db`, поэтому частые записи cache/profile state уходят в RAM. Старый persistent `cache.db` при чистом старте удаляется, а RAM-cache создаётся заново.
- Главное меню теперь раз в секунду перепроверяет состояние процесса Mihomo и TUN без полного перерисовывания экрана.
- `running_pid` умеет заново найти живой Mihomo через `pidof` + `/proc/<pid>/cmdline`, если RAM pidfile потерян/устарел, поэтому статус меньше зависит от состояния pidfile.
- `gc doctor` показывает, находится ли `cache.db` действительно в RAM.

## 4.0.0 production — 2026-09-21 cache/log 3h persistence

- `cache.db` live writes stay in `/tmp/goshacrash/cache.db`; the USB project path is only a symlink to RAM.
- Every 3 hours watchdog saves one rolling `state/cache.db.snapshot` to USB. On reboot the RAM cache is restored from that snapshot.
- Existing pre-update persistent `cache.db` is migrated as the initial snapshot instead of being discarded.
- Cache snapshot is copied RAM→RAM while Mihomo is briefly stopped, then Mihomo immediately continues while the RAM copy is written to USB.
- Runtime logs also use one rolling USB snapshot every 3 hours; heartbeat/PID/locks remain RAM-only.
- `gc cache-save`, `gc logs flush`, `gc storage` and `gc doctor` expose/manual-trigger the snapshot state.
- Main menu retains the 1-second live MIHOMO/TUN status refresh and PID rediscovery fix.
- ASUS PControls guard from the previous build is retained.

## 4.0.0 production

### ASUS PControls / parental control

- Added a stock-ASUSWRT `PControls` guard. GoshaCrash does not create, edit or own the `PControls` chain; ASUS remains the source of truth.
- When ASUS creates one or more `FORWARD ... -j PControls` rules, GoshaCrash keeps its own/Mihomo `FORWARD` hooks after the last stock PControls rule.
- For native Mihomo `auto-redirect`, clients attached by ASUS to PControls are returned from `mihomo-prerouting` before TCP/DNS redirect. Their traffic therefore reaches the normal routing/`FORWARD` path where ASUS can block it before TUN/proxy.
- The watchdog detects PControls appearing, disappearing or changing after boot. Membership changes trigger one clean Mihomo restart so already redirected long-lived sessions (for example Telegram) cannot stay alive behind an old conntrack redirect.
- `gc pcontrols` shows the current guard state. `gc doctor` reports PControls presence, FORWARD priority and native auto-redirect bypass status.
- If PControls does not exist yet, the guard is a no-op and waits for ASUS to create it later.

### USB / filesystem

- Runtime logs live only in `/tmp/goshacrash/logs` (RAM). Each `.log` has an independent 10 MiB cap; when that file reaches the cap it is truncated in RAM. There is no time-based flush and no USB log snapshot. A low-RAM guard clears RAM logs if available memory falls below 32 MiB.
- PID/lock files moved to `/tmp/goshacrash/run`.
- Watchdog heartbeat, WAN counters and routing runtime state moved to RAM; the 10-second heartbeat no longer writes to USB.
- Background runtime no longer touches USB marker/probe files or creates Optware directories/copies payloads on boot; it only verifies the prepared layout and may bind it into `/opt` in the mount namespace.
- USB mount is best-effort remounted with `noatime,nodiratime` to suppress read-driven access-time metadata writes.
- USB unmount hook performs a final `sync` after stopping runtime and releasing `/opt`.
- Persistent `manual-stop` moved off USB to `/jffs/goshacrash/manual-stop`; passive edit backups moved to `/tmp/goshacrash/backups`.
- Old GoshaCrash-owned `logs/`, `run/` and previous snapshot files are removed only during an explicit install/update, never by background runtime.
- Runtime refuses to start when USB is >=95% full or has less than 32 MiB free.
- `gc storage` and `gc doctor` expose USB usage, `.minidlna` size and kernel filesystem errors.
- Installer refuses further writes when current kernel log already contains EXT filesystem/I/O errors for the selected USB. Runtime log maintenance no longer writes logs to USB at all.

### Downloads

- Direct GitHub remains first choice.
- GitHub release URLs automatically fall back to `https://ghproxy.net/github.com/...` when direct download fails.
- Mihomo, Zashboard and project GitHub release assets use the same fallback logic.
- Direct download attempts now fail over on connection/stall instead of waiting indefinitely.

Первая чистая production-сборка **GoshaCrash 4.0.0**.

- Ветка `production` используется как рабочий канал для реальных роутеров.
- Ветка `main` остаётся для разработки, тестов и полной истории изменений.
- Online bootstrap и связанные файлы по умолчанию загружаются из `production`.

### Runtime и routing

- BT10 использует native Mihomo `auto-route + auto-redirect + dns-hijack` без отдельного fallback table.
- Runtime проверяет фактическую готовность TUN, policy routing, TCP redirect и DNS hijack.
- USB device и mountpoint определяются динамически после каждого монтирования и не зависят от `sda/sdb` или имени тома.
- Coldboot не делает лишний повторный Internet probe перед запуском runtime.

### Config

- `config.yaml` создаётся только если отсутствует.
- Переустановка не заменяет пользовательский конфиг.
- Невалидный конфиг не восстанавливается автоматически из backup.
- `gc edit` сохраняет UTF-8 и проверяет YAML через `mihomo -t`.

### Nano / UTF-8

- Для Optware nano используется `LANG=en_US.UTF-8` и `LC_ALL=en_US.UTF-8`.
- `/jffs/configs/profile.add` используется как persistent locale hook.
- `/jffs/etc/profile` считается optional.

### MPTCP

- GoshaCrash не меняет MPTCP sysctl автоматически.
- Текущее состояние MPTCP отображается в `gc doctor`.
- Включённый или выключенный MPTCP сам по себе не считается ошибкой runtime/watchdog.

### Menu

- Раздел Logs использует навигацию `↑/↓`.
- `Enter` открывает выбранный пункт.
- `Esc` возвращает в главное меню.

### Installer

- USB formatting не входит в `install.sh`.
- Установщик работает от фактического текущего USB mountpoint.
- Локальный `goshacrash.sh` из той же сборки используется раньше online-download.
