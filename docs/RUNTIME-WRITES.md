# Runtime write policy

Production goal: high-churn runtime writes stay in RAM. GoshaCrash intentionally opens one rolling persistence window every 3 hours for log and Mihomo cache snapshots. The mount hook also attempts `noatime,nodiratime` so normal reads do not cause atime writes.

## RAM-only paths

- `/tmp/goshacrash/logs` — Mihomo, watchdog, install, packages, boot, coldboot and controller logs.
- `/tmp/goshacrash/run` — PIDs and locks.
- `/tmp/goshacrash/state` — heartbeat, WAN counters, route/sysctl runtime state.
- `/tmp/goshacrash/backups` — passive config backup made before `gc edit`.
- `/tmp/goshacrash/cache.db` — live Mihomo runtime/profile/fake-IP cache; `<USB>/goshacrash/cache.db` is only a symlink to this RAM file.
- `/tmp/goshacrash-opt` — Optware ABI overlay.

Every `.log` is capped independently at 10 MiB by default. Once every 3 hours the watchdog writes one rolling log snapshot and one rolling `cache.db` snapshot to USB. After a successful log snapshot the RAM logs are truncated for the next interval. If available RAM drops below 32 MiB, RAM logs are cleared early.

## Persistent paths

- `<USB>/goshacrash` — binaries, UI, user-owned `config.yaml`, platform/install state. `cache.db` itself points to RAM; `state/cache.db.snapshot` is the rolling 3-hour restore point. `state/logs-last-3h.txt.gz` (or plain fallback) is the rolling log snapshot.
- `/jffs/goshacrash/manual-stop` — persistent manual-stop flag; changed only by explicit `gc stop`/`gc start`/`gc restart`.
- `<USB>/asusware.*` — ASUS Download Master / Optware tree. GoshaCrash runtime verifies it and can bind it to `/opt` without creating probe files or touching USB metadata.

## Intentional USB writes

Background runtime normally reads USB only, except for the scheduled rolling snapshot window once every 3 hours. Installation and user-requested modifications can also write persistent storage:

- `install.sh` / update;
- editing `config.yaml`;
- explicit Optware package install/reinstall/update operations;
- ASUS Download Master or other ASUS services, which are outside GoshaCrash runtime.

## Filesystem guard

Runtime refuses to start if the selected USB is >=95% full, has less than 32 MiB free, or the current kernel log already contains matching EXT filesystem/I/O errors. The installer has the same filesystem-error guard before persistent writes.

## Unmount safety

The USB unmount hook stops GoshaCrash, releases the `/opt` bind mount and runs `sync` before returning to ASUSWRT. Lazy unmount is not used.
