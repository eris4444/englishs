#!/usr/bin/env bash
#
# manageit-ssl.sh: Let's Encrypt certificate for a domain behind the ManageIt CDN proxy.
#
# این اسکریپت روی سرور مبدا اجرا می‌شود و برای دامنه‌ای که با پروکسی روشن CDN
# منیجیت به این سرور اشاره دارد، سرتیفیکیت رایگان Let's Encrypt می‌گیرد و مسیر
# کامل فایل‌ها را نشان می‌دهد. لازم نیست IP سرور معلوم باشد یا پروکسی خاموش شود.
#
# How it works (default, HTTP-01):
#   Let's Encrypt requests http://<domain>/.well-known/acme-challenge/<token>.
#   That request reaches the ManageIt edge, which forwards it to this server on
#   port 80, where certbot answers it. An HTTP->HTTPS redirect on the CDN is
#   fine: Let's Encrypt follows it. Before asking Let's Encrypt, the script
#   checks that path itself with a random token, so a broken setup is reported
#   without spending Let's Encrypt's failed-validation rate limit.
#
# DNS-01 (--dns):
#   You add one TXT record in the ManageIt DNS panel. Needs no port 80 and
#   allows *.wildcards, but renewal is manual: run the script again before the
#   certificate expires.
#
set -Eeuo pipefail

LE_LIVE=/etc/letsencrypt/live

if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_CYN=$'\e[36m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
    C_RED='' C_GRN='' C_YLW='' C_CYN='' C_BLD='' C_RST=''
fi

info() { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST"; }

usage() {
    cat <<'EOF'
Usage: sudo bash manageit-ssl.sh DOMAIN [DOMAIN...] [options]

Gets a Let's Encrypt certificate for domain(s) that point to this server
through the ManageIt CDN (proxy on), and prints the full paths of the files.

Options:
  -e, --email EMAIL      Account e-mail for Let's Encrypt (optional)
      --webroot DIR      Leave port 80 alone: write the challenge files into DIR,
                         which your running web server already serves over HTTP
      --dns              Validate with a TXT record you add in the ManageIt DNS
                         panel (no port 80 needed, allows *.wildcards, manual renewal)
      --deploy-hook CMD  Run CMD after every successful issue/renewal,
                         e.g. "systemctl reload nginx" or "x-ui restart"
      --dry-run          Test against the Let's Encrypt staging server only
      --force            Renew even if the current certificate is still valid
  -y, --yes              Don't ask; answer yes to every question
  -h, --help             Show this help

Examples:
  sudo bash manageit-ssl.sh example.com
  sudo bash manageit-ssl.sh example.com www.example.com -e me@example.com
  sudo bash manageit-ssl.sh panel.example.com --deploy-hook "x-ui restart"
  sudo bash manageit-ssl.sh example.com '*.example.com' --dns
EOF
}

# ---------------------------------------------------------------- arguments --

DOMAINS=()
EMAIL=""
MODE=http            # http | webroot | dns
WEBROOT=""
DEPLOY_HOOK=""
DRY_RUN=0
FORCE=0
ASSUME_YES=0

need_value() { [[ $# -ge 2 && -n $2 ]] || die "$1 needs a value (see --help)"; }

while (($#)); do
    case $1 in
        -e|--email)    need_value "$@"; EMAIL=$2; shift 2 ;;
        --email=*)     EMAIL=${1#*=}; shift ;;
        --webroot)     need_value "$@"; WEBROOT=$2; MODE=webroot; shift 2 ;;
        --webroot=*)   WEBROOT=${1#*=}; MODE=webroot; shift ;;
        --dns)         MODE=dns; shift ;;
        --deploy-hook) need_value "$@"; DEPLOY_HOOK=$2; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --force)       FORCE=1; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "Unknown option: $1 (see --help)" ;;
        *)             DOMAINS+=("$1"); shift ;;
    esac
done

INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1

# confirm QUESTION DEFAULT(y|n): --yes answers yes; without a terminal the default is used.
confirm() {
    local question=$1 default=${2:-y} answer hint
    ((ASSUME_YES)) && return 0
    if ((!INTERACTIVE)); then
        [[ $default == y ]]
        return
    fi
    if [[ $default == y ]]; then hint='Y/n'; else hint='y/N'; fi
    read -r -p "$question [$hint] " answer || answer=''
    answer=${answer:-$default}
    [[ $answer == [Yy]* ]]
}

[[ $(uname -s) == Linux ]] || die "This script runs on the Linux server itself."
((EUID == 0)) || die "Run it as root: sudo bash $0 ${DOMAINS[*]:-example.com}"

if ((${#DOMAINS[@]} == 0)); then
    ((INTERACTIVE)) || die "No domain given (see --help)."
    read -r -p "Domain pointed to this server through ManageIt (e.g. example.com): " line
    read -r -a DOMAINS <<<"${line//,/ }"
    ((${#DOMAINS[@]})) || die "No domain given."
fi

# Accept pasted URLs ("https://Example.com/path") and drop duplicates.
normalized=()
for d in "${DOMAINS[@]}"; do
    d=${d#*://}; d=${d%%/*}; d=${d%%:*}; d=${d%.}; d=${d,,}
    [[ $d =~ ^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,63}$ ]] || die "Not a valid domain: $d"
    if [[ $d =~ (^|\.)example\.(com|net|org)$ || $d =~ \.(example|test|invalid|localhost|local|internal)$ ]]; then
        die "$d is only a placeholder, not your domain. Run it with the domain you added in ManageIt:
    bash $0 yourdomain.com"
    fi
    if [[ $d == \** && $MODE != dns ]]; then
        die "Wildcard $d can only be validated through DNS: add --dns"
    fi
    [[ " ${normalized[*]-} " == *" $d "* ]] || normalized+=("$d")
done
DOMAINS=("${normalized[@]}")
CERT_NAME=${DOMAINS[0]#\*.}

if [[ $MODE == webroot ]]; then
    [[ -d $WEBROOT ]] || die "Webroot $WEBROOT does not exist."
    WEBROOT=$(cd "$WEBROOT" && pwd)
fi

if ((INTERACTIVE && !ASSUME_YES)) && [[ -z $EMAIL ]]; then
    read -r -p "E-mail for Let's Encrypt (optional, Enter to skip): " EMAIL || EMAIL=''
fi

# ------------------------------------------------------------------ cleanup --

TMP_DIR=$(mktemp -d)
TEST_SERVER_PID=""
STOPPED_UNIT=""
WEBROOT_TOKEN_FILE=""

cleanup() {
    if [[ -n $TEST_SERVER_PID ]]; then
        kill "$TEST_SERVER_PID" 2>/dev/null || true
        wait "$TEST_SERVER_PID" 2>/dev/null || true
    fi
    if [[ -n $WEBROOT_TOKEN_FILE ]]; then
        rm -f "$WEBROOT_TOKEN_FILE"
    fi
    rm -rf "$TMP_DIR"
    # Whatever happened, never leave the web server we stopped switched off.
    if [[ -n $STOPPED_UNIT ]] && ! systemctl is-active --quiet "$STOPPED_UNIT"; then
        systemctl start "$STOPPED_UNIT" || warn "Could not start $STOPPED_UNIT again, start it by hand: systemctl start $STOPPED_UNIT"
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------- dependencies --

pkg_install() {
    if command -v apt-get >/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null; then
        dnf install -y -q "$@"
    elif command -v yum >/dev/null; then
        yum install -y -q "$@"
    elif command -v apk >/dev/null; then
        apk add --no-cache "$@"
    elif command -v pacman >/dev/null; then
        pacman -Sy --noconfirm --needed "$@"
    elif command -v zypper >/dev/null; then
        zypper -n install "$@"
    else
        return 1
    fi
}

ensure_deps() {
    local pkgs=()
    command -v curl >/dev/null || pkgs+=(curl ca-certificates)
    command -v openssl >/dev/null || pkgs+=(openssl)
    if ! command -v ss >/dev/null; then
        if command -v dnf >/dev/null || command -v yum >/dev/null; then pkgs+=(iproute); else pkgs+=(iproute2); fi
    fi
    command -v certbot >/dev/null || pkgs+=(certbot)
    ((${#pkgs[@]})) || { ok "curl, openssl, ss and certbot are installed"; return 0; }

    info "Installing: ${pkgs[*]}"
    if [[ " ${pkgs[*]} " == *" certbot "* ]] && { command -v dnf >/dev/null || command -v yum >/dev/null; }; then
        # RHEL / Alma / Rocky ship certbot in EPEL (Fedora has it built in, so a failure here is fine).
        pkg_install epel-release >/dev/null 2>&1 || true
    fi
    pkg_install "${pkgs[@]}" || warn "The package manager could not install everything."

    if ! command -v certbot >/dev/null && command -v snap >/dev/null; then
        info "Installing certbot from snap"
        snap install --classic certbot && ln -sf /snap/bin/certbot /usr/local/bin/certbot
    fi
    command -v certbot >/dev/null || die "certbot is not installed. Install it (https://certbot.eff.org) and run this again."
    command -v curl >/dev/null || die "curl is not installed."
    command -v openssl >/dev/null || die "openssl is not installed."
    if [[ $MODE == http ]] && ! command -v ss >/dev/null; then
        die "ss (iproute2) is not installed."
    fi
    ok "Dependencies ready ($(certbot --version 2>&1 | head -n1))"
}

# ------------------------------------------------------------------ helpers --

server_public_ip() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

resolve() { getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' - || true; }

# Lines of `ss -ltnp` whose local address is port 80.
port80_listeners() { ss -ltnp 2>/dev/null | awk 'NR > 1 && $4 ~ /:80$/'; }
port80_busy() { [[ -n $(port80_listeners) ]]; }

# systemd unit that owns PID, e.g. "nginx.service" (empty if none).
pid_unit() {
    local unit
    unit=$(ps -o unit= -p "$1" 2>/dev/null | tr -d '[:space:]') || unit=''
    if [[ -z $unit || $unit == - ]]; then
        unit=$(grep -o '[^/]*\.service' "/proc/$1/cgroup" 2>/dev/null | tail -n1) || unit=''
    fi
    printf '%s' "$unit"
}

wait_port80_free() {
    local i
    for ((i = 0; i < 40; i++)); do
        port80_busy || return 0
        sleep 0.25
    done
    return 1
}

open_firewall_http() {
    if command -v ufw >/dev/null && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
        ufw allow 80/tcp >/dev/null && ok "ufw: allowed 80/tcp (needed now and for renewals)"
    fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd -q --permanent --add-service=http && firewall-cmd -q --reload \
            && ok "firewalld: allowed http (needed now and for renewals)"
    fi
    return 0
}

# Serve $TMP_DIR/www on port 80 for the self-test (certbot's own server comes later).
start_test_server() {
    local i
    command -v python3 >/dev/null || return 1
    mkdir -p "$TMP_DIR/www"
    (cd "$TMP_DIR/www" && exec python3 -m http.server 80) >/dev/null 2>&1 &
    TEST_SERVER_PID=$!
    for ((i = 0; i < 40; i++)); do
        kill -0 "$TEST_SERVER_PID" 2>/dev/null || break
        port80_busy && return 0
        sleep 0.25
    done
    TEST_SERVER_PID=""
    return 1
}

stop_test_server() {
    [[ -n $TEST_SERVER_PID ]] || return 0
    kill "$TEST_SERVER_PID" 2>/dev/null || true
    wait "$TEST_SERVER_PID" 2>/dev/null || true
    TEST_SERVER_PID=""
    wait_port80_free || die "Port 80 did not become free after the self-test."
}

# Put a random token under DIR/.well-known/acme-challenge/ and fetch it through the
# CDN for every domain, exactly the way Let's Encrypt will. Returns 1 if any fails.
selftest_http() {
    local dir=$1 token file d code body err failed=0
    token=$(openssl rand -hex 16)
    mkdir -p "$dir/.well-known/acme-challenge"
    file="$dir/.well-known/acme-challenge/$token"
    printf '%s' "$token" >"$file"
    chmod 644 "$file"
    [[ $MODE == webroot ]] && WEBROOT_TOKEN_FILE=$file

    for d in "${DOMAINS[@]}"; do
        # -k: Let's Encrypt doesn't check certificates when it follows a redirect to HTTPS either.
        code=$(curl -sS -L -k --max-time 20 -o "$TMP_DIR/body" -w '%{http_code}' \
            "http://$d/.well-known/acme-challenge/$token" 2>"$TMP_DIR/err") || true
        body=$(cat "$TMP_DIR/body" 2>/dev/null || true)
        err=$(head -n1 "$TMP_DIR/err" 2>/dev/null || true)
        if [[ $body == "$token" ]]; then
            ok "$d: the CDN delivers /.well-known/acme-challenge/ to this server"
        else
            warn "$d: test file not received (HTTP ${code:-000}${err:+, $err})"
            case ${code:-000} in
                000) warn "    -> could not connect through the CDN at all (DNS or network problem)" ;;
                404) warn "    -> something answered, but not this server: check the IP in the ManageIt record and that the origin port is 80 (HTTP)" ;;
                403) warn "    -> blocked (403): a WAF/firewall rule in ManageIt or on this server" ;;
                5??) warn "    -> the CDN could not reach this server on port 80: firewall, or origin set to HTTPS/443" ;;
            esac
            failed=1
        fi
        rm -f "$TMP_DIR/body" "$TMP_DIR/err"
    done
    rm -f "$file"
    WEBROOT_TOKEN_FILE=""
    return "$failed"
}

http_hints() {
    cat >&2 <<'EOF'

    The request http://<domain>/.well-known/acme-challenge/... did not reach this server
    through the CDN. Check:
      1. In the ManageIt DNS panel the record of the domain points to THIS server's IP
         (the proxy can stay on). New records can take a few minutes.
      2. The origin (upstream) protocol/port for the domain in ManageIt is HTTP / 80,
         or "auto / same as visitor". An HTTPS-only origin never reaches port 80.
      3. Port 80 is open in the server firewall AND in the datacenter/cloud firewall.
      4. No WAF, firewall or cache rule in ManageIt blocks /.well-known/acme-challenge/.
    Or skip port 80 entirely: run again with --dns (you add one TXT record by hand).
EOF
}

dns_hints() {
    cat >&2 <<'EOF'

    Let's Encrypt did not see the right TXT record. In the ManageIt DNS panel check:
      1. Type TXT, name _acme-challenge (for sub.example.com: _acme-challenge.sub),
         value exactly as certbot showed it.
      2. With two names (example.com + *.example.com) BOTH TXT records must exist.
      3. Wait a minute or two after saving before pressing Enter.
EOF
}

# Explain a certbot failure from what Let's Encrypt answered (in certbot's log), so only
# the hints that match the actual error are shown.
certbot_failure_hints() {
    local log=/var/log/letsencrypt/letsencrypt.log
    [[ -r $log ]] || return 0
    if grep -Eq 'rejectedIdentifier|forbidden by policy' "$log"; then
        warn "Let's Encrypt refuses to issue for this name (reserved or blocked names such as example.com)."
        warn "Run the script with your own domain."
    elif grep -q 'rateLimited' "$log"; then
        warn "Let's Encrypt rate limit reached: wait as long as the error above says. Test with --dry-run meanwhile."
    elif grep -q 'error:caa' "$log"; then
        warn "A CAA record on the domain doesn't allow Let's Encrypt. In the ManageIt DNS panel delete it,"
        warn "or add one more: CAA  0 issue \"letsencrypt.org\""
    elif grep -Eq 'error:(connection|unauthorized|incorrectResponse|dns|tls)' "$log"; then
        if [[ $MODE == dns ]]; then dns_hints; else http_hints; fi
    fi
}

# Make sure something really runs `certbot renew` (it renews ~30 days before expiry).
# Returns 1, after saying why, when nothing on this server can do it.
ensure_auto_renew() {
    local timer schedule
    if [[ -d /run/systemd/system ]]; then
        # Under systemd, Debian/Ubuntu's /etc/cron.d/certbot deliberately does nothing,
        # so only an active timer counts.
        for timer in certbot.timer certbot-renew.timer snap.certbot.renew.timer manageit-certbot-renew.timer; do
            if systemctl is-active --quiet "$timer"; then
                ok "Auto-renewal: systemd timer $timer is active"
                return 0
            fi
        done
        for timer in certbot.timer certbot-renew.timer; do
            if systemctl enable --now "$timer" >/dev/null 2>&1; then
                ok "Auto-renewal: turned on systemd timer $timer"
                return 0
            fi
        done
        printf '%s\n' "[Unit]" "Description=Renew Let's Encrypt certificates (manageit-ssl.sh)" "" \
            "[Service]" "Type=oneshot" "ExecStart=$(command -v certbot) -q renew" \
            >/etc/systemd/system/manageit-certbot-renew.service
        printf '%s\n' "[Unit]" "Description=Run certbot renew twice a day (manageit-ssl.sh)" "" \
            "[Timer]" "OnCalendar=*-*-* 00,12:00:00" "RandomizedDelaySec=12h" "Persistent=true" "" \
            "[Install]" "WantedBy=timers.target" \
            >/etc/systemd/system/manageit-certbot-renew.timer
        if systemctl daemon-reload && systemctl enable --now manageit-certbot-renew.timer >/dev/null 2>&1; then
            ok "Auto-renewal: added systemd timer manageit-certbot-renew.timer (twice a day)"
            return 0
        fi
        warn "Could not turn on a systemd timer for certbot renew."
        return 1
    fi

    # No systemd: a cron job is needed, and a cron daemon that actually runs it.
    if ! grep -qs 'certbot' /etc/cron.d/* /etc/crontabs/root /var/spool/cron/crontabs/root /var/spool/cron/root; then
        schedule="$((RANDOM % 60)) */12 * * *"
        if [[ -d /etc/cron.d ]]; then
            printf '%s\n' "SHELL=/bin/sh" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                "$schedule root certbot renew -q" >/etc/cron.d/manageit-certbot-renew
        else
            { crontab -l 2>/dev/null; echo "$schedule certbot renew -q"; } | crontab -
        fi
    fi
    if ! pgrep -x 'cron|crond' >/dev/null; then
        if ! command -v cron >/dev/null && ! command -v crond >/dev/null; then
            pkg_install cron >/dev/null 2>&1 || pkg_install cronie >/dev/null 2>&1 || true
        fi
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    fi
    if pgrep -x 'cron|crond' >/dev/null; then
        ok "Auto-renewal: certbot cron job, and cron is running"
        return 0
    fi
    warn "This server runs neither systemd nor a cron daemon, so nothing renews the certificate by itself."
    return 1
}

# --------------------------------------------------------------------- main --

step "1/5 Checking dependencies"
ensure_deps

step "2/5 Checking DNS"
SERVER_IP=$(server_public_ip || true)
info "This server's public IPv4: ${SERVER_IP:-unknown}"
for d in "${DOMAINS[@]}"; do
    if [[ $d == \** ]]; then
        info "$d: wildcard, checked through DNS only"
        continue
    fi
    ips=$(resolve "$d")
    if [[ -z $ips ]]; then
        if [[ $MODE == dns ]]; then
            warn "$d does not resolve yet (fine for --dns, the TXT record is what counts)"
            continue
        fi
        die "$d does not resolve. Add an A record for it in the ManageIt panel that points to this server (proxy on) and try again."
    fi
    if [[ -n $SERVER_IP && " $ips " == *" $SERVER_IP "* ]]; then
        ok "$d -> $ips (points straight at this server, proxy off)"
    else
        info "$d -> $ips (behind the CDN; step 3 checks that it reaches this server)"
    fi
done

step "3/5 Preparing validation ($MODE)"
PRE_HOOK=""
POST_HOOK=""
case $MODE in
http)
    open_firewall_http
    if port80_busy; then
        listener=$(port80_listeners | head -n1)
        pid=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<<"$listener" | head -n1)
        [[ -n $pid ]] || die "Port 80 is in use, but its process could not be identified: $listener"
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]') || comm='?'
        unit=$(pid_unit "$pid")
        if [[ $comm == docker-proxy || $unit != *.service || $unit == user@*.service ||
              $unit =~ ^(docker|containerd|podman|ssh|sshd)\.service$ ]]; then
            die "Port 80 belongs to '$comm' (${unit:-no systemd service}), which this script won't stop by itself.
    Either free port 80 and run again, or use:
      --webroot DIR   (DIR is served on port 80 by that program), or
      --dns           (validation through a TXT record, port 80 not needed)"
        fi
        warn "Port 80 is used by '$comm' ($unit). It will be stopped for a few seconds while the"
        warn "certificate is issued (and at each renewal) and then started again."
        confirm "Continue?" y || die "Cancelled. Use --webroot DIR or --dns to avoid stopping $unit."
        PRE_HOOK="systemctl stop $unit"
        POST_HOOK="systemctl start $unit"
        STOPPED_UNIT=$unit
        systemctl stop "$unit"
        wait_port80_free || die "Port 80 is still in use after stopping $unit:
$(port80_listeners)"
        ok "Stopped $unit"
    fi

    if start_test_server; then
        info "Self-test: fetching a test file through the CDN..."
        selftest_ok=1
        selftest_http "$TMP_DIR/www" || selftest_ok=0
        stop_test_server
        if ((!selftest_ok)); then
            http_hints
            confirm "Ask Let's Encrypt anyway?" n || exit 1
        fi
    else
        warn "python3 is not available, skipping the self-test."
    fi
    ;;
webroot)
    info "Self-test: fetching a test file from $WEBROOT through the CDN..."
    if ! selftest_http "$WEBROOT"; then
        warn "Make sure the web server on port 80 serves $WEBROOT/.well-known/acme-challenge/ for these domains."
        http_hints
        confirm "Ask Let's Encrypt anyway?" n || exit 1
    fi
    ;;
dns)
    ((INTERACTIVE)) || die "--dns needs a terminal: certbot will wait for you to add the TXT record."
    cat <<EOF

    certbot will now show a TXT record (one per domain), for example:
        _acme-challenge.${CERT_NAME}   TXT   "Xy12...long value..."
    In the ManageIt panel open DNS records for the domain and add it:
        Type: TXT   Name: _acme-challenge (for a subdomain: _acme-challenge.sub)   Value: the shown value
    Wait a minute or two, then press Enter in certbot. When the same name is asked
    twice (example.com + *.example.com), keep BOTH TXT records.

EOF
    ;;
esac

step "4/5 Requesting the certificate from Let's Encrypt"
cmd=(certbot certonly --agree-tos --cert-name "$CERT_NAME")
if [[ -n $EMAIL ]]; then
    cmd+=(--email "$EMAIL" --no-eff-email)
else
    cmd+=(--register-unsafely-without-email)
fi
if ((FORCE)); then cmd+=(--force-renewal); else cmd+=(--keep-until-expiring); fi
case $MODE in
http)
    cmd+=(--non-interactive --standalone --preferred-challenges http)
    if [[ -n $PRE_HOOK ]]; then cmd+=(--pre-hook "$PRE_HOOK" --post-hook "$POST_HOOK"); fi
    ;;
webroot)
    cmd+=(--non-interactive --webroot -w "$WEBROOT")
    ;;
dns)
    cmd+=(--manual --preferred-challenges dns)
    ;;
esac
if [[ -n $DEPLOY_HOOK ]]; then cmd+=(--deploy-hook "$DEPLOY_HOOK"); fi
if ((DRY_RUN)); then cmd+=(--dry-run); fi
for d in "${DOMAINS[@]}"; do cmd+=(-d "$d"); done

info "$(printf '%q ' "${cmd[@]}")"
if ! "${cmd[@]}"; then
    certbot_failure_hints
    die "certbot failed; the reason is in its message above (full log: /var/log/letsencrypt/letsencrypt.log)"
fi

if ((DRY_RUN)); then
    ok "Dry run succeeded: the real certificate will work. Run again without --dry-run."
    exit 0
fi

step "5/5 Done"
LIVE="$LE_LIVE/$CERT_NAME"
[[ -f $LIVE/fullchain.pem ]] || die "certbot finished but $LIVE/fullchain.pem is missing. See: certbot certificates"

expires=$(openssl x509 -in "$LIVE/cert.pem" -noout -enddate | cut -d= -f2)
issuer=$(openssl x509 -in "$LIVE/cert.pem" -noout -issuer | sed 's/^issuer=[[:space:]]*//')
names=$(openssl x509 -in "$LIVE/cert.pem" -noout -text | grep -o 'DNS:[^,]*' | cut -d: -f2 | paste -sd' ' -)

if [[ $MODE == dns ]]; then
    renew_note="Manual (--dns): run this script again before $expires."
elif ensure_auto_renew; then
    renew_note="Automatic. Test it any time with: certbot renew --dry-run"
else
    renew_note="${C_RED}NOT automatic here: run 'certbot renew' yourself before $expires${C_RST}"
fi

cat <<EOF

${C_GRN}${C_BLD}================== CERTIFICATE READY ==================${C_RST}
  Domains      : $names
  Issuer       : $issuer
  Valid until  : $expires
  Renewal      : $renew_note

  Certificate (fullchain) : ${C_BLD}$LIVE/fullchain.pem${C_RST}
  Private key             : ${C_BLD}$LIVE/privkey.pem${C_RST}
  Certificate only        : $LIVE/cert.pem
  CA chain                : $LIVE/chain.pem
${C_GRN}${C_BLD}========================================================${C_RST}

  nginx:
      ssl_certificate     $LIVE/fullchain.pem;
      ssl_certificate_key $LIVE/privkey.pem;

  Apache:
      SSLCertificateFile    $LIVE/fullchain.pem
      SSLCertificateKeyFile $LIVE/privkey.pem

  Panels (x-ui / 3x-ui / Marzban / Hiddify ...):
      Public key  / certificate file : $LIVE/fullchain.pem
      Private key / key file         : $LIVE/privkey.pem

  These paths never change; renewals replace the files behind them. If a program
  only reads the certificate at start-up, add --deploy-hook "systemctl restart <it>".

  Once a program here serves HTTPS on port 443 with this certificate, ManageIt's
  connection to the origin can be switched to HTTPS ("Full/Strict" if offered). Keep
  plain HTTP on port 80 reaching this server too (origin protocol "auto/same as
  visitor"), or renewals will fail.
  List certificates any time with: certbot certificates
EOF
