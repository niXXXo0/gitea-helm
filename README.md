# gitea-helm

Helm-чарт: Gitea + PostgreSQL + бэкап по расписанию для локального кластера kind.

## Архитектура

```
                        ┌─ Ingress (gitea.local, traefik)
 браузер ───────────────┤
                        └─► Service gitea (ClusterIP :3000/:2222)
                              ├──► Pod gitea (Deployment, 2 реплики)
                              └──► Pod gitea                  │
 Pod gitea ──► Service postgres (headless) ──► postgres-0 (StatefulSet, PVC)
 CronJob backup (2:00) ──► архив файлов + pg_dump ──► PVC backup (хранение 14 дней)
```

## Установка

Потребуется: работающий кластер kind, настроенные `kubectl` и `helm`.

```bash
# 1. Собрать образ бэкапа
docker build -t gitea-backup:0.1.0 backup-image/

# 2. Загрузить его в kind (без этого CronJob не сможет стартовать)
kind load docker-image gitea-backup:0.1.0

# 3. Создать values-файл и задать пароль БД
cp values-dev.yaml.example values-dev.yaml
#   открыть values-dev.yaml и заменить REPLACE_ME на свой пароль

# 4. Установить (одна команда)
helm upgrade --install gitea . -n gitea -f values-dev.yaml --create-namespace

# 5. Проверить, что всё поднялось
kubectl get pods -n gitea
#   ожидается: два пода gitea и postgres-0 — все Running, READY 1/1

# 6. Открыть в браузере
kubectl port-forward -n gitea svc/gitea 3000:3000
#   → http://127.0.0.1:3000
```

Первый запуск занимает 1–2 минуты: init-контейнер выставляет права на PVC,
затем gitea инициализирует БД. Пароль БД берётся из `values-dev.yaml`
(файл в `.gitignore`, в репозиторий не попадает; для своего Secret есть
параметр `postgres.existingSecret`).

Проверка изнутри кластера:

```bash
kubectl run -n gitea -i --rm --restart=Never --image=busybox:1.36 check \
  -- sh -c 'wget -q -O- -T 3 http://gitea.gitea.svc:3000/api/healthz'
#   ожидается: {"status":"pass", ...}
```

## Обновление и откат

```bash
helm upgrade gitea . -n gitea -f values-dev.yaml   # обновить
helm history gitea -n gitea                        # список ревизий
helm rollback gitea <ревизия> -n gitea             # откат
```

Обновление проходит без простоя: стратегия RollingUpdate с
`maxUnavailable: 0`, новый под становится готов до остановки старого.
Проверено замером: 0 ошибок из 110 запросов к `/api/healthz` во время upgrade.

## Бэкап

CronJob `gitea-gitea-helm-backup` запускается ночью в 2:00: останавливает gitea,
снимает архив файлов и дамп БД в PVC `gitea-gitea-helm-backup`. Бэкапы старше
14 дней удаляются автоматически.

```bash
# запустить бэкап вручную и посмотреть лог
kubectl create job manual-backup --from=cronjob/gitea-gitea-helm-backup -n gitea
kubectl logs -n gitea -l job-name=manual-backup -f
# ожидается в конце лога: "Backup completed successfully"
```

Восстановление проверено учебным прогоном: дамп заливается в чистый PostgreSQL
(`pg_restore --no-owner`), архив распаковывается на чистый PVC с владельцем
`1000:1000`, gitea стартует с восстановленных данных без переустановки
(проверено: `healthz`, главная и страница логина отдают 200).

## Встреченные проблемы

1. **`chown: Permission denied` в init-контейнере.** Gitea создаёт каталоги
   с правами 0700, а root без `CAP_DAC_OVERRIDE` (capabilities: CHOWN only)
   не может в них войти. Решение: добавить `DAC_OVERRIDE` и `FOWNER`.
2. **Бэкап делался, но Job падал.** `kubectl rollout status` в скрипте нужен
   глагол `list` на deployments, в RBAC были только `get`/`watch`. Добавлено.
3. **Вторая реплика не стартовала: блокировка LevelDB-очередей.** Два
   экземпляра gitea на общем PVC несовместимы. Решение: очереди в память,
   поиск и сессии — в PostgreSQL (см. `templates/configmap.yaml`).
4. **Отказ ClusterIP/DNS после перезапуска docker на хосте.** kube-proxy на
   ноде ушёл в CrashLoopBackOff, без его правил сломались все ClusterIP,
   CoreDNS отвечал NXDOMAIN на всё. Решение: `docker restart <kind-node>`.
   Диагностический подвох: `busybox nslookup` не применяет search-домены и
   показывает ложный NXDOMAIN — проверять DNS нужны `wget`/`ping`.
