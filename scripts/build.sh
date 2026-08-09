#!/usr/bin/env bash
set -euo pipefail

IMAGE="selcuksan/sre-case-app"
VERSION="0.4.0"
CLUSTER_NAME="sre-case"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">> Image build ediliyor: ${IMAGE}:${VERSION}"
docker build -t "${IMAGE}:${VERSION}" -t "${IMAGE}:latest" "${ROOT_DIR}/app"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo ">> Image kind cluster'ina yukleniyor..."
  kind load docker-image "${IMAGE}:${VERSION}" --name "${CLUSTER_NAME}"
fi

if [[ "${1:-}" == "push" ]]; then
  if ! docker push "${IMAGE}:${VERSION}"; then
    echo "HATA: push basarisiz. Once 'docker login' calistirin." >&2
    exit 1
  fi
  docker push "${IMAGE}:latest"
fi

echo ">> Hazir: ${IMAGE}:${VERSION}"
