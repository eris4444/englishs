#!/usr/bin/env bash
# xray-site: a website and x-ui inbounds sharing the same ports.
#
# On every port in the list, HAProxy looks at the first bytes of each connection: a browser
# gets the website (nginx on 127.0.0.1), everything else goes to the x-ui inbound that port
# is mapped to. x-ui itself is never changed. Several ports can be mapped, to the same or to
# different x-ui inbounds.
#
# Install (asks for the ports):   sudo bash install.sh
# Afterwards, menu:               sudo xray-site
# Or commands:
#   xray-site list                          show the ports
#   xray-site add <port> <x-ui port> [public port]
#   xray-site change <port> <new port> [x-ui port] [public port]
#   xray-site remove <port>
#   xray-site site-port <port>              move the website's internal port
#   xray-site apply                         re-read x-ui after changing an inbound there
#   xray-site status
#   xray-site uninstall
#
# <port> is the port on this server (what the router forwards to). <public port> is only
# shown in summaries: the port people use from the internet, if the router changes it.
# The list lives in /etc/xray-site/xray-site.conf; after editing it by hand run "xray-site apply".
#
# Install without questions: sudo PORTS="1234:8080:8080 2345:8443" bash install.sh
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

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
listeners() { ss -ltnpH "sport = :$1" 2>/dev/null || true; }

# Filled while generating the HAProxy config: per server port, the inbound's description,
# "path host" for a WebSocket self-check, and whether x-ui gets real client IPs.
declare -A MAP_INFO=() MAP_WS=() MAP_PP=()

# ================================================================ config file
# SITE_PORT, CONF_PUBLIC_IP and MAPS (each "server-port:x-ui-port[:public-port]").
load_conf() {
    SITE_PORT="" CONF_PUBLIC_IP="" MAPS=()
    [ -f "$CONF" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        case "$line" in
            "") ;;
            SITE_PORT=*) SITE_PORT="${line#*=}" ;;
            PUBLIC_IP=*) CONF_PUBLIC_IP="${line#*=}" ;;
            port=*)      MAPS+=("${line#*=}") ;;
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
        echo "# port=<port on this server>:<x-ui inbound port>[:<public port, only for display>]"
        echo "SITE_PORT=$SITE_PORT"
        echo "PUBLIC_IP=$CONF_PUBLIC_IP"
        local m
        for m in "${MAPS[@]}"; do echo "port=$m"; done
    } > "$1"
}

# Split "L:X[:P]" into M_LISTEN, M_XUI, M_PUBLIC (public defaults to the server port).
split_map() {
    IFS=: read -r M_LISTEN M_XUI M_PUBLIC _ <<<"$1"
    M_PUBLIC="${M_PUBLIC:-$M_LISTEN}"
}

find_map() {  # index of the mapping whose server port is $1, or nothing
    local i
    for i in "${!MAPS[@]}"; do
        split_map "${MAPS[$i]}"
        [ "$M_LISTEN" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

validate_maps() {
    [ "${#MAPS[@]}" -gt 0 ] || die "No ports configured. Add one with: xray-site add <port> <x-ui port>"
    valid_port "$SITE_PORT" || die "Website port \"$SITE_PORT\" is not a valid port."
    local m seen=" " xuis=" "
    for m in "${MAPS[@]}"; do
        split_map "$m"
        valid_port "$M_LISTEN" || die "\"$M_LISTEN\" in \"$m\" is not a valid port."
        valid_port "$M_XUI"    || die "\"$M_XUI\" in \"$m\" is not a valid port."
        valid_port "$M_PUBLIC" || die "\"$M_PUBLIC\" in \"$m\" is not a valid port."
        case "$seen" in *" $M_LISTEN "*) die "Port $M_LISTEN is listed twice." ;; esac
        seen="$seen$M_LISTEN "
        xuis="$xuis$M_XUI "
        [ "$M_LISTEN" != "$M_XUI" ] || die "Port $M_LISTEN cannot point to itself; the x-ui inbound needs its own port."
        [ "$M_LISTEN" != "$SITE_PORT" ] && [ "$M_XUI" != "$SITE_PORT" ] ||
            die "Port $SITE_PORT is the website's internal port; pick another, or move it with: xray-site site-port <port>"
    done
    for m in "${MAPS[@]}"; do
        split_map "$m"
        case "$xuis" in *" $M_LISTEN "*)
            die "Port $M_LISTEN is both a shared port and an x-ui inbound port; they must differ." ;;
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
    return net, sec, paths, hosts, pp

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
    net, sec, paths, hosts, pp = describe(stream)
except Exception as e:
    print("XUI_ERROR=" + shlex.quote(f"cannot read the settings of the inbound: {e}"))
    sys.exit()
for k, v in dict(REMARK=remark or "", ENABLE=1 if enable else 0, LISTEN=listen or "",
                 PROTO=proto, NET=net, SEC=sec, PATHS=" ".join(paths),
                 HOSTS=" ".join(hosts), PP=1 if pp else 0).items():
    print(f"XUI_{k}={shlex.quote(str(v))}")
PY
}

read_inbound() {  # $1 = x-ui port; sets XUI_*
    XUI_ERROR="" XUI_REMARK="" XUI_ENABLE=1 XUI_LISTEN="" XUI_PROTO="" XUI_NET="" XUI_SEC=""
    XUI_PATHS="" XUI_HOSTS="" XUI_PP=0
    if [ -r "$XUI_DB" ]; then
        eval "$(xui_py one "$1" || true)"
        [ -n "$XUI_ERROR$XUI_PROTO" ] || XUI_ERROR="could not read the inbound from $XUI_DB"
    else
        XUI_ERROR="$XUI_DB not found"
    fi
    [ -z "$XUI_ERROR" ] || XUI_NET=unknown
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
    tcp-request content accept if HTTP
    # gRPC without TLS starts with the HTTP/2 preface "PRI"; browsers never send it here.
    use_backend $be if { req.payload(0,3) -m bin 505249 }
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
    MAP_INFO[$L]="\"$XUI_REMARK\" $XUI_PROTO/$XUI_NET/$XUI_SEC"
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
    local m
    for m in "${MAPS[@]}"; do
        split_map "$m"
        emit_mapping "$1" "$M_LISTEN" "$M_XUI"
    done
}

write_nginx_conf() {
    # HAProxy passes the visitor's address with the PROXY protocol, so nginx logs real IPs.
    cat > "$NGINX_CONF" <<EOF
# Website behind the xray-site splitter. Generated by xray-site.
server {
    listen 127.0.0.1:$SITE_PORT proxy_protocol;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_name _;
    server_tokens off;

    root $SITE_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
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
        die "Port $M_LISTEN is already used by another program:
$owners
Pick another port (and forward the router to it)."
    done
    owners="$(listeners "$SITE_PORT")"
    if [ -n "$owners" ] && ! { grep -q '"nginx"' <<<"$owners" && grep -qs "127.0.0.1:$SITE_PORT " "$NGINX_CONF"; }; then
        die "The website's internal port $SITE_PORT is used by another program. Move it: xray-site site-port <port>"
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
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$M_LISTEN/" || true)"
            [ "$code" = 200 ] && break
            sleep 0.5
        done
        [ "$code" = 200 ] || { echo "port $M_LISTEN: the website answered HTTP $code instead of 200"; return 1; }
        ws="${MAP_WS[$M_LISTEN]:-}"
        if [ -n "$ws" ]; then
            path="${ws%% *}"; host="${ws#* }"
            code="$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 3 ${host:+-H "Host: $host"} \
                -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
                -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://127.0.0.1:$M_LISTEN$path" || true)"
            [ "$code" = 101 ] || { echo "port $M_LISTEN: x-ui did not accept the WebSocket (HTTP $code)"; return 1; }
        fi
    done
}

apply() {
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

print_list() {
    local i=0 m info
    printf '\n  %-3s %-13s %-11s %-13s %s\n' "#" "server port" "x-ui port" "public port" "x-ui inbound"
    for m in "${MAPS[@]}"; do
        i=$((i + 1)); split_map "$m"
        info="${MAP_INFO[$M_LISTEN]:-}"
        if [ -z "$info" ]; then
            read_inbound "$M_XUI"
            if [ -n "$XUI_ERROR" ]; then info="($XUI_ERROR)"; else info="\"$XUI_REMARK\" $XUI_PROTO/$XUI_NET/$XUI_SEC"; fi
        fi
        printf '  %-3s %-13s %-11s %-13s %s\n' "$i" "$M_LISTEN" "$M_XUI" "$M_PUBLIC" "$info"
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
            info="\"$XUI_REMARK\" $XUI_PROTO/$XUI_NET/$XUI_SEC" pp="$XUI_PP"
            [ -z "$XUI_ERROR" ] || { info="($XUI_ERROR)"; pp=x; }
        fi
        printf '  http://%s:%s/  ->  server port %s  ->  x-ui %s %s\n' "$ip" "$M_PUBLIC" "$M_LISTEN" "$M_XUI" "$info"
        [ "$pp" = 0 ] && [[ "$note" != *" $M_XUI"* ]] && note="$note $M_XUI"
    done
    cat <<EOF

  Browsers get the website on these addresses; VPN clients use the links from the x-ui
  panel, with the address $ip and the public port shown above.
EOF
    if [ -n "$note" ]; then
        cat <<EOF

  Note: x-ui sees every VPN user as 127.0.0.1 on inbound(s)$note, so an IP limit on
  clients will not work there. Turn on "Proxy Protocol" for the inbound in x-ui and run
  "sudo xray-site apply".
EOF
    fi
    echo "  Change ports any time with: sudo xray-site"
    echo
}

# ================================================================ questions
ask() {  # $1 variable, $2 question, $3 default
    local ans
    read -r -p "  $2${3:+ [$3]}: " ans || true
    printf -v "$1" '%s' "${ans:-$3}"
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

ask_mapping() {  # $1 default server port, $2 default x-ui port, $3 default public port; sets NEW_MAP
    local l x p
    ask_port l "Port on this server that the router forwards to" "$1"
    ask_port x "x-ui inbound port to send VPN traffic to" "$2"
    ask_port p "Public port people use (the router's outside port)" "${3:-$l}"
    NEW_MAP="$l:$x:$p"
}

yes_no() {  # $1 question, $2 default y|n
    local a
    ask a "$1 (y/n)" "$2"
    [[ "$a" =~ ^[Yy] ]]
}

pick_row() {  # sets ROW to a mapping index chosen by number
    local n
    ask n "Number (#) from the list" ""
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#MAPS[@]}" ] || { echo "    No such row."; return 1; }
    ROW=$((n - 1))
}

# ================================================================ commands
need_installed() {
    [ -f "$CONF" ] || die "xray-site is not installed yet. Run: sudo bash install.sh"
    load_conf
}

cmd_list() { need_installed; print_list; }

cmd_add() {
    need_installed
    [ $# -ge 2 ] || die "Usage: xray-site add <server port> <x-ui port> [public port]"
    find_map "$1" >/dev/null && die "Port $1 is already in the list; use: xray-site change $1 ..."
    MAPS+=("$1:$2:${3:-$1}")
    apply; print_summary
}

cmd_change() {
    need_installed
    [ $# -ge 2 ] || die "Usage: xray-site change <server port> <new server port> [x-ui port] [public port]"
    local i
    i="$(find_map "$1")" || die "Port $1 is not in the list (see: xray-site list)."
    split_map "${MAPS[$i]}"
    # When the public port was simply the server port, it follows the new server port.
    local pub="$M_PUBLIC"; [ "$M_PUBLIC" = "$M_LISTEN" ] && pub="$2"
    MAPS[$i]="$2:${3:-$M_XUI}:${4:-$pub}"
    apply; print_summary
}

cmd_remove() {
    need_installed
    [ $# -ge 1 ] || die "Usage: xray-site remove <server port>"
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
    systemctl --no-pager status xray-site nginx 2>/dev/null | grep -E '●|Active:' || true
    print_list
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
    rm -rf "$CONF_DIR"
    rm -f "$BIN"
    say "Removed. The website files are still in $SITE_DIR (delete them if you like)."
}

cmd_menu() {
    need_installed
    is_tty || die "The menu needs a terminal. See: xray-site help"
    local c
    while :; do
        print_list
        cat <<'EOF'
  1) Add a port
  2) Change a port
  3) Remove a port
  4) Re-read x-ui and apply (after changing an inbound in x-ui)
  5) Change the website's internal port
  6) Status
  0) Exit
EOF
        ask c "Choose" ""
        echo
        case "$c" in
            1)  show_xui_inbounds
                ask_mapping "" "" ""
                split_map "$NEW_MAP"
                if find_map "$M_LISTEN" >/dev/null; then echo "    Port $M_LISTEN is already in the list."; continue; fi
                MAPS+=("$NEW_MAP")
                try_apply
                if [ "$APPLIED" = 1 ]; then print_summary; else warn "Not added; nothing was changed."; fi ;;
            2)  pick_row || continue
                split_map "${MAPS[$ROW]}"
                show_xui_inbounds
                # A public port equal to the server port follows the new server port.
                if [ "$M_PUBLIC" = "$M_LISTEN" ]; then ask_mapping "$M_LISTEN" "$M_XUI" ""
                else ask_mapping "$M_LISTEN" "$M_XUI" "$M_PUBLIC"; fi
                MAPS[$ROW]="$NEW_MAP"
                try_apply
                if [ "$APPLIED" = 1 ]; then print_summary; else warn "Not changed; the previous setup is still running."; fi ;;
            3)  [ "${#MAPS[@]}" -gt 1 ] || { echo "    This is the last port; use \"xray-site uninstall\" to remove everything."; continue; }
                pick_row || continue
                split_map "${MAPS[$ROW]}"
                yes_no "Remove port $M_LISTEN" n || continue
                unset 'MAPS[ROW]'; MAPS=("${MAPS[@]}")
                try_apply
                [ "$APPLIED" = 1 ] || warn "Not removed; nothing was changed." ;;
            4)  try_apply
                if [ "$APPLIED" = 1 ]; then print_summary; fi ;;
            5)  local sp
                ask_port sp "Website internal port (on 127.0.0.1)" "$SITE_PORT"
                SITE_PORT="$sp"
                try_apply
                [ "$APPLIED" = 1 ] || warn "Not changed." ;;
            6)  cmd_status ;;
            0|q|"") return 0 ;;
            *)  echo "    Choose a number from the menu." ;;
        esac
    done
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

    # The very first version of this script ran its own Xray; x-ui replaces it.
    rm -f "$CONF_DIR/config.json" "$CONF_DIR/client.txt"

    load_conf
    if [ -n "${PORTS:-}" ]; then
        local p
        MAPS=()
        for p in ${PORTS//,/ }; do MAPS+=("$p"); done
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
        echo "  Which ports should carry both the website and x-ui?"
        ask_mapping 1234 8080 8080
        MAPS=("$NEW_MAP")
        while yes_no "Add another port" n; do
            ask_mapping "" "" ""
            MAPS+=("$NEW_MAP")
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

# ---------------------------------------------------------------- website
mkdir -p "$SITE_DIR"
if [ ! -f "$SITE_DIR/index.html" ]; then
    say "Writing website to $SITE_DIR/index.html"
    cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>یادداشت‌های من</title>
<style>
  :root { --bg:#f7f6f3; --card:#fff; --text:#1f2328; --muted:#5f6670; --line:#e4e2dc; --accent:#2f6f5e; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#16181b; --card:#1e2125; --text:#e8e6e3; --muted:#a0a4aa; --line:#2c3035; --accent:#6cc4a8; }
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font-family: Vazirmatn, "Segoe UI", Tahoma, sans-serif; line-height:1.9; }
  .wrap { max-width: 760px; margin: 0 auto; padding: 48px 16px 64px; }
  header { display:flex; align-items:center; gap:16px; margin-bottom:40px; }
  .logo { width:56px; height:56px; border-radius:14px; background:var(--accent);
          color:#fff; display:grid; place-items:center; font-size:26px; font-weight:700; flex:none; }
  h1 { margin:0; font-size:26px; }
  header p { margin:0; color:var(--muted); }
  h2 { font-size:18px; margin:40px 0 12px; }
  .post { background:var(--card); border:1px solid var(--line); border-radius:12px;
          padding:18px 20px; margin-bottom:12px; }
  .post h3 { margin:0 0 4px; font-size:16px; }
  .post time { color:var(--muted); font-size:13px; }
  .post p { margin:8px 0 0; color:var(--muted); }
  footer { margin-top:48px; padding-top:16px; border-top:1px solid var(--line);
           color:var(--muted); font-size:13px; }
  a { color:var(--accent); }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="logo">ی</div>
    <div>
      <h1>یادداشت‌های من</h1>
      <p>جایی برای نوشتن درباره‌ی کتاب، سفر و چیزهایی که یاد می‌گیرم.</p>
    </div>
  </header>

  <h2>تازه‌ترین نوشته‌ها</h2>
  <article class="post">
    <h3>شروع دوباره</h3>
    <time>پاییز ۱۴۰۵</time>
    <p>بعد از مدت‌ها تصمیم گرفتم دوباره بنویسم؛ کوتاه، ساده و هر هفته.</p>
  </article>
  <article class="post">
    <h3>سه کتابی که امسال خواندم</h3>
    <time>تابستان ۱۴۰۵</time>
    <p>فهرستی کوتاه از کتاب‌هایی که نگاهم را به کار و زندگی عوض کردند.</p>
  </article>
  <article class="post">
    <h3>یادداشت سفر به شمال</h3>
    <time>بهار ۱۴۰۵</time>
    <p>جاده‌ی چالوس، مه صبحگاهی و یک چای داغ کنار رودخانه.</p>
  </article>

  <h2>درباره‌ی من</h2>
  <p>اینجا خانه‌ی کوچک من در اینترنت است. برای ارتباط می‌توانید ایمیل بزنید.</p>

  <footer>© ۱۴۰۵ — همه‌ی حقوق محفوظ است.</footer>
</div>
</body>
</html>
HTML
fi
chmod -R a+rX "$SITE_DIR"

    apply
    print_list
    print_summary
}

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ================================================================ main
case "${1:-}" in help|-h|--help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $*"
SITE_PORT_ENV="${SITE_PORT:-}"

cmd="${1:-}"
[ $# -gt 0 ] && shift
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
    uninstall)  cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *)          usage; exit 1 ;;
esac
