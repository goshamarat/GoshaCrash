# Changelog

## 3.10.2-rc40-test2

Текущая публичная версия намеренно остаётся **3.10.2-rc40-test2**.

- Публичный online bootstrap переведён на ветку `production`; `main` остаётся для разработки и тестов.

### Runtime и routing

- BT10 использует native Mihomo `auto-route + auto-redirect + dns-hijack` без выдуманного fallback table.
- Runtime проверяет не только наличие `tun0`, но и фактическую готовность native policy routing / redirect / DNS hijack.
- Dynamic USB paths пересчитываются после каждого монтирования и не зависят от постоянного имени `sda/sdb` или mount label.
- Coldboot не должен делать второй лишний Internet probe перед запуском runtime.

### Config

- `config.yaml` создаётся только если отсутствует.
- Обычная переустановка не заменяет пользовательский конфиг.
- Невалидный конфиг не восстанавливается автоматически из backup.
- Backup остаётся пассивным и используется только вручную.
- `gc edit` проверяет сохранённый YAML через `mihomo -t`.
- UTF-8 комментарии сохраняются.

### Nano / UTF-8

- Для Optware nano используется `LANG=en_US.UTF-8` и `LC_ALL=en_US.UTF-8`.
- `/jffs/configs/profile.add` используется как persistent locale hook.
- `/jffs/etc/profile` считается optional.

### MPTCP

- GoshaCrash больше не меняет MPTCP sysctl автоматически.
- Включённый или выключенный MPTCP не считается ошибкой watchdog/runtime сам по себе.
- `gc doctor` показывает текущее состояние.

### Menu

- Раздел Logs переведён на навигацию `↑/↓`.
- `Enter` открывает выбранный пункт.
- `Esc` возвращает из Logs в главное меню.

### Installer

- USB formatting полностью удалён из `install.sh`.
- Установщик работает от фактического текущего USB mountpoint.
- Локальный `goshacrash.sh` из той же сборки используется раньше online-download.
