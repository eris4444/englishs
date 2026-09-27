# Media Library

A single-file web app (`main.py`, FastAPI + Uvicorn) that serves the videos, images and
audio in one folder to your browser, behind a password. Video seeking works (full HTTP
Range support), subtitles next to a video are picked up, images open in a swipeable
lightbox, and playback position is remembered per video. Everything the browser needs
is inline, so the server needs no internet access.

## Run it

Requires Python 3.10+. `ffmpeg` is optional: with it, videos get thumbnails; without it,
they get a generic icon.

```sh
pip install -r requirements.txt
MEDIA_ROOT=/srv/media MEDIA_PASSWORD='a long passphrase' python main.py
```

Then open <http://localhost:8000>. The session cookie is `Secure`, so browsers only
accept it over HTTPS (Chrome and Firefox also allow plain `http://localhost`). To reach
the library from other devices, put it behind a TLS reverse proxy (below).

`uvicorn main:app --host 127.0.0.1 --port 8000` works too.

| Variable | Default | Meaning |
|---|---|---|
| `MEDIA_ROOT` | *required* | Folder to serve. The app refuses to start if it is missing or unreadable. |
| `MEDIA_PASSWORD` | *required* | The login password. Changing it logs out every session. |
| `SECRET_KEY` | generated | Signs session cookies. If unset, a random key is created once and saved to `.secret_key` next to `main.py`. |
| `HOST` / `PORT` | `127.0.0.1` / `8000` | Where `python main.py` listens. |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | Proxies whose `X-Forwarded-For` is trusted, so the login rate limit sees real client IPs. |

Thumbnails are cached in `.thumbs/` next to `main.py` (never inside `MEDIA_ROOT`); delete
the folder to rebuild them. Five failed logins from one IP (one /64 for IPv6) lock it out
for 15 minutes, and each failure is logged with the client address.

## nginx in front (TLS)

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
pip install pytest httpx
pytest
```
