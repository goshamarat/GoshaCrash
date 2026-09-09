# Ветки GoshaCrash

## Рекомендуемая схема

Если хочется отделить рабочий production от разработки:

- `production` — то, что ставится на реальные роутеры;
- `main` — текущая разработка / тестирование;
- Git tags — зафиксированные релизные точки.

Это удобнее, чем постоянно откатывать `main`: рабочая сборка остаётся доступной на отдельной ветке, а `main` можно менять независимо.

## Как перенести текущий production из `main`

Сначала убедиться, что локальный `main` соответствует нужному production-коммиту:

```sh
git switch main
```

```sh
git pull --ff-only origin main
```

Создать ветку production ровно из текущего состояния:

```sh
git switch -c production
```

Опубликовать её:

```sh
git push -u origin production
```

После этого production уже сохранён отдельно.

## Если `main` действительно нужно откатить

Сначала найти нужный коммит:

```sh
git log --oneline --decorate -20
```

Затем переключиться обратно на `main`:

```sh
git switch main
```

Локально поставить `main` на нужный коммит:

```sh
git reset --hard <GOOD_COMMIT>
```

И только после проверки обновить remote:

```sh
git push --force-with-lease origin main
```

Использовать именно `--force-with-lease`, а не обычный `--force`.

## Что нужно поменять перед переводом installer на production

Сейчас в `install.sh` используется:

```sh
BRANCH="${BRANCH:-main}"
```

И README скачивает `install.sh` из `main`.

После создания и проверки ветки `production` есть два варианта.

### Вариант 1 — production становится дефолтом

В production-сборке заменить default branch на:

```sh
BRANCH="${BRANCH:-production}"
```

И публичную ссылку установки направить на:

```text
https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/production/install.sh
```

Для теста main тогда запускать явно:

```sh
BRANCH=main /bin/sh install.sh
```

### Вариант 2 — пока оставить main дефолтом

Ничего в коде не менять. Ветка `production` будет просто безопасной копией текущего рабочего состояния, пока не будет принято окончательное решение.

## Что я рекомендую для этого проекта

Сначала создать `production` из текущей рабочей `3.10.2-rc40-test2`, проверить установку с этой ветки на одном BT10, и только после этого менять default `BRANCH` и публичную ссылку README. Так существующие установки не окажутся привязаны к ветке, которой ещё нет или в которой лежит несовместимый controller.
