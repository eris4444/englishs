#!/usr/bin/env python3
"""Helpers for the xray-site command: site templates and certificate checks.

    helper.py templates                 list the site templates (tab separated: name, title, description)
    helper.py site-get                  current site settings (JSON)
    helper.py site-set key=value ...    template=<name> and/or NAME= TAGLINE= EMAIL= PHONE= (texts are kept
                                        per template; an empty value means the template's own); renders the site
    helper.py site-reset                forget the current template's custom texts; renders the site
    helper.py site-texts                current template's texts: KEY<tab>value<tab>template default
    helper.py render                    render the selected template; prints the web root
    helper.py site-root                 print the web root of the selected template
    helper.py certinfo <file>           tab separated: domains (comma separated), expiry date, days left, issuer
    helper.py certcheck <cert> <key>    exit 0 when the key belongs to the certificate

Marzban API (the panel on this server, or XS_MZ_URL / XS_MZ_USER / XS_MZ_PASS for another one):
    helper.py mz-wait <seconds>                     wait until the panel accepts a login
    helper.py mz-node-cert                          the certificate nodes need (PEM)
    helper.py mz-nodes                              id, name, address, ports, status, message (tab separated)
    helper.py mz-node-add <name> <address> [port] [api port]   prints the new node's id
    helper.py mz-node-wait <id> <seconds>           wait for "connected"; prints the status
    helper.py mz-node-remove <id>
    helper.py mz-links <address> <json {inbound port: public port}>   address and port in client links
    helper.py mz-inbounds [xray_config.json]        tag, protocol, port (tab separated)

Only the Python standard library is used.
"""
import datetime
import html
import json
import os
import re
import shutil
import ssl
import struct
import sys
import tempfile
import time
import zlib

SHARE = os.environ.get("XS_SHARE", "/usr/local/share/xray-site")
CONF_DIR = os.environ.get("XS_CONF_DIR", "/etc/xray-site")
SITE_JSON = os.path.join(CONF_DIR, "site.json")
SITES_DIR = "/var/lib/xray-site/sites"
CUSTOM_DIR = "/var/www/xray-site"
TEMPLATES = os.path.join(SHARE, "templates")
VAR_KEYS = ("NAME", "TAGLINE", "EMAIL", "PHONE")
ORDER = ["download", "blog", "company", "shop", "hosting", "portfolio", "soon", "status", "nginx"]


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def fa_digits(s):
    return str(s).translate(str.maketrans("0123456789", "۰۱۲۳۴۵۶۷۸۹"))


def jalali_year(d=None):
    d = d or datetime.date.today()
    return d.year - 621 if (d.month, d.day) >= (3, 21) else d.year - 622


# ------------------------------------------------------------------ templates
def list_templates():
    try:
        names = os.listdir(TEMPLATES)
    except OSError:
        names = []
    names.sort(key=lambda n: (ORDER.index(n) if n in ORDER else 99, n))
    out = []
    for n in names:
        meta = read_json(os.path.join(TEMPLATES, n, "meta.json"), None)
        if meta and os.path.isfile(os.path.join(TEMPLATES, n, "index.html")):
            out.append({"name": n, "title": meta.get("title_en") or meta.get("title", n),
                        "description": meta.get("description_en") or meta.get("description", ""),
                        "defaults": meta.get("defaults", {})})
    out.append({"name": "custom", "title": "Your own site",
                "description": f"Your own files in {CUSTOM_DIR}", "defaults": {}})
    return out


def template_names():
    return [t["name"] for t in list_templates()]


def site_get():
    s = read_json(SITE_JSON, {})
    if "template" not in s:
        # An older install already has a site in CUSTOM_DIR: keep showing it.
        s["template"] = "custom" if os.path.isfile(os.path.join(CUSTOM_DIR, "index.html")) else "download"
    s.setdefault("texts", {})
    s.pop("vars", None)
    return s


def effective_vars(name, site):
    meta = read_json(os.path.join(TEMPLATES, name, "meta.json"), {})
    v = dict(meta.get("defaults", {}))
    for k, val in (site.get("texts", {}).get(name) or {}).items():
        if k in VAR_KEYS and val:
            v[k] = val
    return v


def render_html(name, site):
    with open(os.path.join(TEMPLATES, name, "index.html"), encoding="utf-8") as f:
        text = f.read()
    v = effective_vars(name, site)
    v["YEAR"] = fa_digits(jalali_year())
    v["GYEAR"] = str(datetime.date.today().year)
    v["LAUNCH_MS"] = str(int(site.get("launch_ms") or (time.time() + 45 * 86400) * 1000))

    def sub(m):
        k = m.group(1)
        if k not in v:
            return m.group(0)
        return v[k] if k == "LAUNCH_MS" else html.escape(v[k], quote=True)
    return re.sub(r"\{\{([A-Z_]+)\}\}", sub, text)


# ------------------------------------------------------------------ the small things a real site has
PLAIN = {"nginx"}   # templates shown exactly as they are (the stock nginx page has no extras)


def favicon_svg(letter, color):
    letter = html.escape((letter or "•")[:1])
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" '
            f'fill="{color}"/><text x="32" y="44" font-family="Tahoma,Arial,sans-serif" font-size="34" '
            f'font-weight="700" text-anchor="middle" fill="#fff">{letter}</text></svg>\n')


def favicon_ico(color):
    """A 32x32 rounded square in the template's colour, as a PNG inside an .ico file."""
    try:
        r, g, b = (int(color.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        r, g, b = 99, 102, 241
    size, rad = 32, 7
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            dx = max(rad - x, 0, x - (size - 1 - rad))
            dy = max(rad - y, 0, y - (size - 1 - rad))
            inside = dx * dx + dy * dy <= rad * rad
            row += bytes([r, g, b, 255 if inside else 0])
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))
    return struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(png), 22) + png


def page_404(name, color, lang):
    fa = lang != "en"
    title = "صفحه پیدا نشد" if fa else "Page not found"
    text = ("صفحه‌ای که دنبالش بودید وجود ندارد یا جابه‌جا شده است." if fa
            else "The page you are looking for does not exist or has been moved.")
    home = "بازگشت به صفحه اصلی" if fa else "Back to the home page"
    name = html.escape(name or "")
    return f"""<!doctype html>
<html lang="{'fa' if fa else 'en'}" dir="{'rtl' if fa else 'ltr'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>404 | {name or title}</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>
  body {{ margin:0; min-height:100vh; display:grid; place-items:center; background:#f6f7fb; color:#1c2030;
         font-family: Vazirmatn, IRANSans, Tahoma, "Segoe UI", sans-serif; text-align:center; padding:16px; }}
  @media (prefers-color-scheme: dark) {{ body {{ background:#11131a; color:#e6e8ef; }} }}
  b {{ display:block; font-size:96px; line-height:1; color:{color}; }}
  h1 {{ font-size:22px; margin:12px 0 6px; }}
  p {{ opacity:.7; margin:0 0 22px; }}
  a {{ display:inline-block; background:{color}; color:#fff; text-decoration:none; padding:10px 22px; border-radius:12px; }}
</style>
</head>
<body><div><b>404</b><h1>{title}</h1><p>{text}</p><a href="/">{home}</a></div></body>
</html>
"""


def head_extras(text, v, color):
    """Favicon, description and theme colour in <head>, unless the template already has them."""
    if 'rel="icon"' in text or "</head>" not in text:
        return text
    desc = html.escape(v.get("TAGLINE", ""), quote=True)
    title = html.escape(v.get("NAME", ""), quote=True)
    extra = ('<link rel="icon" href="/favicon.svg" type="image/svg+xml">\n'
             '<link rel="alternate icon" href="/favicon.ico">\n'
             f'<meta name="theme-color" content="{color}">\n')
    if desc:
        extra += f'<meta name="description" content="{desc}">\n<meta property="og:description" content="{desc}">\n'
    if title:
        extra += f'<meta property="og:title" content="{title}">\n<meta property="og:type" content="website">\n'
    return text.replace("</head>", extra + "</head>", 1)


def site_root(site=None):
    site = site or site_get()
    return CUSTOM_DIR if site["template"] == "custom" else os.path.join(SITES_DIR, site["template"])


def make_readable(top):
    for dirpath, _dirs, files in os.walk(top):
        os.chmod(dirpath, os.stat(dirpath).st_mode | 0o555)
        for fn in files:
            fp = os.path.join(dirpath, fn)
            os.chmod(fp, os.stat(fp).st_mode | 0o444)


def render_site():
    site = site_get()
    name = site["template"]
    if name == "custom":
        os.makedirs(CUSTOM_DIR, exist_ok=True)
        idx = os.path.join(CUSTOM_DIR, "index.html")
        if not os.path.exists(idx):   # start an empty custom site from the blog template
            with open(idx, "w", encoding="utf-8") as f:
                f.write(render_html("blog", site) if "blog" in template_names() else "<h1>Hello</h1>\n")
        make_readable(CUSTOM_DIR)
        return CUSTOM_DIR
    if name not in template_names():
        raise SystemExit(f"Unknown template: {name}")
    if name == "soon" and not site.get("launch_ms"):
        site["launch_ms"] = int((time.time() + 45 * 86400) * 1000)
        write_json(SITE_JSON, site)
    os.makedirs(SITES_DIR, exist_ok=True)
    dest = os.path.join(SITES_DIR, name)
    tmp = tempfile.mkdtemp(dir=SITES_DIR, prefix=".new-")
    src = os.path.join(TEMPLATES, name)
    for fn in os.listdir(src):
        p = os.path.join(src, fn)
        if fn == "meta.json" or not os.path.isfile(p):
            continue
        if fn == "index.html":
            body = render_html(name, site)
            if name not in PLAIN:
                meta = read_json(os.path.join(src, "meta.json"), {})
                body = head_extras(body, effective_vars(name, site), meta.get("accent", "#6366f1"))
            with open(os.path.join(tmp, fn), "w", encoding="utf-8") as f:
                f.write(body)
        else:
            shutil.copy(p, tmp)
    if name not in PLAIN:
        meta = read_json(os.path.join(src, "meta.json"), {})
        color, v = meta.get("accent", "#6366f1"), effective_vars(name, site)
        extras = {"favicon.svg": favicon_svg(v.get("NAME") or meta.get("title_en", name), color),
                  "robots.txt": "User-agent: *\nAllow: /\n",
                  "404.html": page_404(v.get("NAME", ""), color, meta.get("lang", "fa"))}
        for fn, body in extras.items():
            if not os.path.exists(os.path.join(tmp, fn)):
                with open(os.path.join(tmp, fn), "w", encoding="utf-8") as f:
                    f.write(body)
        if not os.path.exists(os.path.join(tmp, "favicon.ico")):
            with open(os.path.join(tmp, "favicon.ico"), "wb") as f:
                f.write(favicon_ico(color))
    make_readable(tmp)
    old = dest + ".old"
    shutil.rmtree(old, ignore_errors=True)
    if os.path.exists(dest):
        os.rename(dest, old)
    os.rename(tmp, dest)
    shutil.rmtree(old, ignore_errors=True)
    return dest


def site_set(pairs):
    site = site_get()
    if "template" in pairs:
        if pairs["template"] not in template_names():
            raise SystemExit(f"Unknown template \"{pairs['template']}\". Templates: {' '.join(template_names())}")
        site["template"] = pairs["template"]
    texts = site["texts"].setdefault(site["template"], {})
    for k, v in pairs.items():
        if k == "template":
            continue
        if k not in VAR_KEYS:
            raise SystemExit(f"Unknown setting \"{k}\". Use template= or {'= '.join(VAR_KEYS)}=")
        v = re.sub(r"[\x00-\x1f\x7f]", " ", v).strip()[:200]
        if v:
            texts[k] = v
        else:
            texts.pop(k, None)
    write_json(SITE_JSON, site)
    return render_site()


# ------------------------------------------------------------------ certificates
def cert_info(path):
    try:
        d = ssl._ssl._test_decode_cert(path)   # pylint: disable=protected-access
    except Exception:
        return None
    names = [v for k, v in d.get("subjectAltName", ()) if k in ("DNS", "IP Address")]
    if not names:
        names = [v for rdn in d.get("subject", ()) for k, v in rdn if k == "commonName"]
    issuer = next((v for rdn in d.get("issuer", ()) for k, v in rdn if k == "organizationName"), "") or \
        next((v for rdn in d.get("issuer", ()) for k, v in rdn if k == "commonName"), "")
    if d.get("issuer") == d.get("subject"):
        issuer = "self-signed"
    try:
        exp = ssl.cert_time_to_seconds(d["notAfter"])
        days = int((exp - time.time()) // 86400)
        date = datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).strftime("%Y-%m-%d")
    except Exception:
        days, date = -1, "?"
    return names, date, days, issuer


# ------------------------------------------------------------------ Marzban API
MZ_ENV = os.environ.get("XS_MZ_ENV", "/opt/marzban/.env")
MZ_XRAY = os.environ.get("XS_MZ_XRAY", "/var/lib/marzban/xray_config.json")


def env_file(path):
    out = {}
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


class Marzban:
    def __init__(self):
        import urllib.request
        if os.environ.get("XS_MZ_URL"):
            self.base = os.environ["XS_MZ_URL"].rstrip("/")
            self.user, self.pw = os.environ.get("XS_MZ_USER", ""), os.environ.get("XS_MZ_PASS", "")
        else:
            e = env_file(MZ_ENV)
            scheme = "https" if e.get("UVICORN_SSL_CERTFILE") else "http"
            self.base = f"{scheme}://127.0.0.1:{e.get('UVICORN_PORT', '8000')}"
            self.user, self.pw = e.get("SUDO_USERNAME", ""), e.get("SUDO_PASSWORD", "")
        # Local panels use their own (often self-signed) certificate; never go through a proxy.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                                  urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        self.token = None

    def req(self, method, path, data=None, form=None, quiet=False):
        import urllib.error
        import urllib.parse
        import urllib.request
        headers, body = {"Accept": "application/json"}, None
        if form is not None:
            body, headers["Content-Type"] = urllib.parse.urlencode(form).encode(), "application/x-www-form-urlencoded"
        elif data is not None:
            body, headers["Content-Type"] = json.dumps(data).encode(), "application/json"
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        r = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with self.opener.open(r, timeout=20) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                detail = json.loads(detail).get("detail", detail)
            except Exception:
                pass
            raise SystemExit(f"Marzban answered {e.code} to {method} {path}: {detail}")
        except Exception as e:
            if quiet:
                raise
            raise SystemExit(f"Cannot reach Marzban at {self.base}: {e}")
        return json.loads(raw) if raw else None

    def login(self, quiet=False):
        self.token = None
        self.token = self.req("POST", "/api/admin/token", form={"username": self.user, "password": self.pw},
                              quiet=quiet)["access_token"]
        return self


def xray_inbounds(path):
    try:
        cfg = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [i for i in cfg.get("inbounds", []) if isinstance(i, dict) and i.get("port")]


def mz_command(cmd, args):
    if cmd == "mz-inbounds":
        for i in xray_inbounds(args[0] if args else MZ_XRAY):
            print(f"{i.get('tag', '')}\t{i.get('protocol', '')}\t{i.get('port')}")
        return 0
    mz = Marzban()
    if cmd == "mz-wait":
        end = time.time() + int(args[0] if args else 120)
        while True:
            try:
                mz.login(quiet=True)
                print("ready")
                return 0
            except (Exception, SystemExit) as e:
                if time.time() > end:
                    print(f"not ready: {e}", file=sys.stderr)
                    return 1
                time.sleep(3)
    mz.login()
    if cmd == "mz-node-cert":
        print(mz.req("GET", "/api/node/settings")["certificate"].strip())
    elif cmd == "mz-nodes":
        for n in mz.req("GET", "/api/nodes") or []:
            msg = (n.get("message") or "").replace("\t", " ").replace("\n", " ")[:120]
            print(f"{n['id']}\t{n['name']}\t{n['address']}\t{n['port']}\t{n['api_port']}\t{n.get('status', '')}\t{msg}")
    elif cmd == "mz-node-add":
        name, address = args[0], args[1]
        port = int(args[2]) if len(args) > 2 else 62050
        api_port = int(args[3]) if len(args) > 3 else 62051
        n = mz.req("POST", "/api/node", data={"name": name, "address": address, "port": port, "api_port": api_port,
                                             "add_as_new_host": True, "usage_coefficient": 1})
        print(n["id"])
    elif cmd == "mz-node-wait":
        node_id, end = int(args[0]), time.time() + int(args[1] if len(args) > 1 else 90)
        while True:
            n = mz.req("GET", f"/api/node/{node_id}")
            if n.get("status") == "connected" or time.time() > end:
                print(f"{n.get('status')}\t{n.get('message') or ''}")
                return 0 if n.get("status") == "connected" else 1
            time.sleep(3)
    elif cmd == "mz-node-remove":
        mz.req("DELETE", f"/api/node/{int(args[0])}")
    elif cmd == "mz-links":
        address, portmap = args[0], json.loads(args[1] if len(args) > 1 else "{}")
        ports = {i.get("tag"): str(i.get("port")) for i in xray_inbounds(MZ_XRAY)}
        hosts = mz.req("GET", "/api/hosts") or {}
        for tag, lst in hosts.items():
            public = portmap.get(ports.get(tag, ""))
            for h in lst:
                h["address"] = address
                h["port"] = int(public) if public else None
        mz.req("PUT", "/api/hosts", data=hosts)
        print(f"{sum(len(v) for v in hosts.values())} link(s) now use {address}")
    else:
        raise SystemExit(f"unknown command {cmd}")
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    cmd, args = argv[0], argv[1:]
    if cmd.startswith("mz-"):
        return mz_command(cmd, args)
    if cmd == "templates":
        for t in list_templates():
            print(f"{t['name']}\t{t['title']}\t{t['description']}")
    elif cmd == "site-get":
        print(json.dumps(site_get(), ensure_ascii=False))
    elif cmd == "site-set":
        pairs = {}
        for a in args:
            if "=" not in a:
                raise SystemExit(f"Expected key=value, got \"{a}\"")
            k, v = a.split("=", 1)
            pairs[k] = v
        print(site_set(pairs))
    elif cmd == "site-reset":
        s = site_get()
        s["texts"].pop(s["template"], None)
        write_json(SITE_JSON, s)
        print(render_site())
    elif cmd == "site-texts":
        s = site_get()
        meta = read_json(os.path.join(TEMPLATES, s["template"], "meta.json"), {})
        own = s["texts"].get(s["template"], {})
        for k in VAR_KEYS:
            d = meta.get("defaults", {}).get(k, "")
            print(f"{k}\t{own.get(k) or d}\t{d}")
    elif cmd == "render":
        print(render_site())
    elif cmd == "site-root":
        print(site_root())
    elif cmd == "certinfo":
        info = cert_info(args[0])
        if not info:
            print(f"{args[0]} is not a readable PEM certificate", file=sys.stderr)
            return 1
        names, date, days, issuer = info
        print(f"{','.join(names)}\t{date}\t{days}\t{issuer}")
    elif cmd == "certcheck":
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(args[0], args[1])
        except Exception as e:
            print(e)
            return 1
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
