# Changelog

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
