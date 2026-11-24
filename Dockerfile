
# syntax=docker/dockerfile:1

# Этап 1: установка Python-зависимостей
FROM python:3.12.16-alpine3.24 AS builder

ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv "${VIRTUAL_ENV}"
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

WORKDIR /build
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt


# Этап 2: production-образ
FROM python:3.12.16-alpine3.24 AS prod

# Данные из seed-файла
ARG LAB_LOGIN
ARG LAB_TOKEN

# Обязательные метки
LABEL org.lab.login="${LAB_LOGIN}" \
      org.lab.token="${LAB_TOKEN}"

# Настройки приложения
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000 \
    LAB_LOGIN="${LAB_LOGIN}" \
    LAB_TOKEN="${LAB_TOKEN}"

# Непривилегированный пользователь
RUN addgroup -S app && adduser -S -D -H -G app app

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app app/ /app/

USER app
EXPOSE 8000
STOPSIGNAL SIGTERM

# Проверка GET /health
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]

# --preload учитывает обработчик SIGTERM в исходном app.py
# /dev/shm позволяет работать с read-only файловой системой
ENTRYPOINT ["gunicorn", "--preload", "--bind=0.0.0.0:8000", "--workers=2", "--worker-tmp-dir=/dev/shm", "--graceful-timeout=30", "--access-logfile=-", "--error-logfile=-", "app:app"]
