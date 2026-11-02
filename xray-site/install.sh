#!/usr/bin/env bash
# xray-site: a website and x-ui inbounds sharing the same ports.
#
# On every port in the list, HAProxy looks at the first bytes of each connection: a browser
# gets the website (nginx on 127.0.0.1), everything else goes to the x-ui inbound that port
# is mapped to. x-ui itself is never changed. Several ports can be mapped, to the same or to
# different x-ui inbounds.
#
# Each entry needs two ports: the x-ui inbound, and the public port people connect to (on
# the router). The router forwards that public port to the same port number on this server;
# only if that number is taken here is another one used (the list shows which).
#
# Browsers can get one of several site templates (download center, blog, shop, ...), over
# http and, with a certificate, over https on the same ports.
#
# Install (asks for the ports):   sudo bash install.sh
# Afterwards, the menu:           sudo xray-site
# Or commands:
#   xray-site list                                     show the entries
#   xray-site add <x-ui port> <public port> [server port]
#   xray-site change <public port> <new public port> [x-ui port] [server port]
#   xray-site remove <public port>
#   xray-site site-port <port>                         move the website's internal port
#   xray-site apply                                    re-read x-ui after changing an inbound
#   xray-site template [name]                          list or choose the site template
#   xray-site site NAME=... TAGLINE=... EMAIL=... PHONE=...   texts of the current template (--reset)
#   xray-site cert list | issue <domain> | add <name> <cert> <key> [--copy] | paths <name>
#   xray-site cert renew|remove <name> | site <name...>|off | force-https on|off | xui-restart on|off
#   xray-site status | logs [xray-site|nginx|access|x-ui|acme] | restart [all|nginx|x-ui]
#   xray-site public-ip <ip|auto> | update | uninstall
#
# The list lives in /etc/xray-site/xray-site.conf; after editing it by hand run "xray-site apply".
# Install without questions: sudo PORTS="123:2082 124:2083" bash install.sh  (x-ui port:public port)
set -euo pipefail

CONF_DIR=/etc/xray-site
CONF=$CONF_DIR/xray-site.conf
HAPROXY_CONF=$CONF_DIR/haproxy.cfg
FW_FILE=$CONF_DIR/firewall-ports
SITE_DIR=/var/www/xray-site
NGINX_CONF=/etc/nginx/conf.d/xray-site.conf
UNIT=/etc/systemd/system/xray-site.service
BIN=/usr/local/bin/xray-site
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
SHARE=/usr/local/share/xray-site
HELPER=$SHARE/helper.py
CERT_DIR=$CONF_DIR/certs
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
VERSION=2.0
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/eris4444/englishs/claude/admiring-planck-kx3x1l/xray-site/install.sh}"
PAYLOAD_MARK=__XRAY_SITE_PAYLOAD__

if [ -z "${NO_COLOR:-}" ]; then
    C0=$'\033[0m' CB=$'\033[1m' CD=$'\033[2m' CR=$'\033[31m' CG=$'\033[32m' CY=$'\033[33m'
    CC=$'\033[36m' CW=$'\033[97m'
else
    C0="" CB="" CD="" CR="" CG="" CY="" CC="" CW=""
fi
say()  { printf '%s==>%s %s\n' "$CB$CG" "$C0" "$*"; }
warn() { printf '%s!!%s %s\n' "$CB$CY" "$C0" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$CB$CR" "$C0" "$*" >&2; exit 1; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
listeners() { ss -ltnpH "sport = :$1" 2>/dev/null || true; }

# Filled while generating the HAProxy config: per server port, the inbound's description,
# "path host" for a WebSocket self-check, and whether x-ui gets real client IPs.
declare -A MAP_INFO=() MAP_WS=() MAP_PP=()
SITE_TLS_PORT="" SITE_CERTS="" FORCE_HTTPS=0 XUI_RESTART=0 SITE_TLS_CHECK="" SITE_ROOT=""
SITE_SNI_EXACT="" SITE_SNI_SUFFIX="" SITE_HOST_REGEX=""

# ================================================================ config file
# SITE_PORT, CONF_PUBLIC_IP and MAPS. In the file an entry is "share=<public>:<x-ui>[:<server>]";
# in MAPS it is kept as "<server>:<x-ui>:<public>".
load_conf() {
    SITE_PORT="" CONF_PUBLIC_IP="" MAPS=() SITE_TLS_PORT="" SITE_CERTS="" FORCE_HTTPS=0 XUI_RESTART=0
    [ -f "$CONF" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        case "$line" in
            "") ;;
            SITE_PORT=*) SITE_PORT="${line#*=}" ;;
            PUBLIC_IP=*) CONF_PUBLIC_IP="${line#*=}" ;;
            SITE_TLS_PORT=*) SITE_TLS_PORT="${line#*=}" ;;
            SITE_CERTS=*)    SITE_CERTS="${line#*=}" ;;
            FORCE_HTTPS=*)   FORCE_HTTPS="${line#*=}" ;;
            XUI_RESTART=*)   XUI_RESTART="${line#*=}" ;;
            share=*)     local f="${line#*=}" sp sx ss
                         IFS=: read -r sp sx ss _ <<<"$f"
                         MAPS+=("${ss:-$sp}:$sx:$sp") ;;
            port=*)      MAPS+=("${line#*=}") ;;   # older format: <server>:<x-ui>:<public>
            *) die "$CONF: cannot understand this line: $line" ;;
        esac
    done < "$CONF"
}

save_conf() {
    mkdir -p "$CONF_DIR"
    {
        echo "# Website + x-ui on shared ports."
        echo "# Change it with \"sudo xray-site\", or edit this file and run \"sudo xray-site apply\"."
        echo "#"
        echo "# share=<public port on the router>:<x-ui inbound port>[:<port on this server>]"
        echo "# The port on this server is the public port unless given."
        echo "SITE_PORT=$SITE_PORT"
        echo "PUBLIC_IP=$CONF_PUBLIC_IP"
        echo "# HTTPS for the site: certificate names (comma separated), its internal port, http -> https"
        echo "SITE_CERTS=$SITE_CERTS"
        echo "SITE_TLS_PORT=$SITE_TLS_PORT"
        echo "FORCE_HTTPS=$FORCE_HTTPS"
        echo "# Restart x-ui after a certificate renewal (when x-ui uses the certificate too)"
        echo "XUI_RESTART=$XUI_RESTART"
        local m
        for m in "${MAPS[@]}"; do
            split_map "$m"
            if [ "$M_LISTEN" = "$M_PUBLIC" ]; then echo "share=$M_PUBLIC:$M_XUI"
            else echo "share=$M_PUBLIC:$M_XUI:$M_LISTEN"; fi
        done
    } > "$1"
}

# Split "L:X[:P]" into M_LISTEN, M_XUI, M_PUBLIC (public defaults to the server port).
split_map() {
    IFS=: read -r M_LISTEN M_XUI M_PUBLIC _ <<<"$1"
    M_PUBLIC="${M_PUBLIC:-$M_LISTEN}"
}

find_map() {  # index of the entry whose public port (or else server port) is $1
    local i
    for i in "${!MAPS[@]}"; do
        split_map "${MAPS[$i]}"
        [ "$M_PUBLIC" = "$1" ] && { echo "$i"; return 0; }
    done
    for i in "${!MAPS[@]}"; do
        split_map "${MAPS[$i]}"
        [ "$M_LISTEN" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

validate_maps() {
    [ "${#MAPS[@]}" -gt 0 ] || die "No ports configured. Add one with: xray-site add <port> <x-ui port>"
    valid_port "$SITE_PORT" || die "Website port \"$SITE_PORT\" is not a valid port."
    local m seen=" " pubs=" " xuis=" $(xui_ports) "
    for m in "${MAPS[@]}"; do
        split_map "$m"
        valid_port "$M_XUI"    || die "x-ui port \"$M_XUI\" is not a valid port."
        valid_port "$M_PUBLIC" || die "Public port \"$M_PUBLIC\" is not a valid port."
        valid_port "$M_LISTEN" || die "Server port \"$M_LISTEN\" is not a valid port."
        case "$pubs" in *" $M_PUBLIC "*) die "Public port $M_PUBLIC is listed twice." ;; esac
        case "$seen" in *" $M_LISTEN "*) die "Port $M_LISTEN on this server is used by two entries." ;; esac
        pubs="$pubs$M_PUBLIC " seen="$seen$M_LISTEN " xuis="$xuis$M_XUI "
        [ "$M_LISTEN" != "$SITE_PORT" ] && [ "$M_XUI" != "$SITE_PORT" ] ||
            die "Port $SITE_PORT is the website's internal port; pick another, or move it with: xray-site site-port <port>"
        [ -z "$SITE_CERTS" ] || { [ "$M_LISTEN" != "$SITE_TLS_PORT" ] && [ "$M_XUI" != "$SITE_TLS_PORT" ]; } ||
            die "Port $SITE_TLS_PORT is the website's internal HTTPS port; pick another port."
    done
    [ -z "$SITE_CERTS" ] || [ "$SITE_TLS_PORT" != "$SITE_PORT" ] || die "The site's HTTP and HTTPS ports must differ."
    for m in "${MAPS[@]}"; do
        split_map "$m"
        case "$xuis" in *" $M_LISTEN "*)
            die "Port $M_LISTEN on this server is an x-ui inbound port, so the router cannot forward
public port $M_PUBLIC to it. Use another server port: xray-site change $M_PUBLIC $M_PUBLIC $M_XUI <server port>" ;;
        esac
    done
}

# ================================================================ x-ui database
# Python reads /etc/x-ui/x-ui.db read-only. "list" prints every inbound; "one <port>"
# prints XUI_* shell variables describing the inbound on that port.
xui_py() {
    python3 - "$XUI_DB" "$@" <<'PY'
import json, re, shlex, sqlite3, sys

db, mode = sys.argv[1], sys.argv[2]

def describe(stream):
    s = json.loads(stream or "{}")
    net = s.get("network") or "tcp"
    sec = s.get("security") or "none"
    paths, hosts = [], []

    def section(*names):
        for n in names:
            if isinstance(s.get(n), dict):
                return s[n]
        return {}

    def as_list(v):
        if not v:
            return []
        return v if isinstance(v, list) else [x.strip() for x in str(v).split(",") if x.strip()]

    if net in ("tcp", "raw"):
        st = section("tcpSettings", "rawSettings")
        header = st.get("header") or {}
        if header.get("type") == "http":
            req = header.get("request") or {}
            net = "tcp-http"
            paths = as_list(req.get("path")) or ["/"]
            hosts = as_list((req.get("headers") or {}).get("Host"))
    elif net in ("ws", "httpupgrade", "xhttp", "splithttp"):
        st = section({"ws": "wsSettings", "httpupgrade": "httpupgradeSettings",
                      "xhttp": "xhttpSettings", "splithttp": "splithttpSettings"}[net])
        paths = [st.get("path") or "/"]
        hosts = as_list(st.get("host") or (st.get("headers") or {}).get("Host"))
    else:
        st = {}
    pp = bool(st.get("acceptProxyProtocol") or (s.get("sockopt") or {}).get("acceptProxyProtocol"))
    # Only plain characters go into the HAProxy config; the query is not part of the path.
    paths = [p.split("?")[0] or "/" for p in paths]
    paths = [p for p in paths if re.fullmatch(r"/[A-Za-z0-9._~%!+,=:@/-]*", p)]
    hosts = [h for h in hosts if re.fullmatch(r"[A-Za-z0-9.-]+(:[0-9]+)?", h)]
    snis = []
    if sec == "tls":
        snis = as_list((s.get("tlsSettings") or {}).get("serverName"))
    elif sec == "reality":
        snis = as_list((s.get("realitySettings") or {}).get("serverNames"))
    snis = [x.lower() for x in snis if re.fullmatch(r"[A-Za-z0-9.*-]+", x)]
    return net, sec, paths, hosts, pp, snis

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    if mode == "list":
        rows = con.execute("SELECT port, remark, enable, protocol, stream_settings "
                           "FROM inbounds ORDER BY port").fetchall()
    else:
        rows = con.execute("SELECT remark, enable, listen, protocol, stream_settings "
                           "FROM inbounds WHERE port = ?", (int(sys.argv[3]),)).fetchall()
except Exception as e:
    if mode == "list":
        sys.exit(1)
    print("XUI_ERROR=" + shlex.quote(f"could not read {db}: {e}"))
    sys.exit()

if mode == "list":
    for port, remark, enable, proto, stream in rows:
        try:
            net, sec = describe(stream)[:2]
        except Exception:
            net, sec = "?", "?"
        print(f"{port}\t{remark or '-'}\t{proto}/{net}/{sec}\t{'on' if enable else 'OFF'}")
    sys.exit()

if not rows:
    print("XUI_ERROR=" + shlex.quote(f"x-ui has no inbound on port {sys.argv[3]}"))
    sys.exit()
rows.sort(key=lambda r: not r[1])                      # prefer an enabled one
remark, enable, listen, proto, stream = rows[0]
try:
    net, sec, paths, hosts, pp, snis = describe(stream)
except Exception as e:
    print("XUI_ERROR=" + shlex.quote(f"cannot read the settings of the inbound: {e}"))
    sys.exit()
for k, v in dict(REMARK=remark or "", ENABLE=1 if enable else 0, LISTEN=listen or "",
                 PROTO=proto, NET=net, SEC=sec, PATHS=" ".join(paths),
                 HOSTS=" ".join(hosts), PP=1 if pp else 0, SNIS=" ".join(snis)).items():
    print(f"XUI_{k}={shlex.quote(str(v))}")
PY
}

read_inbound() {  # $1 = x-ui port; sets XUI_*
    XUI_ERROR="" XUI_REMARK="" XUI_ENABLE=1 XUI_LISTEN="" XUI_PROTO="" XUI_NET="" XUI_SEC=""
    XUI_PATHS="" XUI_HOSTS="" XUI_PP=0 XUI_SNIS=""
    if [ -r "$XUI_DB" ]; then
        eval "$(xui_py one "$1" || true)"
        [ -n "$XUI_ERROR$XUI_PROTO" ] || XUI_ERROR="could not read the inbound from $XUI_DB"
    else
        XUI_ERROR="$XUI_DB not found"
    fi
    [ -z "$XUI_ERROR" ] || XUI_NET=unknown
}

xui_ports() {  # every inbound port in x-ui, space separated
    [ -r "$XUI_DB" ] || return 0
    if [ -z "${XUI_LIST_CACHE+x}" ]; then XUI_LIST_CACHE="$(xui_py list 2>/dev/null || true)"; fi
    [ -n "$XUI_LIST_CACHE" ] || return 0
    cut -f1 <<<"$XUI_LIST_CACHE" | tr '\n' ' '
}

lan_ip() {  # this server's address in the home network, for the router instructions
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "${ip:-this-server}"
}

show_xui_inbounds() {
    [ -r "$XUI_DB" ] || return 0
    local rows
    rows="$(xui_py list 2>/dev/null || true)"
    [ -n "$rows" ] || return 0
    echo "  Inbounds in x-ui:"
    printf '    %-7s %-20s %-28s %s\n' port name type enabled
    while IFS=$'\t' read -r p r t e; do
        printf '    %-7s %-20s %-28s %s\n' "$p" "${r:0:20}" "$t" "$e"
    done <<<"$rows"
    echo
}

# ================================================================ HAProxy config
# Appends the frontend for one mapping (and its x-ui backend, once per x-ui port) to $1.
# Dies with a clear message when the inbound cannot share a port with the website.
emit_mapping() {
    local out="$1" L="$2" X="$3" be="xui_$3" rules="" p h
    read_inbound "$X"
    if [ -n "$XUI_ERROR" ]; then
        warn "Port $L -> x-ui $X: $XUI_ERROR. Using general rules (TCP, TLS/REALITY, WebSocket,"
        warn "HTTPUpgrade, gRPC work; XHTTP and TCP with an HTTP header do not)."
    elif [ "$XUI_ENABLE" != 1 ]; then
        warn "Port $L -> x-ui $X: the inbound \"$XUI_REMARK\" is disabled in x-ui."
    fi
    case "$XUI_NET" in
        kcp|mkcp|quic|hysteria*)
            die "x-ui inbound $X uses $XUI_NET, which runs over UDP and cannot share a TCP port with a
website. Change its transport in x-ui (TCP, WebSocket, XHTTP or gRPC), or map another inbound." ;;
    esac
    if [ "$XUI_SEC" = none ] || [ "$XUI_NET" = unknown ]; then
        case "$XUI_NET" in
            ws|httpupgrade|unknown)
                # Browsers never ask for a WebSocket upgrade on this site.
                rules="    use_backend $be if HTTP { hdr(upgrade) -i websocket }" ;;
            xhttp|splithttp|tcp-http)
                for p in $XUI_PATHS; do
                    [ "$p" = "/" ] && continue
                    rules="$rules
    use_backend $be if HTTP { path -m str ${p%/} } or HTTP { path -m beg ${p%/}/ }"
                done
                for h in $XUI_HOSTS; do
                    rules="$rules
    use_backend $be if HTTP { hdr(host) -i $h }"
                done
                [ -n "$rules" ] || die "x-ui inbound $X ($XUI_NET) uses path \"/\" and no host, so its requests look
exactly like a browser opening the website. In x-ui give it a path such as
/$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n') (and update the client links), then try again." ;;
        esac
    fi

    # HTTP proxy inbounds (http, mixed) speak HTTP too, but send what a browser never sends to
    # a website: CONNECT, or a full URL in the request line.
    case "$XUI_PROTO" in http|mixed)
        rules="$rules
    use_backend $be if HTTP METH_CONNECT
    use_backend $be if HTTP { url_beg -i http:// }" ;;
    esac

    # HTTPS for the site: TLS for one of the site's domains goes to nginx; every other TLS
    # (x-ui inbounds with TLS or REALITY) still goes to x-ui.
    local tls_accept="" tls_rule="" sni
    if [ -n "$SITE_SNI_EXACT$SITE_SNI_SUFFIX" ]; then
        for sni in $XUI_SNIS; do
            if sni_is_site "$sni"; then
                die "x-ui inbound $X uses TLS with the name $sni, which is also a domain of the site's certificate,
so they cannot share port $L. Use another domain for one of them."
            fi
        done
        tls_accept="    tcp-request content accept if { req.ssl_hello_type 1 }"
        [ -z "$SITE_SNI_EXACT" ] || tls_rule="    use_backend site_tls if { req.ssl_sni -i$SITE_SNI_EXACT }"
        [ -z "$SITE_SNI_SUFFIX" ] || tls_rule="$tls_rule
    use_backend site_tls if { req.ssl_sni -m end -i$SITE_SNI_SUFFIX }"
    fi

    local addr server
    case "$XUI_LISTEN" in ""|0.0.0.0|::|"[::]") addr=127.0.0.1 ;; *) addr="$XUI_LISTEN" ;; esac
    timeout 3 bash -c "exec 3<>/dev/tcp/$addr/$X" 2>/dev/null ||
        die "Nothing answers on $addr:$X (x-ui inbound for port $L). Is x-ui running and the inbound enabled?"
    case "$addr" in *:*) server="ipv6@$addr:$X" ;; *) server="$addr:$X" ;; esac

    cat >> "$out" <<EOF

# port $L -> x-ui $X: "$XUI_REMARK" $XUI_PROTO / $XUI_NET / security $XUI_SEC
frontend port_$L
    bind :$L
    # Wait for the first bytes; browsers and VPN clients both speak first, so no delay.
    tcp-request inspect-delay 5s
$tls_accept
    tcp-request content accept if HTTP
    # gRPC without TLS starts with the HTTP/2 preface "PRI"; browsers never send it here.
    use_backend $be if { req.payload(0,3) -m bin 505249 }
$tls_rule
$rules
    use_backend site if HTTP
    # Anything that is not plain HTTP (VLESS/VMess/Trojan/Shadowsocks, TLS, REALITY) is the VPN.
    default_backend $be
EOF
    case " $EMITTED_BACKENDS " in
        *" $be "*) ;;
        *)  EMITTED_BACKENDS="$EMITTED_BACKENDS $be"
            printf '\nbackend %s\n    server xui %s%s\n' "$be" "$server" \
                "$([ "$XUI_PP" = 1 ] && echo " send-proxy-v2")" >> "$out" ;;
    esac
    # For the self-check and summary.
    MAP_INFO[$L]="${XUI_REMARK:+\"$XUI_REMARK\" }$XUI_PROTO/$XUI_NET/$XUI_SEC"
    MAP_WS[$L]=""
    if [ "$XUI_SEC" = none ] && { [ "$XUI_NET" = ws ] || [ "$XUI_NET" = httpupgrade ]; }; then
        MAP_WS[$L]="${XUI_PATHS%% *} ${XUI_HOSTS%% *}"
    fi
    MAP_PP[$L]="$XUI_PP"
    [ "$XUI_NET" != unknown ] || MAP_PP[$L]=x
}

generate_haproxy() {  # $1 = output file
    MAP_INFO=() MAP_WS=() MAP_PP=()
    EMITTED_BACKENDS=""
    cat > "$1" <<EOF
# Website + x-ui on shared ports. Generated by xray-site from $CONF; do not edit by hand.
global
    user haproxy
    group haproxy
    # After a change, connections still open on the old setup are closed after 10 minutes.
    hard-stop-after 10m

defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

backend site
    server site 127.0.0.1:$SITE_PORT send-proxy
EOF
    if [ -n "$SITE_CERTS" ]; then
        printf '\nbackend site_tls\n    server site_tls 127.0.0.1:%s send-proxy\n' "$SITE_TLS_PORT" >> "$1"
    fi
    local m
    for m in "${MAPS[@]}"; do
        split_map "$m"
        emit_mapping "$1" "$M_LISTEN" "$M_XUI"
    done
}

write_nginx_conf() {
    # HAProxy passes the visitor's address with the PROXY protocol, so nginx logs real IPs.
    local redirect="" name
    if [ "$FORCE_HTTPS" = 1 ] && [ -n "$SITE_HOST_REGEX" ]; then
        redirect="
    # Browsers asking for the site's domain over http go to https on the same port.
    if (\$host ~* \"$SITE_HOST_REGEX\") { return 301 https://\$http_host\$request_uri; }"
    fi
    cat > "$NGINX_CONF" <<EOF
# Website behind the xray-site splitter. Generated by xray-site.
server {
    listen 127.0.0.1:$SITE_PORT proxy_protocol;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_name _;
    server_tokens off;

    root $SITE_ROOT;
    index index.html;
$redirect
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    for name in ${SITE_CERTS//,/ }; do
        cert_meta "$name" || continue
        cat >> "$NGINX_CONF" <<EOF

# HTTPS for the site with certificate "$name"
server {
    listen 127.0.0.1:$SITE_TLS_PORT ssl proxy_protocol;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_name $(cert_domains "$CM_CERT");
    server_tokens off;
    ssl_certificate $CM_CERT;
    ssl_certificate_key $CM_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $SITE_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    done
}

write_unit() {
    local hb
    hb="$(command -v haproxy)" || die "haproxy is not installed."
    cat > "$UNIT" <<EOF
[Unit]
Description=Website + x-ui on shared ports (HAProxy splitter)
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=$hb -c -q -f $HAPROXY_CONF
ExecStart=$hb -Ws -f $HAPROXY_CONF -p /run/xray-site.pid
ExecReload=$hb -c -q -f $HAPROXY_CONF
ExecReload=/bin/kill -USR2 \$MAINPID
KillMode=mixed
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

# ================================================================ firewall
fw_sync() {
    local want="" had="" kept="" p m
    for m in "${MAPS[@]}"; do split_map "$m"; want="$want $M_LISTEN"; done
    [ -f "$FW_FILE" ] && had="$(cat "$FW_FILE")"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in $want; do
            if [[ " $had " == *" $p "* ]]; then kept="$kept $p"
            elif ! ufw status | grep -qE "^$p/tcp[[:space:]]"; then
                ufw allow "$p/tcp" >/dev/null && kept="$kept $p" && say "ufw: opened $p/tcp"
            fi
        done
        for p in $had; do
            [[ " $want " == *" $p "* ]] || { ufw delete allow "$p/tcp" >/dev/null 2>&1 || true; say "ufw: closed $p/tcp"; }
        done
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        for p in $want; do
            if [[ " $had " == *" $p "* ]]; then kept="$kept $p"
            elif ! firewall-cmd -q --query-port="$p/tcp"; then
                firewall-cmd -q --permanent --add-port="$p/tcp" && kept="$kept $p" && say "firewalld: opened $p/tcp"
            fi
        done
        for p in $had; do
            [[ " $want " == *" $p "* ]] || { firewall-cmd -q --permanent --remove-port="$p/tcp" || true; say "firewalld: closed $p/tcp"; }
        done
        firewall-cmd -q --reload
    else
        return 0
    fi
    echo "$kept" > "$FW_FILE"
}

selinux_ports() {
    command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ] || return 0
    setsebool -P haproxy_connect_any 1 2>/dev/null || true
    command -v semanage >/dev/null || return 0
    local m
    for m in "${MAPS[@]}"; do
        split_map "$m"
        semanage port -a -t http_port_t -p tcp "$M_LISTEN" 2>/dev/null ||
        semanage port -m -t http_port_t -p tcp "$M_LISTEN" 2>/dev/null || true
    done
    semanage port -a -t http_port_t -p tcp "$SITE_PORT" 2>/dev/null ||
    semanage port -m -t http_port_t -p tcp "$SITE_PORT" 2>/dev/null || true
}

# ================================================================ apply
# Builds everything from SITE_PORT and MAPS, switches over, checks every port, and puts the
# previous setup back if anything fails. Saves the config only when it all works.
check_ports_free() {
    local m owners
    for m in "${MAPS[@]}"; do
        split_map "$m"
        owners="$(listeners "$M_LISTEN")"
        [ -n "$owners" ] || continue
        grep -q '"haproxy"' <<<"$owners" && systemctl is-active --quiet xray-site && continue
        # The first version of this script had nginx itself on the shared port.
        grep -q '"nginx"' <<<"$owners" && grep -qsE "listen $M_LISTEN( |;)" "$NGINX_CONF" && continue
        if grep -q '"xray' <<<"$owners" || [[ " $(xui_ports) " == *" $M_LISTEN "* ]]; then
            die "Port $M_LISTEN on this server belongs to x-ui (an inbound listens there), so public port
$M_PUBLIC cannot be forwarded to it. Use another server port:
  xray-site change $M_PUBLIC $M_PUBLIC $M_XUI <free port>"
        fi
        die "Port $M_LISTEN on this server is already used by another program:
$owners
Use another server port for public port $M_PUBLIC: xray-site change $M_PUBLIC $M_PUBLIC $M_XUI <free port>"
    done
    owners="$(listeners "$SITE_PORT")"
    if [ -n "$owners" ] && ! { grep -q '"nginx"' <<<"$owners" && grep -qs "127.0.0.1:$SITE_PORT " "$NGINX_CONF"; }; then
        die "The website's internal port $SITE_PORT is used by another program. Move it: xray-site site-port <port>"
    fi
    if [ -n "$SITE_CERTS" ]; then
        owners="$(listeners "$SITE_TLS_PORT")"
        if [ -n "$owners" ] && ! { grep -q '"nginx"' <<<"$owners" && grep -qs "127.0.0.1:$SITE_TLS_PORT ssl" "$NGINX_CONF"; }; then
            die "The website's internal HTTPS port $SITE_TLS_PORT is used by another program."
        fi
    fi
}

restore_backup() {
    local f
    for f in "$CONF" "$HAPROXY_CONF" "$NGINX_CONF"; do
        if [ -f "$f.bak" ]; then mv -f "$f.bak" "$f"; else rm -f "$f"; fi
    done
}

self_check() {
    local m code ws path host
    for m in "${MAPS[@]}"; do
        split_map "$m"
        code=000
        for _ in 1 2 3 4 5 6; do
            code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$M_LISTEN/" || true)"
            [ "$code" = 200 ] && break
            sleep 0.5
        done
        [ "$code" = 200 ] || { echo "port $M_LISTEN: the website answered HTTP $code instead of 200"; return 1; }
        if [ -n "$SITE_TLS_CHECK" ]; then
            code="$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$SITE_TLS_CHECK:$M_LISTEN:127.0.0.1" \
                "https://$SITE_TLS_CHECK:$M_LISTEN/" || true)"
            [ "$code" = 200 ] || { echo "port $M_LISTEN: the website over https answered $code instead of 200"; return 1; }
        fi
        ws="${MAP_WS[$M_LISTEN]:-}"
        if [ -n "$ws" ]; then
            path="${ws%% *}"; host="${ws#* }"
            code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --http1.1 --max-time 3 ${host:+-H "Host: $host"} \
                -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
                -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://127.0.0.1:$M_LISTEN$path" || true)"
            [ "$code" = 101 ] || { echo "port $M_LISTEN: x-ui did not accept the WebSocket (HTTP $code)"; return 1; }
        fi
    done
}

apply() {
    unset XUI_LIST_CACHE
    prepare_site
    validate_maps
    check_ports_free
    mkdir -p "$CONF_DIR"
    generate_haproxy "$HAPROXY_CONF.new"
    haproxy -c -q -f "$HAPROXY_CONF.new" || die "haproxy rejected the generated config (errors above)."

    local f
    for f in "$CONF" "$HAPROXY_CONF" "$NGINX_CONF"; do
        rm -f "$f.bak"; [ -f "$f" ] && cp -p "$f" "$f.bak"
    done
    write_nginx_conf
    # With IPv6 turned off, the stock Debian/Ubuntu site's "listen [::]:80" stops nginx.
    if [ ! -e /proc/net/if_inet6 ] && [ -f /etc/nginx/sites-enabled/default ]; then
        sed -i --follow-symlinks -E 's/^(\s*)listen \[::\]/\1# listen [::]/' /etc/nginx/sites-enabled/default
    fi
    if ! nginx -t 2>"$CONF_DIR/nginx-test.log"; then
        cat "$CONF_DIR/nginx-test.log" >&2
        restore_backup; rm -f "$HAPROXY_CONF.new"
        die "nginx rejected the config (shown above). Nothing was changed."
    fi
    mv -f "$HAPROXY_CONF.new" "$HAPROXY_CONF"
    save_conf "$CONF"
    write_unit
    selinux_ports

    systemctl enable --quiet nginx
    if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl restart nginx; fi
    sleep 0.5   # let nginx release ports the first version of this script used
    systemctl daemon-reload
    systemctl enable --quiet xray-site
    if systemctl is-active --quiet xray-site; then systemctl reload xray-site; else systemctl restart xray-site; fi
    sleep 1

    local problem=""
    systemctl is-active --quiet xray-site || problem="the splitter did not start"
    [ -n "$problem" ] || problem="$(self_check)" || true
    if [ -n "$problem" ]; then
        journalctl -u xray-site -n 15 --no-pager >&2 2>/dev/null || true
        if [ -f "$HAPROXY_CONF.bak" ]; then
            restore_backup
            systemctl reload nginx || true
            systemctl restart xray-site || true
            die "Check failed: $problem. The previous setup was put back."
        fi
        die "Check failed: $problem."
    fi
    rm -f "$CONF.bak" "$HAPROXY_CONF.bak" "$NGINX_CONF.bak"
    fw_sync
    say "All ports checked: website and x-ui answer."
}

# Runs apply in a subshell so a failure only cancels this change (used by the menu).
# Sets APPLIED=1 on success. Call it as a plain command, never after && or ||:
# bash ignores "set -e" inside anything called from such a test.
try_apply() {
    local rc
    set +e
    ( set -e; apply )
    rc=$?
    set -e
    load_conf
    APPLIED=0; [ "$rc" = 0 ] && APPLIED=1
    return 0
}

# Same for any command: runs "$@" in a subshell with errexit on, sets RAN=1 on success.
try_run() {
    local rc
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    RAN=0; [ "$rc" = 0 ] && RAN=1
    return 0
}

# ================================================================ output
public_ip() {
    if [ -z "${DETECTED_IP:-}" ]; then
        DETECTED_IP="${PUBLIC_IP:-$CONF_PUBLIC_IP}"
        local u
        if [ -z "$DETECTED_IP" ]; then
            for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
                DETECTED_IP="$(curl -4 -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')" &&
                    [ -n "$DETECTED_IP" ] && break
            done
        fi
        DETECTED_IP="${DETECTED_IP:-YOUR_PUBLIC_IP}"
    fi
    echo "$DETECTED_IP"
}

inbound_info() {  # $1 server port, $2 x-ui port: "name" protocol/transport/security
    local info="${MAP_INFO[$1]:-}"
    if [ -z "$info" ]; then
        read_inbound "$2"
        if [ -n "$XUI_ERROR" ]; then info="(not found in x-ui)"; else info="${XUI_REMARK:+\"$XUI_REMARK\" }$XUI_PROTO/$XUI_NET"; fi
    fi
    echo "$info"
}

print_list() {
    local i=0 m lan
    lan="$(lan_ip)"
    printf '\n  %-3s %-13s %-38s %s\n' "#" "public port" "x-ui inbound" "router forwards to"
    for m in "${MAPS[@]}"; do
        i=$((i + 1)); split_map "$m"
        printf '  %-3s %-13s %-38s %s\n' "$i" "$M_PUBLIC" "$M_XUI $(inbound_info "$M_LISTEN" "$M_XUI")" "$lan:$M_LISTEN"
    done
    printf '\n  Website internal port: 127.0.0.1:%s    Files: %s\n\n' "$SITE_PORT" "$SITE_DIR"
}

print_summary() {
    local ip m note=""
    ip="$(public_ip)"
    echo
    local info pp
    for m in "${MAPS[@]}"; do
        split_map "$m"
        info="${MAP_INFO[$M_LISTEN]:-}" pp="${MAP_PP[$M_LISTEN]:-}"
        if [ -z "$info" ]; then   # the change was applied in a subshell (menu)
            read_inbound "$M_XUI"
            info="${XUI_REMARK:+\"$XUI_REMARK\" }$XUI_PROTO/$XUI_NET/$XUI_SEC" pp="$XUI_PP"
            [ -z "$XUI_ERROR" ] || { info="($XUI_ERROR)"; pp=x; }
        fi
        printf '  http://%s:%s/   website + x-ui %s %s\n' "$ip" "$M_PUBLIC" "$M_XUI" "$info"
        [ "$pp" = 0 ] && [[ "$note" != *" $M_XUI"* ]] && note="$note $M_XUI"
    done
    local lan; lan="$(lan_ip)"
    echo
    echo "  In the router, forward (TCP):"
    for m in "${MAPS[@]}"; do
        split_map "$m"
        printf '    public %-6s ->  %s:%s\n' "$M_PUBLIC" "$lan" "$M_LISTEN"
    done
    cat <<EOF

  In the VPN apps, use address $ip and the public port above (not the inbound's own port).
EOF
    if [ -n "$note" ]; then
        cat <<EOF

  Note: x-ui sees every VPN user as 127.0.0.1 on inbound(s)$note, so an IP limit on
  clients will not work there. Turn on "Proxy Protocol" for the inbound in x-ui and run
  "sudo xray-site apply".
EOF
    fi
    echo "  Open the menu any time: ${CB}sudo xray-site${C0}"
    echo
}

# ================================================================ questions
ask() {  # $1 variable, $2 question, $3 default
    local ans
    read -r -p "  $2${3:+ [$3]}: " ans || { echo; die "No answer (input closed)."; }
    ans="${ans//[[:space:]]/}"   # also drops a stray \r from terminals that send \r\n
    drain_input
    printf -v "$1" '%s' "${ans:-$3}"
}

ask_text() {  # like ask, but keeps the spaces inside the answer
    local ans
    read -r -p "  $2${3:+ [$3]}: " ans || { echo; die "No answer (input closed)."; }
    ans="${ans%$'\r'}"
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    drain_input
    printf -v "$1" '%s' "${ans:-$3}"
}

# Some terminals send two line breaks for Enter; drop whatever arrived with the answer.
drain_input() {
    [ -t 0 ] || return 0
    local _junk
    while read -r -t 0.05 _junk; do :; done
    return 0
}

ask_port() {  # $1 variable, $2 question, $3 default; repeats until valid
    local v
    while :; do
        ask v "$2" "${3:-}"
        valid_port "$v" && break
        echo "    Enter a number from 1 to 65535."
    done
    printf -v "$1" '%s' "$v"
}

# Why port $1 cannot be the server port of an entry ($2 = its x-ui port, $3 = row being
# edited or -1). Prints nothing when the port is usable.
server_port_problem() {
    local l="$1" x="$2" row="$3" i owners
    [ -n "$SITE_PORT" ] && [ "$l" = "$SITE_PORT" ] && { echo "is the website's internal port"; return; }
    if [ "$l" = "$x" ] || [[ " $(xui_ports) " == *" $l "* ]]; then echo "is an x-ui inbound port"; return; fi
    for i in "${!MAPS[@]}"; do
        [ "$i" = "$row" ] && continue
        split_map "${MAPS[$i]}"
        [ "$M_LISTEN" = "$l" ] && { echo "is already used for public port $M_PUBLIC"; return; }
        [ "$M_XUI" = "$l" ] && { echo "is an x-ui inbound port"; return; }
    done
    owners="$(listeners "$l")"
    [ -n "$owners" ] || return 0
    grep -q '"haproxy"' <<<"$owners" && systemctl is-active --quiet xray-site && return 0
    grep -q '"nginx"' <<<"$owners" && grep -qsE "listen $l( |;)" "$NGINX_CONF" && return 0
    echo "is used by $(grep -oE '\(\("[^"]+"' <<<"$owners" | head -1 | tr -d '("')"
}

suggest_server_port() {  # a usable server port near $1
    local p
    for p in $(seq $(( $1 + 1 )) $(( $1 + 30 ))) $(seq 20000 20200); do
        valid_port "$p" && [ -z "$(server_port_problem "$p" "$2" "$3")" ] && { echo "$p"; return; }
    done
}

# Asks for one entry. $1 default x-ui port, $2 default public port, $3 row being edited or -1.
# Sets NEW_MAP ("server:x-ui:public").
ask_mapping() {
    local x p l why old_l="" old_p="" ports
    if [ "$3" -ge 0 ]; then split_map "${MAPS[$3]}"; old_l="$M_LISTEN" old_p="$M_PUBLIC"; fi
    ports="$(xui_ports)"
    while :; do
        ask_port x "x-ui inbound port (from the list above)" "$1"
        if [ -n "$ports" ] && [[ " $ports " != *" $x "* ]]; then
            echo "    $x is not an x-ui inbound. The inbound ports are: $ports"
        elif [ -z "$ports" ] && ! timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$x" 2>/dev/null; then
            echo "    Nothing answers on port $x. Enter the port of an x-ui inbound."
        else
            break
        fi
    done
    while :; do
        ask_port p "Public port people connect to (on the router)" "$2"
        local i taken=""
        for i in "${!MAPS[@]}"; do
            [ "$i" = "$3" ] && continue
            split_map "${MAPS[$i]}"; [ "$M_PUBLIC" = "$p" ] && taken=1
        done
        [ -z "$taken" ] && break
        echo "    Public port $p is already in the list."
    done
    # The router forwards the public port to this server, normally to the same number.
    if [ "$p" = "$old_p" ]; then l="$old_l"; else l="$p"; fi
    why="$(server_port_problem "$l" "$x" "$3")"
    if [ -n "$why" ]; then
        echo "    Port $l on this server $why, so the router has to forward public port $p"
        echo "    to another port here."
        while :; do
            ask_port l "Port on this server for the router to forward $p to" "$(suggest_server_port "$p" "$x" "$3")"
            why="$(server_port_problem "$l" "$x" "$3")"
            [ -z "$why" ] && break
            echo "    Port $l $why."
        done
    fi
    NEW_MAP="$l:$x:$p"
}

first_free_inbound() {  # the first x-ui inbound port not yet in the list
    local p m used=" "
    for m in "${MAPS[@]}"; do split_map "$m"; used="$used$M_XUI "; done
    for p in $(xui_ports); do [[ "$used" == *" $p "* ]] || { echo "$p"; return; }; done
}

# $1 question, $2 default y|n. Without a default an empty answer is asked again, so a stray
# Enter (some terminals send two line breaks) never counts as "no". On a Persian keyboard
# layout the y and n keys type غ and د, so those count too.
yes_no() {
    local a
    while :; do
        ask a "$1 (y/n)" "${2:-}"
        case "$a" in
            y|Y|yes|Yes|YES|غ|بله|آره) return 0 ;;
            n|N|no|No|NO|د|نه|خیر)    return 1 ;;
        esac
        echo "    Please type y or n."
    done
}

pick_row() {  # sets ROW to a mapping index chosen by number
    local n
    ask n "Number (#) from the list" ""
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#MAPS[@]}" ] || { echo "    No such row."; return 1; }
    ROW=$((n - 1))
}

# ================================================================ site files and HTTPS
# The site template's files and the helper ship inside this script, after the payload marker.
install_files() {
    local self tmp src
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    tmp="$(mktemp -d)"
    if grep -q "^$PAYLOAD_MARK\$" "$self"; then
        sed -n "/^$PAYLOAD_MARK\$/,\$p" "$self" | tail -n +2 | base64 -d | tar -xzf - -C "$tmp" ||
            die "The template files inside this script are damaged. Download install.sh again."
    else
        # Running from a git checkout that was not built: use the files next to the script.
        src="$(dirname "$self")"
        [ -f "$src/helper.py" ] && [ -d "$src/templates" ] ||
            die "helper.py and templates/ are missing. Download install.sh again."
        cp -r "$src/helper.py" "$src/templates" "$tmp/"
    fi
    rm -rf "$SHARE.new"
    mkdir -p "$(dirname "$SHARE")"
    mv "$tmp" "$SHARE.new"
    chmod -R a+rX "$SHARE.new"
    rm -rf "$SHARE"
    mv "$SHARE.new" "$SHARE"
}

need_helper() {
    [ -f "$HELPER" ] || install_files
}

cert_meta() {  # $1 name; sets CM_TYPE CM_DOMAIN CM_CERT CM_KEY CM_METHOD CM_CA CM_WILDCARD
    CM_TYPE="" CM_DOMAIN="" CM_CERT="" CM_KEY="" CM_METHOD="" CM_CA="" CM_WILDCARD=""
    local f="$CERT_DIR/$1/meta" k v
    [ -f "$f" ] || return 1
    while IFS='=' read -r k v; do
        case "$k" in
            TYPE) CM_TYPE="$v" ;; DOMAIN) CM_DOMAIN="$v" ;; CERT) CM_CERT="$v" ;; KEY) CM_KEY="$v" ;;
            METHOD) CM_METHOD="$v" ;; CA) CM_CA="$v" ;; WILDCARD) CM_WILDCARD="$v" ;;
        esac
    done < "$f"
}

cert_domains() {  # domains in a certificate file, space separated
    python3 "$HELPER" certinfo "$1" 2>/dev/null | cut -f1 | tr ',' ' '
}

cert_names() {  # every stored certificate name
    local d
    [ -d "$CERT_DIR" ] || return 0
    for d in "$CERT_DIR"/*/; do
        if [ -f "$d/meta" ]; then basename "$d"; fi
    done
    return 0
}

sni_is_site() {  # is TLS name $1 one of the site's HTTPS domains?
    local d
    for d in $SITE_SNI_EXACT; do [ "$1" = "$d" ] && return 0; done
    for d in $SITE_SNI_SUFFIX; do [[ "$1" == *"$d" ]] && return 0; done
    return 1
}

# Renders the selected template and works out the HTTPS settings for the site:
# SITE_ROOT, SITE_SNI_EXACT, SITE_SNI_SUFFIX, SITE_HOST_REGEX, SITE_TLS_CHECK, SITE_TLS_PORT.
prepare_site() {
    need_helper
    SITE_ROOT="$(python3 "$HELPER" render)" || die "The site template could not be prepared."
    SITE_SNI_EXACT="" SITE_SNI_SUFFIX="" SITE_HOST_REGEX="" SITE_TLS_CHECK=""
    [ -n "$SITE_CERTS" ] || return 0
    local name d re="" p m used first=""
    for name in ${SITE_CERTS//,/ }; do
        cert_meta "$name" || die "The site uses certificate \"$name\", which does not exist. Change it: xray-site cert site <name|off>"
        [ -r "$CM_CERT" ] && [ -r "$CM_KEY" ] || die "Certificate \"$name\": $CM_CERT or $CM_KEY cannot be read."
        python3 "$HELPER" certcheck "$CM_CERT" "$CM_KEY" >/dev/null ||
            die "Certificate \"$name\": the private key does not belong to the certificate."
        for d in $(cert_domains "$CM_CERT"); do
            d="${d,,}"
            if [[ "$d" == "*."* ]]; then
                SITE_SNI_SUFFIX="$SITE_SNI_SUFFIX ${d#\*}"
                re="$re|[^.]+${d#\*}"
                [ -n "$SITE_TLS_CHECK" ] || SITE_TLS_CHECK="www${d#\*}"
            else
                SITE_SNI_EXACT="$SITE_SNI_EXACT $d"
                re="$re|$d"
                [ -n "$first" ] || first="$d"
            fi
        done
    done
    SITE_TLS_CHECK="${first:-$SITE_TLS_CHECK}"   # prefer a real name over one made from a wildcard
    [ -n "$re" ] || die "The site's certificate(s) contain no domain name."
    re="${re#|}"
    SITE_HOST_REGEX="^(${re//./\\.})\$"
    if [ -z "$SITE_TLS_PORT" ]; then
        used=" "
        for m in "${MAPS[@]}"; do split_map "$m"; used="$used$M_LISTEN $M_XUI "; done
        for p in $(seq $(( SITE_PORT + 1 )) $(( SITE_PORT + 200 ))); do
            [[ "$used" == *" $p "* ]] && continue
            [ -z "$(listeners "$p")" ] && { SITE_TLS_PORT=$p; break; }
        done
        [ -n "$SITE_TLS_PORT" ] || die "No free port found for the site's internal HTTPS port."
    fi
}

# ================================================================ certificates
acme() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" "$@"; }

pkg_install() {  # best effort
    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null; then dnf install -y -q "$@" >/dev/null 2>&1 || true
    elif command -v yum >/dev/null; then yum install -y -q "$@" >/dev/null 2>&1 || true
    fi
}

acme_install() {  # $1 email (optional)
    [ -x "$ACME_HOME/acme.sh" ] && return 0
    say "Installing acme.sh (the certificate client)"
    command -v crontab >/dev/null || pkg_install cron
    command -v socat >/dev/null || pkg_install socat
    local tmp base="https://raw.githubusercontent.com/acmesh-official/acme.sh/master"
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/dnsapi"
    curl -fsSL --retry 3 -o "$tmp/acme.sh" "$base/acme.sh" &&
        curl -fsSL --retry 3 -o "$tmp/dnsapi/dns_cf.sh" "$base/dnsapi/dns_cf.sh" ||
        { rm -rf "$tmp"; die "Could not download acme.sh from GitHub."; }
    if ! (cd "$tmp" && sh ./acme.sh --install --home "$ACME_HOME" ${1:+--accountemail "$1"}) > "$tmp/log" 2>&1; then
        cat "$tmp/log" >&2
        rm -rf "$tmp"
        die "acme.sh could not be installed (output above)."
    fi
    mkdir -p "$ACME_HOME/dnsapi"
    [ -f "$ACME_HOME/dnsapi/dns_cf.sh" ] || cp "$tmp/dnsapi/dns_cf.sh" "$ACME_HOME/dnsapi/"
    rm -rf "$tmp"
    [ -x "$ACME_HOME/acme.sh" ] || die "acme.sh could not be installed."
}

write_meta() {  # $1 dir, then KEY=VALUE ...
    local dir="$1"; shift
    printf '%s\n' "$@" > "$dir/meta"
    chmod 600 "$dir/meta"
}

valid_cert_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
valid_file_path() { [[ "$1" =~ ^/[A-Za-z0-9._/@:+-]{1,255}$ ]]; }
valid_domain() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

show_cert_paths() {  # $1 name
    cert_meta "$1" || return 0
    local how="added by hand"
    if [ "$CM_TYPE" = acme ]; then
        local wild=""
        if [ "$CM_WILDCARD" = 1 ]; then wild=", wildcard"; fi
        how="from ${CM_CA:-letsencrypt} via acme.sh ($CM_METHOD$wild), renews by itself"
    fi
    cat <<EOF

  ${CB}Files of certificate "$1"${C0} ($how)
  Use them in x-ui: Panel Settings > certificate paths, or an inbound's TLS settings.
    Certificate (public key):  ${CC}$CM_CERT${C0}
    Private key:               ${CC}$CM_KEY${C0}
EOF
}

cmd_cert_issue() {  # <domain> [--method cloudflare|http] [--http-port N] [--email E] [--ca CA] [--wildcard]
    local dom="${1:-}" method="" port=80 email="" ca=letsencrypt wildcard=0 server
    [ -n "$dom" ] || die "Usage: xray-site cert issue <domain> [--method cloudflare|http] [--http-port N] [--email E] [--ca letsencrypt|zerossl] [--wildcard]"
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --method) method="${2:-}"; shift ;;
            --http-port) port="${2:-}"; shift ;;
            --email) email="${2:-}"; shift ;;
            --ca) ca="${2:-}"; shift ;;
            --wildcard) wildcard=1 ;;
            *) die "Unknown option $1" ;;
        esac
        shift
    done
    dom="${dom,,}"
    valid_domain "$dom" || die "\"$dom\" is not a valid domain name (example: vpn.example.com)."
    [ -n "$method" ] || { if [ -n "${CF_Token:-}" ]; then method=cloudflare; else method=http; fi; }
    case "$ca" in
        letsencrypt|zerossl|buypass|google) server="$ca" ;;
        https://*) server="$ca" ;;
        *) die "Unknown certificate authority \"$ca\" (use letsencrypt or zerossl)." ;;
    esac
    [ -z "$email" ] || [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] || die "\"$email\" is not a valid email."
    [ "$ca" != zerossl ] || [ -n "$email" ] || die "ZeroSSL needs an email address: --email you@example.com"
    # Check everything first, so mistakes show up before anything is downloaded.
    local args=(--issue -d "$dom" --server "$server" --keylength ec-256)
    case "$method" in
        cloudflare)
            [ -n "${CF_Token:-}" ] || die "A Cloudflare API token is needed: CF_Token=... xray-site cert issue $dom --method cloudflare"
            export CF_Token
            args+=(--dns dns_cf)
            if [ "$wildcard" = 1 ]; then args+=(-d "*.$dom"); fi ;;
        http)
            valid_port "$port" || die "\"$port\" is not a valid port."
            [ "$wildcard" = 0 ] || die "Wildcard certificates (*.$dom) need the Cloudflare method."
            local owners
            owners="$(listeners "$port")"
            [ -z "$owners" ] || die "Port $port on this server is in use, so the check cannot run there:
$owners
Use another port (--http-port 8880) and forward the router's public port 80 to it."
            args+=(--standalone --httpport "$port") ;;
        *) die "Unknown method \"$method\" (cloudflare or http)." ;;
    esac
    acme_install "$email"
    if [ "$method" = http ]; then
        command -v socat >/dev/null || pkg_install socat
        command -v socat >/dev/null || die "socat is needed for the HTTP method; install it (apt install socat)."
        say "The certificate authority will connect to http://$dom (port 80). The domain must point to"
        say "$(public_ip) and the router must forward public port 80 to this server's port $port."
    fi
    if [ -n "$email" ]; then
        acme --register-account -m "$email" --server "$server" ${XS_ACME_INSECURE:+--insecure} >/dev/null 2>&1 || true
    fi
    say "Requesting a certificate for $dom from $ca ..."
    local rc=0
    acme "${args[@]}" ${XS_ACME_INSECURE:+--insecure} || rc=$?
    # 2 = "skipped, not due for renewal": the certificate already exists, which is fine.
    [ "$rc" = 0 ] || [ "$rc" = 2 ] || die "The certificate was not issued (acme.sh output above).
Check that $dom points to $(public_ip)$([ "$method" = http ] && echo " and that public port 80 reaches this server's port $port")."
    local dir="$CERT_DIR/$dom"
    mkdir -p "$dir"
    chmod 700 "$CERT_DIR" "$dir"
    acme --install-cert -d "$dom" --ecc --fullchain-file "$dir/fullchain.pem" --key-file "$dir/privkey.pem" \
        --reloadcmd "$BIN cert reload" >/dev/null || die "acme.sh could not copy the certificate into $dir."
    chmod 600 "$dir/privkey.pem"
    write_meta "$dir" "TYPE=acme" "DOMAIN=$dom" "CERT=$dir/fullchain.pem" "KEY=$dir/privkey.pem" \
        "METHOD=$method" "CA=$ca" "WILDCARD=$wildcard"
    say "Certificate for $dom is ready; acme.sh renews it automatically."
    show_cert_paths "$dom"
}

cmd_cert_add() {  # <name> <cert file> <key file> [--copy]
    local name="${1:-}" cf="${2:-}" kf="${3:-}" copy="${4:-}"
    [ -n "$kf" ] || die "Usage: xray-site cert add <name> <certificate file> <key file> [--copy]"
    valid_cert_name "$name" || die "The name may use letters, digits, . - and _ only."
    [ ! -e "$CERT_DIR/$name" ] || die "A certificate named \"$name\" already exists; remove it first or use another name."
    cf="$(readlink -f "$cf" 2>/dev/null || echo "$cf")"
    kf="$(readlink -f "$kf" 2>/dev/null || echo "$kf")"
    valid_file_path "$cf" && valid_file_path "$kf" || die "Give full file paths without spaces, e.g. /root/cert.pem"
    [ -r "$cf" ] || die "Cannot read $cf"
    [ -r "$kf" ] || die "Cannot read $kf"
    need_helper
    python3 "$HELPER" certinfo "$cf" >/dev/null || die "$cf is not a PEM certificate."
    local err
    err="$(python3 "$HELPER" certcheck "$cf" "$kf")" || die "The key does not belong to the certificate: $err"
    local dir="$CERT_DIR/$name"
    mkdir -p "$dir"
    chmod 700 "$CERT_DIR" "$dir"
    if [ "$copy" = "--copy" ]; then
        install -m 644 "$cf" "$dir/fullchain.pem"
        install -m 600 "$kf" "$dir/privkey.pem"
        write_meta "$dir" "TYPE=copied" "DOMAIN=" "CERT=$dir/fullchain.pem" "KEY=$dir/privkey.pem"
    else
        write_meta "$dir" "TYPE=manual" "DOMAIN=" "CERT=$cf" "KEY=$kf"
    fi
    local info
    info="$(python3 "$HELPER" certinfo "$dir/fullchain.pem" 2>/dev/null || python3 "$HELPER" certinfo "$cf")"
    say "Added certificate \"$name\": $(cut -f1 <<<"$info" | tr ',' ' '), valid until $(cut -f2 <<<"$info")"
    show_cert_paths "$name"
}

print_certs() {
    local n=0 name info doms date days col used
    printf '\n  %s%-3s %-24s %-8s %-30s %-18s %s%s\n' "$CB" "#" "name" "type" "domains" "expires" "site" "$C0"
    for name in $(cert_names); do
        n=$((n + 1))
        cert_meta "$name"
        info="$(python3 "$HELPER" certinfo "$CM_CERT" 2>/dev/null || true)"
        if [ -z "$info" ]; then
            printf '  %-3s %-24s %-8s %s(file missing: %s)%s\n' "$n" "${name:0:24}" "$CM_TYPE" "$CR" "$CM_CERT" "$C0"
            continue
        fi
        IFS=$'\t' read -r doms date days _ <<<"$info"
        if [ "$days" -lt 0 ]; then col="$CR"; elif [ "$days" -lt 15 ]; then col="$CY"; else col="$CG"; fi
        used=""; [[ ",$SITE_CERTS," == *",$name,"* ]] && used="${CG}✓ https${C0}"
        doms="${doms//,/ }"
        printf '  %-3s %-24s %-8s %-30s %s%-18s%s %s\n' "$n" "${name:0:24}" "$CM_TYPE" "${doms:0:30}" \
            "$col" "$date ($days d)" "$C0" "$used"
    done
    [ "$n" -gt 0 ] || printf '  %s(no certificates yet)%s\n' "$CD" "$C0"
    echo
}

pick_cert() {  # sets PICKED to a certificate name chosen by number
    local names=() n
    mapfile -t names < <(cert_names)
    [ "${#names[@]}" -gt 0 ] || { echo "    No certificates yet."; return 1; }
    ask n "Certificate number (#)" ""
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] || { echo "    No such certificate."; return 1; }
    PICKED="${names[$((n - 1))]}"
}

cmd_cert() {
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        list|ls) need_installed; need_helper; print_certs ;;
        issue|get) need_installed; need_helper; cmd_cert_issue "$@" ;;
        add) need_installed; cmd_cert_add "$@" ;;
        paths) need_installed; [ -n "${1:-}" ] && cert_meta "$1" || die "Usage: xray-site cert paths <name>"; show_cert_paths "$1" ;;
        renew)
            need_installed
            [ -n "${1:-}" ] && cert_meta "$1" || die "Usage: xray-site cert renew <name>"
            [ "$CM_TYPE" = acme ] || die "\"$1\" was added by hand; renew it where it came from, then run: xray-site cert reload"
            acme --renew -d "$CM_DOMAIN" --ecc --force ${XS_ACME_INSECURE:+--insecure} || die "Renewal failed (output above)."
            say "Renewed $1." ;;
        remove|rm)
            need_installed
            [ -n "${1:-}" ] && cert_meta "$1" || die "Usage: xray-site cert remove <name>"
            local rm_type="$CM_TYPE" rm_domain="$CM_DOMAIN"   # apply below reads other certificates
            if [[ ",$SITE_CERTS," == *",$1,"* ]]; then
                local keep="" c
                for c in ${SITE_CERTS//,/ }; do [ "$c" = "$1" ] || keep="$keep${keep:+,}$c"; done
                SITE_CERTS="$keep"
                apply
            fi
            [ "$rm_type" != acme ] || acme --remove -d "$rm_domain" --ecc >/dev/null 2>&1 || true
            rm -rf "${CERT_DIR:?}/$1"
            say "Removed certificate \"$1\"." ;;
        site)
            need_installed
            [ $# -gt 0 ] || die "Usage: xray-site cert site <name> [name ...] | off"
            if [ "$1" = off ]; then SITE_CERTS=""
            else
                local c list=""
                for c in "$@"; do cert_meta "$c" || die "No certificate named \"$c\" (see: xray-site cert list)."; list="$list${list:+,}$c"; done
                SITE_CERTS="$list"
            fi
            apply
            if [ -n "$SITE_CERTS" ]; then
                local m; split_map "${MAPS[0]}"
                say "The site now also answers HTTPS: https://$SITE_TLS_CHECK:$M_PUBLIC/"
            fi ;;
        force-https)
            need_installed
            case "${1:-}" in on) FORCE_HTTPS=1 ;; off) FORCE_HTTPS=0 ;; *) die "Usage: xray-site cert force-https on|off" ;; esac
            apply ;;
        xui-restart)
            need_installed
            case "${1:-}" in on) XUI_RESTART=1 ;; off) XUI_RESTART=0 ;; *) die "Usage: xray-site cert xui-restart on|off" ;; esac
            save_conf "$CONF"
            say "Restart x-ui after a renewal: ${1}." ;;
        reload)
            # Called by acme.sh after a renewal.
            load_conf
            if systemctl is-active --quiet nginx; then systemctl reload nginx || true; fi
            if [ "$XUI_RESTART" = 1 ]; then
                if command -v x-ui >/dev/null; then x-ui restart >/dev/null 2>&1 || systemctl restart x-ui || true
                else systemctl restart x-ui || true; fi
            fi ;;
        *) die "Unknown: xray-site cert $sub (list, issue, add, paths, renew, remove, site, force-https, xui-restart)" ;;
    esac
}

# ================================================================ template and site texts
print_templates() {
    local n=0 cur name title desc mark
    need_helper
    cur="$(python3 "$HELPER" site-get | python3 -c 'import json,sys; print(json.load(sys.stdin)["template"])')"
    echo
    while IFS=$'\t' read -r name title desc; do
        n=$((n + 1))
        if [ "$name" = "$cur" ]; then mark="${CG}★${C0}"; else mark=" "; fi
        printf '  %s %s%3s%s  %-11s %s%-24s%s %s%s%s\n' "$mark" "$CB$CC" "$n" "$C0" "$name" "$CB" "$title" "$C0" "$CD" "$desc" "$C0"
    done < <(python3 "$HELPER" templates)
    echo
}

cmd_template() {
    need_installed
    need_helper
    if [ -z "${1:-}" ] || [ "$1" = list ]; then print_templates; return; fi
    python3 "$HELPER" site-set "template=$1" >/dev/null || exit 1
    apply
    say "The site now uses the \"$1\" template."
}

cmd_site() {
    need_installed
    need_helper
    case "${1:-show}" in
        show)
            python3 "$HELPER" site-get ;;
        --reset)
            python3 "$HELPER" site-reset >/dev/null
            say "Site texts reset to the template's own." ;;
        *)
            python3 "$HELPER" site-set "$@" >/dev/null || exit 1
            say "Site texts saved." ;;
    esac
}

# ================================================================ small commands
cmd_restart() {
    need_installed
    case "${1:-all}" in
        xray-site|splitter) systemctl restart xray-site ;;
        nginx) systemctl restart nginx ;;
        x-ui) if command -v x-ui >/dev/null; then x-ui restart || systemctl restart x-ui; else systemctl restart x-ui; fi ;;
        all) systemctl restart nginx; systemctl restart xray-site ;;
        *) die "Usage: xray-site restart [all|xray-site|nginx|x-ui]" ;;
    esac
    say "Restarted ${1:-all}."
}

cmd_logs() {
    local unit="${1:-xray-site}" n="${2:-60}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=60
    case "$unit" in
        xray-site|splitter) journalctl -u xray-site -n "$n" --no-pager 2>/dev/null || true ;;
        nginx) journalctl -u nginx -n "$n" --no-pager 2>/dev/null || true
               [ -f /var/log/nginx/error.log ] && { echo "--- /var/log/nginx/error.log"; tail -n "$n" /var/log/nginx/error.log; } ;;
        access) [ -f /var/log/nginx/access.log ] && tail -n "$n" /var/log/nginx/access.log ;;
        x-ui) journalctl -u x-ui -n "$n" --no-pager 2>/dev/null || true ;;
        acme) [ -f "$ACME_HOME/acme.sh.log" ] && tail -n "$n" "$ACME_HOME/acme.sh.log" ;;
        *) die "Usage: xray-site logs [xray-site|nginx|access|x-ui|acme] [lines]" ;;
    esac
    return 0
}

cmd_public_ip() {
    need_installed
    case "${1:-}" in
        auto|"") CONF_PUBLIC_IP="" ;;
        *) [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "\"$1\" is not an IPv4 address."; CONF_PUBLIC_IP="$1" ;;
    esac
    save_conf "$CONF"
    DETECTED_IP=""
    say "Public IP: $(public_ip)"
}

cmd_update() {
    local tmp
    tmp="$(mktemp -d)"
    say "Downloading the latest xray-site"
    curl -fsSL --retry 3 -o "$tmp/install.sh" "$UPDATE_URL" || { rm -rf "$tmp"; die "Download failed: $UPDATE_URL"; }
    head -1 "$tmp/install.sh" | grep -q bash && grep -q "^$PAYLOAD_MARK\$" "$tmp/install.sh" ||
        { rm -rf "$tmp"; die "The downloaded file is not xray-site."; }
    bash "$tmp/install.sh" install </dev/null
    rm -rf "$tmp"
}

# ================================================================ commands
need_installed() {
    [ -f "$CONF" ] || die "xray-site is not installed yet. Run: sudo bash install.sh"
    load_conf
}

cmd_list() { need_installed; print_list; }

cmd_add() {
    need_installed
    [ $# -ge 2 ] || die "Usage: xray-site add <x-ui port> <public port> [server port]"
    valid_port "$1" && valid_port "$2" || die "Usage: xray-site add <x-ui port> <public port> [server port]"
    find_map "$2" >/dev/null && die "Public port $2 is already in the list; use: xray-site change $2 ..."
    local l="${3:-$2}" why
    why="$(server_port_problem "$l" "$1" -1)"
    [ -z "$why" ] || die "Port $l on this server $why. Give the server port to forward public port $2 to:
  xray-site add $1 $2 $(suggest_server_port "$2" "$1" -1)   (and forward the router's $2 to it)"
    MAPS+=("$l:$1:$2")
    apply; print_summary
}

cmd_change() {
    need_installed
    [ $# -ge 2 ] || die "Usage: xray-site change <public port> <new public port> [x-ui port] [server port]"
    local i l
    i="$(find_map "$1")" || die "Port $1 is not in the list (see: xray-site list)."
    split_map "${MAPS[$i]}"
    # The server port follows the public port, unless it was different already or is given.
    if [ -n "${4:-}" ]; then l="$4"
    elif [ "$2" = "$M_PUBLIC" ] || [ "$M_LISTEN" != "$M_PUBLIC" ]; then l="$M_LISTEN"
    else l="$2"; fi
    MAPS[$i]="$l:${3:-$M_XUI}:$2"
    apply; print_summary
}

cmd_remove() {
    need_installed
    [ $# -ge 1 ] || die "Usage: xray-site remove <public port>"
    local i
    i="$(find_map "$1")" || die "Port $1 is not in the list (see: xray-site list)."
    [ "${#MAPS[@]}" -gt 1 ] || die "This is the last port. To remove everything use: xray-site uninstall"
    unset 'MAPS[i]'; MAPS=("${MAPS[@]}")
    apply; print_summary
}

cmd_site_port() {
    need_installed
    [ $# -ge 1 ] && valid_port "$1" || die "Usage: xray-site site-port <port>"
    SITE_PORT="$1"
    apply
}

cmd_apply() { need_installed; apply; print_summary; }

cmd_status() {
    need_installed
    need_helper
    status_box
    ports_box
    local m
    echo "  Listening:"
    for m in "${MAPS[@]}"; do split_map "$m"; listeners "$M_LISTEN" | sed 's/^/    /'; done
    echo
}

cmd_uninstall() {
    [ -f "$CONF" ] || [ -f "$UNIT" ] || die "xray-site is not installed."
    if [ "${1:-}" != "--yes" ] && is_tty; then
        yes_no "Remove the website splitter? x-ui is not touched" n || { echo "  Nothing removed."; return; }
    fi
    load_conf
    MAPS=(); fw_sync 2>/dev/null || true
    systemctl stop xray-site >/dev/null 2>&1 || true
    systemctl disable --quiet xray-site >/dev/null 2>&1 || true
    rm -f "$UNIT" "$NGINX_CONF"
    systemctl daemon-reload || true
    systemctl reload nginx 2>/dev/null || true
    rm -rf "$SHARE" /var/lib/xray-site
    rm -f "$BIN"
    if [ -n "$(cert_names)" ]; then
        find "$CONF_DIR" -mindepth 1 -maxdepth 1 ! -name certs -exec rm -rf {} +
        say "Removed. Certificates are kept in $CERT_DIR; your own site files in $SITE_DIR."
    else
        rm -rf "$CONF_DIR"
        say "Removed. Your own site files (if any) are still in $SITE_DIR."
    fi
}

cmd_menu() {
    need_installed
    is_tty || die "The menu needs a terminal. See: xray-site help"
    need_helper
    local c
    while :; do
        unset XUI_LIST_CACHE   # pick up changes made in x-ui meanwhile
        load_conf
        clear_screen
        banner
        status_box
        ports_box
        main_menu_items
        ask c "${CB}Choose${C0}" ""
        echo
        case "$c" in
            1)  menu_add_port ;;
            2)  menu_change_port ;;
            3)  menu_remove_port ;;
            4)  try_apply; if [ "$APPLIED" = 1 ]; then print_summary; fi ;;
            5)  menu_template ;;
            6)  menu_site_texts ;;
            7)  menu_site_port ;;
            8)  menu_cert_issue ;;
            9)  menu_cert_add ;;
            10) menu_certs ;;
            11) menu_site_https ;;
            12) cmd_status ;;
            13) menu_logs ;;
            14) menu_restart ;;
            15) menu_public_ip ;;
            16) cmd_update; return 0 ;;
            17) cmd_uninstall; return 0 ;;
            0|q|exit|"") echo "  Bye."; return 0 ;;
            *)  echo "    Choose a number from the menu." ;;
        esac
        pause
    done
}

# ---------------------------------------------------------------- menu: drawing
clear_screen() { [ -n "$C0" ] && is_tty && printf '\033[H\033[2J'; return 0; }

pause() {
    echo
    read -r -p "  ${CD}Press Enter to go back to the menu${C0} " _ || true
}

c256() { [ -n "$C0" ] && printf '\033[38;5;%sm' "$1"; return 0; }

banner() {
    local colors=(51 45 39 33 63 99) i
    local art=(
        '██╗  ██╗██████╗  █████╗ ██╗   ██╗    ███████╗██╗████████╗███████╗'
        '╚██╗██╔╝██╔══██╗██╔══██╗╚██╗ ██╔╝    ██╔════╝██║╚══██╔══╝██╔════╝'
        ' ╚███╔╝ ██████╔╝███████║ ╚████╔╝     ███████╗██║   ██║   █████╗  '
        ' ██╔██╗ ██╔══██╗██╔══██║  ╚██╔╝      ╚════██║██║   ██║   ██╔══╝  '
        '██╔╝ ██╗██║  ██║██║  ██║   ██║       ███████║██║   ██║   ███████╗'
        '╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝       ╚══════╝╚═╝   ╚═╝   ╚══════╝'
    )
    echo
    for i in "${!art[@]}"; do printf '  %s%s%s\n' "$(c256 "${colors[$i]}")" "${art[$i]}" "$C0"; done
    printf '  %swebsite + x-ui on shared ports%s   %sv%s%s\n' "$CD" "$C0" "$(c256 99)" "$VERSION" "$C0"
}

dot() {  # $1 unit, $2 label
    if systemctl is-active --quiet "$1" 2>/dev/null; then printf '%s●%s %s' "$CG" "$C0" "$2"
    else printf '%s●%s %s%s%s' "$CR" "$C0" "$CD" "$2" "$C0"; fi
}

box_top() { printf '\n  %s╭─ %s%s%s %s%s\n' "$(c256 39)" "$CB$CW" "$1" "$C0$(c256 39)" "$(printf '─%.0s' $(seq 1 $(( 62 - ${#1} ))))" "$C0"; }
box_line() { printf '  %s│%s %s\n' "$(c256 39)" "$C0" "$*"; }
box_end() { printf '  %s╰%s%s\n' "$(c256 39)" "$(printf '─%.0s' $(seq 1 66))" "$C0"; }

status_box() {
    local tpl title https certs n=0 soon="" name info days
    tpl="$(python3 "$HELPER" site-get | python3 -c 'import json,sys; print(json.load(sys.stdin)["template"])' 2>/dev/null || echo '?')"
    title="$(python3 "$HELPER" templates 2>/dev/null | awk -F'\t' -v t="$tpl" '$1==t {print $2}')"
    if [ -n "$SITE_CERTS" ]; then https="${CG}on${C0} (${SITE_CERTS//,/, })"; else https="${CD}off${C0}"; fi
    for name in $(cert_names); do
        n=$((n + 1)); cert_meta "$name"
        info="$(python3 "$HELPER" certinfo "$CM_CERT" 2>/dev/null || true)"
        days="$(cut -f3 <<<"$info")"
        [[ "$days" =~ ^-?[0-9]+$ ]] && { [ -z "$soon" ] || [ "$days" -lt "$soon" ]; } && soon="$days"
    done
    if [ "$n" = 0 ]; then certs="${CD}none${C0}"
    else
        local col="$CG"; [ "${soon:-99}" -lt 15 ] && col="$CY"; [ "${soon:-99}" -lt 0 ] && col="$CR"
        certs="$n, next expiry in $col${soon} days${C0}"
    fi
    box_top "Status"
    box_line "$(dot xray-site splitter)    $(dot nginx website)    $(dot x-ui x-ui)"
    box_line "${CD}Public IP${C0}  $(printf '%-18s' "$(public_ip)") ${CD}LAN${C0}  $(lan_ip)"
    box_line "${CD}Site     ${C0}  ${CB}${title:-$tpl}${C0} ($tpl)   ${CD}HTTPS${C0} $https"
    box_line "${CD}SSL      ${C0}  $certs"
    box_end
}

ports_box() {
    local i=0 m lan conns col
    lan="$(lan_ip)"
    box_top "Ports"
    box_line "$(printf '%s%-3s %-8s %-34s %-22s %s%s' "$CD" "#" "public" "x-ui inbound" "router forwards to" "users" "$C0")"
    for m in "${MAPS[@]}"; do
        i=$((i + 1)); split_map "$m"
        conns="$(ss -tnH state established "( sport = :$M_LISTEN )" 2>/dev/null | wc -l)"
        if [ -n "$(listeners "$M_LISTEN")" ]; then col="$CG"; else col="$CR"; fi
        box_line "$(printf '%-3s %s%-8s%s %-34s %-22s %s' "$i" "$col$CB" "$M_PUBLIC" "$C0" \
            "$M_XUI $(inbound_info "$M_LISTEN" "$M_XUI")" "$lan:$M_LISTEN" "$conns")"
    done
    box_end
}

menu_two_cols() {  # pairs of "num|text" for the left and right columns, separated by "--"
    local left=() right=() side=left x i l r
    for x in "$@"; do
        if [ "$x" = "--" ]; then side=right; continue; fi
        if [ "$side" = left ]; then left+=("$x"); else right+=("$x"); fi
    done
    local rows=${#left[@]}; [ ${#right[@]} -gt "$rows" ] && rows=${#right[@]}
    for (( i = 0; i < rows; i++ )); do
        l="${left[$i]:-}" r="${right[$i]:-}"
        printf '  '
        menu_cell "$l"
        printf '    '
        menu_cell "$r"
        echo
    done
}

menu_cell() {  # "num|text", "#title" for a heading, or empty
    local x="$1"
    if [ -z "$x" ]; then printf '%-34s' ""
    elif [ "${x:0:1}" = "#" ]; then
        local t="${x:1}"
        printf '%s── %s %s%s' "$(c256 99)" "$CB$t" "$C0$(c256 99)$(printf '─%.0s' $(seq 1 $(( 29 - ${#t} ))))" "$C0"
    else
        printf '%s%3s%s  %-29s' "$CB$CC" "${x%%|*}" "$C0" "${x#*|}"
    fi
}

main_menu_items() {
    echo
    menu_two_cols \
        "#Ports" "1|Add a port" "2|Change a port" "3|Remove a port" "4|Re-read x-ui and apply" "" \
        "#SSL certificates" "8|Get a free certificate" "9|Add my own certificate" "10|Manage certificates" "11|HTTPS for the site" \
        -- \
        "#Website" "5|Choose the site template" "6|Edit the site texts" "7|Website internal port" "" "" \
        "#System" "12|Status and connections" "13|Logs" "14|Restart services" "15|Public IP" "16|Update xray-site" "17|Uninstall"
    printf '\n  %s%3s%s  %s\n\n' "$CB$CC" 0 "$C0" "Exit"
}

# ---------------------------------------------------------------- menu: ports
menu_add_port() {
    show_xui_inbounds
    ask_mapping "$(first_free_inbound)" "" -1
    MAPS+=("$NEW_MAP")
    try_apply
    if [ "$APPLIED" = 1 ]; then print_summary; else warn "Not added; nothing was changed."; fi
}

menu_change_port() {
    print_list
    pick_row || return 0
    split_map "${MAPS[$ROW]}"
    show_xui_inbounds
    ask_mapping "$M_XUI" "$M_PUBLIC" "$ROW"
    MAPS[$ROW]="$NEW_MAP"
    try_apply
    if [ "$APPLIED" = 1 ]; then print_summary; else warn "Not changed; the previous setup is still running."; fi
}

menu_remove_port() {
    [ "${#MAPS[@]}" -gt 1 ] || { echo "    This is the last port; use \"Uninstall\" to remove everything."; return 0; }
    print_list
    pick_row || return 0
    split_map "${MAPS[$ROW]}"
    yes_no "Remove public port $M_PUBLIC (x-ui $M_XUI)" n || return 0
    unset 'MAPS[ROW]'; MAPS=("${MAPS[@]}")
    try_apply
    [ "$APPLIED" = 1 ] || warn "Not removed; nothing was changed."
}

# ---------------------------------------------------------------- menu: website
menu_template() {
    local names=() n
    mapfile -t names < <(python3 "$HELPER" templates | cut -f1)
    box_top "Site templates"
    print_templates
    ask n "Template number (Enter = back)" ""
    [ -n "$n" ] || return 0
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] || { echo "    No such template."; return 0; }
    python3 "$HELPER" site-set "template=${names[$((n - 1))]}" >/dev/null || return 0
    try_apply
    if [ "$APPLIED" = 1 ]; then
        say "The site now uses the \"${names[$((n - 1))]}\" template."
        [ "${names[$((n - 1))]}" != custom ] || echo "    Put your own files in $SITE_DIR (index.html is the home page)."
        site_urls
    fi
}

site_urls() {
    local m ip
    ip="$(public_ip)"
    echo
    for m in "${MAPS[@]}"; do
        split_map "$m"
        printf '    %shttp://%s:%s/%s\n' "$CC" "$ip" "$M_PUBLIC" "$C0"
        [ -z "$SITE_TLS_CHECK" ] || printf '    %shttps://%s:%s/%s\n' "$CC" "$SITE_TLS_CHECK" "$M_PUBLIC" "$C0"
    done
}

menu_site_texts() {
    local tpl k cur def v line
    tpl="$(python3 "$HELPER" site-get | python3 -c 'import json,sys; print(json.load(sys.stdin)["template"])')"
    if [ "$tpl" = custom ] || [ "$tpl" = nginx ]; then
        echo "    The \"$tpl\" template has no texts to edit."
        [ "$tpl" != custom ] || echo "    Edit the files in $SITE_DIR instead."
        return 0
    fi
    box_top "Site texts ($tpl)"
    echo "  Enter keeps a text; type - to go back to the template's own text."
    echo
    local args=()
    while IFS=$'\t' read -r k cur def; do
        ask_text v "$(printf '%-8s' "$k")" "$cur" </dev/tty
        if [ "$v" = "-" ]; then args+=("$k=")
        elif [ "$v" != "$cur" ]; then args+=("$k=$v"); fi
    done < <(python3 "$HELPER" site-texts)
    [ "${#args[@]}" -gt 0 ] || { echo "    Nothing changed."; return 0; }
    if python3 "$HELPER" site-set "${args[@]}" >/dev/null; then say "Saved; the site shows the new texts now."; fi
}

menu_site_port() {
    local sp
    ask_port sp "Website internal port (on 127.0.0.1)" "$SITE_PORT"
    SITE_PORT="$sp"
    try_apply
    [ "$APPLIED" = 1 ] || warn "Not changed."
}

# ---------------------------------------------------------------- menu: certificates
menu_cert_issue() {
    local dom method port=80 email ca token wild=0 c
    box_top "Get a free certificate"
    echo "  The domain must already point (DNS A record) to your public IP $(public_ip)."
    echo
    while :; do
        ask dom "Domain (e.g. vpn.example.com)" ""
        [ -n "$dom" ] || return 0
        dom="${dom,,}"
        valid_domain "$dom" && break
        echo "    \"$dom\" is not a valid domain name."
    done
    echo
    echo "  How should the domain be verified?"
    printf '  %s  1%s  Cloudflare DNS  %s(recommended: no port has to be open; domain on Cloudflare)%s\n' "$CB$CC" "$C0" "$CD" "$C0"
    printf '  %s  2%s  HTTP            %s(router must forward public port 80 to this server)%s\n' "$CB$CC" "$C0" "$CD" "$C0"
    ask c "Method" 1
    if [ "$c" = 2 ]; then
        method=http
        ask_port port "Port on this server for the check (router forwards public 80 here)" 80
    else
        method=cloudflare
        echo "  Create a token at dash.cloudflare.com > My Profile > API Tokens > \"Edit zone DNS\"."
        read -r -s -p "  Cloudflare API token (hidden): " token || true
        echo
        token="${token//[[:space:]]/}"
        [ -n "$token" ] || { echo "    No token given."; return 0; }
        yes_no "Also cover *.$dom (wildcard)" n && wild=1
    fi
    ask email "Email for expiry notices (optional)" ""
    echo
    printf '  %s  1%s  Let'"'"'s Encrypt   %s  2%s  ZeroSSL (needs the email)\n' "$CB$CC" "$C0" "$CB$CC" "$C0"
    ask c "Certificate authority" 1
    ca=letsencrypt; [ "$c" = 2 ] && ca=zerossl
    local args=("$dom" --method "$method" --ca "$ca")
    [ -n "$email" ] && args+=(--email "$email")
    [ "$method" = http ] && args+=(--http-port "$port")
    [ "$wild" = 1 ] && args+=(--wildcard)
    CF_Token="$token" try_run cmd_cert_issue "${args[@]}"
    [ "$RAN" = 1 ] || return 0
    if yes_no "Use this certificate for the site's HTTPS now" y; then
        menu_apply_site_certs "$dom"
    fi
}

read_pem() {  # $1 variable, $2 end marker regex; reads pasted lines from the terminal
    local line text="" seen=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        text+="$line"$'\n'
        [[ "$line" == -----BEGIN* ]] && seen=1
        if [ -n "$seen" ] && [[ "$line" =~ $2 ]]; then
            # A chain has several certificates: keep reading while more arrive right away.
            if ! read -r -t 0.3 line; then break; fi
            line="${line%$'\r'}"
            [ -z "$line" ] && break
            text+="$line"$'\n'
        fi
    done
    printf -v "$1" '%s' "$text"
}

menu_cert_add() {
    local name c cf kf copy=""
    box_top "Add my own certificate"
    printf '  %s  1%s  Paste the certificate and key\n' "$CB$CC" "$C0"
    printf '  %s  2%s  Use files that are already on this server\n' "$CB$CC" "$C0"
    ask c "Choose" 1
    while :; do
        ask name "A short name for it (e.g. my-domain)" ""
        [ -n "$name" ] || return 0
        valid_cert_name "$name" && [ ! -e "$CERT_DIR/$name" ] && break
        echo "    Use letters, digits, . - _ and a name not used yet."
    done
    if [ "$c" = 2 ]; then
        ask cf "Certificate file (fullchain), full path" ""
        ask kf "Private key file, full path" ""
        yes_no "Keep a copy inside xray-site (safe if the originals move)" y && copy="--copy"
        try_run cmd_cert_add "$name" "$cf" "$kf" $copy
        [ "$RAN" = 1 ] || return 0
    else
        local cert key tmpd
        echo "  Paste the certificate (-----BEGIN CERTIFICATE----- ...), then press Enter on an empty line:"
        read_pem cert '^-----END CERTIFICATE-----'
        echo "  Paste the private key (-----BEGIN ... PRIVATE KEY----- ...):"
        read_pem key '^-----END .*PRIVATE KEY-----'
        tmpd="$(mktemp -d)"; chmod 700 "$tmpd"
        printf '%s' "$cert" > "$tmpd/cert.pem"; printf '%s' "$key" > "$tmpd/key.pem"; chmod 600 "$tmpd"/*.pem
        try_run cmd_cert_add "$name" "$tmpd/cert.pem" "$tmpd/key.pem" --copy
        rm -rf "$tmpd"
        [ "$RAN" = 1 ] || return 0
    fi
    if yes_no "Use this certificate for the site's HTTPS now" n; then
        menu_apply_site_certs "$name"
    fi
}

menu_apply_site_certs() {  # $1 name to add to the site's certificates
    local list="$SITE_CERTS"
    [[ ",$list," == *",$1,"* ]] || list="$list${list:+,}$1"
    SITE_CERTS="$list"
    try_apply
    if [ "$APPLIED" = 1 ]; then say "HTTPS is on for the site:"; refresh_tls_check; site_urls; else warn "HTTPS was not turned on."; fi
}

# After try_apply (which ran in a subshell), learn the site's HTTPS name for the links.
refresh_tls_check() {
    SITE_TLS_CHECK="$( { prepare_site; } >/dev/null 2>&1; printf '%s' "$SITE_TLS_CHECK" )" || SITE_TLS_CHECK=""
}

menu_certs() {
    local c
    while :; do
        load_conf
        box_top "Certificates"
        print_certs
        printf '  %s  1%s  Renew            %s  2%s  Remove           %s  3%s  Show file paths (for x-ui)\n' \
            "$CB$CC" "$C0" "$CB$CC" "$C0" "$CB$CC" "$C0"
        printf '  %s  4%s  Redirect http to https on the site: %s\n' "$CB$CC" "$C0" "$(onoff "$FORCE_HTTPS")"
        printf '  %s  5%s  Restart x-ui after a renewal:       %s\n' "$CB$CC" "$C0" "$(onoff "$XUI_RESTART")"
        printf '  %s  0%s  Back\n\n' "$CB$CC" "$C0"
        ask c "Choose" ""
        case "$c" in
            1) if pick_cert; then try_run cmd_cert renew "$PICKED"; fi ;;
            2) if pick_cert && yes_no "Remove certificate \"$PICKED\"" n; then try_run cmd_cert remove "$PICKED"; fi ;;
            3) if pick_cert; then show_cert_paths "$PICKED"; fi ;;
            4) if [ "$FORCE_HTTPS" = 1 ]; then FORCE_HTTPS=0; else FORCE_HTTPS=1; fi
               [ -n "$SITE_CERTS" ] || { echo "    Turn on HTTPS for the site first (menu 11)."; FORCE_HTTPS=0; }
               try_apply ;;
            5) if [ "$XUI_RESTART" = 1 ]; then XUI_RESTART=0; else XUI_RESTART=1; fi; save_conf "$CONF" ;;
            0|"") return 0 ;;
            *) echo "    Choose a number from the list." ;;
        esac
        echo
    done
}

onoff() { if [ "$1" = 1 ]; then printf '%son%s' "$CG$CB" "$C0"; else printf '%soff%s' "$CD" "$C0"; fi; }

menu_site_https() {
    local names=() n pick list=""
    mapfile -t names < <(cert_names)
    box_top "HTTPS for the site"
    if [ "${#names[@]}" = 0 ]; then echo "  No certificates yet: get one (8) or add yours (9) first."; return 0; fi
    print_certs
    echo "  Numbers of the certificates to use, separated by commas (e.g. 1 or 1,2); 0 turns HTTPS off."
    ask_text pick "Certificates" ""
    [ -n "$pick" ] || return 0
    if [ "$pick" = 0 ]; then SITE_CERTS=""
    else
        for n in ${pick//,/ }; do
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] || { echo "    No certificate number $n."; return 0; }
            list="$list${list:+,}${names[$((n - 1))]}"
        done
        SITE_CERTS="$list"
    fi
    try_apply
    if [ "$APPLIED" = 1 ]; then
        if [ -n "$SITE_CERTS" ]; then say "HTTPS is on for the site:"; refresh_tls_check; site_urls
        else say "HTTPS for the site is off."; fi
    fi
}

# ---------------------------------------------------------------- menu: system
menu_logs() {
    local c
    printf '  %s  1%s  Splitter (HAProxy)   %s  2%s  nginx errors   %s  3%s  Website visits\n' "$CB$CC" "$C0" "$CB$CC" "$C0" "$CB$CC" "$C0"
    printf '  %s  4%s  x-ui                 %s  5%s  Certificates (acme.sh)\n' "$CB$CC" "$C0" "$CB$CC" "$C0"
    ask c "Choose" 1
    echo
    case "$c" in 1) cmd_logs xray-site ;; 2) cmd_logs nginx ;; 3) cmd_logs access ;; 4) cmd_logs x-ui ;; 5) cmd_logs acme ;; esac
    return 0
}

menu_restart() {
    local c
    printf '  %s  1%s  Splitter + website   %s  2%s  x-ui   %s  3%s  Everything\n' "$CB$CC" "$C0" "$CB$CC" "$C0" "$CB$CC" "$C0"
    ask c "Choose" 1
    case "$c" in
        1) try_run cmd_restart all ;;
        2) try_run cmd_restart x-ui ;;
        3) try_run cmd_restart all; try_run cmd_restart x-ui ;;
    esac
}

menu_public_ip() {
    local ip
    echo "  Shown in summaries and links. Empty = detect automatically (now: $(public_ip))."
    ask ip "Public IP" "$CONF_PUBLIC_IP"
    try_run cmd_public_ip "${ip:-auto}"
}

cmd_install() {
    say "Installing nginx, haproxy, curl, python3"
    if command -v apt-get >/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx haproxy curl python3 iproute2 ca-certificates >/dev/null
    elif command -v dnf >/dev/null; then
        dnf install -y -q nginx haproxy curl python3 iproute
    elif command -v yum >/dev/null; then
        yum install -y -q nginx haproxy curl python3 iproute
    else
        die "No apt-get, dnf or yum found. Install nginx, haproxy, curl and python3, then run again."
    fi

    # Install this script as the "xray-site" command.
    local self
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    [ -f "$self" ] || die "Download the script to a file first, then run: sudo bash install.sh"
    [ "$self" = "$BIN" ] || install -m 755 "$self" "$BIN"
    install_files

    # The very first version of this script ran its own Xray; x-ui replaces it.
    rm -f "$CONF_DIR/config.json" "$CONF_DIR/client.txt"

    load_conf
    if [ -n "${PORTS:-}" ]; then
        # Each item: <x-ui port>:<public port>[:<server port>]
        local item px pp pl
        MAPS=()
        for item in ${PORTS//,/ }; do
            IFS=: read -r px pp pl _ <<<"$item"
            MAPS+=("${pl:-$pp}:$px:$pp")
        done
    elif [ "${#MAPS[@]}" -gt 0 ]; then
        say "Keeping the ports from $CONF"
    elif [ -f "$HAPROXY_CONF" ] && grep -qE '^\s*bind :[0-9]+' "$HAPROXY_CONF"; then
        # The previous version: one port, no xray-site.conf yet.
        local l x
        l="$(grep -oE '^\s*bind :[0-9]+' "$HAPROXY_CONF" | grep -oE '[0-9]+$' | head -1)"
        x="$(grep -oE '^\s*server xui [^ ]+' "$HAPROXY_CONF" | grep -oE '[0-9]+$' | head -1)"
        MAPS=("$l:${x:-8080}:${PUBLIC_PORT:-8080}")
        say "Keeping the previous setup: port $l -> x-ui ${x:-8080}"
    elif [ -n "${SERVER_PORT:-}${XUI_PORT:-}" ] || ! is_tty; then
        MAPS=("${SERVER_PORT:-1234}:${XUI_PORT:-8080}:${PUBLIC_PORT:-8080}")
    else
        echo
        show_xui_inbounds
        echo "  For each x-ui inbound to share with the website, give its port and the public"
        echo "  port people connect to on the router."
        MAPS=()
        while :; do
            ask_mapping "$(first_free_inbound)" "" -1
            MAPS+=("$NEW_MAP")
            split_map "$NEW_MAP"
            echo "    Added: public port $M_PUBLIC -> x-ui $M_XUI $(inbound_info "$M_LISTEN" "$M_XUI")"
            yes_no "Add another inbound" || break
        done
        echo
    fi

    CONF_PUBLIC_IP="${PUBLIC_IP:-$CONF_PUBLIC_IP}"
    if [ -n "${SITE_PORT_ENV:-}" ]; then
        SITE_PORT="$SITE_PORT_ENV"
    elif [ -z "$SITE_PORT" ]; then
        # Keep the port from an older install, otherwise the first free one from 8081.
        SITE_PORT="$(grep -oE 'listen 127\.0\.0\.1:[0-9]+' "$NGINX_CONF" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
        if [ -z "$SITE_PORT" ]; then
            local p m used=" "
            for m in "${MAPS[@]}"; do split_map "$m"; used="$used$M_LISTEN $M_XUI "; done
            for p in $(seq 8081 8199); do
                [[ "$used" == *" $p "* ]] && continue
                [ -z "$(listeners "$p")" ] && { SITE_PORT=$p; break; }
            done
        fi
        [ -n "$SITE_PORT" ] || die "No free port found for the website between 8081 and 8199."
    fi

# The site template (what browsers see).
    local cur
    cur="$(python3 "$HELPER" site-get | python3 -c 'import json,sys; print(json.load(sys.stdin)["template"])')"
    if [ -n "${TEMPLATE:-}" ]; then
        python3 "$HELPER" site-set "template=$TEMPLATE" >/dev/null || die "Unknown template \"$TEMPLATE\"."
    elif [ ! -f "$CONF_DIR/site.json" ] && is_tty; then
        local names=() n def=1 i
        mapfile -t names < <(python3 "$HELPER" templates | cut -f1)
        for i in "${!names[@]}"; do if [ "${names[$i]}" = "$cur" ]; then def=$((i + 1)); fi; done
        echo "  Which site should browsers see? (change it any time with: sudo xray-site)"
        print_templates
        while :; do
            ask n "Template number" "$def"
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] && break
            echo "    Enter a number from the list."
        done
        python3 "$HELPER" site-set "template=${names[$((n - 1))]}" >/dev/null
        echo
    elif [ ! -f "$CONF_DIR/site.json" ]; then
        python3 "$HELPER" site-set "template=$cur" >/dev/null
    fi

    apply
    print_list
    print_summary
}

usage() { sed -n '2,/^set -euo/{/^set -euo/d;p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ================================================================ main
case "${1:-}" in help|-h|--help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $*"
SITE_PORT_ENV="${SITE_PORT:-}"

# One change at a time (menu, commands, updates). The renewal hook only reloads, so it skips this.
take_lock() {
    [ -z "${XS_LOCKED:-}" ] || return 0
    command -v flock >/dev/null || return 0
    exec 9>/run/xray-site.lock
    if ! flock -n 9; then
        say "Waiting for another xray-site change to finish ..."
        flock -w 300 9 || die "Another xray-site change is still running."
    fi
    export XS_LOCKED=1
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd ${1:-}" in
    "list "*|"ls "*|"status "*|"logs "*|"log "*|"cert reload"|"cert list"|"cert ls"|"cert paths"|"cert ") ;;
    *) take_lock ;;
esac
case "$cmd" in
    "")         if [ "$(basename "$0")" = xray-site ]; then cmd_menu; else cmd_install; fi ;;
    install)    cmd_install ;;
    menu)       cmd_menu ;;
    list|ls)    cmd_list ;;
    add)        cmd_add "$@" ;;
    change|edit) cmd_change "$@" ;;
    remove|rm|del) cmd_remove "$@" ;;
    site-port)  cmd_site_port "$@" ;;
    apply)      cmd_apply ;;
    status)     cmd_status ;;
    template|templates) cmd_template "$@" ;;
    site)       cmd_site "$@" ;;
    cert|certs|ssl) cmd_cert "$@" ;;
    restart)    cmd_restart "$@" ;;
    logs|log)   cmd_logs "$@" ;;
    public-ip)  cmd_public_ip "$@" ;;
    update)     cmd_update ;;
    uninstall)  cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *)          usage; exit 1 ;;
esac
exit
# Everything below is the embedded payload (helper.py and the site templates); see build.sh.
__XRAY_SITE_PAYLOAD__
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
