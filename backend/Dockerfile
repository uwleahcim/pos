# The one backend image: the same image runs on every hub and in the cloud.
# Build from this directory:  docker build -t pos-backend .
FROM python:3.12-slim AS build
WORKDIR /src
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir --prefix=/install .

# The face sign-in models (pos/identity/faces.py), from the InsightFace model zoo: the SCRFD-500MF detector out
# of buffalo_sc and the ArcFace ResNet-50 recognizer out of buffalo_l, pinned by checksum. Downloaded once per
# machine (the layer is cached) and baked into the image, so a hub needs no internet to sign staff in.
FROM python:3.12-slim AS models
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /models
RUN curl -fsSL --retry 5 -o sc.zip https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip \
  && echo "57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72  sc.zip" | sha256sum -c - \
  && unzip -q sc.zip det_500m.onnx && rm sc.zip \
  && curl -fsSL --retry 5 -o l.zip https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip \
  && echo "80ffe37d8a5940d59a7384c201a2a38d4741f2f3c51eef46ebb28218a7b0ca2f  l.zip" | sha256sum -c - \
  && unzip -q l.zip w600k_r50.onnx && rm l.zip

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
# A font that covers Chinese, for kitchen tickets printed as images; zone data so TZ gives the restaurant's time;
# the ssh client for the hub's tunnel to the PBX (the `pbx` service in infra/hub/docker-compose.yml).
RUN apt-get update && apt-get install -y --no-install-recommends fonts-wqy-zenhei tzdata openssh-client \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --create-home --home-dir /app pos
COPY --from=build /install /usr/local
COPY --from=models /models /app/models
ENV POS_FACE_MODELS=/app/models
WORKDIR /app
USER pos
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
# The operation log lives in PostgreSQL (DATABASE_URL); more workers are safe, one is plenty for a hub.
# Asked to stop, the API ends the screens' streams itself (pos.api.feed); the three seconds are for whatever
# else is still held open then (a desk-phone watcher's long poll), so a restart never waits to be killed.
CMD ["uvicorn", "pos.api.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--timeout-graceful-shutdown", "3"]
