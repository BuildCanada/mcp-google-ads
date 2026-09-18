#!/usr/bin/env bash
# Provision (or re-point) the google-ads-mcp application on Dokploy.
#
# Usage:
#   DOKPLOY_API_KEY=… ./deploy/dokploy/dokploy.sh [create|env|deploy]
#
# Env:
#   DOKPLOY_URL         default https://nelson.canadasbuilding.com
#   DOKPLOY_API_KEY     required (Dokploy → Settings → Profile → API/CLI)
#   DOKPLOY_PROJECT     project name to create the app in (default: "Google Ads MCP")
#   DOKPLOY_ENVIRONMENT environment name inside the project (default: production)
#   DOKPLOY_SERVER_IP   pick the Dokploy server whose IP matches (default: 66.70.179.6)
#   APP_HOST            public hostname (default: google-ads-mcp.canadasbuilding.com)
#   ENV_FILE            path to a KEY=VALUE file for `env` (default: deploy/dokploy/.env.production)
set -euo pipefail

DOKPLOY_URL="${DOKPLOY_URL:-https://nelson.canadasbuilding.com}"
DOKPLOY_PROJECT="${DOKPLOY_PROJECT:-Google Ads MCP}"
DOKPLOY_ENVIRONMENT="${DOKPLOY_ENVIRONMENT:-production}"
DOKPLOY_SERVER_IP="${DOKPLOY_SERVER_IP:-66.70.179.6}"
APP_HOST="${APP_HOST:-google-ads-mcp.canadasbuilding.com}"
APP_NAME="google-ads-mcp"
REPO_URL="https://github.com/BuildCanada/mcp-google-ads.git"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env.production}"
: "${DOKPLOY_API_KEY:?set DOKPLOY_API_KEY}"

api() { # api METHOD path [json]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$DOKPLOY_URL/api/$path" -H "x-api-key: $DOKPLOY_API_KEY" \
      -H 'content-type: application/json' --data "$body"
  else
    curl -fsS -X "$method" "$DOKPLOY_URL/api/$path" -H "x-api-key: $DOKPLOY_API_KEY"
  fi
}

find_app_id() {
  api GET project.all | jq -r --arg n "$APP_NAME" \
    '.[].environments[]?.applications[]? | select(.appName==$n or .name==$n) | .applicationId' | head -1
}

cmd_create() {
  local projects project_id env_id server_id app_id
  projects="$(api GET project.all)"
  project_id="$(jq -r --arg n "$DOKPLOY_PROJECT" '.[] | select(.name==$n) | .projectId' <<<"$projects" | head -1)"
  if [ -z "$project_id" ]; then
    echo "Creating project '$DOKPLOY_PROJECT'"
    project_id="$(api POST project.create "$(jq -nc --arg n "$DOKPLOY_PROJECT" '{name:$n,description:"Google Ads MCP server for Executor"}')" | jq -r '.projectId')"
    projects="$(api GET project.all)"
  fi
  env_id="$(jq -r --arg p "$project_id" --arg e "$DOKPLOY_ENVIRONMENT" \
    '.[] | select(.projectId==$p) | .environments[] | select(.name==$e) | .environmentId' <<<"$projects" | head -1)"
  [ -n "$env_id" ] || { echo "no environment '$DOKPLOY_ENVIRONMENT' in project"; exit 1; }
  server_id="$(api GET server.all | jq -r --arg ip "$DOKPLOY_SERVER_IP" '.[] | select(.ipAddress==$ip) | .serverId' | head -1)"
  [ -n "$server_id" ] || { echo "no Dokploy server with IP $DOKPLOY_SERVER_IP"; api GET server.all | jq -r '.[] | "\(.name) \(.ipAddress) \(.serverId)"'; exit 1; }

  app_id="$(find_app_id)"
  if [ -z "$app_id" ]; then
    echo "Creating application $APP_NAME"
    app_id="$(api POST application.create "$(jq -nc --arg n "$APP_NAME" --arg e "$env_id" --arg s "$server_id" \
      '{name:$n,appName:$n,description:"FGRibreau/mcp-google-ads over streamable HTTP",environmentId:$e,serverId:$s}')" | jq -r '.applicationId')"
  else
    echo "Application exists: $app_id"
  fi

  api POST application.saveGitProvider "$(jq -nc --arg a "$app_id" --arg u "$REPO_URL" \
    '{applicationId:$a,customGitUrl:$u,customGitBranch:"main",customGitBuildPath:"/",enableSubmodules:false}')" >/dev/null
  api POST application.saveBuildType "$(jq -nc --arg a "$app_id" \
    '{applicationId:$a,buildType:"dockerfile",dockerfile:"deploy/dokploy/Dockerfile",dockerContextPath:".",dockerBuildStage:"",herokuVersion:"",railpackVersion:""}')" >/dev/null

  if ! api GET "application.one?applicationId=$app_id" | jq -e --arg h "$APP_HOST" '.domains[]? | select(.host==$h)' >/dev/null; then
    echo "Adding domain $APP_HOST"
    api POST domain.create "$(jq -nc --arg a "$app_id" --arg h "$APP_HOST" \
      '{applicationId:$a,host:$h,port:8080,https:true,certificateType:"letsencrypt",domainType:"application",path:"/"}')" >/dev/null
  fi
  echo "applicationId=$app_id"
}

cmd_env() {
  local app_id env_text
  app_id="$(find_app_id)"; [ -n "$app_id" ] || { echo "app not found; run create"; exit 1; }
  [ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE"; exit 1; }
  env_text="$(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')"
  api POST application.saveEnvironment "$(jq -nc --arg a "$app_id" --arg e "$env_text" \
    '{applicationId:$a,env:$e,buildArgs:"",buildSecrets:"",createEnvFile:false}')" >/dev/null
  echo "environment saved ($(wc -l <<<"$env_text" | tr -d ' ') vars)"
}

cmd_deploy() {
  local app_id
  app_id="$(find_app_id)"; [ -n "$app_id" ] || { echo "app not found; run create"; exit 1; }
  api POST application.deploy "$(jq -nc --arg a "$app_id" '{applicationId:$a}')" >/dev/null
  echo "deploy queued; watch $DOKPLOY_URL/dashboard and #deployments"
}

case "${1:-all}" in
  create) cmd_create ;;
  env) cmd_env ;;
  deploy) cmd_deploy ;;
  all) cmd_create; cmd_env; cmd_deploy ;;
  *) echo "usage: $0 [create|env|deploy|all]"; exit 2 ;;
esac
