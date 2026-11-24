# The one backend image: the same image runs on every hub and in the cloud.
# Build from this directory:  docker build -t pos-backend .

# Cloudflare's tunnel program, which a hub's `tunnel` service runs (pos/online/tunnel.py; docs/online-orders.md,
# "The way in"). Taken from Cloudflare's own image; `hubctl update` fetches the current one before it builds,
# so a hub has a current program after every update. POS_TUNNEL_IMAGE in /opt/pos/.env names another (a
# version to stay on).
ARG CLOUDFLARED_IMAGE=cloudflare/cloudflared:latest
FROM ${CLOUDFLARED_IMAGE} AS cloudflared

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
# the ssh client for the hub's tunnel to the PBX (the `pbx` service in infra/hub/docker-compose.yml); the
# certificates Cloudflare's program knows Cloudflare by.
RUN apt-get update && apt-get install -y --no-install-recommends fonts-wqy-zenhei tzdata openssh-client ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --create-home --home-dir /app pos
# Where a hub keeps the secret that opens the keys a manager typed in the app (pos/keys.py; the `pos-keys`
# volume in infra/hub/docker-compose.yml). A new volume takes the folder as it is here: the API's own, and
# nobody else's. The note is there so that it is not an empty folder, which not every Docker copies.
RUN install -d -m 0700 -o pos -g pos /keys \
  && echo "The secret this hub seals its keys with is kept here (pos/keys.py). Not part of any backup." > /keys/README \
  && chown pos:pos /keys/README
# Where the API leaves the push door its word and the tunnel its token (pos/online/wayin.py; the `pos-door` and
# `pos-tunnel` volumes). New volumes take the folders as they are here: the hub's own user's, and nobody else's.
RUN install -d -m 0700 -o pos -g pos /door /tunnel \
  && echo "The API tells the push door here which key a push must carry (its SHA-256, not the key)." > /door/README \
  && echo "The API leaves the tunnel its token here, and the tunnel says how it stands. Not part of any backup." > /tunnel/README \
  && chown pos:pos /door/README /tunnel/README
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
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
