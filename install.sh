#!/usr/bin/env bash
# =============================================================================
# BlockDAG Pool-Stack Installer — Linux + macOS (single script, branches inside)
#
# What it does:
#   1.  Detect OS (Ubuntu/Debian, RHEL/Fedora, Arch, macOS)
#   2.  Install Docker + Compose v2 if missing
#   3.  Start the engine and verify
#   4.  Check disk space and host ports
#   5.  Download the official BlockDAG pool-stack-docker release tarball,
#       SHA-256 verify, extract
#   6.  (Optional) Download a snapshot for fast bootstrap, SHA verify if known
#   7.  Prompt for: pool reward wallet, worker name, pool fee, strong RPC creds Y/N,
#       snapshot Y/N — validated, with retries
#   8.  Render .env + node.conf from templates (auto-generates a strong POSTGRES_PASSWORD)
#   9.  docker compose build — auto-retry once with --no-cache if first attempt fails
#                              on apt-mirror flakiness
#   10. docker compose up -d, wait for postgres healthcheck
#   11. Send install-complete notification to dawie@dagminingtrust.com via webhook
#   12. Print a success summary with all reachable endpoints
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Dagtechltd/blockdag-node-and-pool-installer/main/install.sh | bash
#   # or:
#   bash install.sh
#
# Unattended install via env vars:
#   POOL_WALLET=0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f \
#   WORKER_NAME=node-3 \
#   POOL_FEE_PERCENTAGE=1.0 \
#   USE_SNAPSHOT=yes \
#   SNAPSHOT_URL=https://example.com/latest.bdsnap \
#   STRONG_RPC=no \
#   NOTIFY_OPT_OUT=false \
#   UNATTENDED=yes \
#   bash install.sh
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults (override via env vars before running)
# -----------------------------------------------------------------------------
RELEASE_TAG="${RELEASE_TAG:-v1.3.23}"
RELEASE_URL_BASE="${RELEASE_URL_BASE:-https://bdagstack.bdagdev.xyz}"
NOTIFY_URL="${NOTIFY_URL:-https://notify.dagminingtrust.com/install-complete}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/bdag-pool-stack}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" 2>/dev/null && pwd || pwd )"
LOG_DIR="${LOG_DIR:-$INSTALL_DIR/logs}"
UNATTENDED="${UNATTENDED:-no}"

# Inner-folder name on disk after extraction. The current release ships
# `pool-stack-docker-pool-v<TAG>` (pool-only flavor). If BlockDAG bring back
# the cpu/pool variant split, this needs to handle both — for now keep it simple.
INNER_PREFIX="${INNER_PREFIX:-pool-stack-docker-pool-}"

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    RESET=$'\033[0m'; BOLD=$'\033[1m'
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; GRAY=$'\033[90m'
else
    RESET=''; BOLD=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; GRAY=''
fi
banner() {
    printf "\n${BOLD}${CYAN}%s${RESET}\n" "================================================================="
    printf "${BOLD}${CYAN}  %s${RESET}\n" "$*"
    printf "${BOLD}${CYAN}%s${RESET}\n\n" "================================================================="
}
step() { printf "\n${CYAN}==> %s${RESET}\n" "$*"; }
ok()   { printf "    ${GREEN}[OK]${RESET}  %s\n" "$*"; }
warn() { printf "    ${YELLOW}[!]${RESET}   %s\n" "$*"; }
err()  { printf "    ${RED}[X]${RESET}   %s\n" "$*" >&2; }
note() { printf "    ${GRAY}     %s${RESET}\n" "$*"; }
die()  { err "$*"; exit 1; }

read_default()   { local p="$1" d="$2" v; read -r -p "$p [$d]: " v; printf '%s' "${v:-$d}"; }
read_validated() {
    local prompt="$1" rgx="$2" def="${3:-}" tries="${4:-3}" v
    local i=1
    while [ "$i" -le "$tries" ]; do
        if [ -n "$def" ]; then
            read -r -p "$prompt [$def]: " v
            v="${v:-$def}"
        else
            read -r -p "$prompt: " v
        fi
        # trim leading/trailing whitespace
        v="$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ "$v" =~ $rgx ]]; then
            printf '%s' "$v"
            return 0
        fi
        err "value does not match expected pattern (try $i of $tries)"
        i=$((i + 1))
    done
    return 1
}
strong_password() {
    local len="${1:-28}"
    LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c "$len"
}

# -----------------------------------------------------------------------------
# OS detection
# -----------------------------------------------------------------------------
detect_os() {
    case "$(uname -s)" in
        Darwin) OS=macos; PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || echo)" ;;
        Linux)
            if [ -r /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                case "${ID:-}" in
                    ubuntu|debian)                       OS=linux-debian; PRETTY="${PRETTY_NAME:-Linux/Debian}" ;;
                    fedora|rhel|centos|rocky|almalinux)  OS=linux-rhel;   PRETTY="${PRETTY_NAME:-Linux/RHEL}" ;;
                    arch|manjaro|endeavouros)            OS=linux-arch;   PRETTY="${PRETTY_NAME:-Linux/Arch}" ;;
                    *)                                   OS=linux-generic;PRETTY="${PRETTY_NAME:-Linux}" ;;
                esac
            else
                OS=linux-generic; PRETTY="Linux (no /etc/os-release)"
            fi
            ;;
        *) die "Unsupported OS: $(uname -s)" ;;
    esac
    ok "OS detected: $PRETTY ($OS)"
}

# -----------------------------------------------------------------------------
# Prereqs
# -----------------------------------------------------------------------------
have()      { command -v "$1" >/dev/null 2>&1; }
docker_up() { docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; }
sudo_run()  { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

install_docker() {
    case "$OS" in
        macos)
            have brew || die "Homebrew not found. Install from https://brew.sh and re-run this script."
            brew install --cask docker
            warn "Launch Docker Desktop manually (it requires GUI consent on first launch)."
            warn "Wait until the whale icon settles, then re-run this script."
            exit 0
            ;;
        linux-debian)
            sudo_run apt-get update
            sudo_run apt-get install -y ca-certificates curl gnupg
            sudo_run install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | sudo_run gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo_run chmod a+r /etc/apt/keyrings/docker.gpg
            local arch codename
            arch="$(dpkg --print-architecture)"
            codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"
            echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${codename} stable" \
                | sudo_run tee /etc/apt/sources.list.d/docker.list >/dev/null
            sudo_run apt-get update
            sudo_run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo_run systemctl enable --now docker
            sudo_run usermod -aG docker "$USER"
            warn "Added '$USER' to the 'docker' group."
            warn "Log out and back in (or run 'newgrp docker'), then re-run this script."
            exit 0
            ;;
        linux-rhel)
            sudo_run dnf -y install dnf-plugins-core
            sudo_run dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo_run dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo_run systemctl enable --now docker
            sudo_run usermod -aG docker "$USER"
            warn "Added '$USER' to 'docker' group. Log out and back in, then re-run."
            exit 0
            ;;
        linux-arch)
            sudo_run pacman -Sy --noconfirm docker docker-compose
            sudo_run systemctl enable --now docker
            sudo_run usermod -aG docker "$USER"
            warn "Added '$USER' to 'docker' group. Log out and back in, then re-run."
            exit 0
            ;;
        *)
            die "Don't know how to auto-install Docker on $OS. Install Docker + Compose v2 manually then re-run."
            ;;
    esac
}

ensure_docker() {
    step "Checking Docker"
    if ! have docker; then
        warn "Docker not installed. Installing now..."
        install_docker
    fi
    if ! docker_up; then
        case "$OS" in
            macos)   open -a Docker 2>/dev/null || true ;;
            linux-*) sudo_run systemctl start docker || true ;;
        esac
        printf "    Waiting up to 120 s for engine "
        local i
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
            sleep 5
            printf "."
            if docker_up; then
                printf "\n"
                ok "Engine up."
                break
            fi
        done
        if ! docker_up; then
            printf "\n"
            die "Docker engine did not come up in 120 s. Open Docker Desktop manually and re-run."
        fi
    fi
    ok "Docker engine: $(docker --version)"
    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose v2 plugin not found. Update to a Docker Engine that bundles 'docker compose'."
    fi
    ok "Docker Compose v2: $(docker compose version --short 2>/dev/null || echo present)"
}

ensure_disk() {
    step "Checking disk space (need >= 30 GB free for image + chain volume)"
    mkdir -p "$INSTALL_DIR"
    local free_gb
    if [ "$OS" = macos ]; then
        free_gb=$(df -g "$INSTALL_DIR" | awk 'NR==2 {print $4}')
    else
        free_gb=$(df -BG --output=avail "$INSTALL_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
    fi
    free_gb=${free_gb:-0}
    if [ "$free_gb" -lt 30 ]; then
        warn "Only ${free_gb} GB free under $INSTALL_DIR; recommend >= 30 GB."
        if [ "$UNATTENDED" != yes ]; then
            local ans
            read -r -p "    Continue anyway? (y/N) " ans
            [ "$ans" = y ] || die "Aborted on low disk space."
        fi
    fi
    ok "Disk: ${free_gb} GB free under $INSTALL_DIR"
}

check_ports() {
    step "Checking required host ports"
    local ports="8150 38131 18545 18546 6060 3334 8080 9280" busy=""
    for p in $ports; do
        if (have ss && ss -ltn "( sport = :$p )" 2>/dev/null | grep -q LISTEN) \
           || (have lsof && lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1) \
           || (have nc && nc -z 127.0.0.1 "$p" 2>/dev/null); then
            busy="$busy $p"
        fi
    done
    if [ -n "$busy" ]; then
        warn "Ports already in use:$busy"
        if [ "$UNATTENDED" != yes ]; then
            local ans
            read -r -p "    Continue anyway? compose may fail to bind. (y/N) " ans
            [ "$ans" = y ] || die "Aborted on port conflict."
        fi
    else
        ok "All required ports free."
    fi
}

# -----------------------------------------------------------------------------
# Download + verify release tarball
# -----------------------------------------------------------------------------
sha256_of() {
    if have sha256sum; then sha256sum "$1" | awk '{print $1}'; return; fi
    if have shasum;    then shasum -a 256 "$1" | awk '{print $1}'; return; fi
    die "No sha256sum or shasum tool available."
}

download_release() {
    step "Fetching release $RELEASE_TAG"
    local tarball="pool-stack-docker-$RELEASE_TAG.tar.gz"
    local local_tar="$INSTALL_DIR/$tarball"
    if [ -f "$local_tar" ]; then
        ok "Tarball already on disk: $local_tar"
    else
        local url="$RELEASE_URL_BASE/$tarball"
        note "Downloading $url"
        curl -fSL --progress-bar -o "$local_tar" "$url" \
            || die "Failed to download tarball from $url"
    fi
    if [ -f "$SCRIPT_DIR/checksums.json" ]; then
        local expected actual
        expected=$(grep -A2 "\"$RELEASE_TAG\"" "$SCRIPT_DIR/checksums.json" \
                   | grep -m1 '"tarball"' | grep -oE '[a-f0-9]{64}' || true)
        if [ -n "$expected" ]; then
            actual=$(sha256_of "$local_tar")
            if [ "$expected" = "$actual" ]; then
                ok "Tarball SHA-256 verified."
            else
                die "SHA-256 mismatch on tarball — got $actual, expected $expected. Aborting."
            fi
        else
            warn "No published SHA for $RELEASE_TAG in checksums.json — skipping verify."
        fi
    fi
    note "Extracting..."
    tar -xzf "$local_tar" -C "$INSTALL_DIR"
    ok "Extracted to $INSTALL_DIR"
}

locate_release_root() {
    RELEASE_ROOT=$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 2 -type d -name "${INNER_PREFIX}${RELEASE_TAG}*" 2>/dev/null | head -n1 || true)
    [ -n "$RELEASE_ROOT" ] || die "Could not locate extracted release dir under $INSTALL_DIR"
    ok "Release root: $RELEASE_ROOT"
}

# -----------------------------------------------------------------------------
# Snapshot handling
# -----------------------------------------------------------------------------
stage_snapshot() {
    if [ "${USE_SNAPSHOT:-no}" != yes ]; then
        SNAPSHOT_PATH_VAL="docker/no-snapshot.marker"
        ok "Skipping snapshot — node will sync from genesis via P2P."
        return
    fi
    step "Staging snapshot"
    local target="$RELEASE_ROOT/latest.bdsnap"
    if [ -n "${SNAPSHOT_FILE:-}" ] && [ -f "$SNAPSHOT_FILE" ]; then
        cp -f "$SNAPSHOT_FILE" "$target"
        ok "Copied $SNAPSHOT_FILE -> $target"
    elif [ -n "${SNAPSHOT_URL:-}" ]; then
        note "Downloading snapshot from $SNAPSHOT_URL"
        curl -fSL --progress-bar -o "$target" "$SNAPSHOT_URL" \
            || die "Failed to download snapshot from $SNAPSHOT_URL"
    elif [ -f "$RELEASE_ROOT/latest.bdsnap" ]; then
        ok "Snapshot already in place at $target"
    else
        die "Snapshot enabled but no SNAPSHOT_FILE or SNAPSHOT_URL provided, and no $target found."
    fi
    # Verify the binary can read it before we waste time on the build
    if docker run --rm \
        -v "$RELEASE_ROOT/bin:/bin-host:ro" \
        -v "$RELEASE_ROOT:/snap-host:ro" \
        ubuntu:24.04 sh -c \
            "cp /bin-host/blockdag-node /tmp/bn && chmod +x /tmp/bn && /tmp/bn snap info --path /snap-host/latest.bdsnap" \
        2>&1 | grep -q '"format_version"'; then
        ok "Snapshot manifest readable by shipped blockdag-node binary."
    else
        warn "Snapshot manifest could NOT be read by the shipped binary — likely format mismatch."
        warn "Falling back to no-snapshot path. Node will sync from genesis."
        rm -f "$target"
        SNAPSHOT_PATH_VAL="docker/no-snapshot.marker"
        return
    fi
    SNAPSHOT_PATH_VAL="./latest.bdsnap"
}

# -----------------------------------------------------------------------------
# Interactive configuration
# -----------------------------------------------------------------------------
gather_config() {
    step "Configuration"

    POOL_WALLET="${POOL_WALLET:-}"
    if [ -z "$POOL_WALLET" ]; then
        POOL_WALLET=$(read_validated 'Pool reward / dashboard wallet (0x + 40 hex)' \
                                     '^0x[a-fA-F0-9]{40}$') \
            || die "Wallet validation failed."
    fi

    WORKER_NAME="${WORKER_NAME:-}"
    if [ -z "$WORKER_NAME" ]; then
        WORKER_NAME=$(read_validated 'Worker / node name' '^[A-Za-z0-9_-]{1,32}$' "$(hostname -s)") \
            || die "Worker name validation failed."
    fi

    if [ -z "${STRONG_RPC:-}" ]; then
        STRONG_RPC=$(read_default 'Use strong (non-test/test) RPC creds? y/n' 'n')
    fi
    if [ "$STRONG_RPC" = y ] || [ "$STRONG_RPC" = yes ]; then
        NODE_RPC_USER=$(read_validated 'RPC user (3-32 alphanumeric/underscore)' \
                                       '^[A-Za-z0-9_]{3,32}$' \
                                       "bdag_$(strong_password 4 | tr 'A-Z' 'a-z')")
        NODE_RPC_PASS="${NODE_RPC_PASS:-$(strong_password 28)}"
    else
        NODE_RPC_USER=test
        NODE_RPC_PASS=test
        warn "Using default test/test RPC credentials. Fine for local; rotate before exposing the node to the internet."
    fi

    # PostgreSQL password - strict precedence:
    #   1. $POSTGRES_PASSWORD if explicitly exported (unattended override)
    #   2. Existing .env in the release dir (preserves password across re-runs
    #      so a re-installed stack can still authenticate to the existing
    #      postgres-data volume)
    #   3. Auto-generate a strong 28-char password
    if [ -n "${POSTGRES_PASSWORD:-}" ]; then
        :  # use as-is
    elif [ -f "${RELEASE_ROOT:-/nonexistent}/.env" ]; then
        existing=$(awk -F= '/^POSTGRES_PASSWORD=/{sub(/^POSTGRES_PASSWORD=/,""); print; exit}' "$RELEASE_ROOT/.env" 2>/dev/null)
        if [ -n "$existing" ] && [ "$existing" != "change_me_to_a_strong_secret" ]; then
            note "Preserving POSTGRES_PASSWORD from existing .env (so re-installs still authenticate to the existing postgres volume)."
            POSTGRES_PASSWORD="$existing"
        else
            POSTGRES_PASSWORD="$(strong_password 28)"
        fi
    else
        POSTGRES_PASSWORD="$(strong_password 28)"
    fi

    # Pool fee validation (numeric, 0.0-10.0). Used both for env-var and interactive input.
    _validate_fee() {
        case "$1" in
            ''|*[!0-9.]*) return 1 ;;
        esac
        awk -v f="$1" 'BEGIN { if (f+0 >= 0 && f+0 <= 10) exit 0; else exit 1 }'
    }
    if [ -n "${POOL_FEE_PERCENTAGE:-}" ]; then
        _validate_fee "$POOL_FEE_PERCENTAGE" || die "POOL_FEE_PERCENTAGE not in 0.0-10.0: $POOL_FEE_PERCENTAGE"
    else
        i=1
        while [ "$i" -le 3 ]; do
            POOL_FEE_PERCENTAGE=$(read_default 'Pool fee % (0.0-10.0)' '1.0')
            if _validate_fee "$POOL_FEE_PERCENTAGE"; then break; fi
            err "Fee must be a number between 0.0 and 10.0 (try $i of 3)"
            POOL_FEE_PERCENTAGE=
            i=$((i+1))
        done
        [ -n "$POOL_FEE_PERCENTAGE" ] || die "Pool fee validation failed."
    fi

    if [ -z "${USE_SNAPSHOT:-}" ]; then
        local ans
        ans=$(read_default 'Use snapshot for fast bootstrap? y/n (downloads ~4 GB)' 'n')
        [ "$ans" = y ] && USE_SNAPSHOT=yes || USE_SNAPSHOT=no
    fi

    if [ "$USE_SNAPSHOT" = yes ] && [ -z "${SNAPSHOT_FILE:-}" ] && [ -z "${SNAPSHOT_URL:-}" ]; then
        local ans path
        ans=$(read_default 'Have a local snapshot file or a URL? f/u' 'u')
        if [ "$ans" = f ]; then
            read -r -p "    Path to local .bdsnap: " path
            SNAPSHOT_FILE="$path"
        else
            path=$(read_default '    Snapshot URL' 'https://bdagstack.bdagdev.xyz/latest.bdsnap')
            SNAPSHOT_URL="$path"
        fi
    fi

    step "Summary"
    printf "    %-22s = %s\n" \
        POOL_WALLET           "$POOL_WALLET" \
        WORKER_NAME           "$WORKER_NAME" \
        NODE_RPC_USER         "$NODE_RPC_USER" \
        NODE_RPC_PASS         "<${#NODE_RPC_PASS} chars>" \
        POSTGRES_PASSWORD     "<${#POSTGRES_PASSWORD} chars (auto-generated)>" \
        POOL_FEE_PERCENTAGE   "$POOL_FEE_PERCENTAGE" \
        USE_SNAPSHOT          "$USE_SNAPSHOT"
    if [ "$UNATTENDED" != yes ]; then
        local ok_
        read -r -p "    Proceed? (y/N) " ok_
        [ "$ok_" = y ] || die "Cancelled at summary."
    fi
}

# -----------------------------------------------------------------------------
# Render templates
# -----------------------------------------------------------------------------
render_template() {
    local tpl="$1" out="$2"
    [ -f "$tpl" ] || die "Missing template: $tpl"
    local tmp
    tmp="$(mktemp)"
    cp "$tpl" "$tmp"
    local k v
    for k in POOL_WALLET WORKER_NAME NODE_RPC_USER NODE_RPC_PASS POSTGRES_PASSWORD POOL_FEE_PERCENTAGE SNAPSHOT_PATH_VAL; do
        eval "v=\${$k}"
        # Use a sed delimiter unlikely to collide with values; escape & and \
        v=$(printf '%s' "$v" | sed -e 's/[\\&|]/\\&/g')
        sed -i.bak "s|{{$k}}|$v|g" "$tmp" 2>/dev/null || sed -i '' "s|{{$k}}|$v|g" "$tmp"
    done
    mv "$tmp" "$out"
    rm -f "$tmp.bak"
}

# -----------------------------------------------------------------------------
# Build (with retry on apt-mirror flakiness — Bug 14)
# -----------------------------------------------------------------------------
write_build_override() {
    # network: host on the BUILD stage works around transient archive.ubuntu.com
    # connectivity issues observed on multiple operator boxes.
    cat > "$RELEASE_ROOT/docker-compose.override.yml" <<EOF
# Auto-generated by the BlockDAG installer. Forces builds onto the host network
# stack to avoid archive.ubuntu.com / security.ubuntu.com flakiness inside the
# default Docker bridge. Runtime networking is unchanged. Safe to delete after
# the first successful build if you prefer the upstream layout.
services:
  node:
    build:
      network: host
  pool:
    build:
      network: host
  dashboard:
    build:
      network: host
EOF
}

build_with_retry() {
    step "docker compose build (this can take 5–15 min on first run)"
    mkdir -p "$LOG_DIR"
    local log="$LOG_DIR/build-$(date -u +%Y%m%dT%H%M%SZ).log"
    write_build_override
    if ( cd "$RELEASE_ROOT" && docker compose build 2>&1 ) | tee "$log"; then
        ok "Build succeeded."
        return
    fi
    warn "Build failed on first attempt. This is most often apt-mirror flakiness."
    warn "Retrying once with --no-cache (this WILL re-download base images)..."
    log="$LOG_DIR/build-retry-$(date -u +%Y%m%dT%H%M%SZ).log"
    if ( cd "$RELEASE_ROOT" && docker compose build --no-cache 2>&1 ) | tee "$log"; then
        ok "Build succeeded on retry."
        return
    fi
    err "Build failed on retry. See $log for details."
    err "Common causes: Ubuntu mirrors down (try again in 10 min), insufficient disk, or proxy/firewall blocking outbound HTTP."
    exit 1
}

# -----------------------------------------------------------------------------
# Up + healthcheck
# -----------------------------------------------------------------------------
compose_up() {
    step "docker compose up -d"
    ( cd "$RELEASE_ROOT" && docker compose up -d ) || die "compose up -d failed"
    ok "All services started."
    printf "    Waiting for postgres healthcheck "
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
        sleep 5
        printf "."
        if docker compose -f "$RELEASE_ROOT/docker-compose.yml" ps postgres --format '{{.Health}}' 2>/dev/null | grep -q healthy; then
            printf "\n"
            ok "Postgres healthy."
            return
        fi
    done
    printf "\n"
    warn "Postgres did not flip 'healthy' in 90 s. Continuing — check 'docker compose logs postgres' if anything looks off."
}

# -----------------------------------------------------------------------------
# Notification
# -----------------------------------------------------------------------------
notify() {
    if [ "${NOTIFY_OPT_OUT:-false}" = true ] || [ -z "$NOTIFY_URL" ]; then
        warn "Notification opt-out (or NOTIFY_URL empty); skipping."
        return
    fi
    step "Sending install-complete notification"
    local payload
    payload=$(cat <<EOF
{
 "version":"pool-stack-docker-$RELEASE_TAG",
 "hostname":"$(hostname -s 2>/dev/null || hostname)",
 "os":"$OS",
 "wallet":"$POOL_WALLET",
 "worker_name":"$WORKER_NAME",
 "started_at":"$STARTED_AT",
 "duration_seconds":$DURATION,
 "use_snapshot":"${USE_SNAPSHOT:-no}",
 "status":"running"
}
EOF
)
    local i
    for i in 1 2 3; do
        if curl -fsSL -X POST -H 'Content-Type: application/json' \
                -d "$payload" --max-time 10 "$NOTIFY_URL" >/dev/null; then
            ok "Notification sent."
            return
        fi
        warn "Notify attempt $i/3 failed; retrying in $((i * 2))s..."
        sleep "$((i * 2))"
    done
    warn "Notification failed after 3 attempts. Install is fine; just no email landed."
}

# -----------------------------------------------------------------------------
# Success summary
# -----------------------------------------------------------------------------
success_summary() {
    banner "Install complete"
    cat <<EOF
   ${BOLD}Stack root${RESET}     : $RELEASE_ROOT
   ${BOLD}Wallet${RESET}         : $POOL_WALLET
   ${BOLD}Worker${RESET}         : $WORKER_NAME
   ${BOLD}Snapshot${RESET}       : ${USE_SNAPSHOT}
   ${BOLD}Build duration${RESET} : ${DURATION}s

   ${CYAN}Endpoints:${RESET}
     Dashboard         : http://localhost:9280
     Mining pool       : stratum+tcp://localhost:3334
     DAG JSON-RPC      : http://localhost:38131  (Basic auth: $NODE_RPC_USER:[redacted])
     EVM JSON-RPC      : http://localhost:18545
     Node metrics      : http://localhost:6060/metrics

   ${CYAN}Useful commands:${RESET}
     cd $RELEASE_ROOT
     docker compose ps
     docker compose logs -f node
     docker compose down              # stop, keep chain data
     docker compose down -v           # stop, wipe chain data

EOF
}

# =============================================================================
# main
# =============================================================================
main() {
    banner "BlockDAG Pool-Stack Installer — Linux/macOS — release $RELEASE_TAG"
    STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local t0
    t0=$(date +%s)
    detect_os
    ensure_disk
    ensure_docker
    check_ports
    download_release
    locate_release_root
    gather_config
    stage_snapshot
    render_template "$SCRIPT_DIR/templates/env.template"       "$RELEASE_ROOT/.env"
    render_template "$SCRIPT_DIR/templates/node.conf.template" "$RELEASE_ROOT/node.conf"
    ok ".env and node.conf rendered."
    build_with_retry
    compose_up
    DURATION=$(( $(date +%s) - t0 ))
    notify
    success_summary
}
# --- end of script body ---
# Source-guard: when this file is sourced (e.g. by the test harness with
# INSTALL_SH_NORUN=1), do not auto-run main(). Only run on direct invocation.
if [ -z "${INSTALL_SH_NORUN:-}" ]; then
    main "$@"
fi
