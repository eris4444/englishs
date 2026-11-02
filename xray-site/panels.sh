# shellcheck shell=bash
# panels.sh: installers for the 3x-ui (Sanaei) and Marzban panels and for Marzban nodes.
# Sourced by xray-site, whose helpers it uses (say, die, ask, cert_meta, print_certs, ...).

MZ_DIR=/opt/marzban
MZ_SRC=$MZ_DIR/src
MZ_DATA=/var/lib/marzban
MZ_STATE=$CONF_DIR/marzban.conf
MZ_REPO="${MARZBAN_REPO:-https://github.com/eris4444/Marzban}"
MZ_REF="${MARZBAN_REF:-master}"
NODE_DIR=/opt/marzban-node
NODE_DATA=/var/lib/marzban-node
NODE_IMAGE="${MARZBAN_NODE_IMAGE:-gozargah/marzban-node:latest}"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
XUI_INSTALL_URL="${XUI_INSTALL_URL:-https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh}"
XUI_STATE=$CONF_DIR/3x-ui.conf
DOCKER_MIRRORS="${DOCKER_MIRRORS:-https://docker.arvancloud.ir https://focker.ir https://registry.docker.ir}"
BACKUP_DIR=$CONF_DIR/backups

# ================================================================ small helpers
state_get() {  # $1 file, $2 key
    [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -1
    return 0
}

state_set() {  # $1 file, $2 key, $3 value
    mkdir -p "$(dirname "$1")"
    touch "$1"
    chmod 600 "$1"
    local rest
    rest="$(grep -v "^$2=" "$1" || true)"
    printf '%s\n%s=%s\n' "$rest" "$2" "$3" | sed '/^$/d' > "$1.new"
    mv -f "$1.new" "$1"
}

fw_open() {  # open TCP ports in ufw or firewalld when one of them is active
    local p
    for p in "$@"; do
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "$p/tcp" >/dev/null 2>&1 || true
        elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd -q --permanent --add-port="$p/tcp" 2>/dev/null || true
            firewall-cmd -q --reload 2>/dev/null || true
        fi
    done
    return 0
}

random_password() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }

first_free_port() {  # first port from $1 on that nothing listens on
    local p="$1"
    while [ -n "$(listeners "$p")" ]; do p=$((p + 1)); done
    echo "$p"
}

valid_host() {  # IPv4 address or domain name
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || valid_domain "${1,,}"
}

# Lets the user choose a stored certificate for a panel's HTTPS. Sets PANEL_CERT ("" = none).
pick_panel_cert() {  # $1 = what choosing 0 means
    local names=() n
    PANEL_CERT=""
    mapfile -t names < <(cert_names)
    if [ "${#names[@]}" = 0 ]; then
        echo "  No certificates yet, so: $1."
        echo "  (Get one with menu 8 or add yours with menu 9, then run this again for HTTPS.)"
        return 0
    fi
    print_certs
    echo "    0  $1"
    while :; do
        ask n "Certificate number for the panel" 1
        [ "$n" = 0 ] && return 0
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] && break
        echo "    Choose a number from the list."
    done
    PANEL_CERT="${names[$((n - 1))]}"
}

cert_main_domain() {  # first domain of a certificate, without a leading "*."
    local d
    d="$(cert_domains "$1" | awk '{print $1}')"
    echo "${d#\*.}"
}

access_box() {  # title, server port, path, scheme, domain, public port, user, password
    local lan pub
    lan="$(lan_ip)" pub="$(public_ip)"
    box_top "$1"
    box_line "Home network   ${CC}$4://$lan:$2$3${C0}"
    box_line "From outside   ${CC}$4://${5:-$pub}:$6$3${C0}"
    box_line "Router         forward public TCP port $6 to $lan:$2"
    if [ -n "$7" ]; then box_line "Username       ${CB}$7${C0}"; fi
    if [ -n "$8" ]; then box_line "Password       ${CB}$8${C0}"; fi
    box_end
}

# ================================================================ Docker
compose() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"
    elif command -v docker-compose >/dev/null; then docker-compose "$@"
    else die "Docker Compose is missing."; fi
}

docker_hub_reachable() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://registry-1.docker.io/v2/ || true)"
    [ "$code" = 401 ] || [ "$code" = 200 ]
}

docker_setup() {
    if ! command -v docker >/dev/null; then
        say "Installing Docker"
        if command -v apt-get >/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null 2>&1 || true
        fi
        # Distribution packages first (they work from Iran); Docker's own script as a fallback.
        command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh ||
            die "Docker could not be installed. Install it (apt install docker.io) and try again."
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null; then
        say "Installing Docker Compose"
        pkg_install docker-compose-v2
        docker compose version >/dev/null 2>&1 || pkg_install docker-compose-plugin
        docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null || pkg_install docker-compose
        docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null ||
            die "Docker Compose could not be installed (apt install docker-compose-v2)."
    fi
    docker info >/dev/null 2>&1 || die "Docker is installed but not running (systemctl status docker)."
    # Docker Hub refuses connections from Iran; then pull through mirrors.
    if ! docker_hub_reachable; then docker_mirrors; fi
}

docker_mirrors() {
    say "Docker Hub is not reachable from this server; using mirrors: $DOCKER_MIRRORS"
    # shellcheck disable=SC2086
    python3 - /etc/docker/daemon.json $DOCKER_MIRRORS <<'PY'
import json, os, sys
path, mirrors = sys.argv[1], sys.argv[2:]
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
have = cfg.get("registry-mirrors", [])
cfg["registry-mirrors"] = have + [m for m in mirrors if m not in have]
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(cfg, open(path, "w"), indent=2)
PY
    systemctl restart docker || die "Docker did not restart with the mirrors (see /etc/docker/daemon.json)."
}

# ================================================================ 3x-ui (MHSanaei)
xui_installed() { [ -x "$XUI_BIN" ]; }
xui_version() { "$XUI_BIN" -v 2>/dev/null | head -1 || true; }

xui_settings() {  # sets XUI_PANEL_PORT XUI_PANEL_PATH XUI_PANEL_USER
    local out
    out="$("$XUI_BIN" setting -show true 2>/dev/null || true)"
    XUI_PANEL_PORT="$(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$out" | head -1)"
    XUI_PANEL_PATH="$(sed -n 's/^[[:space:]]*webBasePath:[[:space:]]*\([^[:space:]]*\).*/\1/p' <<<"$out" | head -1)"
    XUI_PANEL_USER="$(sed -n 's/^[[:space:]]*username:[[:space:]]*\([^[:space:]]*\).*/\1/p' <<<"$out" | head -1)"
    case "${XUI_PANEL_PATH:-/}" in /*) XUI_PANEL_PATH="${XUI_PANEL_PATH:-/}" ;; *) XUI_PANEL_PATH="/$XUI_PANEL_PATH" ;; esac
}

xui_install() {
    is_tty || die "Run this in a terminal: the 3x-ui installer asks questions."
    if xui_installed; then
        say "x-ui is already installed: $(xui_version)"
        echo "  The official 3x-ui installer keeps the database (/etc/x-ui/x-ui.db): inbounds and clients stay."
        yes_no "Update it to the latest 3x-ui (a backup is made first)" n || return 0
    fi
    if [ -f /etc/x-ui/x-ui.db ]; then
        mkdir -p "$BACKUP_DIR"
        cp -p /etc/x-ui/x-ui.db "$BACKUP_DIR/x-ui-$(date +%Y%m%d-%H%M%S).db"
        say "Backup of the x-ui database is in $BACKUP_DIR"
    fi
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$tmp/install.sh" "$XUI_INSTALL_URL" || { rm -rf "$tmp"; die "Could not download the 3x-ui installer."; }
    say "Running the official 3x-ui installer (answer its questions)"
    if ! bash "$tmp/install.sh"; then rm -rf "$tmp"; die "The 3x-ui installer failed (output above)."; fi
    rm -rf "$tmp"
    xui_installed || die "3x-ui is not installed after its installer ran."
    say "3x-ui is installed: $(xui_version)"
    echo
    xui_access
}

xui_access() {
    xui_installed || die "3x-ui is not installed (xray-site 3x-ui install)."
    xui_settings
    [ -n "$XUI_PANEL_PORT" ] || die "Could not read the 3x-ui settings ($XUI_BIN setting -show true)."
    box_top "3x-ui panel access"
    echo "  Panel port on this server: $XUI_PANEL_PORT   path: $XUI_PANEL_PATH"
    echo
    local user pw pw2 pub_port def
    if yes_no "Set a new panel username and password now" n; then
        ask_text user "Username" "admin"
        while :; do
            read -r -s -p "  Password (hidden, 8 or more characters): " pw || die "No answer."
            echo
            read -r -s -p "  The same password again: " pw2 || die "No answer."
            echo
            [ "$pw" = "$pw2" ] && [ "${#pw}" -ge 8 ] && break
            echo "    The passwords differ or are shorter than 8 characters."
        done
        "$XUI_BIN" setting -username "$user" -password "$pw" >/dev/null || die "Could not set the panel login."
        say "Panel login changed."
    fi
    echo
    echo "  HTTPS for the panel (do this before opening the panel to the internet):"
    pick_panel_cert "plain http (only safe inside the home network)"
    if [ -n "$PANEL_CERT" ]; then
        cert_meta "$PANEL_CERT"
        "$XUI_BIN" cert -webCert "$CM_CERT" -webCertKey "$CM_KEY" >/dev/null 2>&1 ||
            "$XUI_BIN" setting -webCert "$CM_CERT" -webCertKey "$CM_KEY" >/dev/null 2>&1 ||
            die "Could not give the certificate to 3x-ui."
        # Renewals then restart x-ui, so it loads the new certificate.
        # shellcheck disable=SC2034  # read by save_conf in xray-site
        if [ -f "$CONF" ]; then load_conf; XUI_RESTART=1; save_conf "$CONF"; fi
    elif [ -n "$(state_get "$XUI_STATE" CERT)" ]; then
        "$XUI_BIN" cert -reset >/dev/null 2>&1 || true
    fi
    def="$(state_get "$XUI_STATE" PUBLIC_PORT)"
    ask_port pub_port "Public port on the router for the panel" "${def:-$XUI_PANEL_PORT}"
    state_set "$XUI_STATE" PUBLIC_PORT "$pub_port"
    state_set "$XUI_STATE" CERT "$PANEL_CERT"
    fw_open "$XUI_PANEL_PORT"
    systemctl restart x-ui || true
    sleep 2
    xui_info
}

xui_info() {
    xui_installed || die "3x-ui is not installed (xray-site 3x-ui install)."
    xui_settings
    local cert pub scheme=http domain=""
    cert="$(state_get "$XUI_STATE" CERT)" pub="$(state_get "$XUI_STATE" PUBLIC_PORT)"
    if [ -n "$cert" ] && cert_meta "$cert"; then scheme=https domain="$(cert_main_domain "$CM_CERT")"; fi
    access_box "3x-ui panel $(xui_version)" "${XUI_PANEL_PORT:-?}" "$XUI_PANEL_PATH" "$scheme" "$domain" \
        "${pub:-${XUI_PANEL_PORT:-?}}" "$XUI_PANEL_USER" ""
    if [ "$scheme" = http ]; then
        echo "  ${CY}The panel uses plain http: add a certificate before opening it to the internet (xray-site 3x-ui access).${C0}"
    fi
}

cmd_3xui() {
    local sub="${1:-info}"
    case "$sub" in
        install|update) xui_install ;;
        access|https) xui_access ;;
        info|show) xui_info ;;
        restart) xui_installed || die "3x-ui is not installed."; systemctl restart x-ui; say "3x-ui restarted." ;;
        *) die "Usage: xray-site 3x-ui install|access|info|restart" ;;
    esac
}

# ================================================================ Marzban (built from the fork)
mz_installed() { [ -f "$MZ_DIR/docker-compose.yml" ]; }
mz_compose() { (cd "$MZ_DIR" && compose "$@"); }

mz_env_get() {  # value of KEY in /opt/marzban/.env
    [ -f "$MZ_DIR/.env" ] || return 0
    sed -n "s/^$1=//p" "$MZ_DIR/.env" | tail -1 | sed 's/^"\(.*\)"$/\1/'
}

mz_env_set() {  # KEY VALUE ("" removes the key)
    local rest
    rest="$(grep -v "^$1=" "$MZ_DIR/.env" 2>/dev/null || true)"
    { printf '%s\n' "$rest"; [ -z "$2" ] || printf '%s="%s"\n' "$1" "$2"; } | sed '/^$/d' > "$MZ_DIR/.env.new"
    chmod 600 "$MZ_DIR/.env.new"
    mv -f "$MZ_DIR/.env.new" "$MZ_DIR/.env"
}

mz_write_compose() {
    cat > "$MZ_DIR/docker-compose.yml" <<EOF
# Marzban built from $MZ_REPO ($MZ_REF). Written by xray-site.
services:
  marzban:
    build: ./src
    image: marzban-fork:local
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - $MZ_DATA:$MZ_DATA
EOF
}

mz_default_xray_config() {
    cp "$MZ_SRC/xray_config.json" "$MZ_DATA/xray_config.json"
    # The default inbound uses port 1080; move it if something already listens there.
    python3 - "$MZ_DATA/xray_config.json" <<'PY'
import json, socket, sys
path = sys.argv[1]
cfg = json.load(open(path))
for ib in cfg.get("inbounds", []):
    port = ib.get("port")
    if not isinstance(port, int):
        continue
    while True:
        with socket.socket() as s:
            try:
                s.bind(("0.0.0.0", port))
                break
            except OSError:
                port += 1
    ib["port"] = port
json.dump(cfg, open(path, "w"), indent=2)
PY
}

mz_copy_cert() {  # copy a stored certificate to where the container can read it
    cert_meta "$1" || die "No certificate named \"$1\"."
    mkdir -p "$MZ_DATA/certs/panel"
    install -m 644 "$CM_CERT" "$MZ_DATA/certs/panel/fullchain.pem"
    install -m 600 "$CM_KEY" "$MZ_DATA/certs/panel/privkey.pem"
}

mz_self_signed() {  # a certificate for this server's home-network address
    local lan
    lan="$(lan_ip)"
    mkdir -p "$MZ_DATA/certs/panel"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -keyout "$MZ_DATA/certs/panel/privkey.pem" -out "$MZ_DATA/certs/panel/fullchain.pem" \
        -subj "/CN=$lan" -addext "subjectAltName=IP:$lan,IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1 ||
        die "Could not make a self-signed certificate (openssl)."
    chmod 600 "$MZ_DATA/certs/panel/privkey.pem"
}

mz_install() {
    is_tty || die "Run this in a terminal."
    mz_installed && die "Marzban is already installed. Update it with: xray-site marzban update"
    docker_setup
    command -v git >/dev/null || pkg_install git
    command -v git >/dev/null || die "git is needed (apt install git)."
    local port pass
    while :; do
        ask_port port "Dashboard port on this server" "$(first_free_port 8000)"
        [ -z "$(listeners "$port")" ] && break
        echo "    Port $port is already in use; choose another."
    done
    say "Downloading Marzban from $MZ_REPO ($MZ_REF)"
    mkdir -p "$MZ_DIR" "$MZ_DATA"
    rm -rf "$MZ_SRC"
    git clone -q --depth 1 --branch "$MZ_REF" "$MZ_REPO" "$MZ_SRC" || die "Could not download $MZ_REPO."
    [ -f "$MZ_DATA/xray_config.json" ] || mz_default_xray_config
    pass="$(random_password)"
    cat > "$MZ_DIR/.env" <<EOF
# Marzban settings, written by xray-site. Every option: $MZ_SRC/.env.example
UVICORN_HOST="0.0.0.0"
UVICORN_PORT="$port"
SUDO_USERNAME="admin"
SUDO_PASSWORD="$pass"
XRAY_JSON="$MZ_DATA/xray_config.json"
SQLALCHEMY_DATABASE_URL="sqlite:///$MZ_DATA/db.sqlite3"
EOF
    chmod 600 "$MZ_DIR/.env"
    mz_write_compose
    say "Building Marzban from your fork; the first build takes a few minutes"
    mz_compose build || die "Building Marzban failed (output above)."
    state_set "$MZ_STATE" REPO "$MZ_REPO"
    mz_access
    mz_links quiet
}

mz_access() {
    mz_installed || die "Marzban is not installed (xray-site marzban install)."
    local port pub_port def ca=public host
    port="$(mz_env_get UVICORN_PORT)"
    box_top "Marzban access"
    echo "  Marzban only lets other devices in over HTTPS, so it needs a certificate."
    pick_panel_cert "a self-signed certificate for the home network (browsers show a warning)"
    if [ -n "$PANEL_CERT" ]; then
        mz_copy_cert "$PANEL_CERT"
        host="$(cert_main_domain "$CM_CERT")"
        if [ "$(python3 "$HELPER" certinfo "$CM_CERT" | cut -f4)" = self-signed ]; then ca=private; fi
    else
        mz_self_signed
        host="" ca=private
    fi
    def="$(state_get "$MZ_STATE" PUBLIC_PORT)"
    ask_port pub_port "Public port on the router for the dashboard" "${def:-$port}"
    mz_env_set UVICORN_SSL_CERTFILE "$MZ_DATA/certs/panel/fullchain.pem"
    mz_env_set UVICORN_SSL_KEYFILE "$MZ_DATA/certs/panel/privkey.pem"
    mz_env_set UVICORN_SSL_CA_TYPE "$ca"
    mz_env_set XRAY_SUBSCRIPTION_URL_PREFIX "https://${host:-$(public_ip)}:$pub_port"
    state_set "$MZ_STATE" CERT "$PANEL_CERT"
    state_set "$MZ_STATE" PUBLIC_PORT "$pub_port"
    fw_open "$port"
    say "Starting Marzban"
    mz_compose up -d || die "Marzban did not start (output above)."
    python3 "$HELPER" mz-wait 180 >/dev/null || die "Marzban did not answer within 3 minutes; see: xray-site marzban logs"
    mz_info
}

mz_info() {
    mz_installed || die "Marzban is not installed (xray-site marzban install)."
    local cert host="" pub port dpath
    port="$(mz_env_get UVICORN_PORT)" cert="$(state_get "$MZ_STATE" CERT)" pub="$(state_get "$MZ_STATE" PUBLIC_PORT)"
    dpath="$(mz_env_get DASHBOARD_PATH)"
    if [ -n "$cert" ] && cert_meta "$cert"; then host="$(cert_main_domain "$CM_CERT")"; fi
    access_box "Marzban dashboard (from $(state_get "$MZ_STATE" REPO))" "$port" "${dpath:-/dashboard/}" \
        https "$host" "${pub:-$port}" "$(mz_env_get SUDO_USERNAME)" "$(mz_env_get SUDO_PASSWORD)"
    echo "  Subscription links start with: ${CC}$(mz_env_get XRAY_SUBSCRIPTION_URL_PREFIX)${C0}"
    if [ -z "$cert" ]; then
        echo "  ${CY}Self-signed certificate: the browser warns once (Advanced > continue). For access by domain${C0}"
        echo "  ${CY}without a warning, add a certificate (menu 8 or 9) and run: xray-site marzban access${C0}"
    fi
}

# Address and port in client links: the domain (or public IP), and the router's public port when
# an inbound is shared with the website through xray-site.
mz_links() {
    mz_installed || die "Marzban is not installed (xray-site marzban install)."
    local cert host="" map="{" m
    cert="$(state_get "$MZ_STATE" CERT)"
    if [ -n "$cert" ] && cert_meta "$cert"; then host="$(cert_main_domain "$CM_CERT")"; fi
    host="${host:-$(public_ip)}"
    if [ -f "$CONF" ]; then
        load_conf
        for m in "${MAPS[@]}"; do split_map "$m"; map="$map\"$M_XUI\": \"$M_PUBLIC\", "; done
    fi
    map="${map%, }}"
    if [ "${1:-}" = quiet ]; then python3 "$HELPER" mz-links "$host" "$map" >/dev/null || true
    else python3 "$HELPER" mz-links "$host" "$map"; fi
}

mz_update() {
    mz_installed || die "Marzban is not installed (xray-site marzban install)."
    say "Getting the latest code from $MZ_REPO ($MZ_REF)"
    git -C "$MZ_SRC" fetch -q --depth 1 origin "$MZ_REF" && git -C "$MZ_SRC" reset -q --hard FETCH_HEAD ||
        die "Could not update the code from $MZ_REPO."
    say "Rebuilding Marzban"
    mz_compose build || die "Building Marzban failed (output above)."
    mz_compose up -d || die "Marzban did not start (output above)."
    python3 "$HELPER" mz-wait 180 >/dev/null || die "Marzban did not answer; see: xray-site marzban logs"
    say "Marzban is updated ($(git -C "$MZ_SRC" log -1 --format='%h %s'))."
}

mz_uninstall() {
    mz_installed || die "Marzban is not installed."
    if is_tty; then yes_no "Remove Marzban? Users and settings in $MZ_DATA are kept" n || return 0; fi
    mz_compose down || true
    rm -rf "$MZ_DIR" "$MZ_STATE"
    say "Marzban removed. Its data (users, settings) is still in $MZ_DATA."
}

cmd_marzban() {
    local sub="${1:-info}"
    case "$sub" in
        install) mz_install ;;
        access|https) mz_access ;;
        info|show) mz_info ;;
        links) mz_links ;;
        update) mz_update ;;
        restart) mz_installed || die "Marzban is not installed."; mz_compose restart; say "Marzban restarted." ;;
        logs) mz_installed || die "Marzban is not installed."; mz_compose logs --tail "${2:-80}" ;;
        uninstall) mz_uninstall ;;
        *) die "Usage: xray-site marzban install|access|info|links|update|restart|logs|uninstall" ;;
    esac
}

# ================================================================ Marzban nodes
node_installed() { [ -f "$NODE_DIR/docker-compose.yml" ]; }

node_write_compose() {
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
# Marzban node, written by xray-site.
services:
  marzban-node:
    image: $NODE_IMAGE
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "$NODE_DATA/ssl_client_cert.pem"
      SERVICE_PROTOCOL: "rest"
      SERVICE_PORT: "62050"
      XRAY_API_PORT: "62051"
    volumes:
      - $NODE_DATA:$NODE_DATA
EOF
}

# Installs a node on this server, for a Marzban panel on another server.
# node install [--cert-b64 <base64 of the panel's node certificate>] [--cert-file <file>]
node_install() {
    local b64="" file="" cert="" via_panel=0 url="" user="" pw="" c
    while [ $# -gt 0 ]; do
        case "$1" in
            --cert-b64) b64="${2:-}"; shift ;;
            --cert-file) file="${2:-}"; shift ;;
            *) die "Unknown option $1" ;;
        esac
        shift
    done
    if mz_installed; then
        die "This server runs the Marzban panel. Its own core already serves every inbound here, so a node
on the same server would compete for the same ports. Install nodes on your other servers instead
(menu 20 > Add a node on another server)."
    fi
    if [ -n "$b64" ]; then
        cert="$(base64 -d <<<"$b64" 2>/dev/null || true)"
    elif [ -n "$file" ]; then
        cert="$(cat "$file")" || die "Cannot read $file"
    else
        is_tty || die "Give the panel's node certificate: --cert-b64 <...> or --cert-file <file>"
        echo "  How should this node get the panel's certificate?"
        printf '  %s  1%s  Log in to the panel from here (connects the node automatically)\n' "$CB$CC" "$C0"
        printf '  %s  2%s  Paste it (Marzban: Nodes > Add node > copy the certificate)\n' "$CB$CC" "$C0"
        ask c "Choose" 1
        if [ "$c" = 2 ]; then
            echo "  Paste the certificate (-----BEGIN CERTIFICATE----- ...), then Enter on an empty line:"
            read_pem cert '^-----END CERTIFICATE-----'
        else
            ask_text url "Panel address (e.g. https://panel.example.com:8000)" ""
            ask_text user "Panel admin username" "admin"
            read -r -s -p "  Panel admin password (hidden): " pw || die "No answer."
            echo
            cert="$(XS_MZ_URL="$url" XS_MZ_USER="$user" XS_MZ_PASS="$pw" python3 "$HELPER" mz-node-cert)" ||
                die "Could not get the certificate from the panel."
            via_panel=1
        fi
    fi
    [[ "$cert" == *"BEGIN CERTIFICATE"* ]] || die "That is not a certificate (it must start with -----BEGIN CERTIFICATE-----)."
    local p
    for p in 62050 62051; do
        if [ -n "$(listeners "$p")" ] && ! node_installed; then
            die "Port $p is already in use on this server; the node needs ports 62050 and 62051."
        fi
    done
    docker_setup
    mkdir -p "$NODE_DIR" "$NODE_DATA"
    printf '%s\n' "$cert" > "$NODE_DATA/ssl_client_cert.pem"
    chmod 600 "$NODE_DATA/ssl_client_cert.pem"
    node_write_compose
    say "Starting the Marzban node"
    (cd "$NODE_DIR" && compose pull && compose up -d) || die "The node did not start (output above)."
    fw_open 62050 62051
    for _ in $(seq 1 30); do [ -n "$(listeners 62050)" ] && break; sleep 2; done
    [ -n "$(listeners 62050)" ] || die "The node does not listen on port 62050; see: docker logs \$(docker ps -qf name=marzban-node)"
    say "The node is running on ports 62050 (service) and 62051 (API)."
    if [ "$via_panel" = 1 ]; then
        local name id st
        ask_text name "A name for this node in the panel" "$(hostname)"
        id="$(XS_MZ_URL="$url" XS_MZ_USER="$user" XS_MZ_PASS="$pw" python3 "$HELPER" mz-node-add "$name" "$(public_ip)")" ||
            die "The panel did not accept the node."
        if st="$(XS_MZ_URL="$url" XS_MZ_USER="$user" XS_MZ_PASS="$pw" python3 "$HELPER" mz-node-wait "$id" 90)"; then
            say "The panel is connected to this node."
        else
            warn "The panel has not connected yet (${st}). Check that ports 62050 and 62051 are open on this server."
        fi
    else
        echo "  In the panel, add it under Nodes: address $(public_ip), port 62050, API port 62051."
    fi
}

node_add_remote() {
    mz_installed || die "Install the Marzban panel on this server first (menu 19)."
    python3 "$HELPER" mz-wait 20 >/dev/null || die "Marzban is not answering (xray-site marzban restart)."
    local name addr cert b64 cmd c sshuser sshport pw="" id st
    box_top "Add a Marzban node on another server"
    ask_text name "A name for the node (e.g. Germany)" ""
    [ -n "$name" ] || return 0
    while :; do
        ask addr "The other server's public IP or domain" ""
        valid_host "$addr" && break
        echo "    Enter an IPv4 address or a domain."
    done
    cert="$(python3 "$HELPER" mz-node-cert)" || die "Could not read the node certificate from Marzban."
    b64="$(printf '%s\n' "$cert" | base64 -w0)"
    cmd="curl -fsSL $UPDATE_URL -o xray-site.sh && sudo bash xray-site.sh node install --cert-b64 $b64"
    echo
    echo "  How should the node be installed on $addr?"
    printf '  %s  1%s  Over SSH from here (automatic)\n' "$CB$CC" "$C0"
    printf '  %s  2%s  I run one command on that server myself\n' "$CB$CC" "$C0"
    ask c "Choose" 1
    if [ "$c" = 2 ]; then
        echo
        echo "  Run this on $addr as root:"
        echo
        echo "$cmd"
        echo
        read -r -p "  Press Enter here when it has finished " _ || true
    else
        ask_text sshuser "SSH user (root, or one with sudo without a password)" root
        ask_port sshport "SSH port" 22
        echo "  Leave the password empty to log in with your SSH key."
        read -r -s -p "  SSH password (hidden): " pw || true
        echo
        command -v ssh >/dev/null || pkg_install openssh-client
        if [ -n "$pw" ]; then
            command -v sshpass >/dev/null || pkg_install sshpass
            command -v sshpass >/dev/null || die "sshpass is needed for password logins (apt install sshpass)."
            say "Installing the node on $addr over SSH (this takes a minute or two)"
            SSHPASS="$pw" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$sshport" "$sshuser@$addr" "$cmd" </dev/null ||
                die "Installing the node over SSH failed (output above)."
        else
            say "Installing the node on $addr over SSH (this takes a minute or two)"
            ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -p "$sshport" "$sshuser@$addr" "$cmd" </dev/null ||
                die "Installing the node over SSH failed (output above)."
        fi
    fi
    id="$(python3 "$HELPER" mz-node-add "$name" "$addr")" || die "Marzban did not accept the node."
    say "Waiting for Marzban to connect to $name ..."
    if st="$(python3 "$HELPER" mz-node-wait "$id" 90)"; then
        say "Node $name ($addr) is connected."
    else
        warn "Not connected yet (${st}). On $addr, ports 62050 and 62051 must be open."
        echo "  Check again later with: xray-site node list"
    fi
}

node_list() {
    mz_installed || die "The Marzban panel is not installed on this server."
    local rows id name addr port api status msg col
    rows="$(python3 "$HELPER" mz-nodes)" || exit 1
    printf '\n  %s%-4s %-16s %-24s %-13s %-12s %s%s\n' "$CB" id name address ports status message "$C0"
    [ -n "$rows" ] || { printf '  %s(no nodes yet)%s\n\n' "$CD" "$C0"; return 0; }
    while IFS=$'\t' read -r id name addr port api status msg; do
        if [ "$status" = connected ]; then col="$CG"; elif [ "$status" = connecting ]; then col="$CY"; else col="$CR"; fi
        printf '  %-4s %-16s %-24s %-13s %s%-12s%s %s\n' "$id" "${name:0:16}" "${addr:0:24}" "$port/$api" "$col" "$status" "$C0" "${msg:0:50}"
    done <<<"$rows"
    echo
}

node_remove() {
    local id="${1:-}"
    mz_installed || die "The Marzban panel is not installed on this server."
    if [ -z "$id" ]; then
        node_list
        ask id "Node id to remove (Enter = cancel)" ""
        [ -n "$id" ] || return 0
    fi
    [[ "$id" =~ ^[0-9]+$ ]] || die "\"$id\" is not a node id."
    python3 "$HELPER" mz-node-remove "$id" || exit 1
    say "Node $id removed from the panel."
}

cmd_node() {
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        install) node_install "$@" ;;
        add) node_add_remote ;;
        list|ls) node_list ;;
        remove|rm) node_remove "$@" ;;
        *) die "Usage: xray-site node add | install [--cert-b64 ...] | list | remove [id]" ;;
    esac
}

# Called after a certificate renewal: panels that use the certificate load the new one.
panels_cert_reload() {
    local c
    c="$(state_get "$MZ_STATE" CERT)"
    if [ -n "$c" ] && mz_installed && cert_meta "$c"; then
        mz_copy_cert "$c"
        mz_compose restart >/dev/null 2>&1 || true
    fi
    return 0
}

# ================================================================ menus
menu_3xui() {
    local c
    while :; do
        box_top "3x-ui panel (MHSanaei)"
        if xui_installed; then xui_settings; echo "  Installed: $(xui_version)   port $XUI_PANEL_PORT   path $XUI_PANEL_PATH"
        else echo "  Not installed on this server."; fi
        echo
        printf '  %s  1%s  Install or update 3x-ui\n' "$CB$CC" "$C0"
        printf '  %s  2%s  Panel access: login, HTTPS certificate, router port\n' "$CB$CC" "$C0"
        printf '  %s  3%s  Show the panel address\n' "$CB$CC" "$C0"
        printf '  %s  4%s  Restart 3x-ui\n' "$CB$CC" "$C0"
        printf '  %s  0%s  Back\n\n' "$CB$CC" "$C0"
        ask c "Choose" ""
        case "$c" in
            1) try_run xui_install ;;
            2) try_run xui_access ;;
            3) try_run xui_info ;;
            4) try_run cmd_3xui restart ;;
            0|"") return 0 ;;
            *) echo "    Choose a number from the list." ;;
        esac
        echo
    done
}

menu_marzban() {
    local c
    while :; do
        box_top "Marzban panel (built from $MZ_REPO)"
        if mz_installed; then
            echo "  Installed: dashboard port $(mz_env_get UVICORN_PORT), $( (mz_compose ps --status running -q 2>/dev/null | grep -q .) && echo "${CG}running${C0}" || echo "${CR}not running${C0}")"
        else echo "  Not installed on this server."; fi
        echo
        printf '  %s  1%s  Install Marzban\n' "$CB$CC" "$C0"
        printf '  %s  2%s  Dashboard access: HTTPS certificate, router port\n' "$CB$CC" "$C0"
        printf '  %s  3%s  Show the address, username and password\n' "$CB$CC" "$C0"
        printf '  %s  4%s  Put my domain / IP and router ports in client links\n' "$CB$CC" "$C0"
        printf '  %s  5%s  Update (get the latest code of the fork and rebuild)\n' "$CB$CC" "$C0"
        printf '  %s  6%s  Restart        %s  7%s  Logs        %s  8%s  Uninstall\n' "$CB$CC" "$C0" "$CB$CC" "$C0" "$CB$CC" "$C0"
        printf '  %s  0%s  Back\n\n' "$CB$CC" "$C0"
        ask c "Choose" ""
        case "$c" in
            1) try_run mz_install ;;
            2) try_run mz_access ;;
            3) try_run mz_info ;;
            4) try_run mz_links ;;
            5) try_run mz_update ;;
            6) try_run cmd_marzban restart ;;
            7) try_run cmd_marzban logs ;;
            8) try_run mz_uninstall ;;
            0|"") return 0 ;;
            *) echo "    Choose a number from the list." ;;
        esac
        echo
    done
}

menu_nodes() {
    local c
    while :; do
        box_top "Marzban nodes"
        if mz_installed; then try_run node_list; else echo "  (The Marzban panel is not on this server.)"; fi
        printf '  %s  1%s  Add a node on another server (SSH or one command, then connects it)\n' "$CB$CC" "$C0"
        printf '  %s  2%s  Make this server a node of a panel on another server\n' "$CB$CC" "$C0"
        printf '  %s  3%s  Remove a node from the panel\n' "$CB$CC" "$C0"
        printf '  %s  0%s  Back\n\n' "$CB$CC" "$C0"
        ask c "Choose" ""
        case "$c" in
            1) try_run node_add_remote ;;
            2) try_run node_install ;;
            3) try_run node_remove ;;
            0|"") return 0 ;;
            *) echo "    Choose a number from the list." ;;
        esac
        echo
    done
}
