#!/usr/bin/env bash
#
# install-splunk-native.sh
# Interactive installer for Splunk Universal Forwarder (Linux + macOS) or
# Splunk Enterprise (Linux only), x86_64.
#
# - Top-level menu: pick product
# - Self-elevates via sudo
# - Detects OS + package manager (.deb / .rpm / .tgz)
# - Downloads & SHA512-verifies the vendor package
# - Seeds admin via user-seed.conf (Splunk hashes it on first boot and
#   removes the plaintext)
# - UF: writes deploymentclient.conf or outputs.conf
# - Enterprise: optionally enables 9997 receiver, optionally pre-stages
#   deployment-server directory
# - Runs as non-root service user, enables boot-start via systemd/launchd
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Static config — override via env before running
# ---------------------------------------------------------------------------
SPLUNK_VERSION="${SPLUNK_VERSION:-10.2.2}"
SPLUNK_BUILD="${SPLUNK_BUILD:-80b90d638de6}"
SPLUNK_DEPLOYMENT_SERVER_DEFAULT="${SPLUNK_DEPLOYMENT_SERVER:-10.54.10.11}"
SPLUNK_DEPLOYMENT_PORT_DEFAULT="${SPLUNK_DEPLOYMENT_PORT:-8089}"
SPLUNK_ADMIN_USER_DEFAULT="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_RECEIVER_PORT_DEFAULT="${SPLUNK_RECEIVER_PORT:-9997}"

# Product-specific defaults (applied in set_product_vars)
UF_HOME_DEFAULT="/opt/splunkforwarder"
UF_USER_DEFAULT="splunkfwd"
UF_GROUP_DEFAULT="splunkfwd"
ENT_HOME_DEFAULT="/opt/splunk"
ENT_USER_DEFAULT="splunk"
ENT_GROUP_DEFAULT="splunk"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi
info() { echo "${C_CYAN}[info]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[ ok ]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[warn]${C_RESET} $*"; }
err()  { echo "${C_RED}[err!]${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { echo; echo "${C_BOLD}${C_BLUE}==> $*${C_RESET}"; }

usage() {
    cat <<EOF
Splunk installer — Universal Forwarder (Linux + macOS) or
                   Splunk Enterprise server (Linux only). x86_64.

USAGE
  ./install-splunk-native.sh          # interactive (script will sudo itself)
  ./install-splunk-native.sh -h       # this help

ENV OVERRIDES
  SPLUNK_VERSION              $SPLUNK_VERSION
  SPLUNK_BUILD                $SPLUNK_BUILD
  SPLUNK_DEPLOYMENT_SERVER    $SPLUNK_DEPLOYMENT_SERVER_DEFAULT  (UF only)
  SPLUNK_DEPLOYMENT_PORT      $SPLUNK_DEPLOYMENT_PORT_DEFAULT  (UF only)
  SPLUNK_RECEIVER_PORT        $SPLUNK_RECEIVER_PORT_DEFAULT  (Enterprise only)
  SPLUNK_ADMIN_USER           $SPLUNK_ADMIN_USER_DEFAULT
  SPLUNK_HOME_LINUX           (defaults: UF=$UF_HOME_DEFAULT, Enterprise=$ENT_HOME_DEFAULT)
  SPLUNK_HOME_MACOS           (UF only, default: $UF_HOME_DEFAULT)
  SPLUNK_RUN_USER_LINUX       (defaults: UF=$UF_USER_DEFAULT, Enterprise=$ENT_USER_DEFAULT)
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# ---------------------------------------------------------------------------
# Self-elevate
# ---------------------------------------------------------------------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    info "Elevating with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Product menu
# ---------------------------------------------------------------------------
choose_action() {
    hdr "Splunk $SPLUNK_VERSION installer"
    echo "  What do you want to do?"
    echo "    1) Install Splunk Universal Forwarder  (Linux or macOS)"
    echo "    2) Install Splunk Enterprise server    (Linux only)"
    echo "    3) Uninstall an existing Splunk install"
    echo "    4) Back up Splunk Enterprise config    (Linux only, config-only)"
    echo "    5) Restore Splunk Enterprise from a backup tarball"
    echo "    6) Apply performance tuning             (non-prod VM, IOWait profile)"
    echo "    7) Revert performance tuning"
    local c
    while :; do
        read -rp "  Choice [1-7, default 1]: " c
        c="${c:-1}"
        [[ "$c" =~ ^[1234567]$ ]] && break
        warn "Enter 1-7."
    done
    case "$c" in
        1) ACTION="install";   PRODUCT="uf" ;;
        2) ACTION="install";   PRODUCT="enterprise" ;;
        3) ACTION="uninstall" ;;
        4) ACTION="backup";    PRODUCT="enterprise" ;;
        5) ACTION="restore";   PRODUCT="enterprise" ;;
        6) ACTION="tune";      PRODUCT="enterprise" ;;
        7) ACTION="untune";    PRODUCT="enterprise" ;;
    esac
}

# ---------------------------------------------------------------------------
# Derive product-specific settings + URLs
# ---------------------------------------------------------------------------
set_product_vars() {
    if [[ "$PRODUCT" == "uf" ]]; then
        PRODUCT_NAME="Splunk Universal Forwarder"
        PRODUCT_PATH="universalforwarder"
        PKG_PREFIX="splunkforwarder"
        SPLUNK_HOME_LINUX="${SPLUNK_HOME_LINUX:-$UF_HOME_DEFAULT}"
        SPLUNK_HOME_MACOS="${SPLUNK_HOME_MACOS:-$UF_HOME_DEFAULT}"
        SPLUNK_RUN_USER_LINUX="${SPLUNK_RUN_USER_LINUX:-$UF_USER_DEFAULT}"
        SPLUNK_RUN_GROUP_LINUX="${SPLUNK_RUN_GROUP_LINUX:-$UF_GROUP_DEFAULT}"
        SYSTEMD_UNIT="SplunkForwarder.service"
    else
        PRODUCT_NAME="Splunk Enterprise"
        PRODUCT_PATH="splunk"
        PKG_PREFIX="splunk"
        SPLUNK_HOME_LINUX="${SPLUNK_HOME_LINUX:-$ENT_HOME_DEFAULT}"
        SPLUNK_HOME_MACOS=""  # n/a
        SPLUNK_RUN_USER_LINUX="${SPLUNK_RUN_USER_LINUX:-$ENT_USER_DEFAULT}"
        SPLUNK_RUN_GROUP_LINUX="${SPLUNK_RUN_GROUP_LINUX:-$ENT_GROUP_DEFAULT}"
        SYSTEMD_UNIT="Splunkd.service"
    fi

    BASE_URL="https://download.splunk.com/products/${PRODUCT_PATH}/releases/${SPLUNK_VERSION}"
    DEB_URL="${BASE_URL}/linux/${PKG_PREFIX}-${SPLUNK_VERSION}-${SPLUNK_BUILD}-linux-amd64.deb"
    RPM_URL="${BASE_URL}/linux/${PKG_PREFIX}-${SPLUNK_VERSION}-${SPLUNK_BUILD}.x86_64.rpm"
    TGZ_LINUX_URL="${BASE_URL}/linux/${PKG_PREFIX}-${SPLUNK_VERSION}-${SPLUNK_BUILD}-linux-amd64.tgz"
    TGZ_MACOS_URL="${BASE_URL}/osx/${PKG_PREFIX}-${SPLUNK_VERSION}-${SPLUNK_BUILD}-darwin-intel.tgz"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
    local uname_s uname_m
    uname_s="$(uname -s)"
    uname_m="$(uname -m)"

    [[ "$uname_m" == "x86_64" || "$uname_m" == "amd64" ]] \
        || die "Unsupported architecture: $uname_m (script targets x86_64 only)."

    case "$uname_s" in
        Linux)
            OS="linux"
            SPLUNK_HOME="$SPLUNK_HOME_LINUX"
            if command -v dpkg >/dev/null 2>&1 && [[ -f /etc/debian_version ]]; then
                PKG_FMT="deb"; PKG_URL="$DEB_URL"
            elif command -v rpm >/dev/null 2>&1 && \
                 { [[ -f /etc/redhat-release ]] || [[ -f /etc/system-release ]] || \
                   { [[ -f /etc/os-release ]] && grep -Eiq 'rhel|centos|rocky|alma|amzn|fedora' /etc/os-release; }; }; then
                PKG_FMT="rpm"; PKG_URL="$RPM_URL"
            else
                warn "No dpkg/rpm detected — falling back to generic .tgz."
                PKG_FMT="tgz"; PKG_URL="$TGZ_LINUX_URL"
            fi
            ;;
        Darwin)
            [[ "$PRODUCT" == "enterprise" ]] \
                && die "Splunk Enterprise is not supported on macOS by this script (Linux only)."
            OS="macos"
            SPLUNK_HOME="$SPLUNK_HOME_MACOS"
            PKG_FMT="tgz"; PKG_URL="$TGZ_MACOS_URL"
            ;;
        *)
            die "Unsupported OS: $uname_s"
            ;;
    esac
    ok "Platform: $OS/$uname_m, pkg=$PKG_FMT, target=$SPLUNK_HOME"
}

# ---------------------------------------------------------------------------
# Bail if already installed
# ---------------------------------------------------------------------------
check_existing() {
    if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
        die "Splunk is already installed at $SPLUNK_HOME.
Remove it before re-running:
  $SPLUNK_HOME/bin/splunk stop || true
  $SPLUNK_HOME/bin/splunk disable boot-start || true
  # Linux packages:
  #   apt-get remove -y ${PKG_PREFIX}      # deb
  #   dnf remove -y ${PKG_PREFIX}          # rpm
  rm -rf $SPLUNK_HOME"
    fi
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
prompt_inputs() {
    hdr "$PRODUCT_NAME $SPLUNK_VERSION — setup"

    if [[ "$PRODUCT" == "uf" ]]; then
        echo "  Connection mode:"
        echo "    1) Deployment server  (recommended — inputs pushed from server)"
        echo "    2) Direct to indexer  (configure outputs.conf locally)"
        local mode
        while :; do
            read -rp "  Choice [1-2, default 1]: " mode
            mode="${mode:-1}"
            [[ "$mode" =~ ^[12]$ ]] && break
            warn "Enter 1 or 2."
        done
        CONNECTION_MODE="$mode"

        if [[ "$CONNECTION_MODE" == "1" ]]; then
            read -rp "  Deployment server host [$SPLUNK_DEPLOYMENT_SERVER_DEFAULT]: " DS_HOST
            DS_HOST="${DS_HOST:-$SPLUNK_DEPLOYMENT_SERVER_DEFAULT}"
            read -rp "  Deployment server port [$SPLUNK_DEPLOYMENT_PORT_DEFAULT]: " DS_PORT
            DS_PORT="${DS_PORT:-$SPLUNK_DEPLOYMENT_PORT_DEFAULT}"
        else
            read -rp "  Indexer (receiver) host [$SPLUNK_DEPLOYMENT_SERVER_DEFAULT]: " IDX_HOST
            IDX_HOST="${IDX_HOST:-$SPLUNK_DEPLOYMENT_SERVER_DEFAULT}"
            read -rp "  Indexer receiver port [9997]: " IDX_PORT
            IDX_PORT="${IDX_PORT:-9997}"
        fi
    else
        # Enterprise-specific options
        read -rp "  Enable TCP receiver on port $SPLUNK_RECEIVER_PORT_DEFAULT (let UFs forward in)? [Y/n] " e
        e="${e:-Y}"
        [[ "$e" =~ ^[Yy]$ ]] && ENABLE_RECEIVER=1 || ENABLE_RECEIVER=0

        if [[ "$ENABLE_RECEIVER" == "1" ]]; then
            read -rp "  Receiver port [$SPLUNK_RECEIVER_PORT_DEFAULT]: " RECEIVER_PORT
            RECEIVER_PORT="${RECEIVER_PORT:-$SPLUNK_RECEIVER_PORT_DEFAULT}"
        fi

        read -rp "  Pre-stage deployment-server directory (etc/deployment-apps)? [y/N] " d
        d="${d:-N}"
        [[ "$d" =~ ^[Yy]$ ]] && ENABLE_DEPLOY_SERVER=1 || ENABLE_DEPLOY_SERVER=0

        read -rp "  Enable HTTPS on Splunk Web :8000 (Splunk generates a self-signed cert)? [Y/n] " s
        s="${s:-Y}"
        [[ "$s" =~ ^[Yy]$ ]] && ENABLE_WEB_SSL=1 || ENABLE_WEB_SSL=0
    fi

    echo
    echo "  Admin account (required — Splunk needs a local admin at first boot)."
    echo "  Note: auth tokens (JWT) can replace user:password for REST calls"
    echo "        AFTER install, but do not remove the first-boot admin requirement."
    read -rp "  Admin username [$SPLUNK_ADMIN_USER_DEFAULT]: " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-$SPLUNK_ADMIN_USER_DEFAULT}"

    local pw1 pw2
    while :; do
        read -rsp "  Admin password (>=8 chars): " pw1; echo
        [[ ${#pw1} -ge 8 ]] || { warn "Must be at least 8 characters."; continue; }
        read -rsp "  Confirm password: " pw2; echo
        [[ "$pw1" == "$pw2" ]] && break
        warn "Passwords do not match — try again."
    done
    ADMIN_PASS="$pw1"

    hdr "Review"
    echo "  Product          : $PRODUCT_NAME"
    echo "  OS / package     : $OS / $PKG_FMT"
    echo "  Install path     : $SPLUNK_HOME"
    echo "  Version / build  : $SPLUNK_VERSION / $SPLUNK_BUILD"
    if [[ "$PRODUCT" == "uf" ]]; then
        if [[ "$CONNECTION_MODE" == "1" ]]; then
            echo "  Deployment server: ${DS_HOST}:${DS_PORT}"
        else
            echo "  Indexer receiver : ${IDX_HOST}:${IDX_PORT}"
        fi
    else
        echo "  TCP receiver     : $([[ "$ENABLE_RECEIVER" == "1" ]] && echo "enabled on :$RECEIVER_PORT" || echo "disabled")"
        echo "  Deployment server: $([[ "$ENABLE_DEPLOY_SERVER" == "1" ]] && echo "etc/deployment-apps will be pre-staged" || echo "not pre-staged")"
        echo "  Splunk Web HTTPS : $([[ "$ENABLE_WEB_SSL" == "1" ]] && echo "enabled (self-signed cert)" || echo "disabled (HTTP only)")"
    fi
    echo "  Admin user       : $ADMIN_USER"
    echo "  Admin password   : (hidden)"
    echo
    read -rp "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# ---------------------------------------------------------------------------
# Download + SHA512 (Splunk ships BSD-style digests: "SHA512(file)= <hex>")
# ---------------------------------------------------------------------------
sha512_verify() {
    local file="$1" expected_file="$2" expected actual
    expected="$(awk '{print tolower($NF)}' "$expected_file")"
    if command -v sha512sum >/dev/null 2>&1; then
        actual="$(sha512sum "$file" | awk '{print tolower($1)}')"
    else
        actual="$(shasum -a 512 "$file" | awk '{print tolower($1)}')"
    fi
    [[ -n "$expected" && "$expected" == "$actual" ]] \
        || die "SHA512 mismatch on $(basename "$file") (expected=$expected actual=$actual)"
    ok "SHA512 verified: $(basename "$file")"
}

# Produce a SHA-512 crypt hash ($6$...) for use as HASHED_PASSWORD in
# user-seed.conf. Prints the hash on stdout, returns non-zero if no hashing
# tool is available (caller should fall back to plaintext).
hash_password() {
    local pw="$1" h=""
    if command -v openssl >/dev/null 2>&1; then
        h="$(printf '%s' "$pw" | openssl passwd -6 -stdin 2>/dev/null || true)"
        if [[ "$h" == \$6\$* ]]; then printf '%s' "$h"; return 0; fi
    fi
    if command -v mkpasswd >/dev/null 2>&1; then
        h="$(printf '%s' "$pw" | mkpasswd -m sha-512 -s 2>/dev/null || true)"
        if [[ "$h" == \$6\$* ]]; then printf '%s' "$h"; return 0; fi
    fi
    return 1
}

# Splunk best practice for Enterprise (and useful on UF): disable
# Transparent Huge Pages. Implemented as a systemd drop-in that runs
# as root via the `+` prefix before the service user starts splunkd.
# Requires systemd >= 231 — fine on RHEL 8+, Ubuntu 20+, Debian 11+.
apply_thp_dropin() {
    [[ "$OS" == "linux" ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit="$1" d="/etc/systemd/system/$1.d"
    mkdir -p "$d"
    cat > "$d/10-disable-thp.conf" <<'EOF'
# Disable Transparent Huge Pages for Splunk. `+` runs this as root
# regardless of the service's User=. Errors are swallowed so a read-only
# /sys (containers, certain kernels) doesn't break the service.
[Service]
ExecStartPre=+/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null; exit 0'
EOF
    ok "THP-disable drop-in: $d/10-disable-thp.conf"
}

# Fallback ulimits for non-systemd Linux (systemd-managed boot-start
# already sets these via its generated unit file). Values match Splunk's
# documented recommendations.
write_limits_d_fallback() {
    [[ "$OS" == "linux" ]] || return 0
    [[ ! -d /etc/security/limits.d ]] && return 0
    local u="$SPLUNK_RUN_USER_LINUX"
    local f="/etc/security/limits.d/80-splunk.conf"
    cat > "$f" <<EOF
# Splunk ulimit recommendations — used when boot-start is not systemd-managed.
${u}  soft  nofile  65536
${u}  hard  nofile  65536
${u}  soft  nproc   16000
${u}  hard  nproc   16000
${u}  soft  fsize   unlimited
${u}  hard  fsize   unlimited
EOF
    ok "Wrote $f (applies at next login session for $u)"
}

download_package() {
    hdr "Downloading $PKG_FMT package"
    local tmpdir fname sha_file
    tmpdir="$(mktemp -d -t splunkinst.XXXXXX)"
    fname="$(basename "$PKG_URL")"
    PKG_LOCAL="$tmpdir/$fname"
    sha_file="$tmpdir/${fname}.sha512"

    info "URL: $PKG_URL"
    curl -fSL --progress-bar  "$PKG_URL"             -o "$PKG_LOCAL"
    curl -fSL --silent        "${PKG_URL}.sha512"    -o "$sha_file"
    sha512_verify "$PKG_LOCAL" "$sha_file"
}

# ---------------------------------------------------------------------------
# Install package
# ---------------------------------------------------------------------------
install_package() {
    hdr "Installing $PKG_FMT package"
    case "$PKG_FMT" in
        deb)
            DEBIAN_FRONTEND=noninteractive dpkg -i "$PKG_LOCAL"
            ;;
        rpm)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "$PKG_LOCAL"
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "$PKG_LOCAL"
            else
                rpm -ivh "$PKG_LOCAL"
            fi
            ;;
        tgz)
            local parent; parent="$(dirname "$SPLUNK_HOME")"
            mkdir -p "$parent"
            tar -xzf "$PKG_LOCAL" -C "$parent"
            ;;
    esac
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] \
        || die "Install failed — $SPLUNK_HOME/bin/splunk not found."
    ok "Installed at $SPLUNK_HOME"
}

# ---------------------------------------------------------------------------
# Runtime user (Linux non-root; macOS = root)
# ---------------------------------------------------------------------------
ensure_runtime_user() {
    if [[ "$OS" == "linux" ]]; then
        if ! getent group "$SPLUNK_RUN_GROUP_LINUX" >/dev/null; then
            groupadd -r "$SPLUNK_RUN_GROUP_LINUX"
            ok "Created group $SPLUNK_RUN_GROUP_LINUX"
        fi
        if ! id -u "$SPLUNK_RUN_USER_LINUX" >/dev/null 2>&1; then
            useradd -r -g "$SPLUNK_RUN_GROUP_LINUX" -d "$SPLUNK_HOME" \
                    -s /bin/bash -c "$PRODUCT_NAME" "$SPLUNK_RUN_USER_LINUX"
            ok "Created user $SPLUNK_RUN_USER_LINUX"
        fi
        RUN_AS_USER="$SPLUNK_RUN_USER_LINUX"
    else
        RUN_AS_USER="root"
    fi
    info "Runtime user: $RUN_AS_USER"
}

# ---------------------------------------------------------------------------
# Config files
# ---------------------------------------------------------------------------
write_configs() {
    hdr "Writing configuration"
    local localdir="$SPLUNK_HOME/etc/system/local"
    mkdir -p "$localdir"

    # Prefer HASHED_PASSWORD ($6$ SHA-512 crypt) so cleartext never touches
    # disk. If neither openssl nor mkpasswd can produce a hash, fall back to
    # PASSWORD (plaintext) — Splunk replaces it with a hash and deletes the
    # plaintext on first start. Either way, do NOT bake this file into an
    # image or AMI: all instances would share the same admin credential.
    local hashed=""
    if hashed="$(hash_password "$ADMIN_PASS")"; then
        cat > "$localdir/user-seed.conf" <<EOF
[user_info]
USERNAME = $ADMIN_USER
HASHED_PASSWORD = $hashed
EOF
        ok "Wrote user-seed.conf with SHA-512 hashed password"
    else
        cat > "$localdir/user-seed.conf" <<EOF
[user_info]
USERNAME = $ADMIN_USER
PASSWORD = $ADMIN_PASS
EOF
        warn "No openssl/mkpasswd — wrote plaintext PASSWORD (removed on first start)"
    fi
    chmod 600 "$localdir/user-seed.conf"

    if [[ "$PRODUCT" == "uf" ]]; then
        if [[ "$CONNECTION_MODE" == "1" ]]; then
            cat > "$localdir/deploymentclient.conf" <<EOF
[deployment-client]

[target-broker:deploymentServer]
targetUri = ${DS_HOST}:${DS_PORT}
EOF
            ok "Wrote deploymentclient.conf -> ${DS_HOST}:${DS_PORT}"
        else
            cat > "$localdir/outputs.conf" <<EOF
[tcpout]
defaultGroup = default-autolb-group

[tcpout:default-autolb-group]
server = ${IDX_HOST}:${IDX_PORT}

[tcpout-server://${IDX_HOST}:${IDX_PORT}]
EOF
            ok "Wrote outputs.conf -> ${IDX_HOST}:${IDX_PORT}"
        fi
    else
        # Enterprise: optionally enable receiver on 9997
        if [[ "$ENABLE_RECEIVER" == "1" ]]; then
            cat > "$localdir/inputs.conf" <<EOF
[splunktcp://${RECEIVER_PORT}]
disabled = 0
EOF
            ok "Wrote inputs.conf -> receiver on :${RECEIVER_PORT}"
        fi
        # Optionally pre-stage deployment-apps dir so this box can act as DS.
        # Actual serverclass.conf and apps are still up to the operator.
        if [[ "$ENABLE_DEPLOY_SERVER" == "1" ]]; then
            mkdir -p "$SPLUNK_HOME/etc/deployment-apps"
            ok "Pre-staged $SPLUNK_HOME/etc/deployment-apps"
        fi
        # HTTPS on Splunk Web — splunkd auto-generates a self-signed cert on
        # first start (etc/auth/splunkweb/{cert.pem,privkey.pem}). Replace
        # with a CA-issued cert for production.
        if [[ "$ENABLE_WEB_SSL" == "1" ]]; then
            cat > "$localdir/web.conf" <<EOF
[settings]
enableSplunkWebSSL = true
EOF
            ok "Wrote web.conf -> HTTPS on :8000"
        fi
    fi
}

# ---------------------------------------------------------------------------
# First start + boot-start
# ---------------------------------------------------------------------------
first_start_and_boot_start() {
    hdr "First start (accepts EULA, consumes user-seed.conf)"
    if [[ "$OS" == "linux" ]]; then
        chown -R "$SPLUNK_RUN_USER_LINUX:$SPLUNK_RUN_GROUP_LINUX" "$SPLUNK_HOME"
        sudo -u "$SPLUNK_RUN_USER_LINUX" \
            "$SPLUNK_HOME/bin/splunk" start --accept-license --answer-yes --no-prompt

        hdr "Switching to systemd boot-start"
        sudo -u "$SPLUNK_RUN_USER_LINUX" "$SPLUNK_HOME/bin/splunk" stop || true
        if command -v systemctl >/dev/null 2>&1; then
            "$SPLUNK_HOME/bin/splunk" enable boot-start \
                -user "$SPLUNK_RUN_USER_LINUX" -systemd-managed 1 \
                || "$SPLUNK_HOME/bin/splunk" enable boot-start -user "$SPLUNK_RUN_USER_LINUX"

            # Detect the actual unit name Splunk created (Splunkd.service for
            # Enterprise, SplunkForwarder.service for UF; some releases used
            # SplunkEnterprise.service).
            local unit
            unit="$(systemctl list-unit-files --no-legend --type=service 2>/dev/null \
                    | awk '/^(Splunkd|SplunkForwarder|SplunkEnterprise)\.service/ {print $1; exit}')"
            unit="${unit:-$SYSTEMD_UNIT}"

            # Apply THP-disable drop-in (Enterprise only — indexers care
            # most; UFs don't benefit enough to justify touching /sys).
            [[ "$PRODUCT" == "enterprise" ]] && apply_thp_dropin "$unit"

            systemctl daemon-reload
            systemctl enable --now "$unit"
            info "systemd unit: $unit"
        else
            warn "systemd not found — falling back to legacy boot-start."
            "$SPLUNK_HOME/bin/splunk" enable boot-start -user "$SPLUNK_RUN_USER_LINUX"
            write_limits_d_fallback
            sudo -u "$SPLUNK_RUN_USER_LINUX" "$SPLUNK_HOME/bin/splunk" start
        fi
    else
        # macOS (UF only) — launchd
        "$SPLUNK_HOME/bin/splunk" start --accept-license --answer-yes --no-prompt
        hdr "Enabling launchd boot-start"
        "$SPLUNK_HOME/bin/splunk" enable boot-start
    fi
    ok "splunkd is running."
}

# ---------------------------------------------------------------------------
# Verify + summary
# ---------------------------------------------------------------------------
verify() {
    hdr "Verification"
    if [[ "$OS" == "linux" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager status "$SYSTEMD_UNIT" 2>/dev/null \
            || systemctl --no-pager status Splunkd.service 2>/dev/null \
            || systemctl --no-pager status SplunkForwarder.service 2>/dev/null \
            || true
    fi
    if [[ "$OS" == "linux" ]]; then
        sudo -u "$SPLUNK_RUN_USER_LINUX" "$SPLUNK_HOME/bin/splunk" status || true
    else
        "$SPLUNK_HOME/bin/splunk" status || true
    fi

    echo
    ok "Install complete: $PRODUCT_NAME $SPLUNK_VERSION"
    echo
    echo "  Install path  : $SPLUNK_HOME"
    echo "  Run-as user   : $RUN_AS_USER"
    echo "  Admin user    : $ADMIN_USER"
    echo "  Mgmt port     : 8089"
    if [[ "$PRODUCT" == "uf" ]]; then
        if [[ "$CONNECTION_MODE" == "1" ]]; then
            echo "  Polling DS    : ${DS_HOST}:${DS_PORT}"
            echo
            echo "  On the deployment server, confirm with:"
            echo "    splunk list deploy-clients -auth admin:<pw>"
        else
            echo "  Forwarding to : ${IDX_HOST}:${IDX_PORT}"
            echo
            echo "  Add file monitors (example):"
            echo "    $SPLUNK_HOME/bin/splunk add monitor /var/log -auth ${ADMIN_USER}:<pw>"
        fi
    else
        local scheme="http"
        [[ "$ENABLE_WEB_SSL" == "1" ]] && scheme="https"
        echo "  Web UI        : ${scheme}://$(hostname -f 2>/dev/null || hostname):8000"
        [[ "$ENABLE_WEB_SSL" == "1" ]] \
            && echo "                  (self-signed cert — replace for prod: $SPLUNK_HOME/etc/auth/splunkweb/)"
        [[ "$ENABLE_RECEIVER" == "1" ]] \
            && echo "  TCP receiver  : :${RECEIVER_PORT} (open this port in your firewall)"
        [[ "$ENABLE_DEPLOY_SERVER" == "1" ]] \
            && echo "  DS apps dir   : $SPLUNK_HOME/etc/deployment-apps"
        echo
        echo "  Firewall: open 8000/tcp (web), 8089/tcp (mgmt)$([[ "$ENABLE_RECEIVER" == "1" ]] && echo ", ${RECEIVER_PORT}/tcp (receiver)")."
        echo "  THP disabled via $([[ -f /etc/systemd/system/${SYSTEMD_UNIT}.d/10-disable-thp.conf ]] && echo "systemd drop-in" || echo "not applied — check manually")."
    fi
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# UNINSTALL
# ---------------------------------------------------------------------------

# Case-insensitive compare that works on macOS bash 3.2 (no ${var,,}).
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# Find existing installs at the default paths.
detect_existing_installs() {
    UF_FOUND=0; ENT_FOUND=0
    UF_PATH=""; ENT_PATH=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local p="${SPLUNK_HOME_MACOS:-$UF_HOME_DEFAULT}"
        [[ -x "$p/bin/splunk" ]] && { UF_FOUND=1; UF_PATH="$p"; }
    else
        [[ -x "$UF_HOME_DEFAULT/bin/splunk" ]]  && { UF_FOUND=1;  UF_PATH="$UF_HOME_DEFAULT"; }
        [[ -x "$ENT_HOME_DEFAULT/bin/splunk" ]] && { ENT_FOUND=1; ENT_PATH="$ENT_HOME_DEFAULT"; }
    fi
}

# If multiple installs are present, ask which to remove. Sets PRODUCT +
# SPLUNK_HOME.
choose_install_to_remove() {
    if [[ $UF_FOUND -eq 0 && $ENT_FOUND -eq 0 ]]; then
        die "No Splunk install found at $UF_HOME_DEFAULT or $ENT_HOME_DEFAULT.
If you installed to a custom path, re-run with SPLUNK_HOME_LINUX set."
    fi
    local opts=() paths=() i=1
    [[ $UF_FOUND  -eq 1 ]] && { opts+=("uf");         paths+=("$UF_PATH");  echo "  $i) Universal Forwarder at $UF_PATH";  ((i++)); }
    [[ $ENT_FOUND -eq 1 ]] && { opts+=("enterprise"); paths+=("$ENT_PATH"); echo "  $i) Splunk Enterprise at $ENT_PATH"; ((i++)); }

    local idx=0
    if [[ ${#opts[@]} -gt 1 ]]; then
        local c
        while :; do
            read -rp "  Remove which? [1-${#opts[@]}]: " c
            [[ "$c" =~ ^[1-9][0-9]*$ ]] && (( c >= 1 && c <= ${#opts[@]} )) && { idx=$((c-1)); break; }
            warn "Invalid choice."
        done
    fi
    PRODUCT="${opts[$idx]}"
    SPLUNK_HOME="${paths[$idx]}"
}

# Summarise what's on disk so the user can confirm they're removing the
# right thing.
summarize_install() {
    hdr "Found $PRODUCT_NAME at $SPLUNK_HOME"

    local version=""
    [[ -f "$SPLUNK_HOME/etc/splunk.version" ]] \
        && version="$(awk -F= '/^VERSION=/{print $2}' "$SPLUNK_HOME/etc/splunk.version")"
    [[ -n "$version" ]] && info "Version       : $version"

    # Detect install method for later package-manager removal.
    INSTALL_METHOD="tgz"
    if [[ "$OS" == "linux" ]]; then
        if command -v dpkg >/dev/null 2>&1 && dpkg -l "$PKG_PREFIX" 2>/dev/null | grep -q '^ii'; then
            INSTALL_METHOD="deb"
        elif command -v rpm >/dev/null 2>&1 && rpm -q "$PKG_PREFIX" >/dev/null 2>&1; then
            INSTALL_METHOD="rpm"
        fi
    fi
    info "Install from  : $INSTALL_METHOD"

    if command -v du >/dev/null 2>&1; then
        local size; size="$(du -sh "$SPLUNK_HOME" 2>/dev/null | awk '{print $1}')"
        [[ -n "$size" ]] && info "Disk usage    : $size"
    fi

    SYSTEMD_UNIT_ACTUAL=""
    if [[ "$OS" == "linux" ]] && command -v systemctl >/dev/null 2>&1; then
        SYSTEMD_UNIT_ACTUAL="$(systemctl list-unit-files --no-legend --type=service 2>/dev/null \
            | awk '/^(Splunkd|SplunkForwarder|SplunkEnterprise)\.service/ {print $1; exit}')"
        if [[ -n "$SYSTEMD_UNIT_ACTUAL" ]]; then
            local active; active="$(systemctl is-active "$SYSTEMD_UNIT_ACTUAL" 2>/dev/null || echo unknown)"
            info "systemd unit  : $SYSTEMD_UNIT_ACTUAL (status: $active)"
        fi
    fi
}

# Big-red-button confirmation: user must type the hostname, not just y/N.
confirm_uninstall() {
    local h; h="$(hostname -s 2>/dev/null || hostname)"
    echo
    warn "This will STOP the service, REMOVE the package, and take down $PRODUCT_NAME."
    warn "No action is taken on the service user ($SPLUNK_RUN_USER_LINUX) — left in place."
    echo
    local typed
    read -rp "  To proceed, type this host's short name ($h): " typed
    [[ "$(to_lower "$typed")" == "$(to_lower "$h")" ]] \
        || die "Hostname did not match — aborted. Nothing has changed."
}

# Data is separate from removal: keep indexes (rename dir) or delete them.
ask_data_handling() {
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    RENAMED_PATH="${SPLUNK_HOME}.removed-${ts}"
    echo
    echo "  What about indexed data, user apps, and local configs?"
    echo "    1) Keep   — rename $SPLUNK_HOME -> $RENAMED_PATH   (safe, reversible)"
    echo "    2) Delete — rm -rf $SPLUNK_HOME                    (PERMANENT, irreversible)"
    local c
    while :; do
        read -rp "  Choice [1-2, default 1]: " c
        c="${c:-1}"
        [[ "$c" =~ ^[12]$ ]] && break
        warn "Enter 1 or 2."
    done
    if [[ "$c" == "2" ]]; then
        echo
        warn "You chose to DELETE all data. This includes indexes, user apps, certs, secrets."
        local confirm
        read -rp "  Type DELETE (upper case) to confirm, anything else to abort: " confirm
        [[ "$confirm" == "DELETE" ]] || die "Confirmation did not match — aborted."
        DATA_ACTION="delete"
    else
        DATA_ACTION="rename"
    fi
}

teardown_service() {
    hdr "Stopping service + disabling boot-start"
    if [[ "$OS" == "linux" ]]; then
        if command -v systemctl >/dev/null 2>&1 && [[ -n "${SYSTEMD_UNIT_ACTUAL:-}" ]]; then
            systemctl stop    "$SYSTEMD_UNIT_ACTUAL" 2>/dev/null || true
            systemctl disable "$SYSTEMD_UNIT_ACTUAL" 2>/dev/null || true
            ok "systemd: stopped + disabled $SYSTEMD_UNIT_ACTUAL"
        fi
        # Remove our drop-ins (THP + anything else) + any stale unit symlinks.
        local u
        for u in Splunkd SplunkForwarder SplunkEnterprise; do
            if [[ -d "/etc/systemd/system/${u}.service.d" ]]; then
                rm -rf "/etc/systemd/system/${u}.service.d"
                ok "Removed /etc/systemd/system/${u}.service.d"
            fi
        done
        # splunk CLI teardown covers SysV + launchd; harmless on systemd.
        if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
            "$SPLUNK_HOME/bin/splunk" stop 2>/dev/null || true
            "$SPLUNK_HOME/bin/splunk" disable boot-start 2>/dev/null || true
        fi
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    else
        # macOS — launchd
        if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
            "$SPLUNK_HOME/bin/splunk" disable boot-start 2>/dev/null || true
            "$SPLUNK_HOME/bin/splunk" stop 2>/dev/null || true
            ok "splunk: stopped + boot-start disabled (launchd plist removed)"
        fi
    fi
}

# Archive etc/system/local + etc/apps + etc/deployment-apps to a tarball
# under /root (Linux) or /var/root (macOS) before we touch anything.
backup_configs() {
    hdr "Backing up configs"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local dir="/root"
    [[ "$OS" == "macos" ]] && dir="/var/root"
    [[ -d "$dir" && -w "$dir" ]] || dir="/tmp"
    BACKUP_PATH="${dir}/splunk-backup-${PRODUCT}-${ts}.tgz"

    local items=()
    [[ -d "$SPLUNK_HOME/etc/system/local" ]]  && items+=("etc/system/local")
    [[ -d "$SPLUNK_HOME/etc/apps" ]]          && items+=("etc/apps")
    [[ -d "$SPLUNK_HOME/etc/deployment-apps" ]] && items+=("etc/deployment-apps")
    [[ -d "$SPLUNK_HOME/etc/auth" ]]          && items+=("etc/auth")

    if [[ ${#items[@]} -eq 0 ]]; then
        info "No configs found to back up — skipping."
        BACKUP_PATH=""
        return 0
    fi
    if (cd "$SPLUNK_HOME" && tar -czf "$BACKUP_PATH" "${items[@]}" 2>/dev/null); then
        chmod 600 "$BACKUP_PATH"
        ok "Backup: $BACKUP_PATH ($(du -h "$BACKUP_PATH" 2>/dev/null | awk '{print $1}'))"
    else
        warn "Backup failed — continuing."
        BACKUP_PATH=""
    fi
}

# Before `apt-get remove`/`dnf remove`, clear Python bytecode caches that
# splunkd generates at runtime. dpkg/rpm only track files they installed,
# so they refuse to rmdir any directory containing runtime-generated files
# and emit a warning per directory (~17 warnings is typical on Splunk
# Enterprise). Clearing the caches first keeps the output quiet and
# doesn't affect anything — they regenerate on next splunkd start.
clean_bytecode_caches() {
    [[ -d "$SPLUNK_HOME" ]] || return 0
    local cleaned=0
    if [[ -d "$SPLUNK_HOME/lib" || -d "$SPLUNK_HOME/share" ]]; then
        find "$SPLUNK_HOME/lib" "$SPLUNK_HOME/share" \
            \( -type d -name '__pycache__' -o -type f -name '*.pyc' -o -type f -name '*.pyo' \) \
            -print 2>/dev/null \
            | head -1 >/dev/null && cleaned=1
        find "$SPLUNK_HOME/lib" "$SPLUNK_HOME/share" \
            \( -type d -name '__pycache__' -o -type f -name '*.pyc' -o -type f -name '*.pyo' \) \
            -exec rm -rf {} + 2>/dev/null || true
    fi
    [[ $cleaned -eq 1 ]] && ok "Cleared Python bytecode caches (silences dpkg/rpm warnings)."
}

run_package_remove() {
    case "$INSTALL_METHOD" in
        deb)
            hdr "Removing deb package"
            clean_bytecode_caches
            DEBIAN_FRONTEND=noninteractive apt-get remove -y "$PKG_PREFIX" \
                || dpkg -r "$PKG_PREFIX" \
                || warn "Package manager removal returned non-zero — continuing."
            ;;
        rpm)
            hdr "Removing rpm package"
            clean_bytecode_caches
            if command -v dnf >/dev/null 2>&1; then
                dnf remove -y "$PKG_PREFIX" || warn "dnf remove failed — continuing."
            elif command -v yum >/dev/null 2>&1; then
                yum remove -y "$PKG_PREFIX" || warn "yum remove failed — continuing."
            else
                rpm -e "$PKG_PREFIX" || warn "rpm -e failed — continuing."
            fi
            ;;
        tgz|*)
            info "tgz install — no package-manager record to remove."
            ;;
    esac
}

handle_data_removal() {
    if [[ ! -d "$SPLUNK_HOME" ]]; then
        info "$SPLUNK_HOME already gone (cleared by package remove)."
        return 0
    fi
    case "$DATA_ACTION" in
        rename)
            mv "$SPLUNK_HOME" "$RENAMED_PATH"
            ok "Renamed $SPLUNK_HOME -> $RENAMED_PATH"
            ;;
        delete)
            rm -rf "$SPLUNK_HOME"
            ok "Deleted $SPLUNK_HOME"
            ;;
    esac
}

cleanup_extras() {
    if [[ -f /etc/security/limits.d/80-splunk.conf ]]; then
        rm -f /etc/security/limits.d/80-splunk.conf
        ok "Removed /etc/security/limits.d/80-splunk.conf"
    fi
}

uninstall_summary() {
    hdr "Uninstall complete"
    ok "Product: $PRODUCT_NAME removed from $SPLUNK_HOME"
    [[ -n "${BACKUP_PATH:-}" ]] && echo "  Backup         : $BACKUP_PATH"
    if [[ "$DATA_ACTION" == "rename" ]]; then
        echo "  Data preserved : $RENAMED_PATH"
        echo "  Reclaim disk later with:  sudo rm -rf $RENAMED_PATH"
    fi
    echo
    info "Service user '$SPLUNK_RUN_USER_LINUX' was NOT removed (avoids UID-reuse issues)."
    info "To remove it:  sudo userdel $SPLUNK_RUN_USER_LINUX && sudo groupdel $SPLUNK_RUN_GROUP_LINUX"
}

# Platform setup for uninstall (simpler than detect_platform's download-path
# logic — we only need OS + paths).
uninstall_set_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
    else
        OS="linux"
    fi
}

# ---------------------------------------------------------------------------
# BACKUP (Enterprise, config-only — etc/ only, no indexed data)
# ---------------------------------------------------------------------------

# Prompt for output tarball path. Default lives in the original user's
# working directory (we're root after self-sudo but $PWD is preserved).
prompt_backup_destination() {
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local h;  h="$(hostname -s 2>/dev/null || hostname)"
    local default="${PWD}/splunk-enterprise-${h}-${ts}.tgz"
    read -rp "  Output tarball path [$default]: " OUT_TARBALL
    OUT_TARBALL="${OUT_TARBALL:-$default}"
    [[ -e "$OUT_TARBALL" ]] && die "Refusing to overwrite existing file: $OUT_TARBALL"
    local dir; dir="$(dirname "$OUT_TARBALL")"
    [[ -d "$dir" ]] || { mkdir -p "$dir" && ok "Created $dir"; }
}

# Write BACKUP-MANIFEST to a temp dir and include it in the tarball at root.
# On restore we parse this to know what version / product / origin we're
# dealing with.
write_backup_manifest() {
    local ver="$1"
    local ts;  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local h;   h="$(hostname -f 2>/dev/null || hostname)"
    MANIFEST_DIR="$(mktemp -d -t splunkbkp.XXXXXX)"
    cat > "$MANIFEST_DIR/BACKUP-MANIFEST" <<EOF
# Splunk Enterprise config-only backup
product=enterprise
splunk_version=$ver
source_hostname=$h
source_splunk_home=$SPLUNK_HOME
backup_timestamp=$ts
backup_type=config-only
script_version=$SPLUNK_VERSION
EOF
}

# Tar $SPLUNK_HOME/etc plus the manifest. Exclusions:
#   - etc/auth/sessions  : live login state, useless on a new host
#   - etc/auth/audit     : audit logs, large and regenerate
#   - etc/instance.cfg   : the SERVER GUID. Intentionally EXCLUDED so the
#                          new host registers with a unique identity. If
#                          you want to preserve GUID (e.g. SH cluster
#                          replacement), hand-copy it post-restore.
create_backup_tarball() {
    tar -czf "$OUT_TARBALL" \
        --exclude='etc/auth/sessions' \
        --exclude='etc/auth/audit' \
        --exclude='etc/instance.cfg' \
        -C "$SPLUNK_HOME" etc \
        -C "$MANIFEST_DIR"  BACKUP-MANIFEST
    chmod 600 "$OUT_TARBALL"
    rm -rf "$MANIFEST_DIR"
}

backup_flow() {
    uninstall_set_os
    [[ "$OS" == "linux" ]] || die "Backup is Enterprise-only (Linux only)."
    set_product_vars
    SPLUNK_HOME="$SPLUNK_HOME_LINUX"

    [[ -x "$SPLUNK_HOME/bin/splunk" ]] \
        || die "No Splunk Enterprise install found at $SPLUNK_HOME."

    # Pull installed version from etc/splunk.version (set at install).
    local installed_version="$SPLUNK_VERSION"
    if [[ -f "$SPLUNK_HOME/etc/splunk.version" ]]; then
        installed_version="$(awk -F= '/^VERSION=/{print $2}' "$SPLUNK_HOME/etc/splunk.version")"
    fi

    hdr "Back up Splunk Enterprise (config only) from $SPLUNK_HOME"
    info "Installed version : $installed_version"
    info "Backup scope      : $SPLUNK_HOME/etc (excl. sessions, audit, instance.cfg)"
    info "Splunkd           : not stopped (file-level tar on conf dirs is safe"
    info "                    in practice; config files are rarely written)."
    echo

    prompt_backup_destination
    write_backup_manifest "$installed_version"

    hdr "Creating tarball"
    create_backup_tarball

    local sha size
    if command -v sha256sum >/dev/null 2>&1; then
        sha="$(sha256sum "$OUT_TARBALL" | awk '{print $1}')"
    else
        sha="$(shasum -a 256 "$OUT_TARBALL" | awk '{print $1}')"
    fi
    size="$(du -h "$OUT_TARBALL" 2>/dev/null | awk '{print $1}')"

    echo
    ok "Backup complete."
    echo "  File   : $OUT_TARBALL"
    echo "  Size   : $size"
    echo "  SHA256 : $sha"
    echo "  Perms  : 600 (contains splunk.secret + etc/passwd hashes — keep private)"
    echo
    echo "To restore on a fresh host:"
    echo "  1. Copy the tarball across: scp '$OUT_TARBALL' newhost:/tmp/"
    echo "  2. On newhost: ./install-splunk-native.sh  ->  choice 5"
    echo "  3. Provide the tarball path when prompted."
}

# ---------------------------------------------------------------------------
# RESTORE (Enterprise — install fresh package, then overlay etc/ from backup)
# ---------------------------------------------------------------------------

prompt_restore_tarball() {
    hdr "Restore Splunk Enterprise from backup"
    while :; do
        read -rp "  Path to backup tarball: " IN_TARBALL
        [[ -f "$IN_TARBALL" ]] && break
        warn "Not a file: $IN_TARBALL"
    done
}

# Extract the manifest into a tempdir and parse key=value pairs.
parse_backup_manifest() {
    MANIFEST_EXTRACT_DIR="$(mktemp -d -t splunkrst.XXXXXX)"
    if ! tar -xzf "$IN_TARBALL" -C "$MANIFEST_EXTRACT_DIR" BACKUP-MANIFEST 2>/dev/null; then
        die "Tarball has no BACKUP-MANIFEST — not a recognized Splunk backup."
    fi
    local m="$MANIFEST_EXTRACT_DIR/BACKUP-MANIFEST"
    BACKUP_PRODUCT="$(awk -F= '/^product=/{print $2}' "$m")"
    BACKUP_VERSION="$(awk -F= '/^splunk_version=/{print $2}' "$m")"
    BACKUP_HOSTNAME="$(awk -F= '/^source_hostname=/{print $2}' "$m")"
    BACKUP_SRC_HOME="$(awk -F= '/^source_splunk_home=/{print $2}' "$m")"
    BACKUP_TIMESTAMP="$(awk -F= '/^backup_timestamp=/{print $2}' "$m")"
    BACKUP_TYPE="$(awk -F= '/^backup_type=/{print $2}' "$m")"

    [[ "$BACKUP_PRODUCT" == "enterprise" ]] \
        || die "Unsupported backup product '$BACKUP_PRODUCT' — expected 'enterprise'."
}

confirm_restore() {
    echo
    info "Backup manifest:"
    echo "  Product         : $BACKUP_PRODUCT"
    echo "  Splunk version  : $BACKUP_VERSION"
    echo "  Source host     : $BACKUP_HOSTNAME"
    echo "  Source path     : $BACKUP_SRC_HOME"
    echo "  Backup time     : $BACKUP_TIMESTAMP"
    echo "  Backup type     : $BACKUP_TYPE"
    echo

    if [[ "$BACKUP_VERSION" != "$SPLUNK_VERSION" ]]; then
        warn "Version mismatch:"
        warn "  backup  = $BACKUP_VERSION"
        warn "  target  = $SPLUNK_VERSION (what this script installs)"
        warn "Same-minor-version restores (e.g. 10.2.1 -> 10.2.2) are generally safe."
        warn "Cross-major-version restores are UNSUPPORTED by Splunk and may corrupt config."
    fi

    echo "Plan:"
    echo "  1. Install fresh Splunk Enterprise $SPLUNK_VERSION ($PKG_FMT package)"
    echo "  2. Overlay $IN_TARBALL onto the install's etc/"
    echo "  3. Start splunkd (restored admin creds + splunk.secret take effect)"
    echo "  4. Enable systemd boot-start + THP-disable drop-in (same as fresh install)"
    echo
    local confirm
    read -rp "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# Extract etc/ from the tarball over $SPLUNK_HOME. Only etc/ — not the
# manifest, which lives at the tarball root. --no-same-owner so files
# land as root and get chowned to splunk:splunk in first_start_and_boot_start.
extract_backup_over_home() {
    hdr "Restoring config from backup"
    tar -xzf "$IN_TARBALL" -C "$SPLUNK_HOME" --no-same-owner etc
    ok "Restored $SPLUNK_HOME/etc from backup"
    rm -rf "${MANIFEST_EXTRACT_DIR:-}"
}

verify_restore() {
    hdr "Restore verification"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager status Splunkd.service 2>/dev/null || true
    fi
    sudo -u "$SPLUNK_RUN_USER_LINUX" "$SPLUNK_HOME/bin/splunk" status || true

    echo
    ok "Restore complete."
    echo "  Install path   : $SPLUNK_HOME"
    echo "  Restored from  : $IN_TARBALL"
    echo "  Origin host    : $BACKUP_HOSTNAME (path $BACKUP_SRC_HOME)"
    echo "  Admin creds    : whatever was set on the source host (etc/passwd was restored)"
    echo
    local hn; hn="$(hostname -f 2>/dev/null || hostname)"
    echo "  Web UI         : http(s)://$hn:8000  (scheme depends on restored web.conf)"
    echo
    warn "instance.cfg was NOT restored — this host gets a fresh GUID on first boot."
    warn "Deployment server / cluster peers will treat it as a new instance."
    warn "If the source host is still running, decommission it (or at minimum,"
    warn "  remove its deployment-server / cluster registration) to avoid drift."
}

restore_flow() {
    prompt_restore_tarball
    parse_backup_manifest
    set_product_vars            # PRODUCT=enterprise set at top-level menu
    detect_platform             # sets OS, PKG_FMT, PKG_URL, SPLUNK_HOME
    check_existing              # bail if Splunk is already here
    confirm_restore
    download_package
    install_package
    ensure_runtime_user
    extract_backup_over_home    # REPLACES write_configs
    first_start_and_boot_start  # chown + start + systemd + THP drop-in
    verify_restore
}

# ---------------------------------------------------------------------------
# PERFORMANCE TUNING (non-prod VM IOWait profile, Enterprise-only)
# ---------------------------------------------------------------------------

SYSCTL_FILE="/etc/sysctl.d/80-splunk-iowait.conf"
UDEV_FILE="/etc/udev/rules.d/60-splunk-ioscheduler.rules"
TUNING_APP_NAME="splunk_iowait_tuning"

# Write kernel-level tunables. vm.swappiness avoids needless swap I/O;
# dirty_ratio / dirty_background_ratio shrink page-cache flush bursts that
# stall splunkd on shared-storage VMs. Values are conservative defaults
# for a lab.
write_sysctl_tuning() {
    cat > "$SYSCTL_FILE" <<'EOF'
# Managed by install-splunk-native.sh — non-prod VM IOWait profile.
# Remove this file + run `sysctl --system` to revert (or use option 7).

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
EOF
    if command -v sysctl >/dev/null 2>&1; then
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
    ok "Wrote $SYSCTL_FILE (live: swappiness=$(sysctl -n vm.swappiness 2>/dev/null))"
}

# Force mq-deadline on virtio-blk / SCSI / NVMe. On VMs the distro default
# (bfq / none / cfq) fights the hypervisor scheduler and drives up IOWait.
# Three rules instead of one `|`-joined KERNEL match — udev's fnmatch
# doesn't reliably support `|` inside a single KERNEL value across all
# systemd versions.
write_udev_ioscheduler() {
    cat > "$UDEV_FILE" <<'EOF'
# Managed by install-splunk-native.sh — non-prod VM IOWait profile.
# Forces mq-deadline on whole-disk block devices (skips partitions).
# Remove this file + run `udevadm control --reload-rules` to revert.

# SCSI / SATA (pvscsi, VMware paravirt, many cloud providers)
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", ATTR{queue/scheduler}="mq-deadline"
# virtio-blk (KVM, Proxmox, some OpenStack)
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="vd*", ATTR{queue/scheduler}="mq-deadline"
# NVMe (Azure v2, AWS Nitro, modern VMware)
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme*n*", ATTR{queue/scheduler}="mq-deadline"
EOF
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
    fi
    # Show what actually landed on each disk-like device
    local d sched
    for d in /sys/block/sd* /sys/block/vd* /sys/block/nvme*n*; do
        [[ -r "$d/queue/scheduler" ]] || continue
        sched="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^\[/) {gsub(/[\[\]]/,"",$i); print $i}}' "$d/queue/scheduler")"
        info "  $(basename "$d") scheduler = $sched"
    done
    ok "Wrote $UDEV_FILE"
}

# Install an isolated Splunk app carrying the limits.conf overrides.
# App-based layering beats surgical-editing system/local/limits.conf:
# doesn't conflict with other stanzas the user may have added, and revert
# is a single `rm -rf`.
write_splunk_tuning_app() {
    local app="$SPLUNK_HOME/etc/apps/$TUNING_APP_NAME"
    mkdir -p "$app/default" "$app/local"

    cat > "$app/default/app.conf" <<'EOF'
# Managed by install-splunk-native.sh — non-prod VM IOWait profile.

[install]
is_configured = true

[launcher]
version = 1.0.0
description = IOWait tuning bundle for non-prod VMs (install-splunk-native.sh)

[ui]
is_visible = false

[package]
id = splunk_iowait_tuning
EOF

    cat > "$app/local/limits.conf" <<'EOF'
# Managed by install-splunk-native.sh — non-prod VM IOWait profile.
# Caps concurrent searches to reduce disk IO contention on shared VM storage.

[search]
# Concurrent ad-hoc searches per CPU (default 1, explicit here for clarity)
max_searches_per_cpu = 1
# Baseline cap independent of CPU count (default 6)
base_max_searches = 4

[scheduler]
# % of max searches available to the scheduler (default 50)
max_searches_perc = 25
EOF

    chown -R "$SPLUNK_RUN_USER_LINUX:$SPLUNK_RUN_GROUP_LINUX" "$app"
    ok "Installed app: $app"
}

# Detect the mount that contains $SPLUNK_HOME; recommend noatime if not set.
# Deliberately does NOT edit /etc/fstab — a bad fstab can prevent boot.
recommend_noatime() {
    local mp line dev fstype opts
    mp="$(df "$SPLUNK_HOME" 2>/dev/null | tail -1 | awk '{print $NF}')"
    [[ -z "$mp" ]] && { warn "Could not detect mountpoint for $SPLUNK_HOME"; return 0; }
    line="$(awk -v m="$mp" '$2 == m {print; exit}' /proc/mounts 2>/dev/null)"
    [[ -z "$line" ]] && { warn "Could not read /proc/mounts for $mp"; return 0; }
    dev="$(echo "$line" | awk '{print $1}')"
    fstype="$(echo "$line" | awk '{print $3}')"
    opts="$(echo "$line" | awk '{print $4}')"

    if echo ",$opts," | grep -q ",noatime,"; then
        ok "$mp already mounted with noatime ($dev, $fstype)."
        return 0
    fi
    echo
    warn "$mp is mounted WITHOUT noatime.  dev=$dev  fs=$fstype"
    warn "Current opts: $opts"
    warn "Recommended: add 'noatime,nodiratime' to this mount's /etc/fstab options, then:"
    warn "    sudo mount -o remount $mp"
    warn "(Not auto-edited — fstab mistakes can prevent boot.)"
}

# Conditionally restart Splunk after config changes. User confirms y/N.
restart_splunk_prompt() {
    local reason="$1"
    echo
    local r
    read -rp "Restart Splunk now to apply the $reason changes? [Y/n] " r
    r="${r:-Y}"
    if [[ "$r" =~ ^[Yy]$ ]]; then
        if command -v systemctl >/dev/null 2>&1 \
           && systemctl cat Splunkd.service >/dev/null 2>&1; then
            systemctl restart Splunkd.service
            ok "systemd: Splunkd.service restarted"
        else
            sudo -u "$SPLUNK_RUN_USER_LINUX" "$SPLUNK_HOME/bin/splunk" restart
            ok "Splunk restarted via CLI"
        fi
    else
        info "Skipped restart. Apply later with:"
        info "  sudo systemctl restart Splunkd.service"
        info "  (or sudo -u $SPLUNK_RUN_USER_LINUX $SPLUNK_HOME/bin/splunk restart)"
    fi
}

tune_flow() {
    uninstall_set_os
    [[ "$OS" == "linux" ]] || die "Performance tuning is Enterprise-only (Linux only)."
    set_product_vars
    SPLUNK_HOME="$SPLUNK_HOME_LINUX"
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] \
        || die "No Splunk Enterprise install found at $SPLUNK_HOME."

    hdr "Apply non-prod VM IOWait tuning profile"
    warn "This profile is designed for NON-PROD / LAB environments."
    warn "In production, tune against measured metrics, not static defaults."
    echo
    echo "This will write:"
    echo "  - $SYSCTL_FILE"
    echo "       vm.swappiness=10  vm.dirty_ratio=10  vm.dirty_background_ratio=5"
    echo "  - $UDEV_FILE"
    echo "       scheduler=mq-deadline for sd*/vd*/nvme* whole-disk devices"
    echo "  - $SPLUNK_HOME/etc/apps/$TUNING_APP_NAME/local/limits.conf"
    echo "       search throttles: max_searches_per_cpu=1, base_max_searches=4,"
    echo "                         scheduler.max_searches_perc=25"
    echo
    echo "And then:"
    echo "  - print a noatime recommendation if your Splunk FS lacks it"
    echo "  - prompt to restart Splunk (needed for the limits.conf changes)"
    echo
    local confirm
    read -rp "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."

    hdr "OS tunables"
    write_sysctl_tuning
    write_udev_ioscheduler

    hdr "Splunk tunables"
    write_splunk_tuning_app

    hdr "Filesystem check"
    recommend_noatime

    restart_splunk_prompt "tuning"

    echo
    ok "Tuning applied. To revert everything, re-run the script and choose option 7."
}

untune_flow() {
    uninstall_set_os
    [[ "$OS" == "linux" ]] || die "Revert is Enterprise-only (Linux only)."
    set_product_vars
    SPLUNK_HOME="$SPLUNK_HOME_LINUX"
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] \
        || die "No Splunk Enterprise install found at $SPLUNK_HOME."

    hdr "Revert non-prod VM IOWait tuning"
    echo "This will remove:"
    echo "  - $SYSCTL_FILE            (and restore kernel defaults live)"
    echo "  - $UDEV_FILE"
    echo "  - $SPLUNK_HOME/etc/apps/$TUNING_APP_NAME/"
    echo "Then prompt to restart Splunk."
    echo
    local confirm
    read -rp "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."

    # sysctl
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        # Restore live values to typical kernel defaults. A subsequent
        # `sysctl --system` reapplies whatever other /etc/sysctl.d/* files
        # define, so users who had their own overrides are unaffected.
        sysctl -w vm.swappiness=60          >/dev/null 2>&1 || true
        sysctl -w vm.dirty_ratio=20         >/dev/null 2>&1 || true
        sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
        sysctl --system                     >/dev/null 2>&1 || true
        ok "Removed $SYSCTL_FILE (live values reset to defaults)"
    else
        info "$SYSCTL_FILE not present — skipping"
    fi

    # udev
    if [[ -f "$UDEV_FILE" ]]; then
        rm -f "$UDEV_FILE"
        udevadm control --reload-rules 2>/dev/null || true
        ok "Removed $UDEV_FILE"
        info "Live scheduler stays mq-deadline until reboot; distro defaults apply at next boot."
    else
        info "$UDEV_FILE not present — skipping"
    fi

    # Splunk app
    local app="$SPLUNK_HOME/etc/apps/$TUNING_APP_NAME"
    if [[ -d "$app" ]]; then
        rm -rf "$app"
        ok "Removed $app"
    else
        info "$app not present — skipping"
    fi

    restart_splunk_prompt "revert"
    echo
    ok "Revert complete."
}

# ---------------------------------------------------------------------------
# Flow orchestrators
# ---------------------------------------------------------------------------
install_flow() {
    set_product_vars
    detect_platform
    check_existing
    prompt_inputs
    download_package
    install_package
    ensure_runtime_user
    write_configs
    first_start_and_boot_start
    verify
}

uninstall_flow() {
    uninstall_set_os
    detect_existing_installs
    hdr "Select install to remove"
    choose_install_to_remove
    set_product_vars              # gets PKG_PREFIX, PRODUCT_NAME, user/group
    summarize_install
    confirm_uninstall
    ask_data_handling
    teardown_service
    backup_configs
    run_package_remove
    handle_data_removal
    cleanup_extras
    uninstall_summary
}

main() {
    choose_action
    case "$ACTION" in
        install)   install_flow ;;
        uninstall) uninstall_flow ;;
        backup)    backup_flow ;;
        restore)   restore_flow ;;
        tune)      tune_flow ;;
        untune)    untune_flow ;;
    esac
}

main "$@"
