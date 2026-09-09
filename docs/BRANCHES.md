# Ветки GoshaCrash

## Текущая схема

- `production` — рабочая ветка для реальных роутеров;
- `main` — разработка и тестирование;
- Git tags — зафиксированные релизные точки.

Публичная сборка **3.10.2-rc40-test2** использует `production` как default branch для online bootstrap и обновления связанных файлов.

В `install.sh`:

```sh
BRANCH="${BRANCH:-production}"
```

Публичный installer:

```text
https://raw.githubusercontent.com/goshamarat/GoshaCrash/refs/heads/production/install.sh
```

## Обычный цикл разработки

Работу вести в `main`:

```sh
git switch main
```

```sh
git pull --ff-only origin main
```

После проверки изменений переносить их в `production` через Pull Request `main -> production`. Перед merge обязательно просмотреть diff.

## Проверка production локально

```sh
git switch production
```

```sh
git pull --ff-only origin production
```

```sh
git log --oneline --decorate -10
```

## Явный тест main через installer

Production installer можно временно запустить с другим источником, не меняя файл:

```sh
BRANCH=main /bin/sh install.sh
```

Это предназначено для тестов. На обычных роутерах default должен оставаться `production`.

## Если production нужно откатить

Сначала найти известный рабочий коммит:

```sh
git log --oneline --decorate -20
```

Переключиться на production:

```sh
git switch production
```

Поставить локальную ветку на нужный коммит:

```sh
git reset --hard <GOOD_COMMIT>
```

После проверки обновить remote:

```sh
git push --force-with-lease origin production
```

Использовать `--force-with-lease`, а не обычный `--force`.

## Важно

Не откатывать `main` только ради сохранения рабочего production. Рабочая версия уже изолирована в `production`, поэтому `main` можно развивать независимо.
