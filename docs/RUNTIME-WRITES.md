# Runtime write policy

Production goal: GoshaCrash background runtime does not intentionally write files or metadata to the mounted USB filesystem. The mount hook also attempts `noatime,nodiratime` so reads do not cause atime writes.

## RAM-only paths

- `/tmp/goshacrash/logs` — Mihomo, watchdog, install, packages, boot, coldboot and controller logs.
- `/tmp/goshacrash/run` — PIDs and locks.
- `/tmp/goshacrash/state` — heartbeat, WAN counters, route/sysctl runtime state.
- `/tmp/goshacrash/backups` — passive config backup made before `gc edit`.
- `/tmp/goshacrash-opt` — Optware ABI overlay.

Every `.log` is capped independently at 10 MiB by default. A file is truncated only when its own size reaches the cap, by `gc logs clear`, or by reboot because `/tmp` is volatile. If available RAM drops below 32 MiB, all RAM logs are cleared early. No periodic USB flush exists.

## Persistent paths

- `<USB>/goshacrash` — binaries, UI, user-owned `config.yaml`, platform/install state. Background runtime treats this tree as read-mostly.
- `/jffs/goshacrash/manual-stop` — persistent manual-stop flag; changed only by explicit `gc stop`/`gc start`/`gc restart`.
- `<USB>/asusware.*` — ASUS Download Master / Optware tree. GoshaCrash runtime verifies it and can bind it to `/opt` without creating probe files or touching USB metadata.

## Explicit operations that can write USB

Zero USB writes cannot apply to installation or user-requested modifications. These operations intentionally write persistent storage:

- `install.sh` / update;
- editing `config.yaml`;
- explicit Optware package install/reinstall/update operations;
- ASUS Download Master or other ASUS services, which are outside GoshaCrash runtime.

## Filesystem guard

Runtime refuses to start if the selected USB is >=95% full, has less than 32 MiB free, or the current kernel log already contains matching EXT filesystem/I/O errors. The installer has the same filesystem-error guard before persistent writes.

## Unmount safety

The USB unmount hook stops GoshaCrash, releases the `/opt` bind mount and runs `sync` before returning to ASUSWRT. Lazy unmount is not used.
