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

Only the Python standard library is used.
"""
import datetime
import html
import json
import os
import re
import shutil
import ssl
import sys
import tempfile
import time

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
            with open(os.path.join(tmp, fn), "w", encoding="utf-8") as f:
                f.write(render_html(name, site))
        else:
            shutil.copy(p, tmp)
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


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    cmd, args = argv[0], argv[1:]
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
