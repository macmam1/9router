#!/bin/bash
# =============================================================================
# ModelScope Studio Entrypoint for 9Router + Cloudflare Tunnel + Tailscale Funnel
# =============================================================================
# Modes:
#  - Cloudflare Quick Tunnel: no auth, no credit card, URL changes on restart
#  - Cloudflare Named Tunnel: stable URL, requires Zero Trust token
#  - Tailscale Funnel: stable URL, requires tailscaled + auth
#
# Setup:
#  1. Set this file as Studio Entrypoint: /app/docker-entrypoint.sh
#  2. Optional Env Vars in Studio Console:
#     - CLOUDFLARE_TUNNEL_TOKEN
#     - TUNNEL_URL_WEBHOOK
#     - TAILSCALE_AUTH_KEY
#     - TAILSCALE_HOSTNAME
# =============================================================================

set -e

# ---- COLORS ----
GREEN='\033[92m'
RED='\033[91m'
YELLOW='\033[93m'
BLUE='\033[94m'
CYAN='\033[96m'
RESET='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${RESET} $*"; }
log_ok() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅${RESET} $*"; }
log_warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️${RESET} $*"; }
log_err() { echo -e "${RED}[$(date '+%H:%M:%S')] ❌${RESET} $*"; }

# ---- CONFIG ----
APP_PORT="${PORT:-7860}"
TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
WEBHOOK_URL="${TUNNEL_URL_WEBHOOK:-}"
CLOUDFLARED_DIR="/app/.cloudflared"
TUNNEL_URL_FILE="/app/tunnel_url.txt"
STARTUP_WAIT_MAX=180

TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-9router-magoco}"
TAILSCALE_DIR="/var/lib/tailscale"

notify_tunnel_url() {
    local url="$1"
    local mode="$2"

    echo "$url" > "$TUNNEL_URL_FILE"
    echo "$(date -Iseconds) $mode $url" >> "$TUNNEL_URL_FILE.log"
    log_ok "Tunnel URL saved to $TUNNEL_URL_FILE"

    if [ -n "$WEBHOOK_URL" ]; then
        log "Sending tunnel URL to webhook..."
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"tunnel_url\":\"$url\",\"mode\":\"$mode\",\"timestamp\":\"$(date -Iseconds)\",\"service\":\"9router\"}" \
            && log_ok "Webhook notified" || log_warn "Webhook failed (non-critical)"
    fi

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║  🎉 9ROUTER TUNNEL ACTIVE                                  ║${RESET}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║${RESET} Mode: $mode"
    echo -e "${CYAN}║${RESET} URL:  $url"
    echo -e "${CYAN}║${RESET} API:  ${url}/v1"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

wait_for_app() {
    log "Waiting for 9Router on localhost:${APP_PORT} (max ${STARTUP_WAIT_MAX}s)..."
    local count=0
    while [ $count -lt $STARTUP_WAIT_MAX ]; do
        if curl -s -f "http://localhost:${APP_PORT}/api/health" > /dev/null 2>&1; then
            log_ok "9Router /api/health OK"
            return 0
        fi
        if curl -s -f "http://localhost:${APP_PORT}/" > /dev/null 2>&1; then
            log_ok "9Router root endpoint responding"
            return 0
        fi
        sleep 2
        count=$((count + 2))
        if [ $((count % 20)) -eq 0 ]; then
            log "  Still waiting... (${count}s/${STARTUP_WAIT_MAX}s)"
        fi
    done
    log_warn "9Router not fully ready after ${STARTUP_WAIT_MAX}s - starting tunnel anyway"
    return 1
}

install_cloudflared() {
    if command -v cloudflared > /dev/null 2>&1; then
        log_ok "cloudflared already installed"
        cloudflared version
        return 0
    fi

    log "Downloading cloudflared..."
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    if curl -L -o /tmp/cloudflared "$url" 2>/dev/null; then
        chmod +x /tmp/cloudflared
        mv /tmp/cloudflared /usr/local/bin/cloudflared
        log_ok "cloudflared installed"
        cloudflared version
        return 0
    else
        log_err "Failed to download cloudflared"
        return 1
    fi
}

run_quick_tunnel() {
    log "Starting QUICK TUNNEL (TryCloudflare) - NO AUTH NEEDED"
    log "Target: http://localhost:${APP_PORT}"

    cloudflared tunnel --url "http://localhost:${APP_PORT}" --no-autoupdate 2>&1 | while IFS= read -r line; do
        echo "$line"
        url=$(echo "$line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1)
        if [ -n "$url" ]; then
            notify_tunnel_url "$url" "quick"
        fi
    done
}

create_named_tunnel_config() {
    mkdir -p "$CLOUDFLARED_DIR"

    local tunnel_id="omniroute-tunnel"
    if [ -n "$TUNNEL_TOKEN" ]; then
        local payload=$(echo "$TUNNEL_TOKEN" | cut -d'.' -f2)
        payload="${payload}$(printf '%*s' $((4 - ${#payload} % 4)) | tr ' ' '=')"
        local decoded=$(echo "$payload" | base64 -d 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('tid', ''))" 2>/dev/null || echo "")
        [ -n "$decoded" ] && tunnel_id="$decoded"
    fi

    cat > "$CLOUDFLARED_DIR/config.yml" <<EOF
tunnel: $tunnel_id
credentials-file: $CLOUDFLARED_DIR/credentials.json
protocol: http2
no-autoupdate: true

ingress:
  - hostname: omni.magoc.dpdns.org
    service: http://localhost:${APP_PORT}
    originRequest:
      httpHostHeader: localhost:${APP_PORT}
      connectTimeout: 30s
      tlsTimeout: 10s
      noTLSVerify: true
  - service: http_status:404
EOF
    log_ok "Named tunnel config created"
}

create_credentials_from_token() {
    [ -z "$TUNNEL_TOKEN" ] && return 0

    local payload=$(echo "$TUNNEL_TOKEN" | cut -d'.' -f2)
    payload="${payload}$(printf '%*s' $((4 - ${#payload} % 4)) | tr ' ' '=')"

    local token_data=$(echo "$payload" | base64 -d 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(json.dumps({
        'AccountTag': data.get('aid', ''),
        'TunnelID': data.get('tid', ''),
        'TunnelName': 'omniroute-magoco',
        'TunnelSecret': data.get('s', '')
    }))
except:
    print('{}')
" 2>/dev/null || echo '{}')

    if [ "$token_data" != "{}" ] && [ -n "$token_data" ]; then
        echo "$token_data" > "$CLOUDFLARED_DIR/credentials.json"
        log_ok "Named tunnel credentials created"
    else
        log_warn "Could not parse tunnel token"
    fi
}

run_named_tunnel() {
    log "Starting NAMED TUNNEL (stable URL)"
    log "Token: ${TUNNEL_TOKEN:0:20}..."

    notify_tunnel_url "https://omni.magoc.dpdns.org" "named"

    exec cloudflared tunnel --config "$CLOUDFLARED_DIR/config.yml" run --token "$TUNNEL_TOKEN"
}

install_tailscale() {
    if command -v tailscaled > /dev/null 2>&1 && command -v tailscale > /dev/null 2>&1; then
        log_ok "Tailscale already installed"
        return 0
    fi

    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh 2>/dev/null || {
        log_err "Failed to install Tailscale"
        return 1
    }
    log_ok "Tailscale installed"
}

start_tailscale() {
    if [ -z "$TAILSCALE_AUTH_KEY" ]; then
        log_warn "TAILSCALE_AUTH_KEY not set - skipping Tailscale Funnel"
        return 1
    fi

    log "Starting Tailscale..."
    mkdir -p "$TAILSCALE_DIR"
    tailscaled --state="$TAILSCALE_DIR" --socket="$TAILSCALE_DIR/tailscaled.sock" >/dev/null 2>&1 &
    sleep 2

    log "Authenticating Tailscale..."
    tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="$TAILSCALE_HOSTNAME" >/dev/null 2>&1 || true

    if tailscale status >/dev/null 2>&1; then
        log_ok "Tailscale authenticated"
        
        log "Enabling Tailscale Funnel on port ${APP_PORT}..."
        tailscale funnel --bg --port=${APP_PORT} http://localhost:${APP_PORT} >/dev/null 2>&1 || true
        
        sleep 3
        local ts_url=$(tailscale status 2>/dev/null | grep -oE 'https://[a-zA-Z0-9-]+\.ts\.net' | head -1 || true)
        if [ -n "$ts_url" ]; then
            log_ok "Tailscale Funnel active: $ts_url"
            notify_tunnel_url "$ts_url" "tailscale"
        else
            log_warn "Tailscale Funnel URL not detected yet"
        fi
    else
        log_warn "Tailscale auth failed"
    fi
}

start_keepalive() {
    log "Starting 9Router keep-alive worker..."
    cat > /app/keepalive_9router.sh <<'EOF'
#!/bin/bash
# Random keep-alive for 9Router on ModelScope Studio
# Pings the public tunnel URL or ModelScope studio page with randomized intervals

TUNNEL_URL_FILE="/app/tunnel_url.txt"
MODELSCOPE_URL="https://www.modelscope.ai/studios/magoco/9Router"

while true; do
    TARGET="$MODELSCOPE_URL"
    if [ -f "$TUNNEL_URL_FILE" ]; then
        TUNNEL_URL=$(cat "$TUNNEL_URL_FILE" | tr -d '\n')
        if [ -n "$TUNNEL_URL" ]; then
            TARGET="$TUNNEL_URL"
        fi
    fi

    curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$TARGET" >/dev/null 2>&1 || true

    # Random sleep between 15 and 45 minutes to avoid bot detection
    INTERVAL=$(( ( RANDOM % 31 + 15 ) * 60 ))
    sleep "$INTERVAL"
done
EOF
    chmod +x /app/keepalive_9router.sh
    nohup bash /app/keepalive_9router.sh >/dev/null 2>&1 &
    log_ok "Keep-alive started (random 15-45 min)"
}

# ---- MAIN ----
main() {
    log "═══════════════════════════════════════"
    log "  9Router + Multi-Tunnel Entrypoint"
    log "═══════════════════════════════════════"
    log "Port: ${APP_PORT}"
    log "Cloudflare Token: ${TUNNEL_TOKEN:+PROVIDED}${TUNNEL_TOKEN:-NOT SET (Quick Tunnel mode)}"
    log "Tailscale Auth Key: ${TAILSCALE_AUTH_KEY:+PROVIDED}${TAILSCALE_AUTH_KEY:-NOT SET}"
    log "Webhook: ${WEBHOOK_URL:-NOT SET}"

    if ! curl -s -f "http://localhost:${APP_PORT}/api/health" > /dev/null 2>&1; then
        log_warn "9Router not detected on port ${APP_PORT}. If your studio does not auto-start it, start it now."
    else
        log_ok "9Router already reachable on port ${APP_PORT}"
    fi

    wait_for_app || true

    install_cloudflared || exit 1

    # Start Cloudflare tunnel in background
    if [ -n "$TUNNEL_TOKEN" ]; then
        log "NAMED TUNNEL MODE selected"
        create_named_tunnel_config
        create_credentials_from_token
        run_named_tunnel &
    else
        log "QUICK TUNNEL MODE selected"
        run_quick_tunnel &
    fi

    # Start Tailscale Funnel if auth key provided
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        install_tailscale || true
        start_tailscale || true
    fi

    # Start keep-alive
    start_keepalive

    # If the app itself is not PID 1, keep this shell alive so the container stays up.
    if ! curl -s -f "http://localhost:${APP_PORT}/api/health" > /dev/null 2>&1; then
        log_warn "9Router process not detected; entrypoint staying alive for logs/tunnels."
    fi

    wait -n || true
    tail -F /dev/null 2>/dev/null || sleep infinity
}

main "$@"
