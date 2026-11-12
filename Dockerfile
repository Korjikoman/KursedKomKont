FROM python:3.13-slim-trixie

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

COPY migrate.py .
USER 10001:10001
CMD ["python", "migrate.py"]
