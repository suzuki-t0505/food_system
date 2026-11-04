#!/usr/bin/env bash
# Claude Code クラウド環境で Docker 開発環境を使えるようにするセットアップ。
# ローカル開発では不要。Dockerfile.dev / docker-compose.yml は変更しない。
#
# やること:
#   1. dockerd を起動
#   2. プロキシ用 CA と https の apt ソースを入れたベースイメージを作成
#   3. Dockerfile.dev をそのベースイメージでビルド
#   4. DB を起動
#   5. COMPOSE_FILE を ~/.bashrc に追記 (make mix_test などがそのまま使える)
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
CA_BUNDLE="${CCR_CA_BUNDLE:-/root/.ccr/ca-bundle.crt}"
BASE_TAG="food-cloud-base"
OVERRIDE="scripts/cloud/docker-compose.cloud.yml"

: "${HTTPS_PROXY:?HTTPS_PROXY が未設定です (クラウド環境専用スクリプトです)}"
[ -f "$CA_BUNDLE" ] || { echo "CA バンドルが見つかりません: $CA_BUNDLE" >&2; exit 1; }

# 1. dockerd
if ! docker info >/dev/null 2>&1; then
  nohup dockerd >/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 || { echo "dockerd の起動に失敗しました (/var/log/dockerd.log)" >&2; exit 1; }
fi

# 2. ベースイメージ (プロキシ URL は焼き込まず、ビルド時に build-arg で渡す)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$CA_BUNDLE" "$tmp/ca-bundle.crt"
cat >"$tmp/Dockerfile" <<'EOF'
ARG ELIXIR_VERSION=1.20.5-otp-29
FROM elixir:${ELIXIR_VERSION}
COPY ca-bundle.crt /usr/local/share/ca-certificates/ccr-ca.crt
RUN sed -i 's#http://deb.debian.org#https://deb.debian.org#g' /etc/apt/sources.list.d/*.sources \
 && update-ca-certificates
ENV HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
EOF
docker build --network host -t "$BASE_TAG" "$tmp"

# 3. Dockerfile.dev をビルド (docker-compose.yml と同じ target / イメージ名)
docker build -f Dockerfile.dev --target build_as_root --network host \
  --build-arg BASE_IMAGE="$BASE_TAG" --build-arg RUNNER_IMAGE="$BASE_TAG" \
  --build-arg HTTPS_PROXY="$HTTPS_PROXY" --build-arg HTTP_PROXY="${HTTP_PROXY:-$HTTPS_PROXY}" \
  --build-arg NO_PROXY="localhost,127.0.0.1" \
  -t food_system-food_vault_web .
docker tag food_system-food_vault_web food_system-food_ship_web

# 4. COMPOSE_FILE (以降の docker compose / make で override が自動適用される)
export COMPOSE_FILE="docker-compose.yml:${ROOT}/${OVERRIDE}"
line="export COMPOSE_FILE=\"docker-compose.yml:${ROOT}/${OVERRIDE}\""
grep -qxF "$line" ~/.bashrc 2>/dev/null || echo "$line" >>~/.bashrc

# 5. DB
docker compose up -d db

echo "完了。新しいシェルで 'make mix_test' が使えます (このシェルなら: $line)"
