#!/usr/bin/env bash
#
# manageit-check.sh: find out why a site behind the ManageIt CDN shows 502
# ("the origin is unreachable") and what to change.
#
# این اسکریپت از روی خود سرور، آدرس را از طریق CDN منیجیت باز می‌کند و هم‌زمان
# می‌بیند CDN به کدام پورتِ این سرور وصل می‌شود؛ بعد علت خطای 502 و راه‌حل را
# می‌گوید. چیزی را تغییر نمی‌دهد (فقط اگر tcpdump نصب نباشد، نصبش می‌کند).
#
# The CDN edge opens a new TCP connection to this server for the request, so
# watching incoming SYN packets (tcpdump) while fetching the address through
# the CDN shows which port it uses. Combined with what listens on that port
# and how the panel answers locally, that pins down the cause.
#
# Usage:
#   sudo bash manageit-check.sh https://your-domain:2053/panel-path
#
set -uo pipefail

if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_CYN=$'\e[36m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
    C_RED='' C_GRN='' C_YLW='' C_CYN='' C_BLD='' C_RST=''
fi

info() { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST"; }

URL=${1:-}
if [[ -z $URL || $URL == -h || $URL == --help ]]; then
    echo "Usage: sudo bash $0 https://your-domain[:port]/path"
    echo "Use the exact address that shows the 502 page in the browser."
    [[ -n $URL ]]
    exit
fi
((EUID == 0)) || die "Run it as root: sudo bash $0 $URL"

# Split the address into scheme, host, port and path.
[[ $URL == *://* ]] || URL="https://$URL"
SCHEME=${URL%%://*}
SCHEME=${SCHEME,,}
rest=${URL#*://}
HOSTPORT=${rest%%/*}
if [[ $rest == */* ]]; then URL_PATH=/${rest#*/}; else URL_PATH=/; fi
HOST=${HOSTPORT%%:*}
HOST=${HOST,,}
if [[ $HOSTPORT == *:* ]]; then
    PORT=${HOSTPORT##*:}
elif [[ $SCHEME == http ]]; then
    PORT=80
else
    PORT=443
fi
[[ $SCHEME == http || $SCHEME == https ]] || die "The address must start with http:// or https://"
[[ $PORT =~ ^[0-9]+$ ]] || die "Bad port in $URL"

TMP_DIR=$(mktemp -d)
TCPDUMP_PID=""
cleanup() {
    if [[ -n $TCPDUMP_PID ]]; then kill "$TCPDUMP_PID" 2>/dev/null; wait "$TCPDUMP_PID" 2>/dev/null; fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# "address process" for everything listening on TCP port $1.
listeners() {
    ss -ltnp 2>/dev/null | awk -v p="$1" 'NR > 1 && $4 ~ (":" p "$") {
        name = "?"
        if (match($0, /users:\(\("[^"]*"/)) name = substr($0, RSTART + 9, RLENGTH - 10)
        print $4, name
    }'
}

# How the program on port $1 answers locally: "https CODE", "http CODE" or "none 000".
local_protocol() {
    local addr=$2 code
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$HOST:$1:$addr" \
        "https://$HOST:$1$URL_PATH" 2>/dev/null) || code=000
    if [[ $code != 000 ]]; then echo "https $code"; return; fi
    [[ $addr == *:* ]] && addr="[$addr]"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$addr:$1$URL_PATH" 2>/dev/null) || code=000
    if [[ $code != 000 ]]; then echo "http $code"; return; fi
    echo "none 000"
}

# Addresses of this machine (not loopback): SYNs sent to them are the CDN connecting in.
LOCAL_IPS=" $(ip -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | grep -Ev '^(127\.|::1$)' | tr '\n' ' ')"

# Fetch $1 through the CDN while capturing incoming connections.
# Sets PROBE_CODE (HTTP status the CDN answered) and PROBE_PORTS (ports of this server it connected to).
probe() {
    local cap=$TMP_DIR/cap.txt
    PROBE_PORTS=""
    : >"$cap"
    if ((HAVE_TCPDUMP)); then
        tcpdump -nn -l -i any 'tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn and not port 22' >"$cap" 2>/dev/null &
        TCPDUMP_PID=$!
        sleep 2
    fi
    PROBE_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null) || true
    [[ $PROBE_CODE =~ ^[0-9]{3}$ ]] || PROBE_CODE=000
    if [[ -n $TCPDUMP_PID ]]; then
        sleep 2
        kill "$TCPDUMP_PID" 2>/dev/null
        wait "$TCPDUMP_PID" 2>/dev/null
        TCPDUMP_PID=""
        PROBE_PORTS=$(sed -n 's/.* > \([^ ]*\)\.\([0-9][0-9]*\): Flags \[S.*/\1 \2/p' "$cap" |
            while read -r ip port; do
                if [[ $LOCAL_IPS == *" $ip "* ]]; then echo "$port"; fi
            done | sort -un | paste -sd' ' -)
    fi
}

describe_port() {
    local lines
    lines=$(listeners "$1")
    if [[ -z $lines ]]; then
        info "port $1: nothing listens"
    else
        while read -r addr name; do info "port $1: $name listens on $addr"; done <<<"$lines"
    fi
}

step "1/4 DNS"
SERVER_IP=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)
EDGE_IPS=$(getent ahosts "$HOST" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' -)
info "This server's public IPv4: ${SERVER_IP:-unknown}"
[[ -n $EDGE_IPS ]] || die "$HOST does not resolve."
info "$HOST -> $EDGE_IPS"
if [[ -n $SERVER_IP && " $EDGE_IPS " == *" $SERVER_IP "* ]]; then
    warn "$HOST points straight at this server: the ManageIt proxy is OFF for it."
fi

step "2/4 This server"
for p in $(printf '%s\n' "$PORT" 80 443 | awk '!seen[$0]++'); do describe_port "$p"; done

LISTEN=$(listeners "$PORT")
LOOPBACK_ONLY=0
LOCAL_PROTO=none
if [[ -n $LISTEN ]]; then
    if ! grep -qvE '^(127\.[0-9.]+|\[::1\]|\[::ffff:127\.[0-9.]+\]):' <<<"$LISTEN"; then
        LOOPBACK_ONLY=1
        warn "port $PORT only listens on the loopback address: the CDN can't reach it"
    fi
    addr=$(awk 'NR == 1 {print $1}' <<<"$LISTEN")
    addr=${addr%:*}
    addr=${addr#[}
    addr=${addr%]}
    [[ $addr == '*' || $addr == 0.0.0.0 || $addr == :: ]] && addr=127.0.0.1
    read -r LOCAL_PROTO local_code <<<"$(local_protocol "$PORT" "$addr")"
    case $LOCAL_PROTO in
        https) ok "port $PORT answers locally over HTTPS (HTTP $local_code)" ;;
        http)  info "port $PORT answers locally over plain HTTP (HTTP $local_code), not HTTPS" ;;
        *)     warn "port $PORT does not answer a local HTTP(S) request" ;;
    esac
fi

UFW_BLOCKS=0
ufw_status=$(ufw status 2>/dev/null)
if grep -q '^Status: active' <<<"$ufw_status"; then
    if grep -qE "^$PORT(/tcp)?[[:space:]]+ALLOW" <<<"$ufw_status"; then
        ok "ufw is active and allows port $PORT"
    else
        UFW_BLOCKS=1
        warn "ufw is active and does not allow port $PORT"
    fi
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --query-port="$PORT/tcp" || warn "firewalld is running; port $PORT/tcp is not in its allowed ports"
fi

step "3/4 Through the CDN"
HAVE_TCPDUMP=0
if ! command -v tcpdump >/dev/null; then
    info "Installing tcpdump (to see which port the CDN connects to)..."
    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump >/dev/null 2>&1
    elif command -v dnf >/dev/null; then
        dnf install -y -q tcpdump >/dev/null 2>&1
    elif command -v yum >/dev/null; then
        yum install -y -q tcpdump >/dev/null 2>&1
    fi
fi
if command -v tcpdump >/dev/null; then
    HAVE_TCPDUMP=1
else
    warn "tcpdump is not available: can't see which port the CDN uses."
fi

show_probe() {
    local seen
    if ((!HAVE_TCPDUMP)); then
        seen=""
    elif [[ -n $PROBE_PORTS ]]; then
        seen="; the CDN connected to this server on port ${PROBE_PORTS// /, }"
    else
        seen="; no connection from the CDN reached this server"
    fi
    if [[ $PROBE_CODE == 000 ]]; then
        warn "$1 -> no answer from the CDN$seen"
    else
        info "$1 -> CDN answered HTTP $PROBE_CODE$seen"
    fi
}

probe "$URL"
CODE1=$PROBE_CODE
PORTS1=$PROBE_PORTS
show_probe "$URL"
# The same path on the standard ports shows how ManageIt maps ports and protocols.
if [[ $SCHEME != https || $PORT != 443 ]]; then
    probe "https://$HOST$URL_PATH"
    show_probe "https://$HOST$URL_PATH"
fi
if [[ $SCHEME != http || $PORT != 80 ]]; then
    probe "http://$HOST$URL_PATH"
    show_probe "http://$HOST$URL_PATH"
fi

step "4/4 Diagnosis"
say() { printf '  %s\n' "$@"; }

if [[ $CODE1 == 000 ]]; then
    say "This server got no answer from the CDN at all for $URL." \
        "Check that the domain is added and active in ManageIt, and that it proxies port $PORT."
elif [[ $CODE1 != 5?? ]]; then
    if [[ $CODE1 == 400 && $LOCAL_PROTO == https && " $PORTS1 " == *" $PORT "* ]]; then
        say "ManageIt talks plain HTTP to port $PORT, but the panel there expects HTTPS." \
            "Fix: in ManageIt set the connection to the origin to HTTPS (SSL mode \"Full\")."
    elif [[ $CODE1 == [23]?? || $CODE1 == 401 || $CODE1 == 404 ]]; then
        say "Through the CDN the address answers (HTTP $CODE1), so the path CDN -> server works." \
            "If the browser still shows 502, reload with Ctrl+F5 or try a private window."
    else
        say "The CDN answered HTTP $CODE1 (not a 502). A 403 usually means a WAF / firewall rule" \
            "in ManageIt blocked the request."
    fi
elif ((!HAVE_TCPDUMP)); then
    say "The CDN answers $CODE1 but without tcpdump the port it uses can't be seen." \
        "Install tcpdump (apt-get install tcpdump) and run this again."
elif [[ -z $PORTS1 ]]; then
    say "The CDN answered $CODE1 and no connection from it reached this server." \
        "Something in between stops it:" \
        "  - the firewall of your server provider (\"security group\" / firewall in the provider's" \
        "    panel) does not allow TCP port $PORT: allow it there;" \
        "  - or ManageIt does not forward port $PORT: check which ports it proxies, or move the" \
        "    panel to a standard port."
    if ((UFW_BLOCKS)); then say "  - ufw on this server blocks it too: ufw allow $PORT/tcp"; fi
elif [[ " $PORTS1 " == *" $PORT "* ]]; then
    if [[ -z $LISTEN ]]; then
        say "The CDN reaches port $PORT, but nothing listens there: the panel is not running or uses" \
            "another port. Check with: x-ui status   and   x-ui settings"
    elif ((LOOPBACK_ONLY)); then
        say "The panel listens only on 127.0.0.1. In the panel settings clear \"Listen IP\"" \
            "(leave it empty), save, then: x-ui restart"
    elif ((UFW_BLOCKS)); then
        say "The CDN reaches this server on port $PORT, but ufw blocks it. Fix: ufw allow $PORT/tcp"
    elif [[ $LOCAL_PROTO == https ]]; then
        say "The CDN reaches port $PORT, where the panel speaks HTTPS, but the exchange fails:" \
            "ManageIt most likely talks plain HTTP to it (like Cloudflare's \"Flexible\" mode)." \
            "Fix: in ManageIt set the connection to the origin to HTTPS (SSL mode \"Full\")." \
            "Keep plain HTTP (port 80) going to the server as HTTP (\"auto / same as visitor\")," \
            "so the certificate renewal keeps working."
    else
        say "The CDN reaches port $PORT, where the program speaks plain HTTP, but the exchange" \
            "fails: ManageIt most likely talks HTTPS to it. Fix: set ManageIt's connection to the" \
            "origin to HTTP, or give the panel the certificate."
    fi
else
    say "ManageIt sends $URL to port ${PORTS1// /, } of this server, not to $PORT."
    if [[ " $PORTS1 " == *" 80 "* ]]; then
        say "So it connects over plain HTTP to port 80 (like Cloudflare's \"Flexible\" mode), where" \
            "the panel is not." \
            "Fix: in ManageIt set the connection to the origin to HTTPS (SSL mode \"Full\", or" \
            "origin protocol \"auto / same as visitor\") so it keeps port $PORT and uses HTTPS."
    else
        say "Fix: in ManageIt set the origin port to $PORT, or move the panel to port ${PORTS1%% *}."
    fi
fi
echo
