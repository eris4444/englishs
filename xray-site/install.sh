#!/usr/bin/env bash
# Website + the x-ui VPN inbound on one port.
#
# The router forwards public port 8080 to this server's port 1234. HAProxy listens on 1234
# and looks at the first bytes of every connection: a browser gets the website (nginx on
# 127.0.0.1), everything else goes to the x-ui inbound on port 8080. x-ui itself is not
# changed, and the links from the x-ui panel keep working (address = public IP, port 8080).
#
#   sudo bash install.sh
#
# Settings (environment variables):
#   SERVER_PORT  port on this server that the router forwards to   (default 1234)
#   XUI_PORT     port of the x-ui inbound                          (default 8080)
#   PUBLIC_PORT  port people use from the internet, for the summary (default 8080)
#   SITE_PORT    internal port for the website, on 127.0.0.1       (default 8081, or next free)
#   PUBLIC_IP    your public IP; detected automatically if empty
#   XUI_DB       x-ui database                                     (default /etc/x-ui/x-ui.db)
#
# Run it again after changing the inbound in x-ui (transport, path, Proxy Protocol).
set -euo pipefail

SERVER_PORT="${SERVER_PORT:-1234}"
XUI_PORT="${XUI_PORT:-8080}"
PUBLIC_PORT="${PUBLIC_PORT:-8080}"
SITE_PORT="${SITE_PORT:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"

SITE_DIR=/var/www/xray-site
CONF_DIR=/etc/xray-site
HAPROXY_CONF=$CONF_DIR/haproxy.cfg
NGINX_CONF=/etc/nginx/conf.d/xray-site.conf
UNIT=/etc/systemd/system/xray-site.service

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0"

# ---------------------------------------------------------------- packages
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
HAPROXY_BIN="$(command -v haproxy)" || die "haproxy is not installed."

# ---------------------------------------------------------------- x-ui inbound
# Read the inbound on XUI_PORT from the x-ui database (read-only) to learn how VPN
# clients will talk to it.
XUI_ERROR="" XUI_REMARK="" XUI_ENABLE=1 XUI_LISTEN="" XUI_PROTO="" XUI_NET="" XUI_SEC=""
XUI_PATHS="" XUI_HOSTS="" XUI_PP=0
if [ -r "$XUI_DB" ]; then
    eval "$(python3 - "$XUI_DB" "$XUI_PORT" <<'PY'
import json, re, shlex, sqlite3, sys

db, port = sys.argv[1], int(sys.argv[2])
def out(**kv):
    for k, v in kv.items():
        print(f"XUI_{k}={shlex.quote(str(v))}")

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        "SELECT remark, enable, listen, protocol, stream_settings FROM inbounds WHERE port = ?",
        (port,)).fetchall()
except Exception as e:
    out(ERROR=f"could not read {db}: {e}")
    sys.exit()
if not rows:
    out(ERROR=f"x-ui has no inbound on port {port}")
    sys.exit()

rows.sort(key=lambda r: not r[1])                     # prefer an enabled one
remark, enable, listen, proto, stream = rows[0]
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
# Only plain characters go into the HAProxy config; the query part is not part of the path.
paths = [p.split("?")[0] or "/" for p in paths]
paths = [p for p in paths if re.fullmatch(r"/[A-Za-z0-9._~%!+,=:@/-]*", p)]
hosts = [h for h in hosts if re.fullmatch(r"[A-Za-z0-9.-]+(:[0-9]+)?", h)]
out(REMARK=remark or "", ENABLE=1 if enable else 0, LISTEN=listen or "", PROTO=proto,
    NET=net, SEC=sec, PATHS=" ".join(paths), HOSTS=" ".join(hosts), PP=1 if pp else 0)
PY
)"
    [ -n "$XUI_ERROR$XUI_PROTO" ] || XUI_ERROR="could not read the inbound from $XUI_DB"
else
    XUI_ERROR="$XUI_DB not found"
fi

if [ -n "$XUI_ERROR" ]; then
    warn "$XUI_ERROR. Using general rules: they cover TCP, TLS/REALITY, WebSocket, HTTPUpgrade"
    warn "and gRPC inbounds, but not XHTTP or TCP with an HTTP header."
    XUI_NET=unknown
else
    say "x-ui inbound on port $XUI_PORT: \"$XUI_REMARK\" $XUI_PROTO / $XUI_NET / security $XUI_SEC"
    [ "$XUI_ENABLE" = 1 ] || warn "This inbound is disabled in x-ui; enable it or VPN clients cannot connect."
fi

case "$XUI_NET" in
    kcp|mkcp|quic|hysteria*)
        die "The inbound uses $XUI_NET, which runs over UDP and cannot share a TCP port with a website.
Change its transport in x-ui (TCP, WebSocket, XHTTP or gRPC), then run this again." ;;
esac

# Which HTTP requests belong to x-ui instead of the website.
HTTP_RULES=""
if [ "$XUI_SEC" = "none" ] || [ "$XUI_NET" = unknown ]; then
    case "$XUI_NET" in
        ws|httpupgrade|unknown)
            # Browsers never ask for a WebSocket upgrade on this site.
            HTTP_RULES="    use_backend xui if HTTP { hdr(upgrade) -i websocket }" ;;
        xhttp|splithttp|tcp-http)
            for p in $XUI_PATHS; do
                [ "$p" = "/" ] && continue
                HTTP_RULES="$HTTP_RULES
    use_backend xui if HTTP { path -m str ${p%/} } or HTTP { path -m beg ${p%/}/ }"
            done
            for h in $XUI_HOSTS; do
                HTTP_RULES="$HTTP_RULES
    use_backend xui if HTTP { hdr(host) -i $h }"
            done
            [ -n "$HTTP_RULES" ] || die "The inbound ($XUI_NET) uses path \"/\" and no host, so its requests look
exactly like a browser opening the website. In x-ui, give the inbound a path such as
/$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n') (and update the client links), then run this again." ;;
    esac
fi

# ---------------------------------------------------------------- x-ui reachable?
case "$XUI_LISTEN" in
    ""|0.0.0.0|::|"[::]") XUI_ADDR=127.0.0.1 ;;
    *) XUI_ADDR="$XUI_LISTEN" ;;
esac
timeout 3 bash -c "exec 3<>/dev/tcp/$XUI_ADDR/$XUI_PORT" 2>/dev/null ||
    die "Nothing answers on $XUI_ADDR:$XUI_PORT. Is x-ui running (x-ui status) and the inbound enabled?"
case "$XUI_ADDR" in *:*) XUI_SERVER="ipv6@$XUI_ADDR:$XUI_PORT" ;; *) XUI_SERVER="$XUI_ADDR:$XUI_PORT" ;; esac
XUI_SEND_PROXY=""
[ "$XUI_PP" = 1 ] && XUI_SEND_PROXY=" send-proxy-v2"

# ---------------------------------------------------------------- ports
listeners() { ss -ltnpH "sport = :$1" 2>/dev/null || true; }

owners="$(listeners "$SERVER_PORT")"
if [ -n "$owners" ]; then
    if grep -q '"haproxy"' <<<"$owners" && systemctl is-active --quiet xray-site; then
        :   # this script's splitter from an earlier run
    elif grep -q '"nginx"' <<<"$owners" && grep -qs "listen $SERVER_PORT" "$NGINX_CONF"; then
        :   # the previous version of this script; replaced below
    else
        die "Port $SERVER_PORT is already used by another program:
$owners
Stop it, or run with SERVER_PORT=<another port> and change the router forward to match."
    fi
fi
[ "$SERVER_PORT" != "$XUI_PORT" ] || die "SERVER_PORT and XUI_PORT are both $XUI_PORT; they must differ."

# The website's internal port: keep the one from an earlier run, otherwise the first free one.
if [ -z "$SITE_PORT" ]; then
    SITE_PORT="$(grep -oE 'listen 127\.0\.0\.1:[0-9]+' "$NGINX_CONF" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
    if [ -z "$SITE_PORT" ]; then
        for p in $(seq 8081 8199); do
            [ "$p" = "$XUI_PORT" ] || [ "$p" = "$SERVER_PORT" ] && continue
            [ -z "$(listeners "$p")" ] && { SITE_PORT=$p; break; }
        done
    fi
fi
[ -n "$SITE_PORT" ] || die "No free port found for the website between 8081 and 8199; set SITE_PORT."

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

# ---------------------------------------------------------------- nginx (website only)
# HAProxy passes the visitor's address with the PROXY protocol, so nginx logs real IPs.
cat > "$NGINX_CONF" <<EOF
# Website behind the HAProxy splitter. Written by xray-site/install.sh.
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

# With IPv6 turned off, the stock Debian/Ubuntu site's "listen [::]:80" stops nginx from starting.
if [ ! -e /proc/net/if_inet6 ] && [ -f /etc/nginx/sites-enabled/default ]; then
    sed -i --follow-symlinks -E 's/^(\s*)listen \[::\]/\1# listen [::]/' /etc/nginx/sites-enabled/default
fi

mkdir -p "$CONF_DIR"
if ! nginx -t 2>"$CONF_DIR/nginx-test.log"; then
    cat "$CONF_DIR/nginx-test.log" >&2
    rm -f "$NGINX_CONF"
    die "nginx rejected the config (shown above); $NGINX_CONF was removed."
fi

# ---------------------------------------------------------------- haproxy (the splitter)
cat > "$HAPROXY_CONF" <<EOF
# Website + x-ui on one port. Written by xray-site/install.sh; run it again to regenerate.
# x-ui inbound: "$XUI_REMARK" $XUI_PROTO / $XUI_NET / security $XUI_SEC
global
    user haproxy
    group haproxy

defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend public
    bind :$SERVER_PORT
    # Wait for the first bytes. Browsers and VPN clients both speak first, so this adds no delay.
    tcp-request inspect-delay 5s
    tcp-request content accept if HTTP

    # gRPC without TLS starts with the HTTP/2 preface "PRI"; browsers never send it here.
    use_backend xui if { req.payload(0,3) -m bin 505249 }
$HTTP_RULES
    use_backend site if HTTP
    # Anything that is not plain HTTP (VLESS/VMess/Trojan/Shadowsocks, TLS, REALITY) is the VPN.
    default_backend xui

backend site
    server site 127.0.0.1:$SITE_PORT send-proxy

backend xui
    server xui $XUI_SERVER$XUI_SEND_PROXY
EOF
"$HAPROXY_BIN" -c -q -f "$HAPROXY_CONF" || die "haproxy rejected $HAPROXY_CONF (errors above)."

cat > "$UNIT" <<EOF
[Unit]
Description=Website + x-ui on one port (HAProxy splitter)
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=$HAPROXY_BIN -c -q -f $HAPROXY_CONF
ExecStart=$HAPROXY_BIN -Ws -f $HAPROXY_CONF -p /run/xray-site.pid
ExecReload=$HAPROXY_BIN -c -q -f $HAPROXY_CONF
ExecReload=/bin/kill -USR2 \$MAINPID
KillMode=mixed
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# The previous version of this script ran its own Xray; x-ui replaces it.
rm -f "$CONF_DIR/config.json" "$CONF_DIR/client.txt"

# SELinux (Fedora/RHEL/CentOS): let HAProxy use these ports and nginx listen on its port.
if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    setsebool -P haproxy_connect_any 1 2>/dev/null || true
    if command -v semanage >/dev/null; then
        for p in $SERVER_PORT $SITE_PORT; do
            semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null ||
            semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null || true
        done
    fi
fi

# ---------------------------------------------------------------- start
say "Starting nginx and the splitter"
systemctl enable --quiet nginx
if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl restart nginx; fi
sleep 1   # let nginx release SERVER_PORT if the previous version had it
systemctl daemon-reload
systemctl enable --quiet xray-site
systemctl restart xray-site

# ---------------------------------------------------------------- firewall
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$SERVER_PORT/tcp" >/dev/null
    say "ufw: opened $SERVER_PORT/tcp"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port="$SERVER_PORT/tcp"
    firewall-cmd -q --reload
    say "firewalld: opened $SERVER_PORT/tcp"
fi

# ---------------------------------------------------------------- self-check
sleep 1
systemctl is-active --quiet xray-site ||
    { journalctl -u xray-site -n 20 --no-pager >&2 || true; die "The splitter did not start (log above)."; }
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SERVER_PORT/" || true)"
[ "$code" = "200" ] || die "The website answered HTTP $code on port $SERVER_PORT instead of 200."
if [ "$XUI_SEC" = none ] && { [ "$XUI_NET" = ws ] || [ "$XUI_NET" = httpupgrade ]; }; then
    p="${XUI_PATHS%% *}"; h="${XUI_HOSTS%% *}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 3 ${h:+-H "Host: $h"} \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://127.0.0.1:$SERVER_PORT$p" || true)"
    [ "$code" = "101" ] || die "x-ui did not accept the WebSocket through port $SERVER_PORT (HTTP $code)."
    say "Self-check passed: website 200, x-ui WebSocket 101"
else
    say "Self-check passed: website 200, x-ui reachable on $XUI_ADDR:$XUI_PORT"
fi

# ---------------------------------------------------------------- summary
if [ -z "$PUBLIC_IP" ]; then
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ipinfo.io/ip; do
        PUBLIC_IP="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')" && [ -n "$PUBLIC_IP" ] && break
    done
fi
PUBLIC_IP="${PUBLIC_IP:-YOUR_PUBLIC_IP}"

cat <<EOF

  Website:  http://$PUBLIC_IP:$PUBLIC_PORT/
  VPN:      use the links from the x-ui panel. In them the address must be $PUBLIC_IP
            and the port $PUBLIC_PORT (not the server's local IP).

  Website files: $SITE_DIR      Splitter config: $HAPROXY_CONF
EOF
if [ "$XUI_PP" != 1 ] && [ "$XUI_NET" != unknown ]; then
    cat <<EOF

  Note: x-ui now sees every VPN user as 127.0.0.1, so an IP limit on clients will not
  work. To fix it, turn on "Proxy Protocol" for this inbound in x-ui and run this again.
EOF
fi
echo
