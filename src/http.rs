//! Streamable HTTP transport (cargo feature `http`).
//!
//! Serves the same tool surface as the stdio transport over HTTP so the
//! server can run as a long-lived service. Every request under `/mcp` must
//! carry `Authorization: Bearer <MCP_BEARER_TOKEN>`; `/healthz` is open.
//!
//! | Env var | Default | Purpose |
//! |---|---|---|
//! | `MCP_BEARER_TOKEN` | *required* | Shared secret clients must present |
//! | `PORT` | `8080` | TCP port to listen on |
//! | `MCP_BIND` | `0.0.0.0` | Interface to bind |
//! | `MCP_ALLOWED_HOSTS` | (none) | Extra `Host` values accepted, comma-separated. rmcp rejects unknown hosts (DNS-rebinding guard), so list the public hostname here. |

use std::sync::Arc;

use axum::extract::{Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use rmcp::transport::streamable_http_server::session::local::LocalSessionManager;
use rmcp::transport::{StreamableHttpServerConfig, StreamableHttpService};

use crate::error::{McpGoogleAdsError, Result};
use crate::GoogleAdsMcp;

#[derive(Debug, Clone)]
pub struct HttpConfig {
    pub bind: String,
    pub bearer_token: String,
    pub allowed_hosts: Vec<String>,
}

impl HttpConfig {
    pub fn from_env() -> Result<Self> {
        let port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string());
        let bind_addr = std::env::var("MCP_BIND").unwrap_or_else(|_| "0.0.0.0".to_string());
        let bearer_token = std::env::var("MCP_BEARER_TOKEN")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .ok_or_else(|| {
                McpGoogleAdsError::Config(
                    "MCP_BEARER_TOKEN must be set when MCP_TRANSPORT=http".to_string(),
                )
            })?;

        let mut allowed_hosts: Vec<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
            .iter()
            .flat_map(|h| [h.to_string(), format!("{h}:{port}")])
            .collect();
        if let Ok(extra) = std::env::var("MCP_ALLOWED_HOSTS") {
            allowed_hosts.extend(
                extra
                    .split(',')
                    .map(str::trim)
                    .filter(|h| !h.is_empty())
                    .map(str::to_string),
            );
        }

        Ok(Self {
            bind: format!("{bind_addr}:{port}"),
            bearer_token,
            allowed_hosts,
        })
    }
}

/// Byte-wise comparison that does not short-circuit on the first mismatch.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn require_bearer(
    State(token): State<Arc<String>>,
    request: Request,
    next: Next,
) -> Response {
    let presented = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim);

    match presented {
        Some(p) if constant_time_eq(p.as_bytes(), token.as_bytes()) => next.run(request).await,
        _ => (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Bearer")],
            "unauthorized",
        )
            .into_response(),
    }
}

/// Serve `server` over streamable HTTP until the process is stopped.
pub async fn serve(server: GoogleAdsMcp, http: HttpConfig) -> Result<()> {
    let config =
        StreamableHttpServerConfig::default().with_allowed_hosts(http.allowed_hosts.clone());
    let mcp_service: StreamableHttpService<GoogleAdsMcp, LocalSessionManager> =
        StreamableHttpService::new(
            move || Ok(server.clone()),
            Arc::new(LocalSessionManager::default()),
            config,
        );

    let token = Arc::new(http.bearer_token.clone());
    let protected = Router::new()
        .nest_service("/mcp", mcp_service)
        .layer(middleware::from_fn_with_state(token, require_bearer));

    let app: Router = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .merge(protected);

    let listener = tokio::net::TcpListener::bind(&http.bind)
        .await
        .map_err(|e| McpGoogleAdsError::Config(format!("Failed to bind {}: {e}", http.bind)))?;
    tracing::info!(bind = %http.bind, "Serving MCP over streamable HTTP at /mcp");

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await
    .map_err(|e| McpGoogleAdsError::Config(format!("HTTP server error: {e}")))?;

    Ok(())
}
