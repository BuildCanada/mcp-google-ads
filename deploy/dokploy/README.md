# Dokploy deployment (Build Canada)

Runs this server as an always-on HTTP service on Build Canada's Dokploy
(`https://nelson.canadasbuilding.com`) so Executor can call it. Upstream is
stdio-only; the fork adds a `http` cargo feature (`src/http.rs`) that serves
streamable HTTP at `/mcp` behind a bearer token, plus `/healthz`.

```
https://google-ads-mcp.svc.buildcanada.com/mcp      Authorization: Bearer <MCP_BEARER_TOKEN>
https://google-ads-mcp.svc.buildcanada.com/healthz  open
```

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Two-stage build, context = repo root, `cargo build --features http` |
| `entrypoint.sh` | Writes `GOOGLE_ADS_CREDENTIALS_JSON` to `/data/credentials.json`, then execs the binary |
| `dokploy.sh` | Idempotent provisioning through the Dokploy REST API (`create`, `env`, `deploy`) |
| `.env.production.example` | Template for the runtime environment; the real file is git-ignored |

## One-time setup

1. Generate a Dokploy API key: Dokploy → Settings → Profile → API/CLI.
2. `cp deploy/dokploy/.env.production.example deploy/dokploy/.env.production` and fill it in:
   - `MCP_BEARER_TOKEN`: `openssl rand -hex 32`. Store in 1Password (production-secrets) as
     `GOOGLE_ADS_MCP_BEARER_TOKEN`; the same value goes into the Executor connection.
   - `GOOGLE_ADS_DEVELOPER_TOKEN`: Google Ads → manager account 194-692-0796 → Tools & Settings → API Center.
   - `GOOGLE_ADS_CUSTOMER_ID`: the client account the tools should default to.
   - `GOOGLE_ADS_CREDENTIALS_JSON`: run `../../scripts/generate_token.sh <oauth-client.json>` with a
     *Desktop app* OAuth client from Google Cloud (Google Ads API enabled), then merge the client id,
     client secret and refresh token into one line:
     `{"type":"authorized_user","client_id":"…","client_secret":"…","refresh_token":"…"}`
3. `DOKPLOY_API_KEY=… ./deploy/dokploy/dokploy.sh all`

`dokploy.sh` creates the project "Google Ads MCP" if needed and the
application `google-ads-mcp` on the Dokploy host, points it at
`BuildCanada/mcp-google-ads@main` through the org's Dokploy GitHub app with
this Dockerfile, adds the Let's Encrypt domain, saves the env and triggers a
build. The hostname follows the `*.svc.buildcanada.com` convention of the
other Build Canada services. DNS is a **DNS-only** CNAME `google-ads-mcp.svc`
→ `nelson.canadasbuilding.com`, created through Dokploy's Cloudflare DNS
provider (`prod-cloudflare`, Settings → DNS providers, or the
`dnsProvider.*` API). It must stay unproxied: Cloudflare Universal SSL covers
`*.buildcanada.com` but not two-level names, so a proxied record fails the TLS
handshake at the edge. Traefik issues the Let's Encrypt certificate instead
(Dokploy domain certificateType `letsencrypt`).

## Redeploying

Pushing to `main` on the fork auto-deploys through the GitHub app webhook.
To force a rebuild: `DOKPLOY_API_KEY=… ./deploy/dokploy/dokploy.sh deploy`
(or press Deploy in the Dokploy UI).

Changing a secret: edit `.env.production`, run `dokploy.sh env`, then `dokploy.sh deploy`.

## Local check

```
MCP_TRANSPORT=http MCP_BEARER_TOKEN=dev PORT=8080 \
GOOGLE_ADS_DEVELOPER_TOKEN=x GOOGLE_ADS_CUSTOMER_ID=000-000-0000 \
cargo run --features http
curl -s localhost:8080/healthz
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/mcp        # 401
curl -s -X POST localhost:8080/mcp -H 'Authorization: Bearer dev' \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

## Executor

Register as a remote MCP integration: endpoint
`https://google-ads-mcp.svc.buildcanada.com/mcp`, transport streamable-http,
auth method "header" with header `Authorization` and prefix `Bearer `. Create
one org-level connection holding `MCP_BEARER_TOKEN`.
