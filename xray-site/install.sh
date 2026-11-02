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
#   xray-site cert renew|remove <name> | site <name...>|off | xui-restart on|off
#   xray-site http on|off | https on|off | redirect on|off     how browsers reach the site
#   xray-site status | logs [xray-site|nginx|access|x-ui|acme] | restart [all|nginx|x-ui]
#   xray-site public-ip <ip|auto> | update | uninstall
#   xray-site 3x-ui install|access|info|restart                the 3x-ui (MHSanaei) panel
#   xray-site marzban install|access|info|links|update|restart|logs|uninstall   Marzban (eris4444/Marzban)
#   xray-site node add | install [--cert-b64 ...] | list | remove [id]          Marzban nodes
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
VERSION=3.0
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/eris4444/englishs/claude/admiring-planck-kx3x1l/xray-site/install.sh}"
PAYLOAD_MARK=__XRAY_SITE_PAYLOAD__
ACME_WEBROOT=/var/lib/xray-site/acme-webroot
ACME_NGINX_CONF=/etc/nginx/conf.d/xray-site-acme.conf
ACME_WEBROOT_LIST=$CONF_DIR/acme-webroot

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
HTTP_SITE=1 SITE_HTTPS=1 TLS_CERTS=""
SITE_SNI_EXACT="" SITE_SNI_SUFFIX="" SITE_HOST_REGEX=""

# ================================================================ config file
# SITE_PORT, CONF_PUBLIC_IP and MAPS. In the file an entry is "share=<public>:<x-ui>[:<server>]";
# in MAPS it is kept as "<server>:<x-ui>:<public>".
load_conf() {
    SITE_PORT="" CONF_PUBLIC_IP="" MAPS=() SITE_TLS_PORT="" SITE_CERTS="" FORCE_HTTPS=0 XUI_RESTART=0
    HTTP_SITE=1 SITE_HTTPS=1
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
            HTTP_SITE=*)     HTTP_SITE="${line#*=}" ;;
            SITE_HTTPS=*)    SITE_HTTPS="${line#*=}" ;;
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
        echo "# The site over http (1 = shown, 0 = connection closed) and over https (1 = on, 0 = off)"
        echo "HTTP_SITE=$HTTP_SITE"
        echo "SITE_HTTPS=$SITE_HTTPS"
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
        [ -z "$TLS_CERTS" ] || { [ "$M_LISTEN" != "$SITE_TLS_PORT" ] && [ "$M_XUI" != "$SITE_TLS_PORT" ]; } ||
            die "Port $SITE_TLS_PORT is the website's internal HTTPS port; pick another port."
    done
    [ -z "$TLS_CERTS" ] || [ "$SITE_TLS_PORT" != "$SITE_PORT" ] || die "The site's HTTP and HTTPS ports must differ."
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
import json, os, re, shlex, sqlite3, sys

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

def mz_rows():
    """Inbounds of a Marzban panel on this server (its Xray config file)."""
    try:
        cfg = json.load(open(os.environ.get("XS_MZ_XRAY", "/var/lib/marzban/xray_config.json"), encoding="utf-8"))
    except Exception:
        return []
    out = []
    for ib in cfg.get("inbounds", []):
        if isinstance(ib, dict) and isinstance(ib.get("port"), int):
            out.append(dict(port=ib["port"], remark=ib.get("tag") or "", enable=1, listen=ib.get("listen") or "",
                            proto=ib.get("protocol") or "", stream=json.dumps(ib.get("streamSettings") or {}),
                            src="marzban"))
    return out


err, rows = None, []
if os.path.exists(db):
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        for port, remark, enable, listen, proto, stream in con.execute(
                "SELECT port, remark, enable, listen, protocol, stream_settings FROM inbounds ORDER BY port"):
            rows.append(dict(port=port, remark=remark or "", enable=enable, listen=listen or "", proto=proto,
                             stream=stream, src="x-ui"))
    except Exception as e:
        err = e
rows += mz_rows()

if mode == "list":
    if not rows:
        sys.exit(1)
    for r in sorted(rows, key=lambda r: r["port"]):
        try:
            net, sec = describe(r["stream"])[:2]
        except Exception:
            net, sec = "?", "?"
        print(f"{r['port']}\t{r['remark'] or '-'}\t{r['proto']}/{net}/{sec}\t{'on' if r['enable'] else 'OFF'}\t{r['src']}")
    sys.exit()

hits = [r for r in rows if r["port"] == int(sys.argv[3])]
if not hits:
    msg = f"could not read {db}: {err}" if err else f"no x-ui or Marzban inbound on port {sys.argv[3]}"
    print("XUI_ERROR=" + shlex.quote(msg))
    sys.exit()
hits.sort(key=lambda r: not r["enable"])               # prefer an enabled one
r = hits[0]
remark, enable, listen, proto, stream = r["remark"], r["enable"], r["listen"], r["proto"], r["stream"]
try:
    net, sec, paths, hosts, pp, snis = describe(stream)
except Exception as e:
    print("XUI_ERROR=" + shlex.quote(f"cannot read the settings of the inbound: {e}"))
    sys.exit()
print(f"XUI_SOURCE={shlex.quote(r['src'])}")
for k, v in dict(REMARK=remark or "", ENABLE=1 if enable else 0, LISTEN=listen or "",
                 PROTO=proto, NET=net, SEC=sec, PATHS=" ".join(paths),
                 HOSTS=" ".join(hosts), PP=1 if pp else 0, SNIS=" ".join(snis)).items():
    print(f"XUI_{k}={shlex.quote(str(v))}")
PY
}

read_inbound() {  # $1 = x-ui port; sets XUI_*
    XUI_ERROR="" XUI_REMARK="" XUI_ENABLE=1 XUI_LISTEN="" XUI_PROTO="" XUI_NET="" XUI_SEC=""
    XUI_PATHS="" XUI_HOSTS="" XUI_PP=0 XUI_SNIS="" XUI_SOURCE=""
    eval "$(xui_py one "$1" || true)"
    [ -n "$XUI_ERROR$XUI_PROTO" ] || XUI_ERROR="could not read the inbound on port $1"
    [ -z "$XUI_ERROR" ] || XUI_NET=unknown
}

src_tag() {  # " [$1]" for an inbound from Marzban; always succeeds, so it is safe inside assignments
    if [ "$XUI_SOURCE" = marzban ]; then printf ' [%s]' "$1"; fi
    return 0
}

xui_ports() {  # every inbound port in x-ui and Marzban, space separated
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
    local rows
    rows="$(xui_py list 2>/dev/null || true)"
    [ -n "$rows" ] || return 0
    echo "  Inbounds on this server:"
    printf '    %-7s %-20s %-28s %-8s %s\n' port name type enabled panel
    while IFS=$'\t' read -r p r t e src; do
        printf '    %-7s %-20s %-28s %-8s %s\n' "$p" "${r:0:20}" "$t" "$e" "$src"
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
        die "Nothing answers on $addr:$X (inbound for port $L). Is its panel (x-ui / Marzban) running and the inbound enabled?"
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
    MAP_INFO[$L]="${XUI_REMARK:+\"$XUI_REMARK\" }$XUI_PROTO/$XUI_NET/$XUI_SEC$(src_tag marzban)"
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
    if [ -n "$TLS_CERTS" ]; then
        printf '\nbackend site_tls\n    server site_tls 127.0.0.1:%s send-proxy\n' "$SITE_TLS_PORT" >> "$1"
    fi
    local m
    for m in "${MAPS[@]}"; do
        split_map "$m"
        emit_mapping "$1" "$M_LISTEN" "$M_XUI"
    done
}

# What a real site does: its own 404 page, compression, and caching for icons and images.
site_locations() {
    cat <<'EOF'
    error_page 404 /404.html;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml text/plain;

    location = /404.html {
        internal;
    }
    location ~* \.(ico|svg|png|jpe?g|gif|webp|css|js|woff2?)$ {
        expires 7d;
        access_log off;
        try_files $uri =404;
    }
    location / {
        try_files $uri $uri/ =404;
    }
EOF
}

write_nginx_conf() {
    # HAProxy passes the visitor's address with the PROXY protocol, so nginx logs real IPs.
    local redirect="" name http_body
    if [ "$HTTP_SITE" = 0 ]; then
        # The site is off over http: close every connection without an answer.
        http_body="    location / {
        return 444;
    }"
    else
        http_body="$(site_locations)"
    fi
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
$http_body
}
EOF
    for name in ${TLS_CERTS//,/ }; do
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

$(site_locations)
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
    if [ -n "$TLS_CERTS" ]; then
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
        if [ "$HTTP_SITE" = 0 ]; then
            # http is off: the port must accept the connection and close it without an answer.
            local rc=0
            for _ in 1 2 3 4 5 6; do
                rc=0
                curl -s --noproxy '*' -o /dev/null --max-time 5 "http://127.0.0.1:$M_LISTEN/" || rc=$?
                [ "$rc" = 52 ] && break
                sleep 0.5
            done
            [ "$rc" = 52 ] || { echo "port $M_LISTEN: http should get no answer, but curl ended with code $rc"; return 1; }
        else
            code=000
            for _ in 1 2 3 4 5 6; do
                code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$M_LISTEN/" || true)"
                [ "$code" = 200 ] && break
                sleep 0.5
            done
            [ "$code" = 200 ] || { echo "port $M_LISTEN: the website answered HTTP $code instead of 200"; return 1; }
        fi
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
        if [ -n "$XUI_ERROR" ]; then info="(no such inbound)"; else info="${XUI_REMARK:+\"$XUI_REMARK\" }$XUI_PROTO/$XUI_NET$(src_tag mz)"; fi
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
        if [ "$HTTP_SITE" = 1 ]; then
            printf '  http://%s:%s/   website + x-ui %s %s\n' "$ip" "$M_PUBLIC" "$M_XUI" "$info"
        else
            printf '  port %s (http site off)   x-ui %s %s\n' "$M_PUBLIC" "$M_XUI" "$info"
        fi
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
        ask_port x "Inbound port (from the list above)" "$1"
        if [ -n "$ports" ] && [[ " $ports " != *" $x "* ]]; then
            echo "    $x is not an inbound of x-ui or Marzban. The inbound ports are: $ports"
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
        [ -f "$src/helper.py" ] && [ -d "$src/templates" ] && [ -f "$src/panels.sh" ] ||
            die "helper.py, panels.sh and templates/ are missing. Download install.sh again."
        cp -r "$src/helper.py" "$src/templates" "$src/panels.sh" "$tmp/"
    fi
    rm -rf "$SHARE.new"
    mkdir -p "$(dirname "$SHARE")"
    mv "$tmp" "$SHARE.new"
    chmod -R a+rX "$SHARE.new"
    rm -rf "$SHARE"
    mv "$SHARE.new" "$SHARE"
}

need_helper() {
    [ -f "$HELPER" ] && [ -f "$SHARE/panels.sh" ] || install_files
}

need_panels() {  # the panel installers live in panels.sh, next to the helper
    need_helper
    # shellcheck source=panels.sh
    . "$SHARE/panels.sh"
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
    SITE_SNI_EXACT="" SITE_SNI_SUFFIX="" SITE_HOST_REGEX="" SITE_TLS_CHECK="" TLS_CERTS=""
    [ "$SITE_HTTPS" = 0 ] || TLS_CERTS="$SITE_CERTS"
    [ -n "$TLS_CERTS" ] || return 0
    local name d re="" p m used first=""
    for name in ${TLS_CERTS//,/ }; do
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

# When nginx already listens on the check port (its default site uses port 80), the HTTP check
# is answered by nginx from a folder acme.sh writes into, so nothing has to be stopped.
acme_webroot_conf() {
    local port doms
    mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"
    chmod -R a+rX /var/lib/xray-site
    if [ ! -s "$ACME_WEBROOT_LIST" ]; then rm -f "$ACME_NGINX_CONF"; return 0; fi
    {
        echo "# Answers certificate checks (HTTP-01) for xray-site. Generated by xray-site."
        for port in $(awk '{print $1}' "$ACME_WEBROOT_LIST" | sort -u); do
            doms="$(awk -v p="$port" '$1 == p {printf " %s", $2}' "$ACME_WEBROOT_LIST")"
            cat <<EOF
server {
    listen $port;
    server_name$doms;
    server_tokens off;
    location /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
    }
    location / {
        return 404;
    }
}
EOF
        done
    } > "$ACME_NGINX_CONF"
}

acme_webroot_set() {  # $1 add|remove, $2 domain, $3 port
    local tmp
    mkdir -p "$CONF_DIR"
    touch "$ACME_WEBROOT_LIST"
    tmp="$(awk -v d="$2" '$2 != d' "$ACME_WEBROOT_LIST")"
    printf '%s\n' "$tmp" | sed '/^$/d' > "$ACME_WEBROOT_LIST"
    [ "$1" = remove ] || echo "$3 $2" >> "$ACME_WEBROOT_LIST"
    acme_webroot_conf
    if ! nginx -t 2>"$CONF_DIR/nginx-test.log"; then
        cat "$CONF_DIR/nginx-test.log" >&2
        tmp="$(awk -v d="$2" '$2 != d' "$ACME_WEBROOT_LIST")"
        printf '%s\n' "$tmp" | sed '/^$/d' > "$ACME_WEBROOT_LIST"
        acme_webroot_conf
        die "nginx rejected the certificate-check settings (shown above)."
    fi
    systemctl reload nginx || true
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
    local dom="${1:-}" method="" port=80 email="" ca=letsencrypt wildcard=0 server webroot=0
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
            if [ -z "$owners" ]; then
                args+=(--standalone --httpport "$port")
            elif grep -q '"nginx"' <<<"$owners"; then
                webroot=1
                args+=(--webroot "$ACME_WEBROOT")
            else
                die "Port $port on this server is used by another program, so the check cannot run there:
$owners
Use another port (--http-port 8880) and forward the router's public port 80 to it."
            fi ;;
        *) die "Unknown method \"$method\" (cloudflare or http)." ;;
    esac
    acme_install "$email"
    if [ "$method" = http ] && [ "$webroot" = 1 ]; then
        say "nginx already listens on port $port, so it answers the check (nothing is stopped)."
        acme_webroot_set add "$dom" "$port"
    elif [ "$method" = http ]; then
        command -v socat >/dev/null || pkg_install socat
        command -v socat >/dev/null || die "socat is needed for the HTTP method; install it (apt install socat)."
    fi
    if [ "$method" = http ]; then
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
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && [ "$webroot" = 1 ] && [ ! -f "$CERT_DIR/$dom/meta" ]; then
        acme_webroot_set remove "$dom" "$port"
    fi
    [ "$rc" = 0 ] || [ "$rc" = 2 ] || die "The certificate was not issued (acme.sh output above).
Check that $dom points to $(public_ip)$([ "$method" = http ] && echo " and that public port 80 reaches this server's port $port")."
    local dir="$CERT_DIR/$dom"
    mkdir -p "$dir"
    chmod 700 "$CERT_DIR" "$dir"
    acme --install-cert -d "$dom" --ecc --fullchain-file "$dir/fullchain.pem" --key-file "$dir/privkey.pem" \
        --reloadcmd "$BIN cert reload" >/dev/null || die "acme.sh could not copy the certificate into $dir."
    chmod 600 "$dir/privkey.pem"
    write_meta "$dir" "TYPE=acme" "DOMAIN=$dom" "CERT=$dir/fullchain.pem" "KEY=$dir/privkey.pem" \
        "METHOD=$method" "CA=$ca" "WILDCARD=$wildcard" "WEBROOT=$webroot"
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
        used=""
        if [[ ",$SITE_CERTS," == *",$name,"* ]]; then
            if [ "$SITE_HTTPS" = 0 ]; then used="${CD}https (off)${C0}"; else used="${CG}✓ https${C0}"; fi
        fi
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
            if [ -s "$ACME_WEBROOT_LIST" ] && grep -q " $rm_domain\$" "$ACME_WEBROOT_LIST"; then
                acme_webroot_set remove "$rm_domain" ""
            fi
            rm -rf "${CERT_DIR:?}/$1"
            say "Removed certificate \"$1\"." ;;
        site)
            need_installed
            [ $# -gt 0 ] || die "Usage: xray-site cert site <name> [name ...] | off"
            if [ "$1" = off ]; then SITE_HTTPS=0
            else
                local c list=""
                for c in "$@"; do cert_meta "$c" || die "No certificate named \"$c\" (see: xray-site cert list)."; list="$list${list:+,}$c"; done
                SITE_CERTS="$list" SITE_HTTPS=1
            fi
            apply
            if [ -n "$TLS_CERTS" ]; then
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
            fi
            need_panels
            panels_cert_reload ;;
        *) die "Unknown: xray-site cert $sub (list, issue, add, paths, renew, remove, site, force-https, xui-restart)" ;;
    esac
}

# ================================================================ http / https of the site
proto_status() {  # one line per protocol, for the menu and "xray-site http"
    local https_txt red_txt
    if [ "$SITE_HTTPS" = 1 ] && [ -n "$SITE_CERTS" ]; then https_txt="${CG}${CB}on${C0}   certificate(s): ${SITE_CERTS//,/, }"
    elif [ -n "$SITE_CERTS" ]; then https_txt="${CD}off${C0}  (certificates kept: ${SITE_CERTS//,/, })"
    else https_txt="${CD}off${C0}  (no certificate chosen yet)"; fi
    if [ "$FORCE_HTTPS" = 1 ] && [ "$SITE_HTTPS" = 1 ] && [ -n "$SITE_CERTS" ]; then red_txt="${CG}${CB}on${C0}   http://domain goes to https://domain"
    elif [ "$FORCE_HTTPS" = 1 ]; then red_txt="${CY}on${C0}   (does nothing while HTTPS is off)"
    else red_txt="${CD}off${C0}"; fi
    printf '  %-10s %s\n' "HTTP" "$(if [ "$HTTP_SITE" = 1 ]; then printf '%son%s   browsers get the site over http' "$CG$CB" "$C0"; else printf '%soff%s  http connections are closed without an answer' "$CR$CB" "$C0"; fi)"
    printf '  %-10s %s\n' "HTTPS" "$https_txt"
    printf '  %-10s %s\n' "Redirect" "$red_txt"
}

site_off_note() {
    if [ "$HTTP_SITE" = 0 ] && { [ "$SITE_HTTPS" = 0 ] || [ -z "$SITE_CERTS" ]; }; then
        warn "The site is completely off now: browsers get no answer. The VPN works as before."
    fi
}

cmd_http() {
    need_installed
    case "${1:-}" in
        on) HTTP_SITE=1 ;;
        off) HTTP_SITE=0 ;;
        "") proto_status; return 0 ;;
        *) die "Usage: xray-site http on|off" ;;
    esac
    apply
    say "The site over http is ${1}."
    site_off_note
}

cmd_https() {
    need_installed
    case "${1:-}" in
        on) [ -n "$SITE_CERTS" ] || die "Choose the certificate(s) first: xray-site cert site <name> (see: xray-site cert list)"
            SITE_HTTPS=1 ;;
        off) SITE_HTTPS=0 ;;
        "") proto_status; return 0 ;;
        *) die "Usage: xray-site https on|off" ;;
    esac
    apply
    say "The site over https is ${1}."
    site_off_note
}

cmd_redirect() {
    need_installed
    case "${1:-}" in
        on) FORCE_HTTPS=1 ;;
        off) FORCE_HTTPS=0 ;;
        *) die "Usage: xray-site redirect on|off" ;;
    esac
    apply
    say "Redirect from http to https is ${1}."
    if [ "$FORCE_HTTPS" = 1 ] && [ -z "$TLS_CERTS" ]; then warn "It starts working once HTTPS is on."; fi
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
    rm -f "$UNIT" "$NGINX_CONF" "$ACME_NGINX_CONF"
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
            11) menu_site_protocols ;;
            12) cmd_status ;;
            13) menu_logs ;;
            14) menu_restart ;;
            15) menu_public_ip ;;
            16) cmd_update; return 0 ;;
            17) cmd_uninstall; return 0 ;;
            18) need_panels; menu_3xui ;;
            19) need_panels; menu_marzban ;;
            20) need_panels; menu_nodes ;;
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
    printf '  %swebsite + x-ui / Marzban on shared ports%s   %sv%s%s\n' "$CD" "$C0" "$(c256 99)" "$VERSION" "$C0"
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
    https="$(onoff "$( [ "$SITE_HTTPS" = 1 ] && [ -n "$SITE_CERTS" ] && echo 1 || echo 0 )")"
    https="${CD}HTTP${C0} $(onoff "$HTTP_SITE")  ${CD}HTTPS${C0} $https"
    if [ "$SITE_HTTPS" = 1 ] && [ -n "$SITE_CERTS" ]; then https="$https (${SITE_CERTS//,/, })"; fi
    if [ "$FORCE_HTTPS" = 1 ]; then https="$https  ${CD}redirect${C0} $(onoff 1)"; fi
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
    local mz=""
    if [ -f /opt/marzban/docker-compose.yml ]; then
        if docker ps --filter name=marzban --filter status=running -q 2>/dev/null | grep -q .; then mz="    ${CG}●${C0} marzban"
        else mz="    ${CR}●${C0} ${CD}marzban${C0}"; fi
    fi
    box_line "$(dot xray-site splitter)    $(dot nginx website)    $(dot x-ui x-ui)$mz"
    box_line "${CD}Public IP${C0}  $(printf '%-18s' "$(public_ip)") ${CD}LAN${C0}  $(lan_ip)"
    box_line "${CD}Site     ${C0}  ${CB}${title:-$tpl}${C0} ($tpl)"
    box_line "${CD}Serving  ${C0}  $https"
    box_line "${CD}SSL      ${C0}  $certs"
    box_end
}

ports_box() {
    local i=0 m lan conns col
    lan="$(lan_ip)"
    box_top "Ports"
    box_line "$(printf '%s%-3s %-8s %-34s %-22s %s%s' "$CD" "#" "public" "inbound" "router forwards to" "users" "$C0")"
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
    menu_two_cols "#Ports" "1|Add a port" "2|Change a port" "3|Remove a port" "4|Re-read inbounds and apply" \
        -- "#Website" "5|Choose the site template" "6|Edit the site texts" "7|Website internal port"
    echo
    menu_two_cols "#SSL certificates" "8|Get a free certificate" "9|Add my own certificate" "10|Manage certificates" "11|HTTP / HTTPS of the site" \
        -- "#Panels" "18|3x-ui panel (Sanaei)" "19|Marzban panel" "20|Marzban nodes"
    echo
    menu_two_cols "#System" "12|Status and connections" "13|Logs" "14|Restart services" \
        -- "#Maintenance" "15|Public IP" "16|Update xray-site" "17|Uninstall"
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
        refresh_tls_check
        site_urls
    fi
}

site_urls() {
    local m ip
    ip="$(public_ip)"
    echo
    for m in "${MAPS[@]}"; do
        split_map "$m"
        [ "$HTTP_SITE" = 0 ] || printf '    %shttp://%s:%s/%s\n' "$CC" "$ip" "$M_PUBLIC" "$C0"
        local d tls_names="${SITE_SNI_EXACT:-$SITE_TLS_CHECK}"
        for d in $tls_names; do printf '    %shttps://%s:%s/%s\n' "$CC" "$d" "$M_PUBLIC" "$C0"; done
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
    local dom="" method="" port=80 email="" ca="" token="" wild=0 c=""
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
    SITE_CERTS="$list" SITE_HTTPS=1
    try_apply
    if [ "$APPLIED" = 1 ]; then say "HTTPS is on for the site:"; refresh_tls_check; site_urls; else warn "HTTPS was not turned on."; fi
}

# After try_apply (which ran in a subshell), learn the site's HTTPS name for the links.
refresh_tls_check() {
    local out
    out="$( { prepare_site; } >/dev/null 2>&1; printf '%s|%s' "$SITE_TLS_CHECK" "$SITE_SNI_EXACT" )" || out="|"
    SITE_TLS_CHECK="${out%%|*}" SITE_SNI_EXACT="${out#*|}"
}

menu_certs() {
    local c
    while :; do
        load_conf
        box_top "Certificates"
        print_certs
        printf '  %s  1%s  Renew            %s  2%s  Remove           %s  3%s  Show file paths (for x-ui)\n' \
            "$CB$CC" "$C0" "$CB$CC" "$C0" "$CB$CC" "$C0"
        printf '  %s  4%s  Restart x-ui after a renewal: %s\n' "$CB$CC" "$C0" "$(onoff "$XUI_RESTART")"
        printf '  %s  0%s  Back\n\n' "$CB$CC" "$C0"
        ask c "Choose" ""
        case "$c" in
            1) if pick_cert; then try_run cmd_cert renew "$PICKED"; fi ;;
            2) if pick_cert && yes_no "Remove certificate \"$PICKED\"" n; then try_run cmd_cert remove "$PICKED"; fi ;;
            3) if pick_cert; then show_cert_paths "$PICKED"; fi ;;
            4) if [ "$XUI_RESTART" = 1 ]; then XUI_RESTART=0; else XUI_RESTART=1; fi; save_conf "$CONF" ;;
            0|"") return 0 ;;
            *) echo "    Choose a number from the list." ;;
        esac
        echo
    done
}

onoff() { if [ "$1" = 1 ]; then printf '%son%s' "$CG$CB" "$C0"; else printf '%soff%s' "$CD" "$C0"; fi; }

menu_site_protocols() {
    local c
    while :; do
        load_conf
        box_top "HTTP / HTTPS of the site"
        proto_status
        echo
        printf '  %s  1%s  Turn HTTP %s\n' "$CB$CC" "$C0" "$([ "$HTTP_SITE" = 1 ] && echo off || echo on)"
        printf '  %s  2%s  Turn HTTPS %s\n' "$CB$CC" "$C0" "$([ "$SITE_HTTPS" = 1 ] && [ -n "$SITE_CERTS" ] && echo off || echo on)"
        printf '  %s  3%s  Choose the certificate(s) for HTTPS\n' "$CB$CC" "$C0"
        printf '  %s  4%s  Turn the http -> https redirect %s\n' "$CB$CC" "$C0" "$([ "$FORCE_HTTPS" = 1 ] && echo off || echo on)"
        printf '  %s  0%s  Back\n\n' "$CB$CC" "$C0"
        ask c "Choose" ""
        case "$c" in
            1)  if [ "$HTTP_SITE" = 1 ]; then HTTP_SITE=0; else HTTP_SITE=1; fi
                try_apply
                if [ "$APPLIED" = 1 ]; then site_off_note; fi ;;
            2)  if [ "$SITE_HTTPS" = 1 ] && [ -n "$SITE_CERTS" ]; then SITE_HTTPS=0
                elif [ -z "$SITE_CERTS" ]; then menu_pick_site_certs; continue
                else SITE_HTTPS=1; fi
                try_apply
                if [ "$APPLIED" = 1 ]; then site_off_note; refresh_tls_check; site_urls; fi ;;
            3)  menu_pick_site_certs ;;
            4)  if [ "$FORCE_HTTPS" = 1 ]; then FORCE_HTTPS=0; else FORCE_HTTPS=1; fi
                try_apply
                if [ "$APPLIED" = 1 ] && [ "$FORCE_HTTPS" = 1 ] && { [ "$SITE_HTTPS" = 0 ] || [ -z "$SITE_CERTS" ]; }; then
                    echo "    The redirect starts working once HTTPS is on."
                fi ;;
            0|"") return 0 ;;
            *)  echo "    Choose a number from the list." ;;
        esac
        echo
    done
}

menu_pick_site_certs() {
    local names=() n pick list=""
    mapfile -t names < <(cert_names)
    if [ "${#names[@]}" = 0 ]; then echo "  No certificates yet: get one (8) or add yours (9) first."; return 0; fi
    print_certs
    echo "  Numbers of the certificates to use for HTTPS, separated by commas (e.g. 1 or 1,2)."
    ask_text pick "Certificates" ""
    [ -n "$pick" ] || return 0
    for n in ${pick//,/ }; do
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] || { echo "    No certificate number $n."; return 0; }
        list="$list${list:+,}${names[$((n - 1))]}"
    done
    SITE_CERTS="$list" SITE_HTTPS=1
    try_apply
    if [ "$APPLIED" = 1 ]; then say "HTTPS is on for the site:"; refresh_tls_check; site_urls; fi
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
    "list "*|"ls "*|"status "*|"logs "*|"log "*|"cert reload"|"cert list"|"cert ls"|"cert paths"|"cert "|"http "|"https ") ;;
    "3x-ui info"|"3x-ui "|"marzban info"|"marzban "|"marzban logs"|"node list"|"node "|"nodes "*) ;;
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
    http)       cmd_http "$@" ;;
    https)      cmd_https "$@" ;;
    redirect)   cmd_redirect "$@" ;;
    restart)    cmd_restart "$@" ;;
    logs|log)   cmd_logs "$@" ;;
    public-ip)  cmd_public_ip "$@" ;;
    update)     cmd_update ;;
    3x-ui|3xui|xui) need_panels; cmd_3xui "$@" ;;
    marzban)    need_panels; cmd_marzban "$@" ;;
    node|nodes) need_panels; cmd_node "$@" ;;
    uninstall)  cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *)          usage; exit 1 ;;
esac
exit
# Everything below is the embedded payload (helper.py and the site templates); see build.sh.
__XRAY_SITE_PAYLOAD__
H4sIAAAAAAACA+Q7XXPjRnJ+5q8Yz9aFgE2CpKTV7lKkLrJXtpTsSluS1jlbUrFAYiDCAgEYGErk
Kqq6VF0lefCvyIudK6ecu7Pz8ZLfoT293S9Jdw8+BiAlbc5OXkKvRXxM9/T09HcPx8KPRGxF8/f+
9z5t+KyvrdE3fCrfj1dWV9fe6zzurDyGizV6/mS93XmPtd/7P/hME2nHjL33//Tz6P3WNIlbQy9o
ieCCRXM5DoPVGud8hyQjYW4YMzkWbBbb82biScFG4WRiB06X0Z0Uk8i3pUgYPGMjEUvP9UY2jhuL
0Xli1WoMPuNM0DSA6sf3EklzVRAb0h6yRER2DLcwb2BPRINJT/rw5YhkFHuR9MLArMyEaJpnQi5M
xEbTOBaBVBMlQkovOIN5/upwf28pEhjCzsW8f2H7U8Esy8IxGYH9HhK0ietvAbP2tl5u99nR1qcv
dvfgYvvl1u6LPnu1s493hhQzCayKBeCLZI294weIyefbgJkYXMs5U/RMhB0kxLhsSD1h4WVgbjBY
pYO7mHF12eJikSzyCLYdOYdwGbM05CNQm3DCaDHvNola9x3boGGmcV3219uf92DXN2mBdJWNgQ13
7akvK5MoGpaxLn1DxAlfjECENFZGsRdIRfqlGLI4DOVSHsHzxU1B2BIoC93lE1VwkpoEbsh6rueD
6BSfiqg74cT2YHMNUrrijdlgYhZ58Zw5cAtaYM8T5gtXNpiXJFMRL5mQ9JH18HKT9UCcaV4x8yRr
s8uxCIh0eM6Gwg9RIWSoBKBQ6lrtpR2/GYIAbr3aBWmGt5EdCJ+FCO0lQGF8IeIGA0X41eHg5ReD
1wcvWCu7Ptw+yG9ebR0eknWxgxDwxIBCmN0K3ZM3zUsbCOwlYhQGTrK5VDtoyDSQns8KiuzRCDQM
dI354ZkXLCIOQkc0cW13q11l9QxBEhYI2Fnj1fZLcznS5H5d9pxGasJsxwHlSxosCmMJX+CL5BS+
J/DQPhMVw3fHbE3AwlIT1EsxbrJjRHnKju3IY+qS6bIeiEtaDGic59yBVzHeczaXcp/e4vZxeBWQ
tPOSOqnF3IE7FpPwQhD2xRG+F5wn2lp6XyYgXldeMAyn4GNwOV0WTYe+N6Kba6QrHU1eCB8yL2Aj
30PzQvgWp0nxJewYfdsAluF6ZxbOdVpo4xlsThzKcBT6apsWNqW2H/hzWvEr8p648MCxYwfmHcY2
qCioxTQRjoVuteZNCAuqrfQmIrsfy4mfXSMJ2XWYZFdxPjYZT0HU87ukuJTxdCTzu3kOi2YILU1+
r838Bsis1Q53tg62WR/msyAQ8OIwsMD+Gxx0lV7xBuMUKvjhyPZbyRhcWCuPCbhZ+3h/75PB892D
5Tiyt4RGyFEJ9HD3aHuAvlfBRrYcW1+GXmBkUACEQ2lv0vGH6Vy8dWEDUd6wwNjCPwmvffz68Gj/
ZWnc5eWlNnPtaPvlqxdbgKw6MS0ZZs1jEJj1s62DAbglHGtwdPK4ltTN4yU5erwgVw8A+wfPt3Hq
Y+6AM/ZD28G3Q7BG+A0GHezUHC+TcRjh9zhMMBDBS9wZN/S9kN6HsGz8Jo3CqwAM2oyf1mo18IYg
GbYzQN4YuIJG5iFTYyrjeTePMy49OWZhJLKhIhiFDszZ51PpNp9yk9kQ8nVrZQcqp3FAUmnhKgxX
WSIxQwPLjP3D7TgOweZ/hs6ars0CQwqdeW1F8WUM/C+RbEs7BYKNmNjnwvHixMg2BW7QwNFgcn0Q
KQ7C8/5RPBWKGBeMqpxEwO5M1q3JeYLXBgD3lyJSkIolieU6xBdExC/5w6whfjhTnACIbzAXQZJp
LAZ2MvK8/ie2n4CN9yD6CGR/xcwWNxpPQscAWhusHUJelL+IBcjaSKhXRGDKLdceON6ZJxMjSXmU
MhX0HR5ZMob4D8XUgAfEPHpi8HZnZXXt8fqTp89QaG7/9fZ3t7+//cPtD7c/3v7b7b/f/sftf3Iz
m+RL27d9bzAXdmw4/b3CGTvAUwf9eWayLLywZAgxh2Hq5DgWQrMmW1/pMM9lhmNNwoC2F2DmJtsE
1VltsJWOyQQwRwdYATIeseZP/hRpA60KU4pB/shYphIoD4kyADgaJMTI7UJJ0FM5X4Q8Pq3lt1YC
mmtgruDbk6Fjs6ALGoKWwEJJmBmBiawJ0D0pA0GcePYMYoJUIMOpLJCih6XBhL2YeyKkDaMK1S/Z
r3wBgBV2HgenxrPBaGtzPEALoUK3maHwEtSfezHSWix0WiBBZXMB5Ft2BKrkGFccqeZdAqF8Da6J
GPIL9GQggCoUr8pzjgxp3JkgcS3vKyHVni9BrUMBTfz+GchkJRX06cMGu7o2r/MdW1gyVzkS11bO
Pw+nMSZmlFPwxakri3ILANyQBMXgqvBq14hbI/Lq+rqkjkBVqtuZAgxIiIyyETmWx4rmU5Xr4yxV
tck8DdI9QD6kKJKSCOZ+nHhTS8Urd6IcIk7CronxI7YFhPqYoEGaI20f4nYfMc7Z2MbYnTJ0gCmW
3YUURUQQBIWXYJ2ZJ60cW3JcTHaKTj/dAyTjPuEukFdFW2ln4cDVqi1ImFPGg7RixsqLJQPiMDI4
hBv4tNC2zGanrBSuC0GzdyEGONJQCQGuNmXtuys4QZZ1PKPlAm23N5LGXQJs5kbmvIHVBGS1QbGW
0sRibfQA5yKNwgcwapILU7rZ54ggj5TQqADSsn24OD7HvYHnOlsu8lgGs/UBsn+RJ0X08gAz9D18
2JPjKoEi10JmGwXn7t4iNeSYf769dUCSVrho3Y+a+cBP85Hos5d6UvKFOcCLrdd7H+8MXh7mQJBY
aTvj29NgNB5MEmXhDEKHfwyTfcjWHrMP2NP1tXbbhItOG75NVYcjLZ4OjYm2b+cww8Q6i8NpZHTM
8namKnuxNCTMgNpmNdyjTSYEfVDDYjFKn3BjLDB1diQMHNlgX01DKbRwLkUTCwuJjfnJ1cmVcbzV
/GJw+qF5cn2Ctg/eNGjvzJ8tdsC0dYJGSI6pImij/vnKCIE9qoGY7WKWcpVG4NdkwopKJRqlAOIF
eyQhJ7QpEZ5Ttc9QKXE4ApYiKAR4Z4QTOAwAELAlRbh34UEyOkguzgxfSInlFEg/86haPQMqdDam
I1EW+J9+/U/cPO52Tku8NNx6D1Cy2cQPkj4fSxl1W5gRWZerVhiftVZATFowgrMLT1x+FM76vM3a
bH0N/vHNXgy6ABroyHGfwwPIpb2zsVTXMYztwHe9JCVuHUyt3+dXRP01b232SNVg8OoKZ/M+XwMY
F0LEpmtPPB8eHNnjcGI3tmLP9hsJBLHNRMSem45KvDcCYJdNhK8vU4qetNucBKNpg46EcZ9PPMcB
F8wUPY9c1+WbV4pj170WDt3s4dI3T4J6dRvgj6GzH5L4Lba6MltdYTHWD4TDkq+muMdeUC3CItwU
to9c2au9T9HJeY7AAq4FeMmtW1gVWIhKAeiswYaYbKLiEwGWD3bAA9/yCLbX63qg6CugO511kyy4
R8a7DfF1g62ZpdC1yMyWzYDBZ6cNUCtrHeXCgM8NFtsY+q/C8ydKjsLLpByYznFGSDXOIPMAED3r
Cy9h6HAuwaZBvm0ct08LG4GgsztByUrN0CTZMwNpaLIZpEoNAGkyGgzfHfgf3plmGWxeApsT2PxB
sHRT+jjtB/jnQ8T0Af7p9YkNH+DfsgWEBX6oVpgYxykvgYOPH6PZSzGSsdNXjizMIkUFCk900zwa
T4Nz4xz8VyknLud805EE7zc6N/jmLthBH/whjUXLj6BIP9zD1+JgrPZYo3i0umJoQ032F6w9+yT9
KHojCK5A+ob8ZPb0GcjuSXwSnMw69knAAUoROuS7O8+xqFOZaPcj/OBzkiT192mDrdOO4L/yFmj4
nm8d5WSGkwhrevCYK0+P/AOH/oyWmoNs7z0HEBhkmrW7ONXb2dnhNHUH/plV3vSQ3p2d3d0Kze0M
BNUAGQ1cAQJWVhADXKe2Ao35YK29lsYIpK0wHsQ73UAXYzm8Z++DP4S8RGk8JgYYp978+Pbvbv7l
7T+wt/91+/XN9zffsLd/f/PDzfcUuQKsikJfoctAh+yi3UlRqNjFyFH86ddf33xz+zX74z8Dupvv
Ac+3N9+8/c3ND+zm27f/ePM94mdw8R3e4DQw283v4BJefMNuvoO7bxWW7/AeiEA839z84ea3VkpO
SREUaUdUdgfy5uGU/J0fhucYnqOuOyEWzYFuqtugi0K/NxQCIojwQjgWT0vb4URxAyi++f0fv4fJ
f4tUw/wZf+DFj29/c/t1mTEfwR5mzQpCgqTwPCmvuEp6hH6Sl8TFBTvce98JR3IeqRBls9bDL9o3
8GJ1167r09ZFUL/mDMtL8DKWfvmtL2N4jTggqoQvCuhHY4gkhcwi0ewxktTn6Hax8MdBgAKJVSOu
/K0jwBWJJt1gRcmT4B6bsBpf9DuIhARpEwSQ/S27ytZHD9G90ctaD8vgsFhwgOjXwIHHwu3zVurn
LPL8uHZ4PwH+oT/8EIIFxJ/IOaJgbBiCUby6AiMbQxTTbW+wiRc0VSjQhTjzYrwBDEnA/827Z7Hn
bDCqaTUpV+iOYE0i3mBD2K8zcp7dR+66+8Qdbiid6T7qjFbaq+2NmtaIzMODLvixN148sWXQYLsH
W3uHECA0WBozMH4ozkLBXpMO56HDRhoJ+N5ZkBMQ2Q4mBN3OejTbYNfXMN1fToTj2cwAi+OKOGkS
PcDjsZiILhjJ+NzEhWcM0JfQ6XRWO3a+BLEungoX0SrMQxyfMWXoQwi4UYQz3WdEAuyNyNmYYUrj
ppTAcQfxFIArKwiYbkQHbjBWy5cT4eAQjJsn513rST4QIzoFScNsnTYvIDJSErUV5oSkK4T4KWWr
I0ZhbGO9ohtApqtxtg0EqYmGYQwpXRM8qDdNiFKaHAIuJVW9VqohyNvNnuNdbPaGKMy91nCzN+5s
XmWSDNe9CG5hZriLNnt2JsQQzqHiw1MbIjlC0SJ0iJ1UGaMsZaxxtoEKuakdD4lvOcCGoZ8opSgd
L6B0VqI8pHEdhjBKuxtsGvjYfdLjv1IlA+HySA/MRL1QxDoFjmjH0Sil3MiLJfhiIQjAh2nMkIwq
5u1CJYhaZwJz4GqClbmeJZBZb2MZGLEN/U39zzcnEGOXK186LtsHBQ2Qe0uxwp8lCCCz0cwobZHS
X82SZkmICvHTXUD2FcxVi4OoroxPL8pp+PAxoVNjoziMRCwhhwnPug+B1DMCaBvuoaCEVdURNXxK
L+6gAXmvexIxpKpjPrsmSnnrIZe+RkYK0x51TL0MiOcdqCChNwsoU+6rL5Dmol6oT6k15jyFrFy3
0wp35ErLrbms+ddYgMzIww7IAFXPHvrCkGGUBWEYi3ix6jgNsMHUKAqrMMml7Z9rw0v9mhwOnmAf
Lntgwt0ABgjwvO3w8ePH5TTHpdo9TVLOcNyo2nPMZ3CDcnqS0+BGxfRuVJ55DRtJpRIacsdY3BZt
O9LYqMrGTDbV62IzSlzJW3R67XRJX04deJgtdHbvqrjq1Se0gBkUoU4MQGV2qeiC5/ZkcRIqPZFE
C3VjPJsElhh7reUjOIt9UMD4jg2/fOssal8aeqkya+tSdZCq3vRAGfBy8T2NWdGx7QjfD8mtnQTa
0svyW7BqocpWvCrtWe45llX9Cdz2gITDOfZHt2ceSBN/HZwHWLvKgLoqjrzm5oI4UDuanCFOtLQk
WUylhKt4hdVMLGg8XLAsetZFs1jrMBR1WF0aNeuwRBjB/sqFVn8BQdVt5R2rnWQn7yRr4zFU9GZ9
bgXispkyKolH1Rkq5emi5K6Mg9Z3BGCNdQsWAl6XrQOmGwHtSVH9R7OrK07a74gqFRb0C14wFUtw
aepYhqHYt39Xib5cUimLItVNFzXp/h4HLXd5X2MJVXpUh48a95TvG1pDD4+JBRLjnUfrq+vrbodX
qkN3NB2oSw+b8WcaDySxmAdNQnmsOuNjjcJobkR0tMGsPczYn8TQtGqBnY972dN4qDGSRzIJlcr1
iLBbqm7rAeeyHjA2cFOlySL0Zf1aHofDUCaWnEnssr6GvK8JEWcgu+yDk2ALbOxll7XAxC4FhkQj
FfaijLMkEk65U1CIVQF86dogMdcVr99QYukFKSMWm2V3+7ilYmYuitLPK5h3C+e7Usn1IL1K8H3E
lgGR7uGD+rNYnVcEV2K/TG1Cn46xoP2HkNaC27SVq9QsnshYCAMeN5h3FoQxiB5WyxPNeWg95JQF
iK4cK4JpxNNF+KKBc2pne+gFLZfA/qez58eoEqkH4QlIYmSD57s30Ct34UEoCaTUuKUnpTD8wSji
HSMJdsKvFPZ63hk5vT7hFjvK+mYQbNRZPZWIynzmtRYZLeYKi4TnZdFEi22xjX2qt+2rmApTmDXD
cz7d0ehGV5nDP+xc81Zq1h1/Z0amv09APp4T38DAFT8+oG58vZ+xL8NuXvc1vl2QU0h7qccns3a7
eTLruCezJ+4p2jAGfy4wocD2knncXWm3T3XiK+1f4mfaxr/Hh9EwOg1xrh+EeCiey3u/Whrzc3V4
tcPc6oAYPhjgUXx1JHDJ+TA0HEniWwP6A3BygFUvRwwQVoFRRhLNfQ99juMlaHz6eG6YzkU30Ykm
id6Q26YvLJtVY3rkU610uuyiJJKO8j6wlV8C8i1f7uHZnQYDTckPYBj8+d4h7uvuK7alzkVzs8jr
QA4rp8kqc8VOsDhVOodOC43LdAF/oRAGRE06Ff0QAbAGIAeGsQy1GvIQ5jA+swPvDZUZCb9JPhkl
/6RYwk+cRCNfoc9rRCUsJg6uMEa3DNmaeSJ8t5mAORfOkvaumEWpWJEAYh40kOEgPWdvOMccdmnL
lTCj1j6kX3mk+RNiaDItizJZq5WmUBoAuYPSeRO6wBQZLyCLhrwGcDWKQfjnDUihNZUjsgkuTcB/
8XnzF5PmLxxuPiDJSGYjm7vZAW7+kuuaTdLW0H65kv9o5WfScu03KrWXXwy29z5bfipdvaMz6WEk
WxMF1sJxsEh4+6uDrc/vBMWXBJudQM/gqz8n4FllBpAMVDZW2Bp12vPqelFGUFSxIE9J4j1HtstG
lyD69JXZ82rMSUOy/D0daMcywRiNDhfQS97n6ihgIBbDsHOVJyjgyAd/BcOpQlgdCes7Ps8oIY+R
3aTfdV7PLnmd33/iNrJTM1o64jjy4XG26d28lz4YYKdsMDBQFXUdVb97mMY+Nplj8dUUgyqNP8u3
+/XBiyqvEbE1tBNRkpFjDeDUitOltbi5CDtN8HAPXUaXdwoa/mwqS0OWj8DfUvHCai13x0hlLoFK
9CskUbMLjRceDkqox5rWdl5/tvvx/sHe4PDwxeDj7YOjT3ZfYMqmSlk4mt/JGJdfKcTX3Vars/LE
asN/ne6VwlzPML/aPziqN1j9abvdrkPQ9zCzUtIOXz/fJxbp2Zr+DpnzN/sHzysMesRe4E9Z1K/F
6Bc6WDP01HlbIwTbGzDNiJt67LAB7uYC7Px/t/fuzW0cSb7o/M1P0duiloBNgEDjQRASOSNTsq0Y
PbiiPLteWctoAA0SRyAAowFSMs0b6wlbVtzr2Lhx90TciTMTsXEnbqw0GtsaPTwe70b4j/kUlPWf
P8H5CCcfVdVV3dUgKEvW7BlSNgn0o55ZWVmZv8zcRJvzsD/e3HJI+37zlgZGxYbiuqX9wKS2fGPc
6bY2+G4mdm8Ny3kblmAX7oFUOj+1l2j0Eyvy7atX19ZlkWQSuDlaJnmmCWclkMbGvR00lnaC1oa4
DRtK1uzLqH8DhmSZJRS1yqAKWmB0NN7qt9h1gdErZBmYR0a2LT6+P+4EI3aNSF2RdPZJuTdA8/mU
Kxk1QgHq+IWGaM89Qy6BqCPwB8C0miRRLBCL3p+PJC+pDoNmo+8Wckm8l1SGzcs6rrmrbGfJXUWr
y/VowqnBefhCbBvOrVBoNi++oKCht+Rmbnd3N4eP5NQbLVdb0iiOILLnuVulnFZChgyltYTGRB+M
iALMClVVZ8Yw+0MhpTH6+o3AHwLxI1woej2Sd5Or4gr/zUTs43WdmozOLavpZbpb5j8RzRp7qVJB
aKuS/mSG8yREwU6y7BVI6wDi8iC54w39XTpEhQMdJqxtVjr10oKjvQsLjM1RKxj5nS4xMC4pz+eJ
jDj0u8IaF9swEv0xylLeWaiWwGtZCffGL+68eNIsMl2ES2y4E86pUtrye+FuMAxaDrB27M8+QnL2
eFr2nT2cyH046XND9FN9vBmWMQMKJNZhm5dOGBzWxFW/h+sFhru5paRDf+TsKUrDlgV6o+Jeb2EG
KICOWEgJtPGZjJC8jAUrtLO5JBe13qEvyFbdtcvrV0nC9AedBb+13ekt0EOu4Kl7Lu6JwuFE2yNd
nLbd/rAlLw929w/bRbjJ9Dt7zeUT6wbXdj2BQYQyhUhLsq70pE09QzfbmzqNZiaJs8/hXCggqfJb
J4LDQsXi+CaaCEN37TpNYyckj5NeM8h05slLguXeDr9AQCzl+LL9wYYIe5FpbsMe5w83pcoNioJL
bIWJnIpdU46nxphjhUVcKxBKHj8ySYljRUzOJK9qIOM9btvcyN9EUQnEpPdG8pr0Uk7egI7MZS2k
XWCF6QcwM2JJROpCrUfo6K31JuihQsS03mHrrN0perodbwsETwdVmvXDGdv2B3leUEyXpkHZHBeX
UDZu8rbRzxizyShuM6+xiqyF9SikRtTjFRwFuwpdTpVgN61bzFcYaLAc3kLzPWxbw+yMPVYFtbiY
uEm1h90gGGRKQtEtB8g2Zyq0gTZx3DJ4jVjLW+cizoJPL8goKC6sfk3SRa0pH9fEuuwma4oTOylf
0ioSDivXrpvjtx0S2licakQABH4UhPYIoPLeiPWV+qWeuHStDvR23b5yetfmOi3UO4/wI7JM9UVE
DlDfacGom4POhnaBlxQ7YkcrDRov15dtfDBCg2sq21TsB+i0WDnMVK4Vow6QcLscrS6PGRfCkIn/
AB16vM6qXqESkblss/5uKfluKXo3IjjcgOTUGdsPdsQVgljk18nuVqIvcEFFtGD+Wac+kGzJTcJH
xMcjHmuwkg0/3OgFuxvoKA8lIVOAssdIKsCegzaQLAZ8gFtFza7JNADH8k5LKtOssxRjdHhtA2N1
MMfTeFx2Po3/Fa/HB7ko/Hun4IP60POqaWvrc0+0Z99NWtqFOpLDA2SFOlMG5WAo8KHMK1opBo1n
NbIXq3KOVuXc3P4EljtFs3iDmJnM5awTxcFDtKmSo3b23IVzV8/FB06fubRlSiFCtBKNyCzb/kBf
pppIOHnS3T19iCjGCx5DhYABm7ibrbNrny5yZNMEBikbRLZmXAdhgmq473TPFc6aBnumoCbdkIxR
9JTdOC0CrCzLIaA2UifoE5XixsESWP4WqQ1Di6y+dU2xCjwgis+2x2goJFaIW0L8SzQqEr/jJLD2
TnwIBM+iL3GmgLqp8XYG526Hx30nGhWKPUUWSIogk4Gp7fV3SVG0J5oekZOubLMcQMbClieESGcP
aG/f9D8oKPRihyhpJ5IvUZjAK/HNfGOj1W9ubCQkO15VSlBl4t2Re8zOtWL9uiY0GNpfWAtuUsC2
ir9xuSMKlmKKA1aP8hQBd6TvzfCFYCDqmwarhWu2pSxDviXkHk3xERnHbRE7smmlhmapaBmOFPey
rz72FUcncXxFdbqwAPspp1iTZM7dHHAMMRV4bt7ZhALec/f8/ffcGPMVCnl/gjaeLeUxqy2PTgxL
kDYEFClOG4QwCTVQbvhscUfjb2ja2c34EynG4PhCNYzBac3jSg9t3tSe9bGGpyOncGUv693GCkM7
vEBBDNKxAC0DgWU67NO1G6Ym21hBN3CtQIP4QeL/LbzUsq4XHtfEaplquBEAnngzgobb3pNx77TX
KAzesmaHl1t1HH+EN1O4hnhlX+pFyW2bEEDO2rmLuuL+sINY4gCWaqukvandT24oc/MCikGvkvyE
b/PfWyGdzKkE64SoQH3aECUOyM3RTWE9Xl+/sCr09fh17crlq5dXL1/YuHphfWP93JVfnLuSjb9J
ogthFzaaW2KvMc4fR1LMcbeDCaNo7o3TbFzahthBMx4O5MYGDc/GBm6PGxtidHAaMYBhhjZN/Cb3
N6C+nxz/HPrDxq98uPXK4v8uVquLlWT83/Jx/N8fJf6vE24F3S6HBqWPyw0/3Jo54SjKqMvIPHo0
4NLN3LjjZNb9nh90WG8q1erCnoqX8Gl5mXQ/eSh4vT8eNkGsadyKYgrPw6G4j4FBRNBhDOcZYuTf
0L+FulnUl4Sw6xHXwq1xnhkJsTFgyfl8PpufQcTG2fNXlnUwB15bv7K6PMv3FsJhkx47c/XMchy4
Qc9ehb1/eVZGHpS38gjnwPtXzq1dXnZn9y6eufKPb5y5RN/rObKX1xcWNkGGHpPj+kIw7IRl+FkQ
A7Dv8utvmm+/Wc9t+yHGoXBnLl0+ey7RATryilu2Rmv3z18889Y5vfjoaj232f8AeKO/ZbxXJ2l8
BHX/wzvnN944fwnfFh/rOS3eI043/RKPnr8EA3XhAmIc5CvapWhAhv5ungcFLRPCGY3GZ3srJOJZ
IFJa4EFYEKQGZCcqis8HPc2zcfby6s/PXdm4eP7KlctX1rEZ5pWoFbDZ3AiGsDfs+L1mtz9u5Ttw
TBU323xTuzIMNuG0MryVb8lb0Jg3zqz+/J01mp6oNegjOx6ECFta/oE/IvCMWAEzqDURgquzh2CF
2SJJLvPOrIcnAtr+rjk5OFjMFl3nuvO3f+uEsKpyPZDOFv5p1lteWBi4fPNDh4yEudjuuj8jaglT
a4G/JQ4yzTrnGy0YptwAis2ISIpUQ1Yg3Prj5hZd4PMnOq051UIhukTEhEbUkWhKOIJ5y2wOg4GT
23FcbLdsNLQalf78Iq32tjN3MnyvdzJcxj9z8BwWgM97+KuEPcUxmIP+L7TmnBUsCZ1zuIztHTFc
dIkbBWPQ3iUchhwB/OxcXV0T+hoQ0sftXZSi251hsAtT1OJYyXCKEdGeCSTgkz+E1smBAhMPsBB3
9mfuKafV16VaqQyAnmMdKwutYGehNwYqgMnEK6w6czztzocOD9b7jrtOd+uiaigd2tIz5DAsw0f3
B6h+sDBqAkFoRXkrf1uUw2xiDLSGyV7nUEA1W2jcyuWIluLlWxplvvY+vAkED9VhpN4cqspzOPLL
qsVG72OttZc3DFDEnfhiu8N2W6lC0hfFELre396QNlQiDAQbOLmmU/IcKnTMD8F0oPG4inEXRrAy
Wk1n7kzuH/3cB4Xc0hxclO8Vq6ccpDU4XY822sMgIBW4pDm6zOp+8l2EVUjxtP0RHmcwFBXpT4Je
CNd1GltWK4uVytdo/c9m+GncSWEYYXk615H24PnZTGbgvO4Us9lTUeeD5lafHsTew2rvtEjDLlt3
fm2nrMwVFM4DpW06GTEXusYrdvn/cP7pGvT7+l5xvrSfeS8ffcnulfZnnevXcR64AlEIMO3i/Pw+
1XzCuRCI2NG4WQD/6KNM4GPYLIQV6IG4WddCosZc6BC8Ke+s4+trZy6dY4yak3FdRB+jviE/M+g0
b2zQC4zbjhjeMgwejDRVh0Nd4ID62jjTSW4ZXuHBj6pYFg792z45Cjo5gax2TjunMySs8CFQqspw
pPZO0LVrP7u+j80r4NwYi4Snw3Eu9Q24unMrGM07Yb8Obc67iaczbwUjYkoEc9kOemOnhrOF0cFv
gcgVajeW5qlGZzgWUdv9TZwMHFQeyqxrNxaLZaPJXjN6GxzojWNSZN1geiDEOTDpq3pI9fF2AyZb
CpY0Q652AMch64mBQq6TMOpek09I8nudKA0eFTdym4FTdIwr3SA+EXS7MQz8G4mRdZxVSYmysdLB
GNeZmAu1mnTqmN3jKmDZ9TD8VDZ7nWmdBVk8yvJCMDmBWBywvfg6CczTFCJg2He6wFiQWN3X8vrW
ykGqWripUhUyf4CQA/zdG87cHuctmC3uz4l5Fgxgr3Xivdfy3EABAGn0b8qmiXwbHOBf2PUYwsHw
znnR7Hk9NPu8w4gUyUy1pnbxrDBu8BW/h02GPxudAbAruI7fuSC6NMPotpsbo/4gkifwAqGZ3bcx
7E8vGEElN+DG7N7q6v5sGYS5WSi0PuvNluBSYT/+2ps4kzCiFK7LeG2vUs/NQgP267PVlJevwIta
zgkg4V0M+y66L2UIZ7aKQCjRDjdiBcSqF125/rWC3xGoHlEwVP7G/uwit+GUXIRRGTVbGWtixI0y
arEy8PGg12Lu+4Ml2LMkLs9g2C5YLkg3yoeC7jjijgMEFKI6ySosxB9GyWnGJprwczn5XFSYUU7O
Ug6Gnu7AFW6wsyqeAEa43QlxD8jzEMGwcCEbcIDZIPQYuRXKnjEhI9aNBV74QCtvPARpO3RyfSfq
YG4XpNc9PGJsEDhuDgSVbf9mDm2ewKnjZ49cUZ0++gs73kJMHkZGhsUgYywXkLvBff2iB2L3da0D
IOOPB/qU/E1yKBNDGGnS/VuOe57PZsh1eODcFGHWH4wo7U5qcfhz9twb5+GI+uaVy5eunrt0dhm2
6Q4GZ2JpVpUxHpAfSe79963C35SlyNjCuVtUkhrZQ8VhsU4YL34WZ6bTGJMqFOPG+ZuwLTPLzlCk
T+I+tDucBwERZCweKE7H47DxioNBtqE5eHrMa+7X6dOB7WKqaofrFxSxQNcklTRJGA234EnTlqDR
ebM/7rLTRyNQSp1W3hETi1qXDIyYGi01TKzgAapkQUHsOGJsQjJaNUddJ+iRyj2XQzNpsg+JASYq
nI414O78N0dY/IdQrlzyEQUPbmxumP2WZed2vMizabrGQicnlDfojmU+mqOVOU33J9f98ipNJTrJ
XO3EZyM4beCzJqmJVpPJyNJUvdpOqFUCS5ZqBnm3h0SQiWhWHLG5ZFndCUkmb48bIHC2SRcpoCsw
TGG0xMVWMxhTzGD2BNnuEI47H6dxcxMxNqkN8U5s1xFXFdsmYtaaJsxdqkwpmKo8TKdA/MIOi4Lg
6GCqyGR3NSWw9F5dX/UKtSqL+5wVDgRYSt3CjVto+cF2v0f20HixzunTc2vvzun5bNBzaZ5S0rDM
KFqEZixltbk+H33x6tdnlN0rFT6czc7YMez8xt7+zJa/g05ICges9lfRAMYDz8D9a8l7aCqnAl53
rm3TEWWboI2i7Zg7Qdr08bHrM0fPXRJlEYEmzOt+fu4umpmj9CFr78bYLSq/MAaSWBWxBdDqtARx
8FN0+sMzi2x9JgyCtAnFhfBiZEJhKLj4tjAVzNwcdzbUyqSzBUixN0FyEWpnkmX36THBlegh7T5w
IlMjxkoWtbeQpgXfl5BWeYIJUT+AxfARDT3O9K9nrr6tfUWPMk3IQ09D4c6IIp7WHOmen8Pg39QA
m+ZJyG1m7ViSUNrOhQv/dO1aPQSxIqhfv/4aJbnSL7yXocMt/XrtvWz+tYX3iguDOVhqp91ZaJUb
DUSyLujahLp2g8YbfhisAdnFq/wn/evRKsUBnFCp9Fz4wTU2fRLu98zu1nML++S/uvBaNjkS1odP
nXIszy7MmlfouSD0mzOCygQxR7J1uDEa3VLL8YrUsSDwxwHRdLvT87t1zYqmzGuoHgkdcoHCXSav
zorGmrEJOFxOqCJOqoeB42e0pZRN6o0wcm+fkLNA5fEGYaYN1sghho48sjKcvkvag/KtRhYthCKV
GuUApaxrIW6ttzRF1a0g3OhBle+wRA/CpojYyzYoySl8h40qdBrz4VRO8nXWdXo4pDZtFB+E206i
YQnNmma/iMw5UQubA7yXLEZ/mi7mZimFg/P6yXdPbp9s5U6+ffLiyfUsPOua8/IGd0VkhaQOqoFk
kkg0RHSKuc5oeyDjkeFS2r6BiCIn15KkHx0JUOuNAnoJT53uLLyg2dJcwT41Ex0ZWPac4baTG7b5
BbRPIMWuKklNpj2xESsekfcjqeSKEK1Gk8gpwy5iMPcamWfdSFBC23Oy9UJUsrX1qmUVtf0OSZbA
LQaoK2v0d4JsPlJ6GOXQFWN9qZVbkquKt3h528eoDNSFqEqQBAWl02CoNw9Zh7gGVQNEkBDBVfib
YipHamEmytVrjI0Ub/W9UdoRe4JEos3JZaVCjCSQv2jkEOXOlRuiZT+U9Sr1Hb8bpekMQ9fQI6/R
Hc5/aOQVhWGM7d8O6SDN68ilzfHl1URWhcEu/Oehko59JFpBW9Kf5FDrAWpYMUUmN1FuVZxbUurV
4JALTCnGYYCDb1AoX6pLKfJcdF8Axu/GnABM7Tir23FvG5L6aMBjIerLbHVaIAvOs1p/uz8MKJq4
3wRyDIEHu9g1OWGX+sIdM2860qsRSa0PV1ToUwx1UTGd+bl87+gVoFJqsIsqKfzruZEifu/EYHef
1fM1m/7d1MFzhHluEpzXOu02ZzvBYPNAacMR5fj1e1BWNCxa41o6WtwmvqlZdmfxIzRMjQD3wBTq
YusiFMmSmWLIMysf2wzWolvYxN4mRr7Xeb4aO9lrMsaYphEn0+rzimgEbaQBPDFIxstPiG2V9GC9
YJStCxO6aQBz3EEXjQyoSwJeiTlMQ78dyNQVKpS+0Kln44rryMzhJvZZBdMxn7MNPzUlBxLoKrVp
dvWiKFNe+3lwiy///Ny7NvO1QS62eX1RZccmfBP1i/H8wDD0DFBxNbXhlaCHBupQ7GLiPIaPoTkP
BSFyJlF5ebUC81oxKWf0Uhlv0jJu4BTuBBR6RrqP5FRCbl1UcgnCEpkNGBIKr50i+ffKOZAT4HhS
PKUVKN5R2yip46XBWcFVxBQQbMd1cLizSfpIzD+nIJ+kK5QaIIwGnlrd2jtvXDi/ShuDoFfkx8Tm
Fb931yLrFO8uAebxGSVtkGgQC9r1XGzLEWYgBZ1JbQKyDVHrxFfIVp1cKAKXktyXU9QAtKfqQ0aO
VI6nyQ/tfnRoafd/JOFCGEkCngRhLFwmtsMGQ2lEx0eWD6UlYRqcmgIiIiV/WN5odAZFl8U60BoX
qtYJU6pmrdV4STZaEJHJ1JRwYpJf7KwKLa3nfrrvmvNMB013ltuDn7hiVwt4BsXAWAB5WkqLFUcB
hBzX1WEIsuhl3gHSQAize6vv7l9VewtpQqONgxw+TSN1fF+KznlyQ0qSEI9cNq9ZWVkP2txubZRg
9GIWt5BoYK9YzyEd7xt6ALiH537Nv4DI80M2JGV1YoeTfCS4URM+pJnPavK4/gxW9iFKtVm1nvTb
YiFmj7Se8FxiX8un9LOEuIHP61W+luWy30G/zLqTsjQ/FJ2j9ouSVDFSlfECdH0S6pvB6EajCCXR
RvlhZvuDpN4PdxUBzDV1//lb212hCWTfM2lRdjLNlnrJpbWs2XezpPuDNzDOlQaeJAgjHsNhoyel
UDzcmw6nFA2iKHB8BjK0DjrKsihRlsY7Cm8p8YjwqPteJv/ae1l3FvVZczNRKzXwJTbuF2cuvHOO
kEvs5cpiwY1AxOM9HEBZXE60J10duWcAKxWi8hQOxQeMq6QBiJ5adk+GLj9aZOQlDLkFd6k1IEJg
6ohQ6wMSohm/GeuRGD72HYvDDYAJ6S2w0dXp0+cuvwkULwlWo9dZgfGGAy3DtbN55++hHowGpiPW
8zN4Iu00OYrmth57jmJ71Z08Yc05TBWtTgm8xuVQp4mc0dgGsNLurn9LAKpEmDYoRRKnkMMp40Od
PFQ5VWi/O9ZCeeaoAwgUr8sPM9hXHjDhSrahBSiMhm3AY7Z+ZTUZwFAMJ5SWvCdMSLhHiPKlOlDs
FihoFQs1zBUFBI0bAsaT6mNgINwgpM5SIhyB3odC8I0MTxPqtxqbQpz1UWRwMu1MM5MMSuR93ZgQ
PIbHWgZYaOi+27rDrhZfhpFQsIQ0t1cjRrAtJACHq6J+5PlPhsKThFNETwnzjU6vlcm4BYq2V3DZ
kT1riZ6fPHKnxF40olK8viwgep2G5qyNH45m0WK6xCj3BioTL9iBnyBL7CKB8NELxhBEETRk+z0+
A3VGM/ETKIPJpdZCLwyP+y3nPXjkPVeIr5qKWFIc4RwX+FAwo4kUTm7bqZbL+sHS+tJCe4wHNwRO
DILtZBHEDuUh1F4C8N8d2AP4fR4zjMG0waEJ5aj5CYispjqbC+k8n5MYOd35XgHybGC8qYcFZzoM
cXd638ndrBSWYJsMdqHZIEzCq/ABdl34vDHwh/72ZtDbaI6hZXXo3HbgVao7RYfDyTg5CnRbqlYK
mrybwwLGoylGyMmlP2fOhV48RvN13IXVS8sI1YNCYIRQkxcLtbx8fq2OD8zDXxXNcv7spXVm6RSa
ZJIqIaZGQHMxUnoUaNKYxIwYVHm6iu+gUxDKc9mn5GrQZDaUtegNuWva7E15JzLvIAPTZVKx/wlI
l6shOhidNhNDQW12RhOALZtypU96gdqLl1HsDoJWHHACt7IGfpZ1BTLoXQqEWWgUSJtw1g+3Gn2C
fSbV1bicMzHMv4MBTjU7nJC0TMg+bSaHgJLXCFtKRRozgbvuKQWeR/8BpaRVOlABJGHrDm7Cck5T
ZCArE0D5W1Gha5pWWJDgizj+zS5C08k7owW7yxZm4s01hpifmZ+GWlz5ae2yGxVh0bUqs5R8PO/G
5Xe7pECyrF0OmpHRDpH1xTxAlKF5FBdtk6KkVH3MU2SDhNTonAOyuAWskqAqjhS4SNANbvrbg24w
IyPivn15/eqy2sFn9EC5y4JGZozgt8vSyGCEvcVnfbSwYPAYiq+wPEmaW/+7C2curL597uK79MQb
Z9bPsZdf+H4XelBfWFhQb7caeb5acknKnCDjK35iCO0RMb6BQnOCEtFxgY6Pp/ggSVBLkq/hiHUj
ICBlsIs5SMcYd0TWIY+E/KQkoGQVdkNhQlcn3UJdh1ZFRKWyPi2+P3yjWEIcT1Gw4Jgxz+CqsnUa
V01VuEkOGlO56axLM2sBwS4LLLo6LgjXqkx0RHZ0uorj7FWoTIuRTt4j00EXoTXEahxOVss59dBT
gIwYUtONTDg0BZV8inkifVOUelrdPuFkGpgcGvkn2R19Z9cfogLqSIYLXRZNsV3gUB6qEzQV7ujJ
IE4y7uzb5y6soTZOhsLQxUcE+Y6AiZWzrogDKrsvFfU4pbDFUwhqpYcP9TBIumAYa7SrvX6IUj0i
+RekU2/JfVLTq+Pj+2oRCWWIYws1Pr1gnVIQyNYTyjGkpknNObNx9d01LKXpJx4k9rr+zhvrq1fO
r109f/kSss2NNdjYzv+DiKhOfiU4F9B5zbllvz7BUBDNRIqdwP7wJDtEZFnQqkQmvI6KCI1DJhjq
GMEnCZYloYasu7Sy0yT9i8iiTrFWsAlt8bIFcgRlSlhrJcnyT8EqCWxCZre/GWoyLFs+xMeXzIiJ
ecgVhyYPZsh4Bp6OB1stISYd2A0hk1Yt1R+r9uyZ9bffuHzmylkyODyPwWQqbmi1kKgJVgJ0hoXP
lB7hhpsl6wmnSEcuQtCP3IIqAlF80YmOrTjuLB/JlLmEuY5jjoQhR2Wtd6U8lTW3wfVxI8oQzVt/
BLitC48yvbBJfCKrWUB4Hj6I5mGShWbdvlUyzFDsjLQjogdxE86VZ1oYCwGeXlGaqGzeeRMBFWz3
ALGVp1JrUqLayB9R7LbzFoNQJnJGXWJPkuG4Z1uzXHPCCHRC5jBi/A0deHoCZcgjzt0UlJdBl3ve
j86vZedl1m6xIc2FunsiufJDBbSUWWeJh7ctH9VOCjEtUicrgL+mBJbi3o/JUrb9wbK7B39TraZx
XvGy17V42ra1uTMTcAeKqBT+wAiRts2BE/YunllbJy9dcmKnAHcbGJPTnd12T/FwzMLv96DjG//w
zvn33LpDn5kJvofxIDVvd9Fmfm0P/pycd/b3DdsoWhbJOZuEeCV8WTcxXvIRl4EC41AhZZEnz8Op
S5HOIEBSrDJ5aURGm/9bAjCjQXLRmXCySgDP9rlV7bTeDkZwpDcO+v1hZ5MmUh7zge4S7zEChN7b
ws3gzXNXV9/eePvcmbMTlGfCOZBVwfGm6n27EjRih78XeVb8CxKQppCHaEA0YuFBhK7NZhKzgvmz
c6iqwXQD/mh57uSWczKcywr/EKTMXly/eCTijDDurJYUK00iMa+QDVROwk8x8+GQtwEFPEUMtZDp
CQt4AzO8mGBxxae0iUIdkrE2ddVVpNpiNpocNzbOou8knHspJUsGQYPo4iQalqWdZNRBv8qoiTxu
CGvYliH3fyiyIauNeDqiQWkhUgANQjTW7xJPykYaDe2WBFMo1mTFQRyREk7p8yMKORUfdisMAon7
h1WHJQCZk90ext+r52qFfaMORejc655lxFPRGDG2a+AxaGwFOkWCMz7E5nyo6niZWA0yuMxwbHEb
OkPGJEvHZ/DLk23xE0uJq1CxvBT1qc3ozoHMdEP7bBT3LNXCnmJOF7nVtjF5tJhXOvhfOH/u0lWS
ezZQj1BXfUJVQhh2N1gcJcVRpEaAl89dgaPduQ0ZmLOOIVfDUeI24rYcl8L4y3t0Tjizdl6/KcJe
JI3+qjH16KM0/J+QDt6oeMPBilkp5kU0HSOAHz4jjAfiMYzdR29Lyr+WoxQTuUa17JwWYZCEp4sM
zEPPa2eBlevqLYqXcxp/r1w36C/GEaF0FHopaqsrj8aus9PxWVu4XMDMS3gJGTAduXfpQSMs0uwJ
J7c54mA7mjFHcNaiwVdpSFXXstwC4gkogYZbnfZIX/Xa49jIrGjq5BcUqxBxwdkggLFz9CdpvUcZ
4aEc04zTaRtMLyZUCwcZNc947GI4kTHTvIdxcHLYP6Uhid4JnYDsFfJwhJZ3UuUyIc0IXR/5C4hK
dkk6wwUeaKpa9iig4PEq3ADbeqEI0vLrpMaOM9CMGT47eiAB4SFQo1+TNmN+4tFRB+bODk/Hw42g
WRDYyLuQnk3HSul4Z5zi9HKR64lnspr9SuWgajl8M6m+jdlm35IY87T1VHf0NZjP51fwlJ1cYcnj
+9v9XVSU41wRK6CSN3UnBqhOq+mnrhnCt+3MOSAKOk4Rf10AORFzhfc1NwQSxgmqkRGu8wLijjX5
4xGcJ0dQdLd7K8t4stU3ZldXUe5aLaRV5uGvNQwVScEqZMpP5xKREtMIlb/CEJIYPn9SRRiaqgmz
RHZTPQCVOBM2KapKYs5Nt6VwlPQJyFBO2jfOvXX+Eh3Hz795fhWESs5Ui4FLRTCucwiPZdJ2gu3B
6BanXnUT7jobsL+wRmDun6iUc5fOJkqeMxKBGmVEPkrDrvRKkeHdMkF+M6/iizB/EHZJDDFSZ+O1
hBKneD3JIrfZGJ3iAZXi7RS9Ooh5Pj23j5NclyotK3yBvrtOlF51WTr9RPlUl9nrx3owU/mVaH0n
s/LFXEXEsjJsWBIcy2Ns9iDa3IrxSDTiDwU9Yz0OCHOvuQnycl8T4fbELuCPouDoBnXCOtoehyNN
aelMINiYydGMcUniC+cTioe6TA9MyJFdTAHUssaoGwLykMQ7xCSaUxGjYYMjx/Lk9uHpkdqoDXo8
HGQClqJBH6Qs6+oyYDJK6ZyaoJXphEXdcD7F40mp22LH0Td7SuBEzzCEOuqHBqIeiNiehj4jq9GR
GNYpNBrSyqRRhSKXDToTZ8LgfafolAoUjNJCI/SqgYM5Jb1aNIXepPeSDe8Hoch7jU8j4ZAimF4R
2hMRUIPOhO/NZsTXAfCo99uEGVzWjx5ZTT2gqgFSlMFmRA2S/DLiCJONCNHJgJifzRsqSMUCcNsp
WhSmMi6lAzOhJb1VrJhdGc/wX4UFFAK86eaUweMPPqcbrlsvgWOibcCdFduBEd4vyUfVtLE0odRc
lMJXre+8maT2ZbB5UsK5s52Wi1m8bGF21dRzUzsqVlDQYpFIDLwetTO+KaP9RC9ky2cyjUq6hZ4z
s3vhaD+bd1bJD5AixFp5G6nCaPmZnDHJ84yWSEnmvEYhbNLBiOyYE4RFLZXozdFncV5bSvMO0HT0
vZjXLTrEuzCfG6rRDtNry+NC4uAS65oMxEYnhuLS4YpVb6JeVe6WJGFQ0KikPkdquoxNkT3FYXhY
RkPJHCMTN50w3CL5CP4yfILOqdHyVagbPunofDt54omgGGmrXXAilujeohDLtyLRTTBNXotJJ5e0
4K3ULyJTvTGRUe38WhQh2BATo7DCUCuW4k7CNrIsDJ2Pxx72RdlxQKMU8aaQ1lIjGsQPVyyjiWmQ
IQxIF5Cxb/QqGHRuVyI8YeaXXS1Mx+w7a7CtE6IOA3VEmq1wiyK4j2EfpCAYxh1D7aKd+OjImuI6
rp/vRN+MwGuobcCB/akpumiHusu4qNbX39ZPcurclnaUspzXzlOcYcR/SqyuDG4tFu72LcQspRRo
PZdNPpMZBwA5IArnLDtOqb77/VHdnfTiLMxgygPq8MInFyJRJlwaK4oSD2wGOXm70+uEWzDqLog+
cYtgcu+WnMLF0adPGWzpPK4AFeKZaCUywEdgVepVEq8s2Q4VyhgKz0sM04XAVzoHcfziwyhsZF0+
5VPtpLPBkhA35c6kHuiosvSDnBl7Xh9dDdcNLZ8ABGeE/FaOpWTLoQO3d9ux3awBGzmhFvHE0Qog
TiNvRRB0OjDJMaF4EKEJSxevZGPHwngsS7WwFUn35ZLNEKlLjCyDpSgR6G4/axYKT2tikGxsLqBR
Bxa1Php2mqO3gXH/PLhFYgcm62YxDP07+FAkiMvlj0iyPxNcnleQczo1WKQS9qw9Uzxogv3VKlC9
lMGaekz6zhv+qLl1ESMC3wrCv5BBMnUILOJPK61TQ7UNNGF/tgrmNAt/D9IWNlhPBwTsRIi2FByb
5JZ8PjoDhYds55OlcqoWJVVRcoaanzVE87xF/8pS+KV0ufuyIJ75FLGbVCkNFr0tQfpZbOdo+4ix
GCacZGhC8WyakJfx4mRJ+WpCQk5gQaynAeFU3N8NURqN5FfaLvxBRwZJxRzdzb7wWoWnJ85QyLSC
2dnEpi1Fg/d6KByczJVD52SuWMXfHn8u0W8vxNuhlAdco1G4yfLQy0ZxUmJNYhBsH1soRNs9QyzJ
9PrC9gBTm8WKRFVnhdxxSkMO7Gvi8Pk315dn594bzalt7rDhSqrBYOlzPmQMSqpoTMG7+10Y1NW3
oAnC3GB5HpdS7IV36QWKskvfr0TYrJhQljLqIY37SfzEg9FhoDZFaCzUi1VCTFLaW/jqlfclEHNh
FnpMDKxPugTZWhpIfAVGAd6oSEgfSuxsbqH5iYRXSeaMrIgZAYlVMSrrxZN/BLTETsclBbX2jHMQ
TDzzlw4d8bnRTobFv2V0R20GXVNRLsiS6kgLZUhqXXwilsxCdvE9vPueG6ly+WTQmnTW1VJmi8LN
ZanxSuiMALYk9dMCtoKlpWJWcJj25SKMTK50slHWy8PQLLoqmII6GKCWVks8EakPTMxKOPqwG2aj
aTORKdi5D4fb4r4alZ9NF1WDTVewLX5oNYLD/gVTRW1wPpQ0ca3Tum4BcKzqwQRNlfyQ40XVZSY9
OiqhkjtuQ1ChGVHkgHWVn+E3OLknZ0GK5yrgKTgqYFSoYOPuoAZ61J3sS9N0zTsGzGea0E96iqYX
AIBBNVE4g79tEWaaqVoQaxDDKL6xoY+0xG014iOd0hRuKYEipcO9Pe6hPeyhgppGmYQmMUFjqzDO
YBalgNTGgSgnkF80Dke14EaRH+t8ApoXwe6MdDfChwgHYOoKSvhrnUJPKmWqEBymLqOMv64I0jxa
/wr4C8O+KqliCmOztksI7thMIFKKWQz1sIGqlJQQRvjjmU8lIX/4U4oXZeL+8KccPSJjMKm1Gnu0
8KHrZtXqtABdps6jlAp9UURJ+j4EnuKytSMop1i5ppCQsUR/MZfxBIyNqTRXa7hleoWn+/rMwz0n
ozFEtDLlhAApLUi591NSAOazyIVl9qbVt/bFG+xCQfu8vHdlX0uAwPezPx63ECN+NC4RudZLTvFS
WIRgDvP2MK9H4xlrcOrelo4zzgKqw8nfJWpkGPddmbqCCv4S0RUyElKgA/UF9q5N0T2wVga9T4+u
qepsT/zgpUUB8Qn1izVqjoSoJuuY/PUVck87WjrGPK1w6RjvtECmY6zTBp3Gn4rxSBJBjT9VkwPH
TE7xpxftT5MJO/Zozay8lzIYr4yt09H8+Zk6vX4I+1YDoE4Jp0wWmEk9S8bYYTb1oC1Z4CTYopNB
rZ1Q6gtt8rw82AvIXGd0RHjcRYwoo9tFZe1tmTEz2ZCjsU7hlSHKNU+Kf1GC0oSDYmy9G4fO9CWv
nxpf/Xp5AfnfMZ8A7SELLy/HfAF+FisV+gs/8b/0uVgpepVSqVym64uLpcWfOJWf/Ag/Y2SnjvOT
v9KfaP4bsFcs/GXMf7FQrXrH8/8K5h9j893Mb422uy94/qvlctr8L1YWF2Pz71XhklM4nv+X/nP6
b1r95ujWIHBw0ldmTuMfjAC4uey2fddpdYbL7nDUdfFW4LfgD+n7MMVCGIyW3fGonau58jKBI92d
TrDLhk4MLYDBHt3dTmu0tcyhgXL0BQNBdkYdv5sLQcILlotYCOUYXtnbwygM+/unF/j7zOlwdAv/
Ok4dsQ3OHgYP26yfaC+2q+3SKYTEwDERvrfb+AUxFPUTxbZX8mr4fRtOX3C30q5WFwt4gYD1J4Jy
4LWa+B1F/R684kFxlYCNPj/bDlod38kMhkE7GIa5Zr/bH+Y4ajYe8Ic3pIhqtqlYLdaKjahNxcAD
0o6aFdSCalDSmuUX/LLvR83ymqVCqaI3q9pslv0aNwv/fw0qA7k3F3Y+gMN8HT4PW8EwB5f4mUa/
dQsegUPAZqdXhx5jRqXNIXrw1Hf8YQYbmj3lUI/EBWwbXGrDfOXa/nane6vu/ML/oINev7155/yV
M5fW/R4ckq/6W3C4ncckKZv9wHnnvDvvhHAnB4JkB0Yf+5DbCjqbW6N6Mb/EDcrvDv0BtegmT37d
WawWBjdPyTaCwITIolMgQ7Za1KdybXDTKVbhV7U8EP1CAgRxaQ/zHwDXulVvdwO45Xc7m71cB1hZ
WMcBQ/z3pj+o49uyBhic0ai/XS8XZGF54Hd9KIvbU6FnRbv5ixjVod/qjMN6kVqRGEieIjWYTIGy
eZvDDhw44CPQvNk8GmeYvqDuUV30fZdrXyygwzL0rI6Z60XPi8Z8xl/XBmdgPKhPMZFblh/u+TuJ
YYwPWT3nwWDBzJQ81USqs6gmBIvxoSC9GjUiSFK5VtDsD30Kdqf1xoN3tPJqWqVlrrPoqXkaIGZw
Lzn0uLyycprqRXgt7Hc7LYfvIh1mE5NIpUoaw3odr5AkknjlWyVtUKFx5dh4VM3HKaPznnXstZdK
5kvavNVoBCbMXn7kw7HeNn86xcOpuF6k3uH9HC7BOv7SywjhzGbOhReR/nRjurS0ZAwqLluqNa31
beCWtIq1dpZrWhnccn0N0gV7Y6Yd5VQy3Z85vSC2l9MLYotDBgp/Wp0dp9mlmJA4cC5uQKd5na0Q
59efQHbirnz/m385vQBXo/sr4vh2equobWzwRV4fwOWrZ966cP4S3RmIV2Up3Ciu8TQsuJXTvrM1
xIhtJ5BwQnfl6e2ndw6eHNx/+un3//zZ008P7p5e8LWn/AamTVw5eHDw8ODewd2Dh08/dZ5+8vS2
+RSFUm7ic/effgJPPabbC1jhDHXbIyO8qPLgPjzyiCqEjw+fffb0tmNpxpZHrUZnlGY3kCOFZbii
l1ulFXjnIbz5jXPwAP6IFsK7JfEILqeVp98e3H322bPPDh45e3vvnjtzhaWD7UA8NFiBN785eOBg
u6B70Nv7ohkOtPCrp59AGz9xvoNBePoRdtGozTm4h62H4h/Dq792vvsd3IMuwuufOQeP4aEHOGh3
HLjwEH5REZ/mHWzT09s4CJ9DPU9/CSMM5WEbHh/cxxo+wtH57jYNyTMo6hsY+DvYFpoBh+p/cvAg
H027RlG4Qt2V07hGV2iIHkHjaGzoEt9Qo35bXo4IR4z7NHPwGPr33e9oWu9B62AAYFDuQn3Q+acf
OwdfQi13n96GLn0Snxp+CXuMT6RNz9OPcOzwKS5ejC/Pl6xZzBhONDfh6W2YMXgM5+shTuU9bieO
MkwHjAg06bsHPLR3Dv6I9x5CI+EqzhwMrwOjfxvp4nMY8Y/lRMQbQPMK72Jlnxw+G7K95kx8AgQI
1PXssx8yE0CDQG3YEJxVID6goYfc74MnuDKffpyYgHs4aPBU2sr4nAlYdP02lgHdf3xAVAjlfgUD
9QUPNFLmHefZZ9/9jh7EgcWm/AeO2G0mbqTEBwdf4mTjGpDj+w0MymN8WVx4+i105Qk+g7XjXDzk
8mSPcLk++2wK0qcXjKHmyn7IMEPnvoZ+QDu+ofG+r9OgRu23me6QDnGkHhC/SC6BR7RSJi4AXsE4
APeQz+DcfgUd+4J5zD1kR1gbsY6D3+Ng49gixzOXBPz6BGeHCJ3HO/kQrLZfHnwNd+HPfe6CZH1T
DLgYEmPI4yRvGXRtm7DsOUx9vPGIfQEGhRgocU9JUdEC/e429JP55APiqvQsMFT8LUfq106yktiI
IL9FzqI4vGBvD2gR3Id1dpfroLnl8cHmCUEF+6N2xz//Ts2vI3dz5/t//u/cOtxkPq7DjXMXz5y/
gCTAZaBoQeN1ekGIFgt83P5L0//gIZ7iQP/kx9P/FAteJa7/qRSKx/qfH+MHNRguaVncuuOiRPT0
44O73wG/fgIL8qtnn7nz6omNoIcPrQVDIBCMzAIUw7dbgQqBGS9GE54UW73LO3NCYETmePfgS1ik
vLsL/ugkRNdEraJp6x0MVDBP8FxMkEhNZH+VYYDyvsPyK72OSi58qe3zdz4R4BWhB5K1UKz4EG6w
usfFVY+PmVt11AfVQnhWCPb4OHI54kdqK4xkNxsTEwz3QG2ZKbyemyG5HApDxMZkC4gVYf2YPrL/
My2Yg3xi7e3L3EKX9Ev7Mz85/vnr0/8jAMnv3XoJJqCj23+K5ULl2P7zaub/xZuAJu//XsFL7P+l
cqF0vP8f238Otf802j6bfGz2n0axUipohpZqo1qplTX7TzOotRfJ0FKsn1hslnzEB8E3r36i1fAW
FxePYAmKtazQLjSKLc0KVCuWuDHCCtQMltq6ccovLzWbmnHK871SGRtgs/j8xRt8Im1rp7cFz40m
mQOS1qFiUVfL1+PGoYKjqdwR/DWNRei/wUrvtG/lBEnW4RgLpNgIRrtB0IsZBQrCGuKlas8xdVFr
ektUIW7kqRUMM05xSfUH+nxDmaVKulmqZDNLFWJmKZwOf5jbxPvQgkyxVGkFm/NCae4Xs+qjl81q
Q5hmEfKsxh+r1t06TqOeVmynR9QCUnnzxg9ptW5sUxOHhiPPswyRtQfCxFEwl4Ci1uYYDjnD+qDf
4VmUnclvbiXMUSOgBaCmITTcusYmW1OoZKi1r40TGw7xd05u0Mh1xts96E6+2B46+aW2oC22aNoo
T44MmjPRahWZPqk6silGw9LswsEg4wH5zzvlfHlnF/7Ai9n4Ci+f0k1hkS1QFRpsq3KRa8NCB57S
/SHTDYumcaMzykUloLP/oI7jq5erX+V5MKYmauUgxTyndcxLN/JREXm/iWzMboabYHZD7O6e44eD
oDnKESusFxeKcZr1arFljddhq1Qj1uwMUbnpj5xS4ST+P++c8BdrsB/OO1qnnUrlJAxm+tuLlZPO
Ir3dLi96jWrs7QK+nTZbJ0pFL6gV4UOtVKyVSzCAcLzuEHcfBkC0nR3g8Oic3u72d+sc++EU72Nb
fgsuFaDlaOHHX8PNhp8peuX5Sm3eKy3O571KVhuzPO6j6Mgra/AbsJjGmAdJHyYsxKtU5uX/+WI5
y0+0hv0BhsSEpVFvdMfDTI2IO7E4k0VQQ2I8pRpxwRgbKgvcQoqxl/uCS4+Mmt7JU86QV1bhJO72
4gGPNny2RpfhRjdoxx8piTLKVVVGiR6Q1TQ02hQsVwMOeAYQwk7HTIbxnVOBGGL0nWqK1YENfdh2
O6Nb9fxiNGYCZ8CrphuMoPQcbs/CnszNDANacEgCkq/pr+mPrDDCgCQOYoypuAttwVeTpQzy4bhh
L+gQ7lGKeC1y8SlZ+zAYBP6IYuwApY7mMRQFCEUZD1n3vAN8H7khMZiI7YY7zReFjtCN8IJAiBvw
gqOPmAfAyXsgF0bLGL9HjalvUTiKPUc9z29iT9/N5Mpi1Wk8gJZMSfGAamG+VJgHCRAWbyGr9bKT
GEYbtIYFp7IuOJWraVLBixFBLJudRmiTASbYsTi+JM49Fo2nD0f42KA6ecaahz+QFIs1Oyk+/0DG
Nj4DoVMqxNmsZSlqMJJKIdHdiUxQW6bCwjOtEAYiWFFKYLxuWELs33yJi1FV0ekNxjAn9BlHBHZr
X50ZigXcBY5UV8FA8OBKjITmSCae+lAZI3Y1yDbkT2VKnI8+Ek5hOtyPhVj083x03qzhIsVDPMl2
8zo1pM6/2on1g2vZem7V52X/yIAj3UrbH0gbti+v0UnUFTCeBWHDlTfxMAmX2GYbqVV8UYgJJ5K5
FdyVgy8R6HFwF23Ah0OJ4oCjSVCiWNtHPTf5FpZOpiKykkMRaKC9w8gXn23OZEyNDQ5OnWvHXZEV
6ksytJwOtlcOfkuWZAWJQBzCwefPPiMD/senF+ARNL88ZkDKHYE3YfhFOnQrz1CSg68JBfQFIymg
TjQyf4NWrPto+KJOKaQQQoq+RRMQVH4PbWPw9zMNa0FVIjqFcDM6NMXsuziMuCv2sY1mVozmp2ST
S0xz9KqzyZmoppl4De9mQt9U64YSemFeJ5G+WYRWN1aeffPsm6e/h99/egqtaWBVaJt/ePAY5+Db
gz+gWYvgIwikQDu+Qpnpk50ovUSlv/7s0bOvnv0BC4ayoIDvfsWmxDuIlDikCI8b+OjZk4VnX4si
jClDuMVthP0kByL6EIMKKrTFmStXzxhIi0uXf3H+knFl7cyV9fNnzGtnz1w9v25cuXJ5/e3ooWiJ
SHkWcQwRIQgkjKetdTGjDM5A6pbtxVAtSDkIobqDtIwYmbtso7yLsCpB+VpJNCAa6OchwtySi8qK
RUGWa6UXkH5g1Dor33/2q9MLnRUCrkXrC9bMw6efUNOefnTwiIuHRxBmYqxJQiZJRBSxhkdMWHcJ
X3XbsEffP/gC+3Pn4B69+gmDBhHnIYzYnyCoDytjy+8vqWydaGnNppKY6tOvPlJ9eoSvSZ7lkBH4
IZKX6MxDXMDcz9tkfX5EXAOxXPDlc7h/n9pKmCV87oFoHq8dXLzY8DvJtcQGeKptylb/+p5qNVIC
8q/7iB24h6Zp1WKonhrJ4MLoSW73twg3Q8aC3aHVhC2hpiL2kHkkXnnCwM67CKFEzvopMe4H2PIp
m/v/3okI5+CLpx/zPD5galDNZYv+PRwqLp2mlip7yM0mW/wDJrKDJ5rp/1O06GP3JBRVFq6NMFEc
k9qUzf7Nv6tmR5QMPficRk0iIpNkAle+jirWn3JoPu4pOmCQhgCYyccELsoGk7otQKuHt/3fHsu2
J9mmhUhl8+UWyeOX2CV58clhJAKBRn5JAAgkaR6fPxIiiwC6T7CD8San7Ffi7GDwIN5FHj57RJuT
QMWqGeCCouf+JPYa3G3vy7WnZl1uFdHzT9Tz9xF2c/CV+cCzJ7wlMp6Y4XAwTU+QQu27jmD6yR1A
7OQR+9e3dA2fbt8EWAphNvGIOA6xoMfEij5Tsg/PyR1NdqMrDLtjgoVyPiJmQUAfWtUEVbzHz8fp
bHKnlOwYdUvw5rsCOygkUYG4Rq6R2kdB/09IBnvMXVEFIfqS5wAHgHCyDOwUywapWtCiROQg4en9
iIkYRtPNe3C8U9dJ2gRS0HCGSBM61nCQePb+049xJ5ZPEtDH/iRS5ze0dct+8Es0DPek9Podo3kf
yqsw5c++4VuwNL7WhVODL5DWSOuUA7LquLHdGS27wQ6czPKDIf09y1irDHoPbXXC/PvjYHhrPejC
VPeHmbnGGA6UvblsHg92q8K0PMfbOe4ILC0f/B4mmTahB873v/nXuVP6GNLJmfVGW/1uCxOG4TzD
28SMuBxGouIBhLDlmJz0/XFnGLQmFxRNDWGyRHvYv0DQn7UodYLnmJolN9Y+s394nJNvaIXw2BjC
P5r1iaZhoF3ehJlvyRJhhumtaNJwotJ5iQSxClBrOhaWest84ounv0QUMi6hL4AW7xz8SZyB8jo4
9i8MFfvXjP958RDgQ/G/1Tj+q+R5x/ifV4D/RVcsxJ3S+Y03YhsC+GrQ3HIEvVgBwMhn5EmACpQC
W+Qjo50WUXD4LbNKOsZImUlKEerAo85kgpmmoIBXuWUOhezkUPni2DvvSLUwojfk1nsYGpiRQYeh
gWnH+K2SdaTcz+LAQ9HaGCKYOsYbrjxAJA+xQpFkPxRGR+zE2RpLTICAMWDVRAzwsz88e/TsYQ4k
WJBho3/H0OD/3fk/JsTGgLEvHgD8HPjfSrl6jP99RfP/wgHAh+B/K16pFN//K5XC8f7/V4//dT50
DNf4w9DA5Xa13UhDA5eLvufraODaYqGmhV0JSsFiu2BEg6lUS0EjuuLVTxSqjWqLIMT9GxjqxS+V
/R8WLqbQKnpeQQMKV4pNL9CAwtVgqe1p7V7y/VJDDxdT9lrlst7uSqPW5K6rdnteqxQE/xUjyNRe
EKC4MC2gWAWZmR7SwKEkzK+pOFU2YDtLGlTBAr19DgTzj4tY9qL2c8nhzmYEWy7rsOWy0dNx1w6Z
JLwDBkBUSBqczogC1Vwl8S0KU7ZUSem8wNdORo+UyxaAbDosRwBmywSYRbhsieGyJsw06kDUSgnm
AZqCg5ROp9WyTqaIUSNKRcCDOWQacTJ52aIVySETEAsdclUwIFeFefyXLyrEpWgaK7n2OBpRUQdN
98cjYj+FOEjERJHEsUEWqLTizNswDTwKBbMVQrW1p1U/XRwme8sKdpQ4Q40ssG8K5WxgVnKVCAyM
obp/MKiqmgBVeUYFLwpTZFAFszzLkjAopSpiJAlcLGHzqkArhWpWb+AUWNOU6DuyBBGKaOqoSc2t
zsCOWq3ZeKBcUhxcScPFYTkRbaWN48TRTwmFVFVI4DhZmYQ5yblC7KqqpXleCFORv2hc+rhTopIE
6SruT8/g1jAleXPItvZQbK4RONC2ybwEeo6Q19zyJo2VAGbVdDxoLQ0Peji8NIH7THHoqZkjaEA8
U/wKSIKebgVY9s9y6s7f6tpIpn/DSi7EXSegA5cMePsEIo6R/HRiBxW8uwU3CACOUgB3ZIKwB93T
ZY+ijvzVRpezWE4N5jYhqLL1UbXS/DhNLLuI2bSB/4+HwQ/dMDxvwoYh6ng5e0YtUY2F88dCLiZe
eT4E84tDjzql1AB1tq1GVCxPFSYl/zChfNT3iQUrr5Z25yY6oYqh84RHRHtUryB41AKp/4dMDr10
HA1jT86T5qZ1olgs1rzFFJcVT8VBtPFEuwtAKUzBmVOX8iFm19ibssES5Z8E5laqEpgr9qGUnafA
Ow9hck2+X9D5Pm9rgiNSUVxCvegsOLliuqvLRNSuFp/PBuCNYUv8ncjWnwrijey6yNpQn/JG/+ay
y45p8J/rtDvdLpQG/Mh1wtGwfyOgPNMoWa/iHMurPJDLLoIYKWNUa9m9WPSc0k7R24bycuVcebvs
wL9c+WLZKS7ueL7neBiAEitzvK2icSHn7eQ8dwExxTubUTulykZZkpVt+vS4u3K624nwwdC9KLLL
Xfj4MeJhEEeKT+lPngj77dEunBYwxqEF3Gd9R7JYVwDlnt6OgKqJh1OgyvjMArR7EkhIgxvL4I6a
qsoACUfRve5jYJxnnx38hxnzi8Ja/YnsRL9GDNknFMKLYYYqiiEaeh4ePBa4qY/QtMYo3icSynjX
hJnEgBd8mnIFDhQ/vwl3k+AIvP++Qg+Il6yIieSciCh9n6OBn0xRB58jUu53BPd78P0//7tLwiHa
DrvBCMrvt9tuEsUQQy6YxU2JWhDxtuTinDlN57hJ6Ho6ylmWLF5nCPDDZ4+efv7siYR3ibh/H0k8
KBsxZaA4IDwMs/cgHjEtrfBHT3//7LHDABL4/w4GSpN16OWJQGgESoqCQR5W+kMHoSwY5I/iz93X
yn4Mk/YNxRpkeOjUDVaAaDEQMYxeMlScDbZP5zhBlWq5z1gwLXRQ6/dcp+WPfBBlRsuu3+0Ca6D1
YlKF5VX9vd1OD967I7wA7hw8OtLbwKqHfYQoCwAuY2gfHKmMbb+JkOrvfnekt0CaGd+E95A+bpOd
9/GR3t/EXM6EjUNzsv6qfW4oDzFNDX1asaLZSbDmp/jjCqGkHzKWF6FGDyjYlwh0asWlR0xbIfi+
u028RG4sB/+mAfa02mNvWm+6DJxjxOJtjDyJfOoxLjWi3sEKx3WlYUVEHwHetOhj2toT70k85222
8QukH4fGZBZO0S/h7d8efKkC5CIsUMRC07aE/6DAtofgxI2uRFuBjqU2+iKZEofhFFhk3mieMKfW
g6P+Fm9wlMQ7Anr92NhxRAcRcfpg+obKHmsA6V8iWWgjD+PzEAGZDL9LPk37pR49FHvynUK0Ewr4
MQfUpL0oUc9RWotvYDfvsWNJQ6LBNdaLw6jB6GWA1C9lMyncMAoeHxE4NFZmKgDZQNnhToU7li0A
5QQpk7htKihPiBUTAXlUglZYnKNroS2dP3+tI0rlm2rfVdg+w33Nl/yEPyo3ldOM4cES4DyGwi2c
kZeda5xK2F3M/SMwsnmHGDf88cr5Qg0/FPNV5+Ib+An25ifP/vDsqwX49Sf89Qivnii2q+2ggR+3
RqNBWF9Y2N3dzS/mPkBV2nBTWb3J3u1enxcV/uLCqnORDiNrcNQLhlrdpXwh7xXxU9mz1P31AuyL
f6K620uLpWI1XvdOpxX0u36Pqt/pNheiWi/BkMGh7PXXtepq+cU81VbJF9Oq+4qq87xmBYMWRtX1
uLzcoDsO6ZfR5VCr+WrQDTaH/rZzNghvoJdh1IBKvpovUXdraUP9kOovBH4lWNLrb3Fh+ZEonaqP
Kr3QaQyDy+12p0mt5s2NZ7eW92isvYK9zw+ffcPTW27U/MQQd7HgPhVs9Fh9yGlPaA166/zFNbMl
+WIhXyJK85ZSm8KUVmtUmu1EUzY724PUUX+zA6eQPtWE8gDSc6mYL9CHcmEyYQftMvzEq9vufwDn
Qp9qbHPpC71gV6vzF51w7Hed9dG41ek7q/1WoFefX6owtRWXKvbuPn72B6q/1Kh5ZncxByVQNxYf
UumIL1s4K/odtWC9s9nzu/imFKTg42IeZp3mvJq6qr5mMiervF5xSAWaM60tqmB3rTMIYvXBGl7k
+oqpy4oHutX0qp7RURjQAZSY7wUjrZ6f55aci34n3jFByUv5chr58OptV5aCgtGtG0uwD3Tz/mCg
1bI+HgTDq+ObP0efSniYJDqaOaKFas1GNn+Mpq1YaCzVisboYYmj8c0bUCJ1KTljBedM/mxerw6H
TxCM85atPjgbUH1+rVJpL+r1oe6sAAwXicMyXRc7vdY4HA1vGb0r0wQUqym9eyg4blAstso1vTa/
N74R5Duj5la+01/YVoVfh+qunxLbDcjGsNnQaWKes7cvO61+c7yNrgmbwehcN8CPb9w638qwJJzF
V9vjHkuww6AHZ0yVshKLfH9SEe+72fyO3x0H+dGws53J5kf9C/3dYLjqh0EmO+/04OUC5wCkjICd
Xi8Yvn314gVspXtKJEWHLTIPJ99zfnMro5qSactWUOrLTAb79jfLoneYLbh9rXidrsCdLKYIzrzP
lwvXzXbkCQh2uZ15P+ucdgpZmdxQJifsvf66/Ig9Drp6l5tDEKwC0euMC7s8jxknG86TQHAJc+1C
y1C152o39e7O6fIDavakzMCuUegrRg5j2lNoRpHOtYaDrPULF0a/55zXlSZiLtLNtWDcRv5wE9FO
Gw3YuW+gFwcp3/qDAJqKlb0oLR0sY1NPV94pFhN6uorjFbaKZaWGM9UN/sqcNpqmD41L6lGgP9Jl
5iMVMYx1+1rl+uEvar439E7hOvyX/tpWyfqOTjnbcC3+4pluF6okixjOU0Q820SnRnmuOli5zutQ
unf9FDxWTDx28AV6MIuHSvSQdz3RtvKkMQBayOZRd0iPVg99lBBrVLd+iuAWFK7DH1cdKQRgXpwv
1XogBgB7ALCY1a1Ot5UJumIs9sXfVDbDp3E51cJsAY3pOT91BE3WHZdsNlQdKm9VYZbZIG1C1sJz
mpLnNPP9XrPbad7A4VG3I470XKWT/v8ms4wLOBqcfzXjIjmeUsOAtUfP+K2WfIC5ezOPapAwANbk
j04pli2GkrpPX1JHU1OZZvPSf83oZ4ANDSy+bKoyrmjivtDvsRZ2Wbwl96jRyNhy6PyUGWGNSeYb
L5cPW1nMcRwjd8p7HB82tN3QwHWhy1c720F/DFVRSi98B8ZQXjTm2CxJTpIsbH/e8aoFaemJhh8Y
mDj6HXuB/WXgv1+4A9jh/l+J+M+lxeP8D6/C/8vQdT3mbCtJ/y95QnDYPGrPAfEJeX49MtWnVpPR
vaTJ6IDUao9FbogoMsQdUtJyXCDTPpbmDPYmyMkL0rDgSCI3fMMIZEgOYbAQNvvDTjBFhghxCp3s
E6b3XeYHsvmBGUP0CUcIonxlHPvioTLRWMZP5LmiGCaoWL779FscI/SwRzfthAcYnPcQmz+VE9hD
+PMYTlpfPfvjs6/hjHXsBPa/L//HeE+d3uZfSP6H4nH+71c0/z96/oeil/T/LheP/b+O/b+cDx2K
N/JYhIkRdjctItYhHmGFarFQ1PJDFJpF38jCsNgusKeUcK6qBX6pqaWIKPpes0zOVn5dGDhkhohq
qVptF6UrGBtfTv3XStZQixpUrzcCOHpz3mLGvrnuqQQusdODSY+1OR5cvIquVk6ZfsPRu1Y56eSK
GGKcI3yX54vVyrxXKlFgbSPeuCVSecUsTMY6p6KWluaLBW/eKxehqFhJ2HRCHufoMB6+iHQTluDm
R3dNs6WrOARDOim2/xHTVeiI9SWbQ9d0MO1azPerE3l+6XjLkgVTWjtatOBYsGB7IonDk1hMg/dN
B9BzEovnbvRUIHsvEYLXKzw/yt4yPukucMpfpaCBo7VMB4NOt5uexOP5U4WXlYdYHHWdHl1dBRWu
Tp3MooK+eRWGROuZKxhbbTDEUiVWpnBKmmLqT5RqjVa7hmkYKo1yu/njpq1Q/oMWRuZ40Vi1+sqb
zYBYJ3hfilfVi/coSLQt4XOY4j1o9UVM2TSTToA1FeMaJBxG3tS7o6HhD4e4e5tb4shvhIfy8AS7
FAMskhZ46RlCoPij+KOlZp+R1HG4j1rt6IxGtjTFH02Mvd4cEmroNRi1XvgyUyJgBS/I/cUznJ84
KYw58TSHERFxwxNOOdik/BaJpja3vHhKBGJQ0L5oQ2GSIT6WFKTIcTdFPFFV1+t+mx1olISHGDCK
c0pZr+8zTlEX+6IkK+T3yh3iXCNewcoQfGtuBCIki9dtjBo9tSqjeUz3nKuZD+YHQzhckD+SJtXY
Hzqqsym9S57r03moTyNqJN0uq2Z93Y5NKv/+N//quGYN5MqXcEbUOs0CjOY3xUw+JT4++Wn94AVa
si9QrRHVguEZdjjTm5QgIU6NIp3QvFedL9fm88pbmWo6os/aczqspSWhESUtGjtBLDEN2WLhRN3p
hi/Hka+sGH9atoZwvA238Khqc182kvrorT0ktxb7XxfSXfqqhSO69JVZai1P69J3dP+9lL365aZx
QBekzqE5G2gvRfcljqunwNNmRgbNJ+ouOh1wFu54doe2/76L3iD/PwYJlQHh74uA2x+/iBwPorUE
niYT0z2O204BrRNxrKfP9SAv40nFXfn+f/x/nNIB82cLI5ZztQOEdv78ecQtH/z26bd4k0wsKvHA
N5h4IEJmbxVXCMT/SIWcjtxl4PI3BxJ8rwUof8B+aYwsagxXokzfYouN4iKauSTMTBLWQMEsHiNh
JCPP3uqPh6h6I2POii0WrMBlAO1hXF0jfi4HSFbpFgQanELnuoarwQPur+Zrc4hrDwrKDPcWE2/z
UUFxV3n1QAML6NEjlX7TOrpAIVEJRaJiVhVi1oKkt8vk9z3t/UjVmPCViZEe9VB19oLuLzOT9DkQ
j8b9XmJPsVsCh1x+4Fz6xcVAOSVQJG0R4/2hI4lSiHEMKlpfPyvSE+D6NbwoKOD3dw8O/iADTH7E
sT4VECnhqGBrGUb5R3ujCIHNuROkF4pydjF8CBzK7PJAplShmKCJPAWI7hRlWmK221qCQd/RGw5e
Xl+/4HA3vyOzqhyxr8jT66FIysLR/B+YzdFKiVaucJtQxC8Y7FTNIvkaLbV/AmI+e7a/LgfnI7Rc
S4H7uwcxn5FP0GXo4B5HHIfn7rGXJ+VUMOvVCAykDaKoQ5g4+1CdFrv1ymmxy7MvGyamocD2ik+R
05RcjgfsQfjQGF/BL9A/S5ZFLq9PP6b44KnR1PX6VB6RuNMrTpbk5Oi2+Fg4mJr1Q0mfs0eqJeI6
DJHoa1q/xYboUEOpSUaeGUdAEh6ImPTwO9ZXmib0uoryEWgeXlDg1wffaE5U94nKyCOWHdLuskta
VCN3Upj42X/rAZLllF3ClaMnpfhWpFHAwLHf3Wb8RKwPxjPoDobEQ15rvEZ5FYjJvK/F4v3m4I/Y
2Sc8RZQXg2L7Q61IcPH2zpBTctKtKd15yUDtwohQ5w5xRNJDi7M/kulfxBoI5V90zeX9++mnhC0H
UQCnk9AVcOGa++wr4TxLLJjx52qN4NeYyxclkvmC+M0DvB1nSe7161gsPCJFNrwncO3fPPtDrPZH
cCVe/1dm/TZGTDeikPQ8t8AG7x58BZWJJhhZKajkx5YW/DHZAsUikt09vxavDC4mEnj84vwaNELi
/q+5v1hbzxVFC54kWvBQJMECIlxde4ceeySbhJAYuvLEMlAPHaoHC8EayBkD+vMoOcrJGp4kavhT
sgagc2Q2clslf0rlba3VXObmgKj50HDy5tqfJGv/U6L2h9aJIBn36bec5AQYvjGqq93+uOWsyxlD
EBFusH+kmM5YszVlkZgwjSOod6kksRdhDO+vYNbFFJ9ZOy/6y7VejNeKcCJZr9Zje28vIEzrDR9W
apP97+LFX4gX/4h8QkTxfzKLh6GLV0Aby2N090WG/EiKTxRNgVbthTM4lNJRRGFdEdGauaE7e2Aa
xgnwWyUPspbP6s5BHOnajesW/PNg3ulEEGqsr3Wop4XTMl0ssHhEnWc6zvLyslNEBLiz1R8RAjwC
17divhc29wpSoJF0QwlCxKHoPuZkoq1vwRaYgIKAYESNw3L/PUYJAOUFw42hNYVXwQC9CpJPNiwP
FhVuf4AeAHYnGhrpbmfCUHc7LmVHj7sQWFoxRmcAHcXf7RjQdSQL/XbLwPgfBszH04sNOT+SZDNK
w+U/V7GHA/KhQisUn5bO6yMFxb8hIfHcT7pdOAaFv1L81yvI/1HxEvk/Ssf471eA/5YnPXEqtWGu
kmjwt5lwjpYQxInp1mTkBFOLKXRskcJSNMl+uE2DgMsGLsDWg4LDYNhHJ/wh47/5LIAoljfP/N2h
uG/p5H4I7psG6+C32G0L3jvSb2nY7oMoP6OmtWJId5Tr464lE94T/sgHiYcsyyRh3343CKcCfT9h
Ke0488dfF//vbXZ6NxdeRh3Pgf8uVI/x369k/l88+vvw/b9YXozv/zT/x/v/j4H/Pnt59eq7a+d0
/HeE9WZ89d8HXdgwAmfUd4hK/iYBvCbUuLD7qqQXXTQQU+oLtJYK2DNDqZxSJdhWNmFHoM5mDICz
xDL/Ihi2/B58ODPs+F0TzzwpKmfR1m40uJ0erJxvO7f6YycMAko06Qz8zWAePgb8oLMbNChpGKop
QyccgwAQhu1xt3sLIdAjv9sNWigzzOz2hzdAtsg7b46H8PoQcRrtzuaYgb/4skz4yHEZsfI3+0On
TyBKdfzipymNArtngVgSwBHJoWwi0IEZZXrFyBYYhATbyQF1VtRnPDTnTzeGCyszq/3t7WDYhBFT
RUJj/B2/0/Ub3cDxRylFYlwOWSR85iJl008H2ytXt/zeDRo+OBo64xBFK3789ALcpmePj23/Rfn/
iz/9Hcr/0Ukjxv+9xcKx/88rOP+pmIccNRBPYR/B6eSPvL6TRz9mluIcREzU7gv8qdANqvL//PsE
b/7zfx78WmUi1+CIbEtjyxmfjyhbtLqNcXPR+JZ2+rsKTB1IvNNz5hJ1zmltloc+eCtx6CssVUuH
HvosB73EKSxx6HrVp6to/eMW0e53O/0XfgZ4Dvl/sVI+lv9f1fy/6DPAZP5frJQLCfl/sXrM/4/9
Pzlu6W3CL7F6K8pse7jvZwP+tY3EepViM/L9bHvwr6In1mssNfyGllivCv/awvez3Vgs1irTpPqj
Uw9aSGLJCX38l5acsAr/Wnpywka1sagnJ6zBv4DzEPwXcjBdSvW4LNSmzcf3St0rOV/IZBjwC/M9
1N30Yj555YLFY8CKxyePL0qFQZXX0vIvUWVwHETup1LneLr3ZtGWEoTSkGj0BGPaaUbecO1hf9uB
F9kljhcNfqDglvCBg6SqW1nDGdBsFJqcVcMKWK1sF32Z3CyNzA9P6RTNw8QMgKcm+ReWJ+T+q3IW
oOoUdLAYpVHxN4+Q3Sx6RXosPr9bZulIbpnsJNHpjjCremp7Zfa1gjYU1j7IkqKcf5Pd/1I6eGQ/
uMpzprWyNDotRVv2VJrrl+4vRQVuooKJXS/Esi5h9DQxB3AhF/N4QzUUVjoM/Bu5Ti/stIK6v9NH
io+5d5QtaX5oivo7wbDd7e/WtzqtFvJFiz+ZtfdUd76zvRlbrjEHG3saoUqolVLfwkbIsqLcQSQg
ZIr5Qjlr1NmkXcXirMZhCjhzJnubKDZTEBOdzE0Z9+zVyG3eSJO5WIl7dcvUngWjm5QjKdE5brR8
oyhz+8FVi1eSuieWdXxFqpyitYlZyTgBo2RHYhFGnnHhjU63+xJykpXNGl6UI1M1mcVS5s8jZyKx
T1St/omTOGBiCWhuSbVYNZ3kZJn7UzphLdm3x7RWMQ1QakBzBhNBBDzDxauUmt9zCm/2RlD0Sk34
sNgs+cQ+E0wKm2Q4ZyZT5HplowN+ahQBbaAT65KrlMlii8V4mIRyWuIyq5uacjnTE/w5helcx1Ic
JiflLRPynH0tkZxmK1QTzWIi8r4SDZ4rV9lUrmmnG5rfWWMl5nKGzCx0V/SjmO4ZxsyEksB8aqDF
UxzIUDnIZck0YFSdzccmxeuLh8rlkNDf/+bf9ZjO6mEzU5fsnJGmy+aBFXdo2gwlVv3ga/K++eLZ
Z3AKWnjnHwycOgI2OGYhAmnMW99Qbx9H+ZEY2Y45c56gu0oi+dJkJyshfLA/kZgbm4uT8rFq2/Mm
ycflM+MOZ1CDrnwdc8xLeYNdGBN9T3l6sNUfwWzqw3GIi5WQirin8stKSkYhSYYqn5CFHm35hIz3
LLdcfeLt42PGIqf44B2H1qPQg9SXKiddcu9MkKq1RpipO4yeunfwFftrkX+JPsyHV1o7WqXRxFCq
GAR6P/14mmoKR+uboHsHHYukD8UU1SymVmPLqRPPOTby3URaHSSTEjnCPL3z3a+UWwZ7YR38AVH+
jnRRYx8geDziL+RJ9oT8vT7W8yU9/YRKYJc7USo69NzDXuPtvN72JH9Uji6mQ6zyo0lxmpnsAEN8
QkuwE48aKlwZ8CtC4YEXgGSX9yqYZKHcLleDCqd8qTaqrbJLoPwkkRJs7yMG0zNvmHfyNTPZhcxj
ovI/fPc7GBMtBRQh/RBMR9k4mGlgW8pUf3uxWg04sUVQ8ms+N4Vm6QkFtkC/yYP7B1+Qt8XHWm9A
isfXWLzhRB8Nb3FxMWoJxmNFj0BqBEdvRe6BQ6X3qEi1V/1S2ecxqS0VG54Yk2/pjYfsQPgQdZmE
pfyanNm+4eZEfSrh+0tQUtHTc4JELRLeT+RF9KnhpqXNUtHMhHFiqVQqBXJk7lmC6qrVbUzUkpls
RaYXUo3BAdam6Qnb4KLu5Gs0wJx4lkqotrxaa8lMvbE5yXFC8vhs0v9CpbnYtLpTEH1boOu7ZnaM
tpkaY1emxmjHc108n9cFtsLVi8CD7aGFwEOx/Bjbm6oUvMnx/P1wANztCmpA8SHMYIseHruY/iDx
sJHnwY0H2Wt2hk2ChGBwPS3AnlepzMv/86VYsD6nXDiZnXfSThDclhLlOJDfyvQtawwJHm4PHRJ4
yBwSuKBKwZsGDQjXFCPPh8uFHOocsqvlprC8wLkoYu/sOeMOGs9twgD0nVYU3jc2bLhBKwVvqJ3W
dfavIRFejxxfdK8QmE8iMv0aNBKP2z/Ae8TUXlk9Phpy2TSey5Fkihqm8ClpTPApaSiXkrbFpYQW
+LFbybT23xeNATrU/6OciP9bWTy2/74K/4+krZWjm5AkdR+jRLDbahIKtCbJx+7/oZKpPkGfURQY
xCnKQedTR7JAkZX0AUl9UoZkLcMBSiqxI5wK5gCvpuF/zgaYHy4Ywv5IDBd2qgECNaWOnUCXfOg7
zPlDClWHOH88pjbe5QybFGjCFvNf9t+6bVDHxJhIWNSX0FPKF/uVyNFKkheNkZQvxSlFnD4YdIVb
jsUbZOhPdAY59vr4a+P/sFMOXor7x3PgvwqLGP/9GP/1o8//y3D/OCz+P6YAOMb/HuO/7PH/YyoP
UnaQSuU2pzw/BAXWbrdr7VIK7MorF6uFpga7WvSr1Uo1gl21i0G5VRMQsMCv1PhpDP/PuplpAGHo
AJPEgxWBxRUaUcO8YnGxoLWtXQkagae1rdHwF5e0tpV8z0fM2P5/yZwDtiD81WkhYfkGWcaOEns2
zXyXCEONRM72QQkrCEdw3r3FEXALh4XAVjgLuyX7gxxx2HoUZ9xvJVAzaVH3Y4ZvAU2jcrr9zf4h
4f2LcQQPjtbuFlSTI0Bcvdc3cDicL0AE4TYbeCRrvWe1rNvpL6o6EQXcFu07DRskh2hJhRM2QT0W
Mk9G+YZpHelkEKFgpg7NbaMPa7z/KBq5LdTqxIYnAVfViZA/6lZjmtVjBSPEwzlH42ZgBz0LXtEG
vYtWd7S4m2bw4TiSMnpFxvBPYLQslnxJgLmbIvZxKuU3fNQlRsxSQkBjUAtj/vTgs2LwJmAsBDxy
coaL54auRiNlz2XB3TOQjUnghsA3eojoKeWriHDEPmbNQsywyAqLtORJQGJnm0YyBRQYi7yvvZJM
u5DUR3vJNVWwr6lEZOx40pOIiCvVCTCPGKiquKRtVyUBqiofOcKwPocNPwyQXFR94bZPuKlJSEw/
Fvy7rIJ/47p7LlRXtxvBuoqTAu2/KEhXLR6b+ghR9msTcvNACwWakM0lOUKM18sLJTtDPhJYWAvX
PiFKfUV7Kg/VBwrPrmRIe8h5ClQ/STaIqGUyLtgWF19DGouI+EcJh99vt+3AS5SRmDVi8gzxUcdy
tZroVjFpo6nZthlFGkBNERIPLtrC2k/OsXPovqdJD4n914Z/HQRoS/+B4MlCYpXpkM1SWZP1sD4T
4d3yw63gyJhJC5eb2kuB2mDBq6YdIGJLQYHwjhrm/QfB9PKUB1snXJHVTMjsvBkw4cbTCTDw0EYm
JIczA7NKvjFoMAGa6RMSxrsZjxMTWWHD1N48mrBMxHBUkPR8mQbv10CMHKmYH3OQXyOIrgoN/SXj
W6Rd/x6HWqL4ikbcSkeL+fc//+1fPpJAEz5AxbFbCmwYR/T5LSvWCg80rgbUSwER4VnBHhI9llDY
wDlwytyHHKqTzA8q1/C/uzHEkgmiQ+lZIIfwEwZavkdRpHnQ4HEBKxr34O6zP5Ad2gw8bg8ZjUKv
q0MB73EgZBMj+DGH+SQMinnnU5gxtM7cNrGGIjomxu9FlBUGG34QL/IOh4B1KIbybUSmGE9g1Eya
9wSQ8UuOOmUtPIZZZLJEspg5TVmeJmFQWbrUqGUFQZsYLRda+rmItY/Rw1AhBGPhYNzPp/fx85cU
WfsjAnYmEZ0pY08yJ88qfxQdLBSM/qZ+tQbjXmEXehwgdmkXeQBgxf0K2n2aJDsMEP6E3Ncf8Dhi
kOXvb//fUDLdjsJ1ayhI2FgEBBI/pcSYp03JliEBrnPs9j/y2uUg31/RKr/PkK2PERvZWNFiPuMl
srcp8xxh9UgFRyHmYejvYeYD6/iqOp99LQIUO3rtlLwaynyC+SgwqLyMm83B0Z6QBfJTDGpG1AZP
/5FxZYdVZ0awfcBx1b7ANdXgmN245LkjZG8jCFPE9x5hhPwp6jCisWHZWjTq+CpA2oe/E5B7HM5a
Qf4UjM/AaMO2IOiVPioaiKH82r4B0+ihFpJxTc76aAibF1zKg0iCfDOz8F5rAU6l0eMt7XEMDhdL
Bv7sG/da6zpDM/YlnGsb9qNbqZW2/UwPNrULfVT4iha4QS/3zrqb1Royj+1wn37uZhEupO0zrlYT
icAagpFi9z/hgP2KGzHg7i5FHkYU0v/8t39FjFqxtkSmh3nHK1bEJ/dEuxVUCUEo0XaKp0bxJzgp
+7e0Ih5zif9yF/56pQoXUyqq8hrtVqOtA+ZszBhBfHcwSKDjfv/Z/4A/ZVkAtylo+k3fwCRGOwC8
y4BEkTCBdOPf3eZm/T//iYVVa6K0ildQDWsutjyjYRhB+lsEf1JKBtoSMCTy7yXCGQMl330qCv7v
/yeOYLWitbLRaC+2ClqBYjvVEtMTqlYM2Jc4YHIGSuVoAhrNdlDTiyHYwT0RBQQxoDTDB3ehpU9k
e/71a/i7WNJHrdVqVfUO0oTdYQwuglqdePhv7Nb/hd0qim4VyxXVqqC16Psx1CIerCcBF5EzZ+cd
kgPgwQK+SBRrgT51Rnos6eeI7SyQcPHgzRrHQAShBErbYjrjsdRd+f5Xn2j/3RbPp4Z+Ph0iuE4W
a8pJIBtTrqGPYJO+A/N4m1P9sLikBKI52fAYyg6P7AmUXWeEcZtTH7bgHOGN8vWUKiwBpOHxQtrj
SaAgcTqYu2vedYG2Q0ApfC9djzCmiXLC9HJK17M6LrI/gQ4YhQhnC5MQ4FTu4sVYOGo/c9EfbeVp
VDLAXZycQ812Fhyq1nnNgatZYrZP77t26GFfQgpTZgwnPJsKDqR18Prrp9JXDEvM2WTb6QYekHCn
y7h//j1CSWmqsL1//k+dsDTZAIFGD1y5NTm0Yi0YSQYJ4niP0NlXNporG8ko4MGktc5bMNQUxBo/
wksxyCKe5QjQ2g384VUQNvtjqIf6h6+EwUheNAcwsCAjZVn7wE2BuwvdbPoI44ElfYq4y8ywfkog
JhpQylNF8F01F7QpS6lQ5UShSPLx4xAdET5WAHo1H9FAQ1MyOvvrwVl32ekFu85ZoPgM8NCA1rK6
Ag/gWPdaeRist/vjYZjxysT38T9BpVgSCgdE+O1uH0g0g+XksPwsED5uslA2Qo+vaQ+FcKtUpVux
q9VC1jkJv+ehXPx7XatowMlEJiBgT0RqbRlsf2DZCXY40j+XeK1zPbkahNC0k80P/Nb6CKY048Em
VXCzKpw8EgEP6ymkp/Oo/9jxuxm8Ns8dP0bCHv/Y8T8vI/zfFPHf4/Gf4GP5GP/zCvC/k9E2SdTv
ZQ5jirRjj/xHLmEykF+s9HsCIyuUcncpBjpmo6Gg7p858d2EkMi6UkWpU9Kwv+sjTJ7bHgILFcHe
h/3WuDkKgfWjLMtx332H9sZD0b+E/zkU/UtHHkqvd1smt8Th+9yGAVb7pJ5wS1fJ4cnrc85/hhpb
CpKvaXBF1j8lAz2kffahQ+ejOyImooH7hYmaKgj8N3CkPA4C/1fF//v93l8Q/rdyjP99BfP/CvC/
hWrVgv8tLh7v/8f4X4z/iHsbqjxJkWRF/B4V+4pwnyhWz87WNLCPBKz0xUJidUtzoVGoegULZpKh
V5sWAzbHu8p5scBD6X6+nvTzFQ7weHjWfXtLFfTtTX+/Bu979D57zSfeL0x+vwrv1+h9Tqhjqx8G
mvxG643ueJipsp1cgcwWT4Hs1tnmAJCoEHGKtdDBmPk5mN7+eASD0kYKg/qwlJ4/Epign90IbrWH
QKihQ++h7sMINzbsj1DT4KEjc9aRwceKGK1wX0xC/6YdGjoBYUwABkZeRKDnRQYa6GHTdDyvDHWh
ISsXkyBpxxaoMYFgSCLoip4NpmVB2lWOGEaxpIA2rWF/kNOnsVhQKEKCIMYhhyXCwRDgsMIhFTWQ
okL+DOJxkZxSwQyHVtFHucKDwehS0nDZMImM10iLqhQDK5pR9bjDVvAV16cHs1yqxsFuSXipwJNM
mr1CbbrZK9ayaXPhRYhObqYF0aPNKsF/TNblGa8ng9QZEBhcs4z+GW5PChUpp61ctjkETCbpKSk6
CZAyQqcpZN8PgqHH94wIR5bEqCbw51Rzva5hWhRAL9mfqpjGKGpmGgQuBqH2CoeD3FJDsQXFRrmR
EmYt32ZnFw2c59VsMUUVcVSnxjEpW5Z5uX8zgSRhFJEKCTZjD/9lDf1lgHPIOKEjezRoSmOlEEWb
YHiDmfrU8pSwBB/63APShvwynkzV8uTvGX4QezIWLgiWHaWIV4gpFPyW3WDb73RdlagmhqPSMkh/
yVnQybf5Dqv90fmYMpm70gSIuCAEV31Ct6LwXwtYf3xkkUrcaXAQAj9hi2X046Mcuj68voWRP/Yu
nHnn0urbGxfX9w8xbChzBMI9C4Z9ISPKy5GFI9/r72ayykihWTR2LNaKWrVsM1eQEcMBGa08rSVj
kvVCbA720CDCZtFIN1Zc61z/ofaKCXatNhm1wnFjuzMyCCFgw9lgGOzAw2dZY4e1YMYni61chBfT
ePOpSC5zcYnd4wSWD9Aj/y6imO6KeAi3HSZ6wtBRxHrNAZ80fN//5l+ZeueIjv5i7C+x8/+r0P8X
FivVhP6/XD0+///4+v/YWdvJMEyO4DwqCEU2aQZY7W9jFjAkocnhP/78+1gVZMBHrTYZmjHxN+EJ
MQrcwWPS+H9Ee4nYVG5jOth0ff8qMqpWf7dHeX1Y5e+j7TjsBiNEnOMedKiin4PUH6bojwIFEsrM
ot7/Dpc+op8odNwjFaTjoTCuUEy5X8cVHPp48JYLTxPujALaPcgnlPpbQbfbf85oHtr6h0PvOHwZ
GuDnyP/jHef//NH5P8//S9AAH5L/Bya+ksj/XS0d8/9Xrf8FnvpKtL7rRImHh3aotmvpGXXaXsmr
6Rl1KtXWohY+oVVrBUEZv/dvwOP+Yru0iN92/WGvfqLRrtFRFmry4eVm2/O84PmDPRRaxWJxUctF
VC02PC9qbVANWhylQrS21lqq+gUt2EOhVC21ZGtL7cZSpRC1tuUtLXFx1Np2rVIsL/24kSFy/gA2
n1x4KwSOYiq+r/Qb/VF/3nk76O4EINXbM7maeqVqWpSI2sQgESVPZncoR16CLyglUHoKIFMX6EU1
U+THWFiGRZsDskUZWZjoxc8ld5ROkSuVzvcWZ7TFQ5JdqMD/HPEVPnBIW6kfhPPV4VllUjyBLbRj
cfmUc7hopJ85YiYW5byfaEv/xsTwBqZijEgo0o3Juauac1esPdfc9fqaD/BkR0ZB5jXyLff0EAnD
1otyvS5Y43NQNUNyPLQMyuFum/L9erszDEe5JmJuTX/PglZJfuuoKzQaZ70QoYDWh5bm3erD2vBT
MhZpnrfcRd3+UiqYBXQS2mFlgbF6G1N7DDuFVlZ+1zaryOTJ9iSfsobvANavFiturUcd0UPoMT4o
ahzjURH0fE8lkfrKU2PW6TUjMpgcKyduIVHvp+XJwXsyYEJqqip8SDMflWUmlWldn5XrsjYWpWlS
e6V7Jv/AZB26DpwzMJzuUGR803s25qEBDN11BBgcSkKVmKbAW55bHzfwdN0IWqi7mnNX1AU0l44H
LTw0aNpdS74G6ccJ7ztnYFbWSTgIncuDgBP3+V3re8ggXV0lj7rgC+i6zdW2HFJ6ky4brrgrCZ23
4Vg7bEnV/fYgNPwlt7yVNSwWaKIDXG8UGv6W+A7c0RyCDb+9tywK678bByF2LPyp1YfPqr6mZqFm
1z2zhuKSe9YPtxp9bDZ8OTMebUHLQGoiXQpcudz4b0Fz5CC0kXIXO+7q2UuElDg3HvYHxpUzYYeC
0v990Njq92+ErvJgCoMAYfWLhtJ62GuRL4C4maG/r4FAVSsskja5WF4s10rVMoiyQmVOjywYd/ZF
FWgkX57k8YHTQbpd+mjRLTd1BfrwcMeooekPA5uCG2nPiXdihPh5hzREwiuLzJFOhlwK6Rr8Oe0s
4d/XX5cOINgRGpx5ICss5aaz4uSXahV0lWig6wNfqOL3XXKFcE+RQxA8nqX60PuFmvA66ps7kjzn
nNepyNedOU5nMXdK+NgM0925tjQfLCR8Y0HFDEWa9z8QP1bHrYASE8/QviG9n5cKcJi5FTr+Zt/w
eza+XO3DM0adwqdreLgHVdP6JEcM5x2M/SWuFeOOEMKLiabxNaeQL3hQdv9NxMJkPPJPOQmsAn0u
xPwDKRrOP8OY84/hYZKd4KaE7CbejxbU/c7VVWHtiExNrvPWxasU+x7uuqou3IAit1UofYdYGix+
BxUxveYteAczQVwJYFPcQf6LK9nZ7oSNYMvfQUVrE9ZJ4PT6rQA+jkN4JgThDdZkOADmE4RE034D
UTDFGtqWYTsK85FD5NkA9k54a5f5gtMKuh2QADtBSE6Q8crPqtvwxjBwYMLGcKs1xh47PqX0wWA0
TtvvdCnLHQVVxuGBHSZwOiNa4t0AOqq1Yh060Rp3oSR0i4au+/Bw3UkwODRioYqZC6AWiZs0BKJR
4wEeZrBTqPXt9eGAEIJ0ganatkHSGeVNF85OYxJzQr5PMwYfUqLVK8YSHM6YglhCByg9Ykwjnfgi
CyAQ+E3MR/Ea2viCirADBimpDkS4APEXQx0MVlz5yqFL8abyfEw8TCUmXhgBzWNTJdGnvDyw1CTT
U3QaxpIM1JI89k16lfrfl2ABPNT/p5DQ/xYWj/G/r8L+J+10T+8c/BHzE7HZ7yG58Tx2MuQ+/wBN
3hgKwWIIZNUtW98y53qb3U64lbWaBPUn2RPIVqWI849+QZSagL1N0V/mWzSqkVns2TfP/iDiilDL
2dyGjjFfkgvOwcODL+k9CsKS6ioUDHcoDhq3izaRpUIOxBshSpDcZNoOg17CdigTQU22HV7qbDeg
ktVuf9yyGA4vwG4rG9JvO/3xEMWDcJ4CfdHRgB2XcN91+BwZJl196P3jIP/HP8c/xz/HP8c/xz/H
P8c/xz/HP8c/xz/HP8c/xz/HP8c/xz/HP8c/xz/HP8c/xz/HP8c/fz0//wsHsMwqADACAA==
