use mcp_google_ads::config::Config;
use mcp_google_ads::error::Result;

use rmcp::ServiceExt;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .with_writer(std::io::stderr)
        .init();

    tracing::info!("Starting MCP Google Ads server");

    let config = Config::load()?;
    let server = mcp_google_ads::GoogleAdsMcp::new(config)?;

    // `MCP_TRANSPORT=http` serves streamable HTTP (feature `http`); anything
    // else keeps the upstream stdio behaviour.
    let transport_kind = std::env::var("MCP_TRANSPORT").unwrap_or_default();
    if transport_kind.eq_ignore_ascii_case("http") {
        return serve_http(server).await;
    }

    let transport = rmcp::transport::io::stdio();

    let service = server.serve(transport).await.map_err(|e| {
        mcp_google_ads::error::McpGoogleAdsError::Config(format!(
            "Failed to start MCP server: {}",
            e
        ))
    })?;

    service.waiting().await.map_err(|e| {
        mcp_google_ads::error::McpGoogleAdsError::Config(format!("Server error: {}", e))
    })?;

    Ok(())
}

#[cfg(feature = "http")]
async fn serve_http(server: mcp_google_ads::GoogleAdsMcp) -> Result<()> {
    let http = mcp_google_ads::http::HttpConfig::from_env()?;
    mcp_google_ads::http::serve(server, http).await
}

#[cfg(not(feature = "http"))]
async fn serve_http(_server: mcp_google_ads::GoogleAdsMcp) -> Result<()> {
    Err(mcp_google_ads::error::McpGoogleAdsError::Config(
        "MCP_TRANSPORT=http requires a build with `--features http`".to_string(),
    ))
}
