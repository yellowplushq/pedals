#!/usr/bin/env bash
# Deploy the Pedals relay to Cloud Run (ARCHITECTURE.md "Relay deploy").
#
# Requires: gcloud authenticated with access to the project, billing enabled.
# Prints the service URL (https://...) on success; the wss:// endpoint is the
# same host with the scheme swapped.
set -euo pipefail

PROJECT="vigilant-willow-501102-i3"
REGION="asia-northeast1"
SERVICE="pedals-relay"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  --project "$PROJECT"

gcloud run deploy "$SERVICE" \
  --source "$REPO_ROOT/relay" \
  --project "$PROJECT" \
  --region "$REGION" \
  --allow-unauthenticated \
  --timeout 3600 \
  --max-instances 1 \
  --session-affinity

URL="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT" --region "$REGION" --format 'value(status.url)')"
mkdir -p "$REPO_ROOT/.artifacts"
printf '%s\n' "$URL" > "$REPO_ROOT/.artifacts/relay-url.txt"
echo "service URL: $URL (recorded in .artifacts/relay-url.txt)"
echo "relay URL:   ${URL/https:\/\//wss://}"
