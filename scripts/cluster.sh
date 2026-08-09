#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sre-case"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/kind-config.yaml"

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "HATA: Docker daemon'a ulasilamiyor. Docker Desktop'i baslatip tekrar deneyin." >&2
    exit 1
  fi
}

up() {
  require_docker

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo ">> Cluster '${CLUSTER_NAME}' zaten var, olusturma adimi atlaniyor."
  else
    echo ">> Cluster olusturuluyor..."
    kind create cluster --config "${CONFIG_FILE}"
  fi

  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

  echo ">> Node'lar Ready bekleniyor..."
  kubectl wait --for=condition=Ready nodes --all --timeout=180s

  if helm status metrics-server -n kube-system >/dev/null 2>&1; then
    echo ">> metrics-server zaten kurulu, atlaniyor."
  else
    echo ">> metrics-server kuruluyor..."
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
    helm repo update metrics-server >/dev/null
    # kind kubelet'i self-signed sertifika kullanir; metrics-server bunu dogrulayamaz.
    helm install metrics-server metrics-server/metrics-server \
      --namespace kube-system \
      --set 'args={--kubelet-insecure-tls}' \
      --wait --timeout 180s
  fi

  echo ">> Metrik akisi bekleniyor..."
  for _ in $(seq 1 30); do
    kubectl top nodes >/dev/null 2>&1 && break
    sleep 5
  done

  status
}

down() {
  require_docker
  kind delete cluster --name "${CLUSTER_NAME}"
}

status() {
  echo
  kubectl get nodes -o wide
  echo
  kubectl top nodes
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "Kullanim: $0 {up|down|status}" >&2; exit 1 ;;
esac
