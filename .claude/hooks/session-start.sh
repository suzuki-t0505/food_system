#!/bin/bash
# クラウド環境専用: セッション開始時に Docker 開発環境 (scripts/cloud/setup.sh) を用意する。
# 環境設定のセットアップスクリプトはビルド時に走り HTTPS_PROXY が無いため、ここで実行する。
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"
ROOT="$PWD"
export COMPOSE_FILE="docker-compose.yml:${ROOT}/scripts/cloud/docker-compose.cloud.yml"

if [ -z "${HTTPS_PROXY:-}" ]; then
  echo "HTTPS_PROXY が未設定のため Docker 環境のセットアップをスキップしました。" >&2
  exit 0
fi

# 入力ファイルが変わったとき、または dockerd・イメージ・DB のいずれかが無いときだけ実行する
state_dir="${HOME}/.cache/food_system"
hashes="${state_dir}/session-start.sha256"
mkdir -p "$state_dir"

needs_setup() {
  sha256sum --check --status "$hashes" 2>/dev/null || return 0
  docker info >/dev/null 2>&1 || return 0
  docker image inspect food_system-food_vault_web food_system-food_ship_web >/dev/null 2>&1 || return 0
  [ -n "$(docker compose ps --status running -q db 2>/dev/null)" ] || return 0
  return 1
}

if needs_setup; then
  rm -f "$hashes"
  log="${state_dir}/setup.log"
  if ! bash scripts/cloud/setup.sh >"$log" 2>&1; then
    echo "scripts/cloud/setup.sh が失敗しました。末尾のログ:" >&2
    tail -n 20 "$log" >&2
    exit 1
  fi
  sha256sum .claude/hooks/session-start.sh scripts/cloud/setup.sh scripts/cloud/docker-compose.cloud.yml \
    Dockerfile.dev docker-compose.yml >"$hashes"
fi

# 以降のシェルで make / docker compose に override を適用する
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export COMPOSE_FILE=\"${COMPOSE_FILE}\"" >>"$CLAUDE_ENV_FILE"
fi
