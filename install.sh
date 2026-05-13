#!/usr/bin/env bash
# Install / upgrade langfuse on ti-cloud TKE.
#
# Prerequisites:
#   - kubectl context points at the target TKE cluster
#   - ./.env.token exists (gitignored) with all required secret vars
#   - eg-tke Gateway already has the `http` listener (port 80, hostname *.jmpti.woa.com)
#
# Usage:
#   ./install.sh            # helm upgrade --install
#   ./install.sh dry-run    # helm template + kubectl apply --dry-run
#   ./install.sh uninstall  # helm uninstall + delete HTTPRoute

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/charts/langfuse"
NAMESPACE="${LANGFUSE_NAMESPACE:-ti-cloud-teamai}"
RELEASE="${LANGFUSE_RELEASE:-langfuse}"
HTTPROUTE_PATH="${SCRIPT_DIR}/deploy-ticloud/httproute.yaml"

if [[ ! -f "${SCRIPT_DIR}/.env.token" ]]; then
  echo "ERROR: ${SCRIPT_DIR}/.env.token not found. Copy .env.token.example and fill in secrets." >&2
  exit 1
fi

# Load secrets into the current shell.
set -a
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env.token"
set +a

required_vars=(
  NEXTAUTH_SECRET LANGFUSE_SALT LANGFUSE_ENCRYPTION_KEY
  REDIS_PASSWORD CLICKHOUSE_PASSWORD
  POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DATABASE
  COS_SECRET_ID COS_SECRET_KEY COS_BUCKET COS_REGION COS_ENDPOINT
)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: \$${v} is empty in .env.token" >&2
    exit 1
  fi
done

# Build --set overrides. Use --set-string for strings that might look numeric.
SETS=(
  --set-string "langfuse.salt.value=${LANGFUSE_SALT}"
  --set-string "langfuse.encryptionKey.value=${LANGFUSE_ENCRYPTION_KEY}"
  --set-string "langfuse.nextauth.secret.value=${NEXTAUTH_SECRET}"
  --set-string "postgresql.host=${POSTGRES_HOST}"
  --set-string "postgresql.auth.username=${POSTGRES_USER}"
  --set-string "postgresql.auth.password=${POSTGRES_PASSWORD}"
  --set-string "postgresql.auth.database=${POSTGRES_DATABASE}"
  --set-string "redis.auth.password=${REDIS_PASSWORD}"
  --set-string "clickhouse.auth.password=${CLICKHOUSE_PASSWORD}"
  --set-string "s3.bucket=${COS_BUCKET}"
  --set-string "s3.region=${COS_REGION}"
  --set-string "s3.endpoint=${COS_ENDPOINT}"
  --set-string "s3.accessKeyId.value=${COS_SECRET_ID}"
  --set-string "s3.secretAccessKey.value=${COS_SECRET_KEY}"
)

cmd="${1:-install}"

case "${cmd}" in
  install|upgrade)
    echo ">>> helm dependency update"
    helm dependency update "${CHART_DIR}"

    echo ">>> helm upgrade --install ${RELEASE} -n ${NAMESPACE}"
    helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
      --namespace "${NAMESPACE}" --create-namespace \
      -f "${CHART_DIR}/values-ticloud.yaml" \
      "${SETS[@]}"

    echo ">>> kubectl apply HTTPRoute"
    kubectl apply -f "${HTTPROUTE_PATH}"
    echo "Done. Watch progress: kubectl -n ${NAMESPACE} get pods -w"
    ;;
  dry-run|template)
    helm dependency update "${CHART_DIR}" 1>&2
    helm template "${RELEASE}" "${CHART_DIR}" \
      --namespace "${NAMESPACE}" \
      -f "${CHART_DIR}/values-ticloud.yaml" \
      "${SETS[@]}"
    ;;
  uninstall)
    kubectl delete -f "${HTTPROUTE_PATH}" --ignore-not-found
    helm uninstall "${RELEASE}" -n "${NAMESPACE}" || true
    echo "Note: PVCs (cbs-ssd-sc reclaim=Retain) and the namespace are preserved."
    echo "To wipe completely:"
    echo "  kubectl -n ${NAMESPACE} delete pvc --all"
    echo "  kubectl delete ns ${NAMESPACE}"
    ;;
  *)
    echo "Usage: $0 [install|upgrade|dry-run|uninstall]" >&2
    exit 2
    ;;
esac
