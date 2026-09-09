# Changelog

## 4.0.0 production

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
