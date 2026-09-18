# Build context is the repository root:
#   docker build -f deploy/dokploy/Dockerfile .
FROM rust:1-bookworm AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked --features http

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin mcp \
 && mkdir -p /data && chown mcp:mcp /data
COPY --from=builder /src/target/release/mcp-google-ads /usr/local/bin/mcp-google-ads
COPY deploy/dokploy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh
USER mcp
WORKDIR /data
ENV MCP_TRANSPORT=http \
    PORT=8080 \
    GOOGLE_ADS_CREDENTIALS_PATH=/data/credentials.json \
    GOOGLE_ADS_TOKEN_PATH=/data/token.json \
    GOOGLE_ADS_AUDIT_LOG=/data/audit.log \
    RUST_LOG=info
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
