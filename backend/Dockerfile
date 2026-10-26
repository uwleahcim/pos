# The one backend image: the same image runs on every hub and in the cloud.
# Build from this directory:  docker build -t pos-backend .
FROM python:3.12-slim AS build
WORKDIR /src
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir --prefix=/install .

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
# A font that covers Chinese, for kitchen tickets printed as images.
RUN apt-get update && apt-get install -y --no-install-recommends fonts-wqy-zenhei && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --create-home --home-dir /app pos
COPY --from=build /install /usr/local
WORKDIR /app
USER pos
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
# The operation log lives in PostgreSQL (DATABASE_URL); more workers are safe, one is plenty for a hub.
CMD ["uvicorn", "pos.api.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
