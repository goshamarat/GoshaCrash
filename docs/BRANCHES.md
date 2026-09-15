# Ветки GoshaCrash

## Схема репозитория

- `main` — разработка, тесты и полная история проекта;
- `production` — чистый рабочий snapshot для реальных роутеров;
- tags — зафиксированные релизные точки.

Текущая рабочая версия: **GoshaCrash 4.0.1 production**.

В `install.sh` и `goshacrash.sh` production-ветка используется по умолчанию:

```sh
BRANCH="${BRANCH:-production}"
```

Публичный installer:

```text
https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/production/install.sh
```

## Важно: production содержит один commit

`production` не используется как обычная ветка разработки и не накапливает историю из `main`.

Вся история, тестовые файлы и промежуточные изменения остаются в `main`. При выпуске новой рабочей версии содержимое `production` заменяется новым чистым snapshot-коммитом.

Не нужно делать обычный `Merge pull request` из `main` в `production`, если цель — сохранить production с одним commit.

## Разработка

Работа ведётся в `main`:

```sh
git switch main
```

```sh
git pull --ff-only origin main
```

После тестирования из нужного состояния `main` собирается чистый production snapshot.

## Проверка production

```sh
git switch production
```

```sh
git log --oneline --decorate
```

В production должен быть один root commit текущей рабочей сборки, например:

```text
GoshaCrash 4.0.1 production
```

## Явный тест main через installer

Production installer можно временно запустить с другим источником без изменения файла:

```sh
BRANCH=main /bin/sh install.sh
```

На обычных роутерах default должен оставаться `production`.
