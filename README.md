# Лабораторная работа: продакшн-образы Docker

## Цель работы

Цель работы --- подготовка production-образа для Flask-приложения с
учётом требований к размеру, безопасности, конфигурации и корректному
завершению контейнера.

Итоговый образ: - имеет размер менее 150 MB; - использует
непривилегированного пользователя; - содержит настроенный
`HEALTHCHECK`; - корректно обрабатывает сигнал `SIGTERM`; - запускается
с файловой системой только для чтения; - получает параметры приложения
через переменные окружения без пересборки; - содержит обязательные
Docker LABEL; - публикуется в Docker Hub.

## Структура проекта

``` text
02_docker_image_lab/
├── app/
│   └── app.py
├── requirements.txt
├── Dockerfile
├── .dockerignore
├── .gitignore
├── README.md
└── seed-<login>.json
```

Файл `seed-<login>.json` содержит персональные параметры лабораторной
работы. Он хранится локально и исключается из Git и Docker build
context.

## Требования к окружению

Команды в этом документе предназначены для Windows PowerShell. Docker
Desktop должен быть запущен, а Docker CLI доступен в терминале.

Рабочая директория команд --- корень проекта `02_docker_image_lab`.

## Загрузка параметров из seed-файла

Следующий блок находит единственный файл `seed-*.json`, считывает
значения `login`, `token` и `prefix`, проверяет их наличие и
соответствие префикса первым восьми символам токена. На основании этих
значений формируется имя Docker-образа.

``` powershell
$SeedFiles = @(Get-ChildItem -File -Filter "seed-*.json")
if ($SeedFiles.Count -ne 1) {
    throw "Ожидался один seed-файл. Найдено: $($SeedFiles.Count)"
}

$SEED_JSON = $SeedFiles[0].FullName
$Seed = Get-Content -Raw -Path $SEED_JSON | ConvertFrom-Json

$LOGIN = [string]$Seed.login
$TOKEN = [string]$Seed.token
$PREFIX = [string]$Seed.prefix

if ([string]::IsNullOrWhiteSpace($LOGIN) -or
    [string]::IsNullOrWhiteSpace($TOKEN) -or
    [string]::IsNullOrWhiteSpace($PREFIX)) {
    throw "В seed-файле отсутствует login, token или prefix."
}

if ($TOKEN.Length -lt 8 -or $PREFIX -cne $TOKEN.Substring(0, 8)) {
    throw "Поле prefix не совпадает с первыми восемью символами token."
}

$IMAGE = "${LOGIN}/image-lab:${PREFIX}"
```

## Сборка Docker-образа

Dockerfile использует multi-stage-сборку. На этапе `builder` создаётся
виртуальное окружение и устанавливаются Python-зависимости. В итоговый
этап копируются только виртуальное окружение и файлы приложения.

Команда передаёт значения `LAB_LOGIN` и `LAB_TOKEN` в качестве build
arguments и присваивает образу имя, сформированное из seed-файла.

``` powershell
docker build `
  --build-arg "LAB_LOGIN=$LOGIN" `
  --build-arg "LAB_TOKEN=$TOKEN" `
  -t "$IMAGE" .
```

## Проверка метаданных образа

### Docker LABEL

Следующий блок получает LABEL из конфигурации образа и сравнивает их со
значениями seed-файла.

``` powershell
$labelsJson = docker image inspect $IMAGE --format '{{json .Config.Labels}}'
$labels = $labelsJson | ConvertFrom-Json

$actualLogin = [string]$labels.PSObject.Properties['org.lab.login'].Value
$actualToken = [string]$labels.PSObject.Properties['org.lab.token'].Value

if ($actualLogin -cne $LOGIN) {
    throw "LABEL org.lab.login не совпадает с seed-файлом."
}
if ($actualToken -cne $TOKEN) {
    throw "LABEL org.lab.token не совпадает с seed-файлом."
}

Write-Host "Login LABEL is correct."
Write-Host "Token LABEL is correct."
```

### Пользователь контейнера

Команда выводит пользователя, указанного в конфигурации образа. Значение
`app` подтверждает, что приложение запускается не от `root`.

``` powershell
docker image inspect $IMAGE --format '{{.Config.User}}'
```

### HEALTHCHECK

Команда выводит конфигурацию проверки состояния. Проверка отправляет
HTTP-запрос на `/health` внутри контейнера.

``` powershell
docker image inspect $IMAGE --format '{{json .Config.Healthcheck}}'
```

## Проверка контейнера

### Запуск с файловой системой только для чтения

Команда запускает контейнер с параметром `--read-only`, задаёт
`ROCKET_SIZE=Big` и публикует порт контейнера `8000` на локальный порт
`8080`.

``` powershell
docker rm -f image-lab-test2>$null

docker run -d `
  --name image-lab-test `
  --read-only `
  -e ROCKET_SIZE=Big `
  -p 8080:8000 `
  $IMAGE
```

### Проверка HTTP-ответа приложения

Корневой маршрут возвращает приветствие и значение `ROCKET_SIZE`.

``` powershell
(Invoke-WebRequest -UseBasicParsing http://localhost:8080/).Content
```

Ожидаемый ответ при `ROCKET_SIZE=Big`:

``` text
Hello from Docker! Rocket=Big
```

Маршрут `/health` возвращает JSON со статусом приложения и временем его
работы.

``` powershell
Invoke-RestMethod http://localhost:8080/health
```

### Проверка HEALTHCHECK и read-only

Пауза позволяет Docker выполнить несколько циклов проверки состояния.
После этого первая команда выводит статус health check, а вторая
подтверждает настройку read-only root filesystem.

``` powershell
Start-Sleep -Seconds 12
docker inspect image-lab-test --format '{{.State.Health.Status}}'
docker inspect image-lab-test --format '{{.HostConfig.ReadonlyRootfs}}'
```

Ожидаемые значения:

``` text
healthy
true
```

### Проверка корректного завершения по SIGTERM

Команда останавливает контейнер с периодом ожидания 35 секунд. Код
завершения `0` и сообщения в логах подтверждают штатное завершение
Gunicorn после получения `SIGTERM`.

``` powershell
docker stop -t 35 image-lab-test
docker inspect image-lab-test --format '{{.State.ExitCode}}'
docker logs image-lab-test
```

### Проверка изменения конфигурации без пересборки

Контейнер запускается повторно с `ROCKET_SIZE=Small`. Используется тот
же Docker-образ, поэтому пересборка не требуется.

``` powershell
docker rm -f image-lab-test 2>$null
docker run -d --name image-lab-test --read-only -e ROCKET_SIZE=Small -p 8080:8000 $IMAGE
Start-Sleep -Seconds 2
(Invoke-WebRequest -UseBasicParsing http://localhost:8080/).Content
```

Ожидаемый ответ:

``` text
Hello from Docker! Rocket=Small
```

## Проверка размера образа

Команда получает размер образа в байтах, переводит значение в мегабайты
и сравнивает его с ограничением 150 MB.

``` powershell
$SIZE = docker image inspect $IMAGE --format '{{.Size}}'
$SIZE_MB = [math]::Round(([double]$SIZE / 1MB), 2)

Write-Host "Image size: $SIZE_MB MB"

if ([double]$SIZE -lt 150000000) {
    Write-Host "PASS: меньше 150 MB" -ForegroundColor Green
} else {
    Write-Host "FAIL: размер больше 150 MB" -ForegroundColor Red
}
```

## История слоёв образа

Команда `docker history` выводит историю слоёв образа. Результат
одновременно отображается в терминале и сохраняется в
`docker-history.txt`.

``` powershell
docker history $IMAGE | Tee-Object -FilePath docker-history.txt
```

## Публикация в Docker Hub

Перед публикацией выполняется вход в Docker Hub. Образ отправляется в
репозиторий с именем `image-lab` в пространстве имён Docker Hub,
соответствующем `$LOGIN`.

``` powershell
docker login
docker push $IMAGE
```

После успешной публикации страница образа доступна по адресу:

``` text
https://hub.docker.com/r/<login>/image-lab
```

Для выполнения требования о публичной публикации репозиторий `image-lab`
должен иметь статус Public.

## Защита служебных файлов

Файл `.dockerignore` исключает seed-файл из Docker build context:

``` text
seed-*.json
```

Файл `.gitignore` также исключает `seed-*.json` из Git. Персональный
seed-файл не включается в публичный репозиторий.

## Результаты проверки

В ходе проверки собранный образ показал следующие результаты:

  -----------------------------------------------------------------------
  Проверка                            Результат
  ----------------------------------- -----------------------------------
  Размер образа                       96,69 MB --- соответствует
                                      ограничению менее 150 MB

  Docker LABEL `org.lab.login`        Совпадает со значением из
                                      seed-файла

  Docker LABEL `org.lab.token`        Совпадает со значением из
                                      seed-файла

  Пользователь контейнера             `app`, не `root`

  HEALTHCHECK                         Настроен; состояние контейнера
                                      `healthy`

  Файловая система толькодля чтения  `ReadonlyRootfs = true`

  HTTP-маршрут `/` при                Возвращает
  `ROCKET_SIZE=Big`                   `Hello from Docker! Rocket=Big`

  HTTP-маршрут `/` при                Возвращает
  `ROCKET_SIZE=Small`                 `Hello from Docker! Rocket=Small`
                                      без пересборки образа

  HTTP-маршрут `/health`              Возвращает статус `ok`

  Завершение по SIGTERM               Контейнер завершился с кодом `0`
  -----------------------------------------------------------------------

Публикация в Docker Hub подтверждается успешным выполнением
`docker push` и доступностью публичной страницы образа.