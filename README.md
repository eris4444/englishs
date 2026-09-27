# Media Library

A self-hosted web app for your videos, photos and music, in a single file (`main.py`,
FastAPI + Uvicorn). Video seeking works (full HTTP Range support), subtitles next to a
video are picked up, photos open in a swipeable lightbox, and playback position is
remembered per video. Everything the browser needs is inline, so the server needs no
internet access to serve pages.

<div dir="rtl">

## راه‌اندازی سریع

فقط فایل `main.py` را روی سرور لینوکسی (مثلاً اوبونتو) بگذارید و اجرا کنید:

```sh
sudo python3 main.py
```

برنامه هرچه لازم دارد را خودش نصب می‌کند و بعد می‌پرسد: پوشه‌ی فیلم و عکس و موزیک، رمز
عبور، اینکه گواهی HTTPS رایگان (Let's Encrypt) می‌خواهید یا نه، دامنه، و پورت. اگر
گواهی بخواهید، رکورد A دامنه باید از قبل به IP سرور اشاره کند و پورت ۸۰ آزاد باشد؛ گواهی
را خودش می‌گیرد، تنظیم می‌کند و خودکار تمدید می‌کند. در پایان سایت به‌صورت سرویس systemd
بالا می‌آید و بعد از ری‌استارت سرور هم خودش اجرا می‌شود. برای تغییر تنظیمات:
`sudo python3 main.py setup`

</div>

## One command setup

Copy `main.py` to a Linux server (Python 3.10+; Ubuntu 22.04+, Debian 12+ and similar) and run:

```sh
sudo python3 main.py
```

The first run:

1. installs what it needs into `.venv` next to `main.py` (installing `python3-venv`
   and `ffmpeg` with the system package manager when they are missing);
2. asks for the media folder, a password, whether you want a free HTTPS certificate
   (and if so the domain), and the port;
3. gets the certificate from Let's Encrypt (the domain's A record must point to the
   server and port 80 must be reachable), opens the ports in ufw/firewalld if active;
4. starts the site as a systemd service that runs at boot, or in the terminal where
   systemd is not available.

With HTTPS, port 80 answers Let's Encrypt and redirects everyone else to HTTPS. The
server renews the certificate by itself (it checks twice a day) and loads the new one
without restarting. If your hosting provider has its own firewall, allow TCP 80 and
your port there too.

| Command | What it does |
|---|---|
| `sudo python3 main.py` | First run: set up and start. Later: start with the saved settings. |
| `sudo python3 main.py setup` | Change the settings (your answers are the suggested defaults). |
| `sudo python3 main.py renew [--force]` | Renew the certificate now and load it into the running site. |
| `sudo python3 main.py uninstall` | Remove the systemd service (files and settings stay). |
| `python3 main.py serve` | Run in the foreground without questions (what the service runs). |
| `setup --staging` | Use Let's Encrypt's staging server to try things out (untrusted test certificates). |

Everything lives next to `main.py`: `config.json` (settings; the password is stored only
as a salted PBKDF2 hash), `.secret_key` (signs session cookies), `.venv/`, `.thumbs/`
(thumbnail cache, never inside the media folder) and `.certbot/` (certificates). Service
logs: `journalctl -u media-library -f`.

Five failed logins from one IP (one /64 for IPv6) lock it out for 15 minutes. The session
cookie is `HttpOnly`, `SameSite=Lax` and, whenever the site is reached over HTTPS,
`Secure`. Without HTTPS it cannot be `Secure` (browsers would drop it), and the password
travels unencrypted, so use a certificate when the site is reachable from the internet.

## Behind your own reverse proxy

Instead of `config.json`, the app can be configured with environment variables and put
behind nginx or similar:

```sh
pip install -r requirements.txt
MEDIA_ROOT=/srv/media MEDIA_PASSWORD='a long passphrase' python3 main.py serve
# or: uvicorn main:app --host 127.0.0.1 --port 8000
```

| Variable | Default | Meaning |
|---|---|---|
| `MEDIA_ROOT` | *required* | Folder to serve. The app refuses to start if it is missing or unreadable. |
| `MEDIA_PASSWORD` | *required* | The login password. Changing it logs out every session. |
| `SECRET_KEY` | generated | Signs session cookies. If unset, a random key is created once and saved to `.secret_key`. |
| `HOST` / `PORT` | `127.0.0.1` / `8000` | Where `python3 main.py serve` listens. |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | Proxies whose `X-Forwarded-For`/`-Proto` are trusted, so the rate limit sees real client IPs. |
| `MEDIA_NO_VENV` | unset | `1` uses the current Python instead of creating `.venv` (install `requirements.txt` yourself). |

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name media.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;                      # nginx < 1.25.1: use "listen 443 ssl http2;" instead
    server_name media.example.com;

    ssl_certificate     /etc/letsencrypt/live/media.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/media.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;

    # Nothing is uploaded; the only request body is the login form.
    client_max_body_size 64k;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Overwrite rather than append, so clients cannot fake their IP to the rate limiter.
        proxy_set_header X-Forwarded-For $remote_addr;

        # Stream video straight through instead of buffering it in nginx, and
        # let long playback sessions stay open.
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

## Tests

```sh
pip install -r requirements.txt pytest httpx
pytest
```
