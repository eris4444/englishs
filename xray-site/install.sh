#!/usr/bin/env bash
# Website + Xray on one port.
#
# nginx listens on the port your router forwards to. A normal browser visit gets the
# website; a VPN client (VLESS over WebSocket on a secret path) is handed to Xray, which
# listens only on 127.0.0.1. Run as root on Debian/Ubuntu (dnf/yum also work).
#
#   sudo bash install.sh
#
# Settings (environment variables):
#   SERVER_PORT  port on this server that the router forwards to   (default 1234)
#   PUBLIC_PORT  port people use from the internet                 (default 8080)
#   PUBLIC_IP    your public IP; detected automatically if empty
#   XRAY_ZIP     path to a downloaded Xray-linux-*.zip, if GitHub is unreachable
#   ALLOW_LAN    1 lets VPN users reach your home network (default 0: blocked)
#
# Running it again keeps the same UUID and path, so existing clients keep working.
set -euo pipefail

SERVER_PORT="${SERVER_PORT:-1234}"
PUBLIC_PORT="${PUBLIC_PORT:-8080}"
PUBLIC_IP="${PUBLIC_IP:-}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
XRAY_ZIP="${XRAY_ZIP:-}"
ALLOW_LAN="${ALLOW_LAN:-0}"
XRAY_LOCAL_PORT="${XRAY_LOCAL_PORT:-10000}"

SITE_DIR=/var/www/xray-site
CONF_DIR=/etc/xray-site
XRAY_BIN=/usr/local/bin/xray
NGINX_CONF=/etc/nginx/conf.d/xray-site.conf
UNIT=/etc/systemd/system/xray-site.service

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0"

# ---------------------------------------------------------------- packages
say "Installing nginx, curl, unzip"
if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nginx curl unzip ca-certificates iproute2 >/dev/null
    apt-get install -y -qq qrencode >/dev/null 2>&1 || true
elif command -v dnf >/dev/null; then
    dnf install -y -q nginx curl unzip iproute
    dnf install -y -q qrencode >/dev/null 2>&1 || true
elif command -v yum >/dev/null; then
    yum install -y -q epel-release >/dev/null 2>&1 || true
    yum install -y -q nginx curl unzip iproute
    yum install -y -q qrencode >/dev/null 2>&1 || true
else
    die "No apt-get, dnf or yum found. Install nginx, curl and unzip yourself, then run again."
fi

# ---------------------------------------------------------------- xray binary
if [ -x "$XRAY_BIN" ]; then
    say "Xray already installed: $("$XRAY_BIN" version | head -1)"
else
    case "$(uname -m)" in
        x86_64|amd64)  asset=Xray-linux-64.zip ;;
        aarch64|arm64) asset=Xray-linux-arm64-v8a.zip ;;
        armv7l|armv7)  asset=Xray-linux-arm32-v7a.zip ;;
        i386|i686)     asset=Xray-linux-32.zip ;;
        *) die "Unsupported CPU $(uname -m). Download Xray yourself and pass XRAY_ZIP=..." ;;
    esac
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    if [ -n "$XRAY_ZIP" ]; then
        cp "$XRAY_ZIP" "$tmp/xray.zip"
    else
        say "Downloading Xray $XRAY_VERSION ($asset)"
        curl -fL --retry 3 -o "$tmp/xray.zip" \
            "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$asset" ||
        curl -fL --retry 3 -o "$tmp/xray.zip" \
            "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" ||
        die "Could not download Xray from GitHub. Download $asset by hand and run: XRAY_ZIP=/path/to/$asset bash $0"
    fi
    unzip -qo "$tmp/xray.zip" -d "$tmp/x"
    install -m 755 "$tmp/x/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    cp -f "$tmp/x/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    say "Installed $("$XRAY_BIN" version | head -1)"
fi

# ---------------------------------------------------------------- ports
# A port is free if nothing listens on it, or only what an earlier run of this script
# started there: nginx for the public ports, the xray-site service for Xray's port.
port_busy_by_other() {  # $1 port, $2 nginx|xray
    local owners pid
    owners="$(ss -ltnpH "sport = :$1" 2>/dev/null || true)"
    [ -n "$owners" ] || return 1
    if [ "$2" = nginx ]; then
        ! grep -q '"nginx"' <<<"$owners"
    else
        pid="$(systemctl show -p MainPID --value xray-site 2>/dev/null || true)"
        ! { [ -n "$pid" ] && [ "$pid" != 0 ] && grep -q "pid=$pid," <<<"$owners"; }
    fi
}
port_busy_by_other "$SERVER_PORT" nginx &&
    die "Port $SERVER_PORT is already used by another program:
$(ss -ltnpH "sport = :$SERVER_PORT")
Stop it, or run with SERVER_PORT=<another port> and change the router forward to match."
port_busy_by_other "$XRAY_LOCAL_PORT" xray &&
    die "Port $XRAY_LOCAL_PORT (Xray's internal port) is in use. Run with XRAY_LOCAL_PORT=<free port>."

listens="    listen $SERVER_PORT default_server;"
if [ "$PUBLIC_PORT" != "$SERVER_PORT" ]; then
    if port_busy_by_other "$PUBLIC_PORT" nginx; then
        warn "Port $PUBLIC_PORT is used by another program; nginx will listen only on $SERVER_PORT."
    else
        # Also answer on the public port, for testing inside your home network.
        listens="$listens
    listen $PUBLIC_PORT default_server;"
    fi
fi

# ---------------------------------------------------------------- secrets
mkdir -p "$CONF_DIR"
if [ -f "$CONF_DIR/config.json" ]; then
    UUID="$(grep -oE '"id": *"[0-9a-f-]{36}"' "$CONF_DIR/config.json" | grep -oE '[0-9a-f-]{36}' | head -1 || true)"
    WS_PATH="$(grep -oE '"path": *"/[^"]+"' "$CONF_DIR/config.json" | sed -E 's/.*"(\/[^"]+)"/\1/' | head -1 || true)"
fi
if [ -z "${UUID:-}" ] || [ -z "${WS_PATH:-}" ]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    WS_PATH="/$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    say "Generated new UUID and secret path"
else
    say "Keeping existing UUID and path from $CONF_DIR/config.json"
fi

# ---------------------------------------------------------------- xray config
if [ "$ALLOW_LAN" = "1" ]; then
    domain_strategy=AsIs
    lan_rule=''
else
    # Stop VPN users from reaching this server's own services or your home network
    # (router admin page, other devices). IPIfNonMatch resolves host names first, so
    # "localhost" or a name pointing at 192.168.x.x is caught too.
    domain_strategy=IPIfNonMatch
    lan_rule='{ "type": "field", "outboundTag": "block", "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "::1/128", "fc00::/7", "fe80::/10"] }'
fi

cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": $XRAY_LOCAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "email": "user1" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": { "domainStrategy": "$domain_strategy", "rules": [ $lan_rule ] }
}
EOF
chmod 644 "$CONF_DIR/config.json"
"$XRAY_BIN" run -test -c "$CONF_DIR/config.json" >/dev/null || die "Xray rejected $CONF_DIR/config.json"

cat > "$UNIT" <<EOF
[Unit]
Description=Xray (VLESS over WebSocket, behind nginx)
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=$XRAY_BIN run -c $CONF_DIR/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

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

# ---------------------------------------------------------------- nginx
cat > "$NGINX_CONF" <<EOF
# Website + Xray on one port. Written by xray-site/install.sh.
server {
$listens
    server_name _;
    server_tokens off;

    root $SITE_DIR;
    index index.html;

    # VPN clients: VLESS over WebSocket on a secret path, handed to Xray.
    location = $WS_PATH {
        if (\$http_upgrade !~* ^websocket\$) { return 404; }
        proxy_pass http://127.0.0.1:$XRAY_LOCAL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }

    # Everyone else: the website.
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# With IPv6 turned off, the stock Debian/Ubuntu site's "listen [::]:80" stops nginx from starting.
if [ ! -e /proc/net/if_inet6 ] && [ -f /etc/nginx/sites-enabled/default ]; then
    sed -i --follow-symlinks -E 's/^(\s*)listen \[::\]/\1# listen [::]/' /etc/nginx/sites-enabled/default
fi

if ! nginx -t 2>"$CONF_DIR/nginx-test.log"; then
    cat "$CONF_DIR/nginx-test.log" >&2
    rm -f "$NGINX_CONF"
    die "nginx rejected the config (shown above); $NGINX_CONF was removed."
fi

# SELinux (Fedora/RHEL/CentOS): let nginx use these ports and connect to Xray.
if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    if command -v semanage >/dev/null; then
        for p in $SERVER_PORT $PUBLIC_PORT; do
            semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null ||
            semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null || true
        done
    fi
fi

# ---------------------------------------------------------------- start
say "Starting Xray and nginx"
systemctl daemon-reload
systemctl enable --quiet xray-site
systemctl restart xray-site
systemctl enable --quiet nginx
if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl restart nginx; fi

# ---------------------------------------------------------------- firewall
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$SERVER_PORT/tcp" >/dev/null
    [ "$PUBLIC_PORT" != "$SERVER_PORT" ] && ufw allow "$PUBLIC_PORT/tcp" >/dev/null
    say "ufw: opened $SERVER_PORT/tcp"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port="$SERVER_PORT/tcp"
    [ "$PUBLIC_PORT" != "$SERVER_PORT" ] && firewall-cmd -q --permanent --add-port="$PUBLIC_PORT/tcp"
    firewall-cmd -q --reload
    say "firewalld: opened $SERVER_PORT/tcp"
fi

# ---------------------------------------------------------------- self-check
sleep 1
systemctl is-active --quiet xray-site || { journalctl -u xray-site -n 20 --no-pager >&2 || true; die "Xray did not start (log above)."; }
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SERVER_PORT/")"
[ "$code" = "200" ] || die "The website answered HTTP $code on port $SERVER_PORT instead of 200."
code="$(curl -s -o /dev/null -w '%{http_code}' --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' --max-time 3 \
    "http://127.0.0.1:$SERVER_PORT$WS_PATH" || true)"
[ "$code" = "101" ] || die "The VPN path answered HTTP $code instead of 101; check: journalctl -u xray-site"
say "Self-check passed: website 200, VPN path 101"

# ---------------------------------------------------------------- client link
if [ -z "$PUBLIC_IP" ]; then
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ipinfo.io/ip; do
        PUBLIC_IP="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')" && [ -n "$PUBLIC_IP" ] && break
    done
fi
[ -n "$PUBLIC_IP" ] || { PUBLIC_IP="YOUR_PUBLIC_IP"; warn "Could not detect your public IP; replace YOUR_PUBLIC_IP in the link."; }

enc_path="${WS_PATH//\//%2F}"
LINK="vless://$UUID@$PUBLIC_IP:$PUBLIC_PORT?encryption=none&security=none&type=ws&path=$enc_path#home-$PUBLIC_PORT"

cat > "$CONF_DIR/client.txt" <<EOF
Website:   http://$PUBLIC_IP:$PUBLIC_PORT/
VPN link:  $LINK

Manual settings
  protocol  VLESS
  address   $PUBLIC_IP
  port      $PUBLIC_PORT
  uuid      $UUID
  network   ws
  path      $WS_PATH
  security  none (no TLS)
EOF
chmod 600 "$CONF_DIR/client.txt"

echo
cat "$CONF_DIR/client.txt"
echo
if command -v qrencode >/dev/null; then qrencode -t ansiutf8 "$LINK"; fi
say "Saved to $CONF_DIR/client.txt. Site files: $SITE_DIR"
