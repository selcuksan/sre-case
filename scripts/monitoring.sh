#!/usr/bin/env bash
set -euo pipefail

NS="monitoring"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_if_missing() {
  local release="$1" chart="$2" values="$3"
  if helm status "$release" -n "$NS" >/dev/null 2>&1; then
    echo ">> ${release} zaten kurulu, atlaniyor."
  else
    echo ">> ${release} kuruluyor..."
    helm install "$release" "$chart" -n "$NS" --create-namespace \
      -f "${ROOT_DIR}/monitoring/${values}" --wait --timeout 10m
  fi
}

up() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community grafana open-telemetry >/dev/null

  install_if_missing kube-prometheus-stack prometheus-community/kube-prometheus-stack values-kube-prometheus-stack.yaml
  install_if_missing tempo grafana/tempo values-tempo.yaml
  # Collector en sona: hedefleri (Tempo, Prometheus) ayakta olsun.
  install_if_missing otel-collector open-telemetry/opentelemetry-collector values-otel-collector.yaml

  # Dashboard'u ConfigMap olarak yukle. Grafana'nin sidecar'i grafana_dashboard etiketli
  # ConfigMap'leri otomatik aliyor, arayuzden elle import gerekmiyor.
  echo ">> Dashboard yukleniyor..."
  kubectl create configmap sre-case-dashboard -n "$NS" \
    --from-file=dashboard.json="${ROOT_DIR}/grafana/dashboard.json" \
    --dry-run=client -o yaml \
    | kubectl label -f- --local -o yaml grafana_dashboard=1 \
    | kubectl apply -f -

  echo
  kubectl get pods -n "$NS"
  echo
  echo "Grafana: http://localhost:30300  (admin / admin)"
}

down() {
  helm uninstall otel-collector -n "$NS" 2>/dev/null || true
  helm uninstall tempo -n "$NS" 2>/dev/null || true
  helm uninstall kube-prometheus-stack -n "$NS" 2>/dev/null || true
  kubectl delete namespace "$NS" --ignore-not-found
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "Kullanim: $0 {up|down}" >&2; exit 1 ;;
esac
