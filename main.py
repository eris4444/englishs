#!/usr/bin/env python3
"""Personal media library server in a single file.

Run it and answer a few questions::

    sudo python3 main.py

The first run installs everything it needs (into .venv next to this file),
asks for your media folder, a password, the port, and whether to get a free
Let's Encrypt HTTPS certificate for your domain, then starts the server, as a
systemd service when it can. Later runs start it with the same answers.

    python3 main.py setup      change the answers
    python3 main.py serve      start without any questions (what the service runs)
    python3 main.py renew      renew the HTTPS certificate now
    python3 main.py uninstall  remove the systemd service

It can also be configured with environment variables and run behind your own
reverse proxy (``uvicorn main:app``); README.md has the details.
"""

from __future__ import annotations

import sys

if sys.version_info < (3, 10):  # checked before anything that needs a newer Python
    sys.exit("This program needs Python 3.10 or newer (found %d.%d)." % sys.version_info[:2])

import argparse
import asyncio
import base64
import contextlib
import functools
import getpass
import hashlib
import hmac
import html
import importlib.util
import ipaddress
import json
import logging
import math
import os
import re
import secrets
import shutil
import signal
import socket
import socketserver
import ssl
import stat
import subprocess
import tempfile
import threading
import time
import urllib.request
from collections import Counter, deque
from dataclasses import asdict, dataclass, fields
from datetime import timezone
from email.utils import formatdate, parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence, Union
from urllib.parse import parse_qs, quote, urlsplit

APP_DIR = Path(__file__).resolve().parent
SCRIPT = Path(__file__).resolve()
VENV_DIR = APP_DIR / ".venv"
REQUIREMENTS = {  # import name -> pip requirement
    "fastapi": "fastapi>=0.115",
    "uvicorn": "uvicorn[standard]>=0.30",
    "itsdangerous": "itsdangerous>=2.1",
    "PIL": "Pillow>=11.3",
}
CERTBOT_REQUIREMENT = "certbot>=2.0"


# --------------------------------------------------------------------------
# Bootstrap. Standard library only: this runs before the web stack exists.
# --------------------------------------------------------------------------

_COLORS = {"bold": "1", "dim": "2", "red": "31", "green": "32", "yellow": "33"}


def say(message: str = "", color: str = "") -> None:
    """Print a line for the person running the command, coloured on terminals."""
    if color and sys.stdout.isatty() and "NO_COLOR" not in os.environ:
        message = f"\033[{_COLORS[color]}m{message}\033[0m"
    print(message, flush=True)


def is_root() -> bool:
    """True when running as root (needed for ports below 1024, apt and systemd)."""
    return hasattr(os, "geteuid") and os.geteuid() == 0


_PACKAGE_MANAGERS = (  # (tool, install command, command that refreshes its index first)
    ("apt-get", ["apt-get", "install", "-y", "-q"], ["apt-get", "update", "-q"]),
    ("dnf", ["dnf", "install", "-y", "-q"], None),
    ("yum", ["yum", "install", "-y", "-q"], None),
    ("zypper", ["zypper", "--non-interactive", "install"], None),
    ("pacman", ["pacman", "-S", "--noconfirm", "--needed"], ["pacman", "-Sy"]),
    ("apk", ["apk", "add"], None),
)


@functools.lru_cache(maxsize=None)
def _refresh_package_index(command: tuple[str, ...]) -> None:
    subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def install_system_package(*names: str) -> bool:
    """Install the first of names the system package manager has. Needs root."""
    if not is_root():
        return False
    env = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
    for tool, install, refresh in _PACKAGE_MANAGERS:
        if shutil.which(tool) is None:
            continue
        if refresh:
            _refresh_package_index(tuple(refresh))
        for name in names:
            if subprocess.run([*install, name], env=env, capture_output=True, check=False).returncode == 0:
                return True
        return False
    return False


def venv_python() -> Path:
    """The interpreter inside .venv."""
    return VENV_DIR / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def create_venv() -> bool:
    """Create .venv, first installing Debian/Ubuntu's python3-venv if it is missing."""
    say("Preparing a private Python environment in .venv (first run only)...")
    version = "%d.%d" % sys.version_info[:2]
    for attempt in range(2):
        made = subprocess.run(
            [sys.executable, "-m", "venv", "--clear", str(VENV_DIR)], capture_output=True, text=True, check=False
        )
        if made.returncode == 0 and venv_python().exists():
            return True
        shutil.rmtree(VENV_DIR, ignore_errors=True)
        if attempt == 0 and not install_system_package(f"python{version}-venv", "python3-venv"):
            break
    say(f"Could not create {VENV_DIR}:\n{(made.stderr or made.stdout).strip()}", "red")
    return False


def pip_install(*requirements: str) -> None:
    """Install packages into the running interpreter (our .venv)."""
    names = ", ".join(re.split(r"[<>=\[]", req)[0] for req in requirements)
    say(f"Installing {names} (first run only, about a minute)...")
    command = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--quiet", *requirements]
    if subprocess.run(command, check=False).returncode != 0:
        sys.exit("Installing Python packages failed; pip's output above says why.")


def bootstrap() -> None:
    """Make the web stack importable before the rest of this file imports it.

    Packages go into .venv next to this file, never into the system Python:
    unless we already run from .venv, create it and re-run this script with
    its interpreter. MEDIA_NO_VENV=1 uses the current interpreter instead.
    """
    missing = [req for module, req in REQUIREMENTS.items() if importlib.util.find_spec(module) is None]
    in_venv = Path(sys.prefix).resolve() == VENV_DIR.resolve()
    if in_venv or os.environ.get("MEDIA_NO_VENV") == "1":
        if missing:
            pip_install(*missing)
        return
    if venv_python().exists() or create_venv():
        os.execv(venv_python(), [str(venv_python()), str(SCRIPT), *sys.argv[1:]])
    if missing:
        sys.exit(f"Could not install the Python packages. Install them yourself: pip install {' '.join(missing)}")


if __name__ == "__main__":
    bootstrap()

# The rest of the file needs the packages bootstrap() installs.
import anyio  # noqa: E402
import uvicorn  # noqa: E402
from fastapi import FastAPI, Query, Request  # noqa: E402
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response  # noqa: E402
from itsdangerous import BadData, URLSafeTimedSerializer  # noqa: E402
from PIL import Image, ImageOps  # noqa: E402
from starlette.concurrency import run_in_threadpool  # noqa: E402
from starlette.datastructures import Headers  # noqa: E402
from starlette.exceptions import HTTPException  # noqa: E402
from starlette.requests import HTTPConnection  # noqa: E402
from starlette.types import ASGIApp, Message, Receive, Scope, Send  # noqa: E402

log = logging.getLogger("media")

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

CONFIG_FILE = APP_DIR / "config.json"
CERTBOT_DIR = APP_DIR / ".certbot"
ACME_WEBROOT = CERTBOT_DIR / "webroot"
SERVICE_NAME = "media-library"
SERVICE_FILE = Path("/etc/systemd/system") / f"{SERVICE_NAME}.service"
LETSENCRYPT_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
PBKDF2_ITERATIONS = 600_000  # OWASP's 2023 recommendation for PBKDF2-HMAC-SHA256
CERT_RENEW_INTERVAL = 12 * 60 * 60  # seconds between `certbot renew` runs

VIDEO_TYPES = {
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    # QuickTime is the same ISO-BMFF container as MP4. Firefox refuses to play
    # anything labelled video/quicktime but plays the identical bytes as MP4.
    ".mov": "video/mp4",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
    ".avi": "video/x-msvideo",
}
IMAGE_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".avif": "image/avif",
}
AUDIO_TYPES = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".flac": "audio/flac",
    ".ogg": "audio/ogg",
}
MEDIA_TYPES = {**VIDEO_TYPES, **IMAGE_TYPES, **AUDIO_TYPES}
KIND_BY_EXT = {
    **{ext: "video" for ext in VIDEO_TYPES},
    **{ext: "image" for ext in IMAGE_TYPES},
    **{ext: "audio" for ext in AUDIO_TYPES},
}
SUBTITLE_EXTS = (".vtt", ".srt")

SESSION_COOKIE = "media_session"
SESSION_MAX_AGE = 30 * 24 * 60 * 60  # 30 days
LOGIN_MAX_FAILURES = 5
LOGIN_LOCKOUT_SECONDS = 15 * 60

STREAM_CHUNK_SIZE = 256 * 1024  # bytes read from disk per send()
MAX_RANGES = 16  # more ranges than this in one request is abuse, not a player

THUMB_EDGE = 480  # longest thumbnail edge in pixels
THUMB_VERSION = "1"  # bump to invalidate every cached thumbnail
FFMPEG_TIMEOUT = 60  # seconds
MAX_SUBTITLE_BYTES = 5 * 1024 * 1024


def media_kind(name: str) -> str | None:
    """Return ``"video"``, ``"image"`` or ``"audio"`` for a recognised file name."""
    return KIND_BY_EXT.get(os.path.splitext(name)[1].lower())


def is_listable_name(name: str) -> bool:
    """Hide dotfiles, and names that could not round-trip through a URL."""
    if not name or name.startswith(".") or "\\" in name:
        return False
    try:
        name.encode("utf-8")
    except UnicodeEncodeError:  # undecodable bytes on disk surface as lone surrogates
        return False
    return True


_DIGIT_RUNS = re.compile(r"([0-9]+)")


def natural_key(name: str) -> tuple[tuple[str | int, ...], str]:
    """Case-insensitive sort key that orders digit runs numerically ("Ep 2" < "Ep 10")."""
    parts = _DIGIT_RUNS.split(name.casefold())
    return tuple(int(part) if i % 2 else part for i, part in enumerate(parts)), name


def human_size(size: float) -> str:
    """Format a byte count for people: ``1.4 GB``."""
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024:
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


def plural(count: int, noun: str) -> str:
    """``plural(1, "video") == "1 video"``, ``plural(2, "video") == "2 videos"``."""
    return f"{count} {noun}{'' if count == 1 else 's'}"


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------


class ConfigError(Exception):
    """The environment or config.json does not describe a server that can start."""


@dataclass(frozen=True)
class Settings:
    """What the web app needs, from environment variables or from config.json."""

    media_root: Path
    secret_key: str
    password: str = ""  # MEDIA_PASSWORD in plain text, or...
    password_hash: str = ""  # ...a hash_password() result from config.json
    thumb_dir: Path = APP_DIR / ".thumbs"
    ffmpeg: str | None = None
    ffprobe: str | None = None

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None, app_dir: Path = APP_DIR) -> Settings:
        """Use MEDIA_ROOT and MEDIA_PASSWORD when either is set, else config.json.

        Every problem is reported at once.
        """
        env = os.environ if environ is None else environ
        secret_key = functools.partial(load_secret_key, env.get("SECRET_KEY", ""), app_dir / ".secret_key")
        tools = {"ffmpeg": shutil.which("ffmpeg"), "ffprobe": shutil.which("ffprobe")}

        if "MEDIA_ROOT" not in env and "MEDIA_PASSWORD" not in env:
            site = SiteConfig.load(app_dir / "config.json")
            if site is None:
                raise ConfigError(
                    "Not set up yet. Run `python3 main.py` in a terminal and answer the questions, "
                    "or set MEDIA_ROOT and MEDIA_PASSWORD."
                )
            media_root = check_media_root(site.media_root, label="The media folder")
            return cls(media_root, secret_key(), password_hash=site.password_hash, thumb_dir=app_dir / ".thumbs", **tools)

        problems: list[str] = []
        root: Path | None = None
        raw_root = env.get("MEDIA_ROOT", "").strip()
        if not raw_root:
            problems.append("MEDIA_ROOT is not set. Point it at the folder to serve, e.g. MEDIA_ROOT=/srv/media")
        else:
            try:
                root = check_media_root(raw_root)
            except ConfigError as exc:
                problems.append(str(exc))

        password = env.get("MEDIA_PASSWORD", "")
        if not password.strip():
            problems.append("MEDIA_PASSWORD is not set. Export the password that unlocks the library.")

        if problems:
            raise ConfigError("\n".join(problems))
        assert root is not None
        return cls(root, secret_key(), password=password, thumb_dir=app_dir / ".thumbs", **tools)


@dataclass
class SiteConfig:
    """The setup answers, kept in config.json next to this file (owner-only)."""

    media_root: str
    password_hash: str
    port: int
    domain: str = ""  # when set: HTTPS with a Let's Encrypt certificate for it
    email: str = ""  # optional contact address for the Let's Encrypt account
    acme_server: str = ""  # empty means Let's Encrypt itself
    host: str = ""  # address to listen on; empty means every IPv4 and IPv6 address

    def __post_init__(self) -> None:
        self.port = int(self.port)

    @property
    def tls(self) -> bool:
        """True when the site is served over HTTPS."""
        return bool(self.domain)

    @classmethod
    def load(cls, path: Path = CONFIG_FILE) -> SiteConfig | None:
        """Read config.json; None when setup has not been run yet."""
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return cls(**{f.name: data[f.name] for f in fields(cls) if f.name in data})
        except FileNotFoundError:
            return None
        except PermissionError:
            raise ConfigError(f"{path} belongs to another user; run this with sudo.") from None
        except (OSError, ValueError, TypeError) as exc:
            raise ConfigError(f"{path} is damaged ({exc}). Run `python3 main.py setup` to write it again.") from None

    def save(self, path: Path = CONFIG_FILE) -> None:
        """Write config.json atomically, readable by its owner only (it holds the password hash)."""
        tmp = path.with_name(f".{path.name}.tmp")
        tmp.unlink(missing_ok=True)
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as fh:
            json.dump(asdict(self), fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)

    def public_url(self) -> str:
        """The address people open in their browser."""
        if self.tls:
            return f"https://{self.domain}" + ("" if self.port == 443 else f":{self.port}")
        host = self.host or guess_server_ip()
        if ":" in host:
            host = f"[{host}]"
        return f"http://{host}" + ("" if self.port == 80 else f":{self.port}")


def check_media_root(raw: str, label: str = "MEDIA_ROOT") -> Path:
    """Resolve the media folder and check that it is a readable directory."""
    try:
        root = Path(raw).expanduser().resolve(strict=True)
    except FileNotFoundError:
        raise ConfigError(f"{label} ({raw}) does not exist.") from None
    except (OSError, RuntimeError) as exc:
        raise ConfigError(f"{label} ({raw}) cannot be opened: {exc}") from None
    if not root.is_dir():
        raise ConfigError(f"{label} ({raw}) is not a directory.")
    if not os.access(root, os.R_OK | os.X_OK):
        raise ConfigError(f"{label} ({raw}) is not readable by this user.")
    return root


def load_secret_key(configured: str, key_file: Path) -> str:
    """Return SECRET_KEY, or a random key that is generated once and kept in key_file."""
    if configured.strip():
        return configured.strip()
    try:
        if not key_file.exists():
            # Write the key to a private temp file, then hard-link it into
            # place. The link is atomic, so concurrent workers never read a
            # half-written file and all of them agree on whichever key won.
            fd, tmp = tempfile.mkstemp(dir=key_file.parent, prefix=".secret_key.")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(secrets.token_urlsafe(48) + "\n")
                try:
                    os.link(tmp, key_file)
                    log.info("Generated SECRET_KEY and saved it to %s", key_file)
                except FileExistsError:
                    pass
            finally:
                os.unlink(tmp)
        key = key_file.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ConfigError(f"Cannot create or read {key_file} ({exc}). Set SECRET_KEY instead.") from None
    if not key:
        raise ConfigError(f"{key_file} is empty. Delete it to generate a new key, or set SECRET_KEY.")
    return key


def load_settings_or_exit() -> Settings:
    """Read the environment; on bad config print a readable message and exit."""
    try:
        return Settings.from_env()
    except ConfigError as exc:
        details = "\n".join(f"  - {line}" for line in str(exc).splitlines())
        print(f"\nCannot start the media server:\n{details}\n", file=sys.stderr)
        raise SystemExit(2) from None


# --------------------------------------------------------------------------
# Authentication: password check, login rate limiting, signed sessions
# --------------------------------------------------------------------------


def hash_password(password: str, iterations: int = PBKDF2_ITERATIONS) -> str:
    """Salted PBKDF2-SHA256 hash, stored as ``pbkdf2_sha256$iterations$salt$digest``."""
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8", "surrogateescape"), salt, iterations)
    return "$".join(["pbkdf2_sha256", str(iterations), base64.b64encode(salt).decode(), base64.b64encode(digest).decode()])


class PasswordChecker:
    """Timing-safe password verification against a salted PBKDF2 hash.

    The submitted password goes through the same PBKDF2 as the stored one,
    and ``hmac.compare_digest`` compares the two fixed-length digests, so the
    time taken reveals neither the password nor its length. PBKDF2 is slow
    on purpose (~0.4 s): call ``verify`` from a worker thread.
    """

    def __init__(self, password_hash: str) -> None:
        try:
            scheme, iterations, salt, digest = password_hash.split("$")
            if scheme != "pbkdf2_sha256":
                raise ValueError(scheme)
            self._iterations = int(iterations)
            self._salt = base64.b64decode(salt, validate=True)
            self._digest = base64.b64decode(digest, validate=True)
        except ValueError:
            raise ConfigError("The saved password hash is damaged. Run `python3 main.py setup` to set the password again.") from None

    def verify(self, candidate: str) -> bool:
        """True if candidate is the password."""
        attempt = hashlib.pbkdf2_hmac("sha256", candidate.encode("utf-8", "surrogateescape"), self._salt, self._iterations)
        return hmac.compare_digest(attempt, self._digest)


class LoginRateLimiter:
    """In-memory failed-login tracking per client.

    ``max_failures`` failures within ``lockout_seconds`` lock the client out
    for ``lockout_seconds``. Nothing is persisted; a restart forgets everything.
    """

    def __init__(
        self,
        max_failures: int = LOGIN_MAX_FAILURES,
        lockout_seconds: int = LOGIN_LOCKOUT_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.max_failures = max_failures
        self.lockout_seconds = lockout_seconds
        self.clock = clock
        self._failures: dict[str, deque[float]] = {}
        self._locked_until: dict[str, float] = {}
        self._lock = threading.Lock()

    def retry_after(self, client: str) -> int:
        """Seconds until client may try again; 0 if it is not locked out."""
        now = self.clock()
        with self._lock:
            until = self._locked_until.get(client)
            if until is None:
                return 0
            if until <= now:
                del self._locked_until[client]
                return 0
            return math.ceil(until - now)

    def record_failure(self, client: str) -> int:
        """Count a failed attempt. Returns attempts left; 0 means now locked out."""
        now = self.clock()
        with self._lock:
            self._prune(now)
            recent = self._failures.setdefault(client, deque())
            while recent and recent[0] <= now - self.lockout_seconds:
                recent.popleft()
            recent.append(now)
            if len(recent) < self.max_failures:
                return self.max_failures - len(recent)
            del self._failures[client]
            self._locked_until[client] = now + self.lockout_seconds
            return 0

    def reset(self, client: str) -> None:
        """Forget a client's failures after it logs in successfully."""
        with self._lock:
            self._failures.pop(client, None)
            self._locked_until.pop(client, None)

    def _prune(self, now: float) -> None:
        """Drop stale entries once the tables grow, so memory stays bounded."""
        if len(self._failures) + len(self._locked_until) < 1024:
            return
        horizon = now - self.lockout_seconds
        self._failures = {c: q for c, q in self._failures.items() if q and q[-1] > horizon}
        self._locked_until = {c: t for c, t in self._locked_until.items() if t > now}


def client_key(host: str | None) -> str:
    """Rate-limit key for a client address.

    IPv6 clients are grouped by /64, the smallest block an ISP hands out;
    otherwise one household could cycle through billions of addresses.
    """
    if not host:
        return "unknown"
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return host
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return str(ip.ipv4_mapped)
        network = int(ip) >> 64 << 64
        return f"{ipaddress.IPv6Address(network)}/64"
    return str(ip)


class SessionManager:
    """Stateless sessions: an itsdangerous-signed, timestamped cookie value."""

    def __init__(self, secret_key: str, credential: str, max_age: int = SESSION_MAX_AGE) -> None:
        # The password (or its stored hash) is folded into the signing salt,
        # so changing the password invalidates every existing session.
        fingerprint = hashlib.sha256(credential.encode("utf-8", "surrogateescape")).hexdigest()
        self._serializer = URLSafeTimedSerializer(secret_key, salt=f"media-session:{fingerprint}")
        self.max_age = max_age

    def issue(self) -> str:
        """Create a new session token."""
        return self._serializer.dumps({"sid": secrets.token_urlsafe(16)})

    def is_valid(self, token: str | None) -> bool:
        """True if token was signed by us and is younger than max_age."""
        if not token:
            return False
        try:
            self._serializer.loads(token, max_age=self.max_age)
        except BadData:  # bad signature, expired, or garbage
            return False
        return True


def safe_next(target: str | None) -> str:
    """Post-login redirect target, restricted to local paths (no open redirects)."""
    if (
        not target
        or not target.startswith("/")
        or target.startswith("//")
        or "\\" in target
        or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in target)
    ):
        return "/"
    parts = urlsplit(target)
    if parts.scheme or parts.netloc or parts.path in ("/login", "/logout"):
        return "/"
    return target


async def read_form(request: Request, limit: int = 8 * 1024) -> dict[str, str]:
    """Parse a small urlencoded form body without needing python-multipart."""
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > limit:
            raise HTTPException(status_code=413)
    try:
        fields = parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True, max_num_fields=20)
    except ValueError:
        raise HTTPException(status_code=400) from None
    return {key: values[0] for key, values in fields.items()}


# --------------------------------------------------------------------------
# The media library: every filesystem path derived from a URL goes through here
# --------------------------------------------------------------------------


class NotFound(HTTPException):
    """404, used for anything missing, hidden, unsupported or outside MEDIA_ROOT."""

    def __init__(self) -> None:
        super().__init__(status_code=404)


def clean_rel(rel: str) -> str:
    """Normalise a URL path to ``a/b/c`` form (no empty or trailing segments)."""
    return "/".join(part for part in rel.split("/") if part)


def parent_rel(rel: str) -> str:
    """``"a/b/c.mp4"`` -> ``"a/b"``; ``"c.mp4"`` -> ``""``."""
    return rel.rpartition("/")[0]


@dataclass(frozen=True)
class Entry:
    """One visible item of a folder listing."""

    name: str
    rel: str  # "/"-separated path relative to MEDIA_ROOT, as used in URLs
    kind: str  # "folder", "video", "image" or "audio"
    size: int
    mtime: float


@dataclass(frozen=True)
class SubtitleTrack:
    """A subtitle file that belongs to a video."""

    rel: str
    label: str
    srclang: str | None


_LANGUAGE_TAG = re.compile(r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*")


class MediaLibrary:
    """Read-only view of MEDIA_ROOT that never lets a URL escape it."""

    def __init__(self, root: Path) -> None:
        self.root = root  # already resolved by check_media_root

    def resolve(self, rel: str) -> Path:
        """Map a path taken from a URL onto an existing path inside MEDIA_ROOT.

        The candidate is resolved with ``Path.resolve`` (following every
        symlink) and must then satisfy ``is_relative_to(MEDIA_ROOT)``.
        ``..`` (plain or URL-encoded, which arrives here decoded), absolute
        paths, symlinks pointing outside the root, hidden files and missing
        paths all raise NotFound.
        """
        if rel.startswith("/") or "\\" in rel or "\x00" in rel:
            raise NotFound()
        parts = [part for part in rel.split("/") if part]
        if any(part.startswith(".") for part in parts):  # ".", ".." and dotfiles
            raise NotFound()
        try:
            resolved = self.root.joinpath(*parts).resolve(strict=True)
        except (OSError, RuntimeError, ValueError):  # missing, unreadable, symlink loop
            raise NotFound() from None
        if not self._visible(resolved):
            raise NotFound()
        return resolved

    def _visible(self, resolved: Path) -> bool:
        return resolved.is_relative_to(self.root) and not any(
            part.startswith(".") for part in resolved.relative_to(self.root).parts
        )

    def _link_ok(self, item: os.DirEntry[str]) -> bool:
        """False for symlinks that lead outside MEDIA_ROOT (or nowhere)."""
        if not item.is_symlink():
            return True
        try:
            return self._visible(Path(item.path).resolve(strict=True))
        except (OSError, RuntimeError):
            return False

    def list_dir(self, directory: Path, rel: str) -> list[Entry]:
        """Visible folders and media files in directory: folders first, then
        files, each group in natural alphabetical order."""
        folders: list[Entry] = []
        files: list[Entry] = []
        prefix = f"{rel}/" if rel else ""
        with os.scandir(directory) as items:
            for item in items:
                if not is_listable_name(item.name):
                    continue
                try:
                    if not self._link_ok(item):
                        continue
                    if item.is_dir():
                        folders.append(Entry(item.name, prefix + item.name, "folder", 0, 0.0))
                        continue
                    kind = media_kind(item.name)
                    if kind is None or not item.is_file():
                        continue
                    info = item.stat()
                except OSError:
                    continue
                files.append(Entry(item.name, prefix + item.name, kind, info.st_size, info.st_mtime))
        folders.sort(key=lambda entry: natural_key(entry.name))
        files.sort(key=lambda entry: natural_key(entry.name))
        return folders + files

    def subtitles_for(self, rel: str) -> list[SubtitleTrack]:
        """Subtitle files next to the video at rel.

        ``Movie.vtt`` / ``Movie.srt`` match ``Movie.mp4``, and so do language
        variants such as ``Movie.en.srt``. A .vtt wins over a .srt with the
        same label because browsers read WebVTT natively.
        """
        folder = parent_rel(rel)
        stem = os.path.splitext(PurePosixPath(rel).name)[0]
        chosen: dict[str, str] = {}  # label -> file name
        with os.scandir(self.resolve(folder)) as items:
            for item in items:
                base, ext = os.path.splitext(item.name)
                ext = ext.lower()
                if ext not in SUBTITLE_EXTS or not is_listable_name(item.name):
                    continue
                if base == stem:
                    label = ""
                elif base.startswith(stem + "."):
                    label = base[len(stem) + 1 :]
                else:
                    continue
                try:
                    if not (self._link_ok(item) and item.is_file()):
                        continue
                except OSError:
                    continue
                if label not in chosen or ext == ".vtt":
                    chosen[label] = item.name
        tracks = []
        for label in sorted(chosen, key=natural_key):
            language = label.split(".")[0]
            tracks.append(
                SubtitleTrack(
                    rel=f"{folder}/{chosen[label]}" if folder else chosen[label],
                    label=label or "Subtitles",
                    srclang=language if _LANGUAGE_TAG.fullmatch(language) else None,
                )
            )
        return tracks


# --------------------------------------------------------------------------
# HTTP Range requests and streaming
# --------------------------------------------------------------------------

ByteRange = tuple[int, int]  # inclusive (first, last) byte positions
Segment = Union[bytes, tuple[int, int]]  # literal bytes, or (offset, length) of the file

_RANGE_SPEC = re.compile(r"([0-9]*)-([0-9]*)")


class RangeNotSatisfiable(Exception):
    """The Range header is malformed, or none of its ranges overlap the file."""


def parse_range_header(header: str, size: int, max_ranges: int = MAX_RANGES) -> list[ByteRange]:
    """Parse ``Range: bytes=...`` (RFC 9110 section 14) for a file of size bytes.

    Handles ``first-last``, open-ended ``first-`` and suffix ``-length`` specs,
    and comma-separated lists of them. Returns inclusive ``(first, last)``
    pairs clamped to the file; overlapping or adjacent ranges are merged.

    Raises RangeNotSatisfiable for anything malformed (another unit,
    non-digits, ``last < first``, too many ranges) and when no range overlaps
    the file; the caller answers both with 416.
    """
    unit, sep, spec = header.partition("=")
    if not sep or unit.strip().lower() != "bytes":
        raise RangeNotSatisfiable(header)
    specs = [part.strip() for part in spec.split(",") if part.strip()]
    if not specs or len(specs) > max_ranges:
        raise RangeNotSatisfiable(header)

    ranges: list[ByteRange] = []
    for part in specs:
        match = _RANGE_SPEC.fullmatch(part)
        if match is None:
            raise RangeNotSatisfiable(header)
        first_text, last_text = match.groups()
        try:
            first = int(first_text) if first_text else None
            last = int(last_text) if last_text else None
        except ValueError:  # thousands of digits: Python refuses to convert them
            raise RangeNotSatisfiable(header) from None
        if first is not None:
            if last is not None and last < first:
                raise RangeNotSatisfiable(header)
            if first < size:  # a range starting past the end is skipped, not fatal
                ranges.append((first, size - 1 if last is None else min(last, size - 1)))
        elif last is not None:
            if last > 0 and size > 0:  # "-500" means the final 500 bytes
                ranges.append((max(0, size - last), size - 1))
        else:
            raise RangeNotSatisfiable(header)  # a bare "-"
    if not ranges:
        raise RangeNotSatisfiable(header)

    merged: list[ByteRange] = []
    for first, last in sorted(ranges):
        if merged and first <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], last))
        else:
            merged.append((first, last))
    # Parts should come back in the order they were asked for, unless some
    # overlapped and had to be combined (RFC 9110 section 15.3.7.2).
    return merged if len(merged) < len(ranges) else ranges


def multipart_segments(ranges: Sequence[ByteRange], size: int, media_type: str, boundary: str) -> list[Segment]:
    """Body plan for a ``multipart/byteranges`` response."""
    segments: list[Segment] = []
    for first, last in ranges:
        head = f"--{boundary}\r\nContent-Type: {media_type}\r\nContent-Range: bytes {first}-{last}/{size}\r\n\r\n"
        segments.append((f"\r\n{head}" if segments else head).encode("latin-1"))
        segments.append((first, last - first + 1))
    segments.append(f"\r\n--{boundary}--\r\n".encode("latin-1"))
    return segments


def parse_http_date(value: str) -> float | None:
    """Parse an HTTP date header into a Unix timestamp (None if invalid)."""
    try:
        parsed = parsedate_to_datetime(value)
    except (TypeError, ValueError, IndexError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def is_not_modified(headers: Headers, etag: str, mtime: float) -> bool:
    """Evaluate If-None-Match, else If-Modified-Since (RFC 9110 section 13.2.2)."""
    if_none_match = headers.get("if-none-match")
    if if_none_match is not None:
        tags = {tag.strip().removeprefix("W/") for tag in if_none_match.split(",")}
        return "*" in tags or etag in tags
    since = parse_http_date(headers.get("if-modified-since", ""))
    return since is not None and int(mtime) <= since


def if_range_allows(if_range: str | None, etag: str, last_modified: str) -> bool:
    """False when If-Range names an older version, so the full file is sent instead."""
    return if_range is None or if_range.strip() in (etag, last_modified)


async def _cancel_on_disconnect(receive: Receive, scope: anyio.CancelScope) -> None:
    """Cancel scope as soon as the client goes away.

    Browsers abort a range request every time the viewer seeks. Uvicorn then
    silently drops further ``send()`` calls, so without this watcher a stream
    would go on reading the rest of a multi-gigabyte file into the void.
    """
    while (await receive())["type"] != "http.disconnect":
        pass
    scope.cancel()


class FileStreamResponse(Response):
    """Sends parts of a file in fixed-size chunks, never the whole file at once."""

    def __init__(
        self,
        path: Path,
        segments: Sequence[Segment],
        *,
        status_code: int,
        headers: Mapping[str, str],
        media_type: str,
    ) -> None:
        self.path = path
        self.segments = list(segments)
        length = sum(len(s) if isinstance(s, bytes) else s[1] for s in self.segments)
        super().__init__(
            status_code=status_code,
            headers={**headers, "Content-Length": str(length)},
            media_type=media_type,
        )

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        start: Message = {"type": "http.response.start", "status": self.status_code, "headers": self.raw_headers}
        if scope["method"] == "HEAD":
            await send(start)
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return
        try:
            file = await anyio.open_file(self.path, "rb")
        except OSError:  # deleted or made unreadable since it was stat()ed
            await Response(status_code=404)(scope, receive, send)
            return
        async with file:
            await send(start)
            async with anyio.create_task_group() as group:
                group.start_soon(_cancel_on_disconnect, receive, group.cancel_scope)
                try:
                    await self._send_segments(file, send)
                except OSError as exc:  # ASGI 2.4 servers raise here once the client is gone
                    log.debug("Stopped streaming %s: %s", self.path, exc)
                group.cancel_scope.cancel()

    async def _send_segments(self, file: anyio.AsyncFile[bytes], send: Send) -> None:
        for segment in self.segments:
            if isinstance(segment, bytes):
                await send({"type": "http.response.body", "body": segment, "more_body": True})
                continue
            offset, remaining = segment
            await file.seek(offset)
            while remaining > 0:
                chunk = await file.read(min(STREAM_CHUNK_SIZE, remaining))
                if not chunk:
                    raise RuntimeError(f"{self.path} shrank while it was being sent")
                remaining -= len(chunk)
                await send({"type": "http.response.body", "body": chunk, "more_body": True})
        await send({"type": "http.response.body", "body": b"", "more_body": False})


def file_response(request_headers: Headers, path: Path, info: os.stat_result, media_type: str) -> Response:
    """Answer GET/HEAD for a media file: validators, 304, Range/206/416, streaming."""
    size = info.st_size
    etag = f'"{info.st_mtime_ns:x}-{size:x}"'
    last_modified = formatdate(info.st_mtime, usegmt=True)
    headers = {
        "Accept-Ranges": "bytes",
        "ETag": etag,
        "Last-Modified": last_modified,
        "Cache-Control": "private, max-age=3600",
    }
    if is_not_modified(request_headers, etag, info.st_mtime):
        return Response(status_code=304, headers=headers)

    range_header = request_headers.get("range")
    if range_header is not None and if_range_allows(request_headers.get("if-range"), etag, last_modified):
        try:
            ranges = parse_range_header(range_header, size)
        except RangeNotSatisfiable:
            return Response(status_code=416, headers={**headers, "Content-Range": f"bytes */{size}"})
        if len(ranges) == 1:
            first, last = ranges[0]
            headers["Content-Range"] = f"bytes {first}-{last}/{size}"
            return FileStreamResponse(
                path, [(first, last - first + 1)], status_code=206, headers=headers, media_type=media_type
            )
        boundary = secrets.token_hex(16)
        return FileStreamResponse(
            path,
            multipart_segments(ranges, size, media_type, boundary),
            status_code=206,
            headers=headers,
            media_type=f"multipart/byteranges; boundary={boundary}",
        )
    return FileStreamResponse(path, [(0, size)], status_code=200, headers=headers, media_type=media_type)


# --------------------------------------------------------------------------
# Subtitles
# --------------------------------------------------------------------------

_SRT_TIME = r"([0-9]+):([0-9]{1,2}):([0-9]{1,2})[,.]([0-9]{1,3})"
_SRT_TIMING = re.compile(rf"\s*{_SRT_TIME}\s*-->\s*{_SRT_TIME}")
_ASS_OVERRIDE = re.compile(r"\{\\[^}]*\}")  # {\an8} and friends
_FONT_TAG = re.compile(r"</?font\b[^>]*>", re.IGNORECASE)
_NOT_A_CUE_TAG = re.compile(r"<(?!/?[ibu]>)", re.IGNORECASE)


def decode_text(data: bytes) -> str:
    """Decode a subtitle file: UTF-8 or UTF-16 (BOM-aware), else Windows-1252."""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16", "replace")
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return data.decode("cp1252", "replace")


def _vtt_timestamp(hours: str, minutes: str, seconds: str, fraction: str) -> str:
    millis = fraction.ljust(3, "0")
    return f"{int(hours):02d}:{int(minutes):02d}:{int(seconds):02d}.{millis}"


def srt_to_vtt(data: bytes) -> str:
    """Convert SubRip (.srt) subtitles to WebVTT."""
    text = decode_text(data).replace("\r\n", "\n").replace("\r", "\n")
    lines = ["WEBVTT", ""]
    for line in text.split("\n"):
        timing = _SRT_TIMING.match(line)
        if timing:
            times = timing.groups()
            lines.append(f"{_vtt_timestamp(*times[:4])} --> {_vtt_timestamp(*times[4:])}")
            continue
        line = _FONT_TAG.sub("", _ASS_OVERRIDE.sub("", line))
        # Cue text is markup in WebVTT: escape everything but <i>, <b>, <u>.
        line = _NOT_A_CUE_TAG.sub("&lt;", line.replace("&", "&amp;"))
        lines.append(line.replace("-->", "--&gt;"))
    return "\n".join(lines).rstrip("\n") + "\n"


def vtt_text(data: bytes) -> str:
    """Pass a .vtt file through as UTF-8, adding the header if it is missing."""
    text = decode_text(data)
    return text if text.startswith("WEBVTT") else f"WEBVTT\n\n{text}"


# --------------------------------------------------------------------------
# Thumbnails
# --------------------------------------------------------------------------


class ThumbnailService:
    """Generates thumbnails on first request and caches them in ``cache_dir``.

    ``cache_dir`` is ``.thumbs`` next to this file: the media library itself is
    never written to. Video frames need ffmpeg; without it (or when anything
    goes wrong) callers get None and show a generic icon instead.
    """

    def __init__(self, cache_dir: Path, ffmpeg: str | None, ffprobe: str | None) -> None:
        self.cache_dir = cache_dir
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.enabled = True
        try:
            cache_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            log.warning("Thumbnail cache %s is not writable (%s); showing icons instead", cache_dir, exc)
            self.enabled = False
        # ffmpeg and Pillow are CPU-heavy. A folder of 500 videos asks for 500
        # thumbnails at once, so only a few are made at a time; the waiting
        # requests queue here without tying up threadpool threads.
        self._slots = asyncio.Semaphore(max(1, min(4, os.cpu_count() or 1)))

    @property
    def video_enabled(self) -> bool:
        """True if video thumbnails can be made."""
        return self.enabled and self.ffmpeg is not None

    async def get(self, source: Path, kind: str) -> tuple[Path, str] | None:
        """Return ``(thumbnail path, media type)`` for source, or None for an icon."""
        if not self.enabled or kind == "audio" or (kind == "video" and not self.ffmpeg):
            return None
        try:
            info = source.stat()
        except OSError:
            return None
        fingerprint = f"{THUMB_VERSION}\0{source}\0{info.st_size}\0{info.st_mtime_ns}"
        key = hashlib.sha256(fingerprint.encode("utf-8", "surrogateescape")).hexdigest()
        folder = self.cache_dir / key[:2]
        cached = self._lookup(folder, key)
        if cached or self._failed(folder, key):
            return cached
        async with self._slots:
            cached = self._lookup(folder, key)  # made by another request while we waited?
            if cached or self._failed(folder, key):
                return cached
            return await run_in_threadpool(self._generate, source, kind, folder, key)

    @staticmethod
    def _lookup(folder: Path, key: str) -> tuple[Path, str] | None:
        for ext, media_type in (("jpg", "image/jpeg"), ("png", "image/png")):
            path = folder / f"{key}.{ext}"
            if path.is_file():
                return path, media_type
        return None

    @staticmethod
    def _failed(folder: Path, key: str) -> bool:
        return (folder / f"{key}.failed").exists()

    def _generate(self, source: Path, kind: str, folder: Path, key: str) -> tuple[Path, str] | None:
        try:
            folder.mkdir(parents=True, exist_ok=True)
            if kind == "image":
                return self._image_thumbnail(source, folder, key)
            return self._video_thumbnail(source, folder, key)
        except Exception as exc:  # a corrupt file must never break the page
            log.warning("No thumbnail for %s: %s", source, exc)
        with contextlib.suppress(OSError):
            (folder / f"{key}.failed").touch()  # don't retry on every page view
        return None

    def _image_thumbnail(self, source: Path, folder: Path, key: str) -> tuple[Path, str]:
        with Image.open(source) as original:
            original.draft("RGB", (THUMB_EDGE, THUMB_EDGE))  # JPEG: decode at reduced scale
            image = ImageOps.exif_transpose(original)
        # Convert before resizing: palette images would otherwise be scaled
        # with nearest-neighbour sampling.
        transparent = image.mode in ("RGBA", "LA", "PA") or "transparency" in image.info
        image = image.convert("RGBA" if transparent else "RGB")
        image.thumbnail((THUMB_EDGE, THUMB_EDGE), Image.Resampling.LANCZOS, reducing_gap=3.0)
        if transparent:
            return self._save(image, folder / f"{key}.png", "PNG", "image/png", optimize=True)
        return self._save(image, folder / f"{key}.jpg", "JPEG", "image/jpeg", quality=82, progressive=True)

    @staticmethod
    def _save(image: Image.Image, target: Path, fmt: str, media_type: str, **options: object) -> tuple[Path, str]:
        tmp = target.with_name(f"{target.stem}.{secrets.token_hex(4)}.tmp")
        try:
            image.save(tmp, fmt, **options)
            os.replace(tmp, target)  # atomic: readers never see a partial file
        finally:
            tmp.unlink(missing_ok=True)
        return target, media_type

    def _video_thumbnail(self, source: Path, folder: Path, key: str) -> tuple[Path, str]:
        assert self.ffmpeg is not None
        target = folder / f"{key}.jpg"
        tmp = folder / f"{key}.{secrets.token_hex(4)}.tmp.jpg"
        duration = self._duration(source)
        # A frame at 10% avoids black intros and title cards; fall back to the
        # very first frame for files whose duration is unknown or that fail
        # to seek.
        seeks = ([duration * 0.1] if duration else []) + [0.0]
        errors = ""
        try:
            for seek in seeks:
                result = subprocess.run(
                    [
                        self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                        "-ss", f"{seek:.3f}", "-i", f"file:{source}",
                        "-map", "0:V:0",  # first real video stream, not embedded cover art
                        "-frames:v", "1", "-an", "-sn", "-dn",
                        "-vf", f"scale='min({THUMB_EDGE},iw)':-2",
                        "-q:v", "4", "-f", "image2", "-update", "1", f"file:{tmp}",
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    timeout=FFMPEG_TIMEOUT,
                    check=False,
                )
                if tmp.is_file() and tmp.stat().st_size > 0:
                    os.replace(tmp, target)
                    return target, "image/jpeg"
                errors = result.stderr.decode("utf-8", "replace").strip()
        finally:
            tmp.unlink(missing_ok=True)
        last_error = errors.splitlines()[-1] if errors else "no output"
        raise RuntimeError(f"ffmpeg produced no frame ({last_error})")

    def _duration(self, source: Path) -> float | None:
        """Video duration in seconds via ffprobe (or ffmpeg's banner), if known."""
        assert self.ffmpeg is not None
        try:
            if self.ffprobe:
                result = subprocess.run(
                    [
                        self.ffprobe, "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", f"file:{source}",
                    ],
                    capture_output=True, stdin=subprocess.DEVNULL, timeout=FFMPEG_TIMEOUT, check=False,
                )
                seconds = float(result.stdout.split()[0])
            else:
                # ffmpeg prints "Duration: 00:01:02.03" before complaining
                # that no output file was given.
                result = subprocess.run(
                    [self.ffmpeg, "-hide_banner", "-nostdin", "-i", f"file:{source}"],
                    capture_output=True, stdin=subprocess.DEVNULL, timeout=FFMPEG_TIMEOUT, check=False,
                )
                found = re.search(rb"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", result.stderr)
                if not found:
                    return None
                seconds = int(found[1]) * 3600 + int(found[2]) * 60 + float(found[3])
        except (OSError, subprocess.SubprocessError, ValueError, IndexError):
            return None
        return seconds if math.isfinite(seconds) and seconds > 0 else None


# --------------------------------------------------------------------------
# Frontend: icons, CSS and JS (all inline; nothing is loaded from elsewhere)
# --------------------------------------------------------------------------

ICON_PATHS = {
    "library": '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/><path d="m10 8 5 2.5-5 2.5z"/>',
    "home": '<path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 9.8V20h13V9.8"/>',
    "folder": '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4.4l2 2h8.6A1.5 1.5 0 0 1 21 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"/>',
    "video": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m10 9 5 3-5 3z"/>',
    "image": '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="2"/><path d="m21 16-5-5-9 9"/>',
    "audio": '<path d="M9 18V5l11-2v13"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
    "logout": '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="m10 17-5-5 5-5M5 12h11"/>',
    "prev": '<path d="m15 18-6-6 6-6"/>',
    "next": '<path d="m9 18 6-6-6-6"/>',
    "close": '<path d="M6 6l12 12M18 6 6 18"/>',
    "download": '<path d="M12 4v11m-5-5 5 5 5-5M5 20h14"/>',
}

# One hidden sprite per page; icons reference it with <use>, so a folder of
# 1000 files does not repeat the path data 1000 times.
ICON_SPRITE = (
    '<svg class="sprite" aria-hidden="true" focusable="false">'
    + "".join(f'<symbol id="i-{name}" viewBox="0 0 24 24">{paths}</symbol>' for name, paths in ICON_PATHS.items())
    + "</svg>"
)


def icon(name: str) -> str:
    """Inline SVG that draws one sprite icon in the current text colour."""
    return f'<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-{name}"/></svg>'


def standalone_icon(name: str) -> bytes:
    """A 16:10 SVG image with a centred icon, served when there is no thumbnail."""
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 100">'
        '<g transform="translate(56 26) scale(2)" fill="none" stroke="#8b93a3" '
        f'stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">{ICON_PATHS[name]}</g></svg>'
    ).encode()


FAVICON = "data:image/svg+xml," + quote(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#7aa2ff" '
    f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{ICON_PATHS["library"]}</svg>'
)

APP_CSS = r"""
:root {
  color-scheme: dark;
  --bg: #0e1116;
  --panel: #161a22;
  --panel-2: #1e232d;
  --border: #2a303c;
  --text: #e8eaf0;
  --muted: #9aa3b4;
  --accent: #7aa2ff;
  --on-accent: #0b1020;
  --danger: #ff8080;
  --bar: rgba(14, 17, 22, 0.86);
  --radius: 12px;
  --gutter: 16px;
}
@media (prefers-color-scheme: light) {
  :root {
    color-scheme: light;
    --bg: #f4f5f8;
    --panel: #ffffff;
    --panel-2: #e9ecf1;
    --border: #d5dae2;
    --text: #151821;
    --muted: #5b6475;
    --accent: #2c5ee8;
    --on-accent: #ffffff;
    --danger: #c42b2b;
    --bar: rgba(244, 245, 248, 0.88);
  }
}
*, *::before, *::after { box-sizing: border-box; }
[hidden] { display: none !important; }
html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
body {
  margin: 0;
  min-height: 100vh;
  background: var(--bg);
  color: var(--text);
  font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
}
a { color: var(--accent); }
:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
.sprite { position: absolute; width: 0; height: 0; overflow: hidden; }
.icon {
  width: 22px; height: 22px; flex: none;
  fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round;
}

/* Top bar and page frame */
.topbar {
  position: sticky; top: 0; z-index: 20;
  display: flex; align-items: center; gap: 8px; min-height: 56px;
  padding: 6px max(var(--gutter), env(safe-area-inset-right)) 6px max(var(--gutter), env(safe-area-inset-left));
  background: var(--bar);
  -webkit-backdrop-filter: saturate(1.4) blur(10px);
  backdrop-filter: saturate(1.4) blur(10px);
  border-bottom: 1px solid var(--border);
}
.brand {
  display: inline-flex; align-items: center; gap: 10px; min-height: 44px; padding: 0 4px;
  color: var(--text); font-weight: 650; text-decoration: none;
}
.brand .icon { color: var(--accent); }
.spacer { flex: 1; }
.topbar form { margin: 0; }
.wrap {
  width: 100%; max-width: 1480px; margin: 0 auto;
  padding: 12px max(var(--gutter), env(safe-area-inset-right)) 48px max(var(--gutter), env(safe-area-inset-left));
}

/* Buttons */
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  min-height: 44px; min-width: 44px; padding: 0 16px;
  border: 1px solid var(--border); border-radius: 10px;
  background: var(--panel); color: var(--text);
  font: inherit; font-size: 15px; text-decoration: none; cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
.btn:hover { border-color: var(--accent); }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent); font-weight: 600; }
.btn.quiet { background: transparent; border-color: transparent; color: var(--muted); }
.btn.quiet:hover { color: var(--text); background: var(--panel); }
.btn[aria-disabled="true"], .btn:disabled { opacity: 0.4; pointer-events: none; }

/* Breadcrumbs and folder header */
.crumbs ol {
  list-style: none; margin: 0 0 4px; padding: 0;
  display: flex; flex-wrap: wrap; align-items: center; font-size: 15px;
}
.crumbs li { display: flex; align-items: center; min-width: 0; }
.crumbs li + li::before { content: "/"; color: var(--muted); opacity: 0.6; padding: 0 2px; }
.crumbs a, .crumbs [aria-current] {
  display: inline-flex; align-items: center; gap: 6px; min-height: 44px; padding: 0 8px;
  border-radius: 8px; color: var(--muted); text-decoration: none; overflow-wrap: anywhere;
}
.crumbs .icon { width: 18px; height: 18px; }
.crumbs a:hover { color: var(--text); background: var(--panel); }
.crumbs [aria-current] { color: var(--text); font-weight: 600; }
.head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; margin: 4px 0 6px; }
.head h1 {
  flex: 1 1 260px; min-width: 0; margin: 0;
  font-size: clamp(22px, 4vw, 30px); line-height: 1.2; overflow-wrap: anywhere;
}
.search { position: relative; flex: 1 1 260px; max-width: 440px; }
.search .icon {
  position: absolute; left: 12px; top: 50%; transform: translateY(-50%);
  width: 20px; height: 20px; color: var(--muted); pointer-events: none;
}
.search input {
  width: 100%; min-height: 44px; padding: 0 12px 0 42px;
  border: 1px solid var(--border); border-radius: 10px;
  background: var(--panel); color: var(--text); font: inherit; font-size: 16px;
}
.count { margin: 0 0 16px; color: var(--muted); font-size: 14px; }

/* Grid of cards: 2 columns on phones up to 5 on wide screens */
.grid {
  list-style: none; margin: 0; padding: 0;
  display: grid; gap: 12px; grid-template-columns: repeat(2, minmax(0, 1fr));
}
@media (min-width: 640px) { .grid { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px; } }
@media (min-width: 960px) { .grid { grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px; } }
@media (min-width: 1280px) { .grid { grid-template-columns: repeat(5, minmax(0, 1fr)); } }
.card {
  display: flex; flex-direction: column; height: 100%; min-height: 44px; overflow: hidden;
  border: 1px solid var(--border); border-radius: var(--radius);
  background: var(--panel); color: inherit; text-decoration: none;
  transition: border-color 0.15s, transform 0.15s;
  -webkit-tap-highlight-color: transparent;
}
.card:hover { border-color: var(--accent); }
@media (hover: hover) { .card:hover { transform: translateY(-2px); } }
.thumb {
  position: relative; display: grid; place-items: center; aspect-ratio: 16 / 10; overflow: hidden;
  background: var(--panel-2); color: var(--muted);
}
.thumb .icon { width: 34%; height: 34%; max-width: 64px; max-height: 64px; stroke-width: 1.4; }
.thumb.folder { color: var(--accent); }
.thumb img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.thumb.loaded > .icon { visibility: hidden; } /* the icon is the placeholder while loading */
.badge {
  position: absolute; left: 8px; top: 8px; padding: 1px 6px; border-radius: 6px;
  background: rgba(0, 0, 0, 0.62); color: #fff;
  font-size: 11px; font-weight: 650; letter-spacing: 0.04em;
}
.progress { position: absolute; left: 0; right: 0; bottom: 0; height: 4px; background: rgba(0, 0, 0, 0.45); }
.progress span { display: block; width: 0; height: 100%; background: var(--accent); }
.meta { display: flex; flex-direction: column; gap: 2px; min-width: 0; padding: 8px 10px 10px; }
.name {
  display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden;
  font-size: 14px; line-height: 1.35; overflow-wrap: anywhere;
}
.sub { color: var(--muted); font-size: 12px; }
.empty { padding: 48px 16px; text-align: center; color: var(--muted); }
.empty h1 { color: var(--text); }

/* Player page */
.title { margin: 4px 0 12px; font-size: clamp(20px, 3.4vw, 26px); line-height: 1.25; overflow-wrap: anywhere; }
.screen { background: #000; border-radius: var(--radius); overflow: hidden; }
/* Keep the native controls above the fold, but never shrink below 240px (landscape phones) */
.screen video { display: block; width: 100%; max-height: max(240px, calc(100vh - 260px)); background: #000; }
.listen {
  display: grid; justify-items: center; gap: 20px; padding: 36px 16px;
  border: 1px solid var(--border); border-radius: var(--radius); background: var(--panel);
}
.listen .icon { width: 88px; height: 88px; color: var(--accent); stroke-width: 1.2; }
.listen audio { width: 100%; max-width: 560px; }
.notice {
  display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; margin: 12px 0 0; padding: 10px 12px;
  border: 1px solid var(--border); border-radius: var(--radius); background: var(--panel);
}
.notice .grow { flex: 1 1 200px; }
.notice.error { border-color: var(--danger); }
#resume { margin: 0 0 12px; }
.actions { display: flex; align-items: center; gap: 8px; margin-top: 12px; }
.actions .download { margin-left: auto; }
@media (max-width: 479px) {
  /* Phones: icon-only previous/next either side of a wide download button */
  .actions .download { flex: 1; margin-left: 0; }
  .actions .label { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
}

/* Image lightbox (a modal <dialog>) */
.lightbox {
  width: 100%; height: 100%; height: 100dvh; max-width: none; max-height: none;
  margin: 0; padding: 0; border: 0; overflow: hidden;
  background: #05070a; color: #fff;
}
.lightbox::backdrop { background: rgba(0, 0, 0, 0.6); }
.lightbox[open] { display: grid; grid-template-rows: auto minmax(0, 1fr); }
.lb-bar {
  display: flex; align-items: center; gap: 8px;
  padding: max(8px, env(safe-area-inset-top)) max(8px, env(safe-area-inset-right)) 8px max(12px, env(safe-area-inset-left));
}
.lb-title { flex: 1; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font-size: 15px; }
.lb-count { color: rgba(255, 255, 255, 0.7); font-size: 14px; font-variant-numeric: tabular-nums; white-space: nowrap; }
.lb-btn {
  display: inline-flex; align-items: center; justify-content: center; flex: none;
  width: 48px; height: 48px; border: 0; border-radius: 50%;
  background: rgba(255, 255, 255, 0.12); color: #fff; cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
.lb-btn:hover { background: rgba(255, 255, 255, 0.24); }
.lb-stage { position: relative; min-height: 0; overflow: hidden; touch-action: pan-y pinch-zoom; }
.lb-stage img {
  position: absolute; inset: 0; margin: auto;
  max-width: calc(100% - 16px); max-height: calc(100% - 16px);
  user-select: none; -webkit-user-select: none;
}
.lb-prev, .lb-next { position: absolute; top: 50%; transform: translateY(-50%); }
.lb-prev { left: max(8px, env(safe-area-inset-left)); }
.lb-next { right: max(8px, env(safe-area-inset-right)); }
.lb-stage.loading::after {
  content: ""; position: absolute; left: 50%; top: 50%; width: 40px; height: 40px; margin: -20px 0 0 -20px;
  border: 3px solid rgba(255, 255, 255, 0.25); border-top-color: #fff; border-radius: 50%;
  animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
html.lb-open { overflow: hidden; }

/* Login */
.login { min-height: 100vh; min-height: 100dvh; display: grid; place-items: center; padding: 24px var(--gutter); }
.login-card {
  width: 100%; max-width: 380px; display: grid; gap: 14px; padding: 28px 24px;
  border: 1px solid var(--border); border-radius: 16px; background: var(--panel);
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.25);
}
.login-card h1 { display: flex; align-items: center; gap: 10px; margin: 0 0 6px; font-size: 22px; }
.login-card h1 .icon { width: 28px; height: 28px; color: var(--accent); }
.login-card label { color: var(--muted); font-size: 14px; }
.login-card input {
  min-height: 48px; padding: 0 14px; border: 1px solid var(--border); border-radius: 10px;
  background: var(--bg); color: var(--text); font: inherit; font-size: 16px;
}
.alert { margin: 0; padding: 10px 12px; border: 1px solid var(--danger); border-radius: 10px; color: var(--danger); font-size: 14px; }

@media (prefers-reduced-motion: reduce) {
  .card { transition: none; }
  .card:hover { transform: none; }
}
"""

APP_JS = r"""
(() => {
  "use strict";
  const RESUME = "resume:";
  const $ = (selector, root) => (root || document).querySelector(selector);
  const $$ = (selector, root) => Array.from((root || document).querySelectorAll(selector));

  // localStorage throws in some private modes and when full; never let that break the page.
  const store = {
    get(key) {
      try { return JSON.parse(localStorage.getItem(key) || "null"); } catch (e) { return null; }
    },
    set(key, value) {
      try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* ignore */ }
    },
    remove(key) {
      try { localStorage.removeItem(key); } catch (e) { /* ignore */ }
    },
  };

  const clock = (seconds) => {
    const total = Math.max(0, Math.floor(seconds));
    const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
    const two = (n) => String(n).padStart(2, "0");
    return h ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
  };

  // Thumbnails sit on top of an icon: hide the icon once the image has
  // loaded, or drop the image if it fails (file deleted, session expired).
  // load/error don't bubble, hence capture listeners registered from <head>.
  const onThumb = (handler) => (event) => {
    const img = event.target;
    if (img instanceof HTMLImageElement && img.parentElement && img.parentElement.classList.contains("thumb")) {
      handler(img);
    }
  };
  document.addEventListener("load", onThumb((img) => img.parentElement.classList.add("loaded")), true);
  document.addEventListener("error", onThumb((img) => img.remove()), true);

  function initFilter() {
    const input = $("#filter");
    const items = $$("#grid > li");
    if (!input || !items.length) return;
    const fold = (text) => text.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
    const names = items.map((li) => fold(li.dataset.name || ""));
    const noMatch = $("#no-match");
    const apply = () => {
      const query = fold(input.value.trim());
      let shown = 0;
      items.forEach((li, i) => {
        const match = !query || names[i].includes(query);
        li.hidden = !match;
        if (match) shown += 1;
      });
      if (noMatch) noMatch.hidden = shown > 0;
    };
    input.addEventListener("input", apply);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && input.value) { input.value = ""; apply(); }
    });
    document.addEventListener("keydown", (event) => {
      if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return;
      const target = event.target;
      if (target.closest && target.closest("input, textarea, select, dialog")) return;
      event.preventDefault();
      input.focus();
    });
    apply(); // the browser may have restored the query on back/forward
  }

  function paintProgress() {
    $$(".card[data-resume]").forEach((card) => {
      const bar = $(".progress", card);
      if (!bar) return;
      const saved = store.get(RESUME + card.dataset.resume);
      const show = Boolean(saved && saved.d > 0 && saved.t > 0);
      bar.hidden = !show;
      if (show) bar.firstElementChild.style.width = `${Math.min(100, (100 * saved.t) / saved.d).toFixed(1)}%`;
    });
  }

  function pruneResume(limit) {
    try {
      const keys = [];
      for (let i = 0; i < localStorage.length; i += 1) {
        const key = localStorage.key(i);
        if (key && key.startsWith(RESUME)) keys.push(key);
      }
      if (keys.length <= limit) return;
      keys
        .map((key) => [key, (store.get(key) || {}).at || 0])
        .sort((a, b) => a[1] - b[1])
        .slice(0, keys.length - limit)
        .forEach(([key]) => store.remove(key));
    } catch (e) { /* storage unavailable */ }
  }

  function initPlayer() {
    const player = $("#player");
    if (!player) return;
    const key = RESUME + player.dataset.resume;
    const banner = $("#resume");
    let saving = true;
    let lastSave = 0;

    const save = () => {
      if (!saving) return;
      const t = player.currentTime;
      const d = player.duration;
      if (!(d > 0) || !Number.isFinite(d)) return;
      if (t < 5 || t / d > 0.95) store.remove(key); // barely started, or finished
      else store.set(key, { t: Math.floor(t), d: Math.floor(d), at: Date.now() });
    };

    const saved = store.get(key);
    if (banner && saved && saved.t >= 5) {
      // Offer to resume, and keep the old position until the viewer answers.
      saving = false;
      $("#resume-at").textContent = clock(saved.t);
      banner.hidden = false;
      const answer = (resume) => {
        banner.hidden = true;
        saving = true;
        const start = () => {
          if (resume) player.currentTime = saved.t;
          const playing = player.play();
          if (playing) playing.catch(() => {});
        };
        if (player.readyState >= 1) start();
        else player.addEventListener("loadedmetadata", start, { once: true });
      };
      $("#resume-yes").addEventListener("click", () => answer(true));
      $("#resume-no").addEventListener("click", () => answer(false));
    }

    player.addEventListener("timeupdate", () => {
      if (!saving) {
        // Playing on from the start without answering means "start over".
        if (player.currentTime > 30) { banner.hidden = true; saving = true; }
        return;
      }
      const now = Date.now();
      if (now - lastSave > 5000) { lastSave = now; save(); }
    });
    player.addEventListener("pause", save);
    player.addEventListener("seeked", save);
    player.addEventListener("ended", () => store.remove(key));
    window.addEventListener("pagehide", save);
    player.addEventListener("error", () => {
      const box = $("#play-error");
      if (box) box.hidden = false;
    });
  }

  function initLightbox() {
    const dialog = $("#lightbox");
    const grid = $("#grid");
    if (!dialog || !grid || typeof dialog.showModal !== "function") return;
    const img = $("#lb-img");
    const stage = $("#lb-stage");
    const title = $("#lb-title");
    const count = $("#lb-count");
    const download = $("#lb-download");
    let items = [];
    let index = 0;

    const visibleImages = () => $$("#grid > li:not([hidden]) a[data-lightbox]");
    const nameOf = (link) => link.closest("li").dataset.name;
    const hashName = () => {
      const match = /^#view=(.+)$/.exec(location.hash);
      if (!match) return null;
      try { return decodeURIComponent(match[1]); } catch (e) { return null; }
    };

    const show = (i) => {
      index = (i + items.length) % items.length;
      const link = items[index];
      const name = nameOf(link);
      stage.classList.add("loading");
      img.src = link.href;
      img.alt = name;
      title.textContent = name;
      count.textContent = `${index + 1} / ${items.length}`;
      download.href = link.href;
      download.setAttribute("download", name);
      [index - 1, index + 1].forEach((j) => {
        const near = items[(j + items.length) % items.length];
        if (near !== link) new Image().src = near.href; // preload neighbours
      });
      if (!dialog.open) {
        dialog.showModal();
        document.documentElement.classList.add("lb-open");
      }
      history.replaceState(history.state, "", `#view=${encodeURIComponent(name)}`);
    };

    const open = (link) => {
      items = visibleImages();
      const i = items.indexOf(link);
      if (i < 0) return;
      history.pushState({ lightbox: true }, "", `#view=${encodeURIComponent(nameOf(link))}`);
      show(i);
    };

    const step = (delta) => {
      if (dialog.open && items.length > 1) show(index + delta);
    };

    // The URL hash drives the viewer: the back button closes it, and a link
    // ending in #view=photo.jpg opens straight into that photo.
    const sync = () => {
      const name = hashName();
      if (name !== null) {
        if (dialog.open && items[index] && nameOf(items[index]) === name) return;
        items = visibleImages();
        const i = items.findIndex((link) => nameOf(link) === name);
        if (i >= 0) { show(i); return; }
      }
      if (dialog.open) dialog.close();
    };

    dialog.addEventListener("close", () => {
      document.documentElement.classList.remove("lb-open");
      img.removeAttribute("src");
      if (hashName() !== null) {
        // Closed from inside the viewer: remove its history entry as well.
        if (history.state && history.state.lightbox) history.back();
        else history.replaceState(null, "", location.pathname + location.search);
      }
      const current = items[index];
      if (current) current.focus();
    });

    grid.addEventListener("click", (event) => {
      const link = event.target.closest("a[data-lightbox]");
      if (!link || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      open(link);
    });
    dialog.addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft") { event.preventDefault(); step(-1); }
      else if (event.key === "ArrowRight") { event.preventDefault(); step(1); }
      // Escape is handled natively: it closes the <dialog>.
    });
    $("#lb-prev").addEventListener("click", () => step(-1));
    $("#lb-next").addEventListener("click", () => step(1));
    $("#lb-close").addEventListener("click", () => dialog.close());
    stage.addEventListener("click", (event) => {
      if (event.target === stage) dialog.close(); // tap on the backdrop
    });
    img.addEventListener("load", () => stage.classList.remove("loading"));
    img.addEventListener("error", () => stage.classList.remove("loading"));

    // Swipe left/right to change image, down to close. Ignored while the
    // page is pinch-zoomed, where a swipe pans instead.
    let touch = null;
    stage.addEventListener("touchstart", (event) => {
      const t = event.touches;
      touch = t.length === 1 ? { x: t[0].clientX, y: t[0].clientY, at: Date.now() } : null;
    }, { passive: true });
    stage.addEventListener("touchcancel", () => { touch = null; }, { passive: true });
    stage.addEventListener("touchend", (event) => {
      if (!touch || event.changedTouches.length !== 1) return;
      const dx = event.changedTouches[0].clientX - touch.x;
      const dy = event.changedTouches[0].clientY - touch.y;
      const quick = Date.now() - touch.at < 800;
      touch = null;
      const zoomed = window.visualViewport && window.visualViewport.scale > 1.01;
      if (!quick || zoomed) return;
      if (Math.abs(dx) > 50 && Math.abs(dx) > 1.5 * Math.abs(dy)) step(dx < 0 ? 1 : -1);
      else if (dy > 90 && dy > 1.5 * Math.abs(dx)) dialog.close();
    });

    window.addEventListener("hashchange", sync);
    window.addEventListener("popstate", sync);
    sync();
  }

  document.addEventListener("DOMContentLoaded", () => {
    initFilter();
    paintProgress();
    initPlayer();
    initLightbox();
    pruneResume(500);
  });
  // Coming back via the back button restores the page from cache: refresh
  // the progress bars, since the viewer probably just watched something.
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) paintProgress();
  });
})();
"""


def _csp_hash(source: str) -> str:
    digest = hashlib.sha256(source.encode("utf-8")).digest()
    return f"'sha256-{base64.b64encode(digest).decode()}'"


# The only script and stylesheet are the two static blocks above, allowed by
# hash. No 'unsafe-inline': even if a file name slipped past escaping, the
# browser would refuse to run it.
CONTENT_SECURITY_POLICY = "; ".join(
    [
        "default-src 'none'",
        f"script-src {_csp_hash(APP_JS)}",
        f"style-src {_csp_hash(APP_CSS)}",
        "img-src 'self' data:",
        "media-src 'self'",
        "form-action 'self'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
    ]
)

SECURITY_HEADERS = {
    "Content-Security-Policy": CONTENT_SECURITY_POLICY,
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "same-origin",
    "X-Frame-Options": "DENY",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
}


# --------------------------------------------------------------------------
# HTML rendering. Every value that comes from the filesystem or the request
# goes through h(); fragments built by other render_* helpers are trusted.
# --------------------------------------------------------------------------


def h(value: object) -> str:
    """HTML-escape a value for element content or a quoted attribute."""
    return html.escape(str(value), quote=True)


def folder_url(rel: str) -> str:
    """URL of a folder listing."""
    return f"/browse/{quote(rel)}" if rel else "/"


def thumb_url(rel: str, mtime: float) -> str:
    """URL of a thumbnail; the mtime makes browsers refetch it when the file changes."""
    return f"/thumb/{quote(rel)}?v={int(mtime)}"


def render_page(title: str, content: str, *, signed_in: bool = True, main_class: str = "wrap") -> str:
    """Wrap content in the page skeleton with the inline CSS and JS."""
    topbar = ""
    if signed_in:
        topbar = (
            '<header class="topbar">'
            f'<a class="brand" href="/">{icon("library")}<span>Media Library</span></a>'
            '<span class="spacer"></span>'
            '<form method="post" action="/logout">'
            f'<button class="btn quiet" type="submit">{icon("logout")}<span>Log out</span></button>'
            "</form></header>"
        )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<meta name="robots" content="noindex, nofollow">
<title>{h(title)} · Media Library</title>
<link rel="icon" href="{h(FAVICON)}">
<style>{APP_CSS}</style>
<script>{APP_JS}</script>
</head>
<body>
{ICON_SPRITE}
{topbar}
<main class="{main_class}">
{content}
</main>
</body>
</html>
"""


def html_page(content: str, status_code: int = 200, headers: Mapping[str, str] | None = None) -> HTMLResponse:
    """An HTML response that shared caches must not store."""
    return HTMLResponse(content, status_code=status_code, headers={"Cache-Control": "private, no-cache", **(headers or {})})


def render_breadcrumbs(rel: str) -> str:
    """Clickable trail from the library root down to rel (a non-empty path)."""
    parts = rel.split("/")
    items = [f'<li><a href="/">{icon("home")}<span>Library</span></a></li>']
    for i, name in enumerate(parts):
        if i == len(parts) - 1:
            items.append(f'<li><span aria-current="page">{h(name)}</span></li>')
        else:
            items.append(f'<li><a href="{h(folder_url("/".join(parts[: i + 1])))}">{h(name)}</a></li>')
    return f'<nav class="crumbs" aria-label="Breadcrumb"><ol>{"".join(items)}</ol></nav>'


def render_card(entry: Entry, video_thumbs: bool) -> str:
    """One grid card: a folder, or a media file with its thumbnail."""
    name = h(entry.name)
    if entry.kind == "folder":
        return (
            f'<li data-name="{name}"><a class="card" href="{h(folder_url(entry.rel))}">'
            f'<span class="thumb folder">{icon("folder")}</span>'
            f'<span class="meta"><span class="name">{name}</span><span class="sub">Folder</span></span></a></li>'
        )
    thumb = [icon(entry.kind)]
    if entry.kind == "image" or (entry.kind == "video" and video_thumbs):
        thumb.append(f'<img src="{h(thumb_url(entry.rel, entry.mtime))}" alt="" loading="lazy" decoding="async">')
    thumb.append(f'<span class="badge">{h(os.path.splitext(entry.name)[1][1:].upper())}</span>')
    if entry.kind == "image":
        link = f'href="/file/{h(quote(entry.rel))}" data-lightbox'
    else:
        thumb.append('<span class="progress" hidden><span></span></span>')
        link = f'href="/watch/{h(quote(entry.rel))}" data-resume="{h(entry.rel)}"'
    return (
        f'<li data-name="{name}"><a class="card" {link}>'
        f'<span class="thumb">{"".join(thumb)}</span>'
        f'<span class="meta"><span class="name">{name}</span><span class="sub">{human_size(entry.size)}</span></span>'
        "</a></li>"
    )


LIGHTBOX_HTML = f"""<dialog class="lightbox" id="lightbox" aria-label="Image viewer">
<div class="lb-bar">
<span class="lb-title" id="lb-title"></span>
<span class="lb-count" id="lb-count"></span>
<a class="lb-btn" id="lb-download" href="#" download aria-label="Download">{icon("download")}</a>
<button class="lb-btn" id="lb-close" type="button" aria-label="Close" autofocus>{icon("close")}</button>
</div>
<div class="lb-stage" id="lb-stage">
<img id="lb-img" alt="">
<button class="lb-btn lb-prev" id="lb-prev" type="button" aria-label="Previous image">{icon("prev")}</button>
<button class="lb-btn lb-next" id="lb-next" type="button" aria-label="Next image">{icon("next")}</button>
</div>
</dialog>"""


def render_browse(rel: str, entries: Sequence[Entry], video_thumbs: bool) -> str:
    """A folder listing: breadcrumbs, filter box and card grid."""
    title = rel.rpartition("/")[2] or "Library"
    counts = Counter(entry.kind for entry in entries)
    summary = " · ".join(
        plural(counts[kind], noun)
        for kind, noun in (("folder", "folder"), ("video", "video"), ("image", "image"), ("audio", "audio file"))
        if counts[kind]
    )
    # At the root the heading already says "Library"; a one-item trail adds nothing.
    parts = [render_breadcrumbs(rel)] if rel else []
    parts.append(f'<div class="head"><h1>{h(title)}</h1>')
    if entries:
        parts.append(
            f'<label class="search">{icon("search")}'
            '<input id="filter" type="search" placeholder="Filter this folder" aria-label="Filter this folder" '
            'aria-keyshortcuts="/" autocomplete="off" spellcheck="false" enterkeyhint="search"></label>'
        )
    parts.append("</div>")
    if entries:
        parts.append(f'<p class="count">{h(summary)}</p>')
        parts.append(f'<ul class="grid" id="grid">{"".join(render_card(e, video_thumbs) for e in entries)}</ul>')
        parts.append('<p class="empty" id="no-match" hidden>Nothing in this folder matches.</p>')
    else:
        parts.append('<p class="empty">No folders, videos, images or audio here.</p>')
    if counts["image"]:
        parts.append(LIGHTBOX_HTML)
    return render_page(title, "\n".join(parts))


def render_player(
    rel: str,
    kind: str,
    mtime: float,
    tracks: Sequence[SubtitleTrack],
    previous: Entry | None,
    following: Entry | None,
    video_thumbs: bool,
) -> str:
    """The page for one video or audio file."""
    name = rel.rpartition("/")[2]
    src = h(f"/file/{quote(rel)}")
    if kind == "video":
        poster = f' poster="{h(thumb_url(rel, mtime))}"' if video_thumbs else ""
        track_tags = "".join(
            f'<track kind="subtitles" src="{h("/subtitle/" + quote(track.rel))}" label="{h(track.label)}"'
            + (f' srclang="{h(track.srclang)}"' if track.srclang else "")
            + ">"
            for track in tracks
        )
        media = (
            f'<div class="screen"><video id="player" controls preload="metadata" playsinline{poster} '
            f'src="{src}" data-resume="{h(rel)}">{track_tags}</video></div>'
        )
    else:
        media = (
            f'<div class="listen">{icon("audio")}'
            f'<audio id="player" controls preload="metadata" src="{src}" data-resume="{h(rel)}"></audio></div>'
        )

    def neighbour(entry: Entry | None, label: str, rel_attr: str) -> str:
        if entry is None:
            return f'<span class="btn" aria-disabled="true">{label}</span>'
        return f'<a class="btn" href="/watch/{h(quote(entry.rel))}" rel="{rel_attr}" title="{h(entry.name)}">{label}</a>'

    content = f"""{render_breadcrumbs(rel)}
<h1 class="title">{h(name)}</h1>
<div class="notice" id="resume" hidden>
<span class="grow">Resume from <strong id="resume-at"></strong>?</span>
<button class="btn primary" id="resume-yes" type="button">Resume</button>
<button class="btn" id="resume-no" type="button">Start over</button>
</div>
{media}
<p class="notice error" id="play-error" hidden>Your browser can't play this file. <a href="{src}" download="{h(name)}">Download it</a> to play it elsewhere.</p>
<div class="actions">
{neighbour(previous, f'{icon("prev")}<span class="label">Previous</span>', "prev")}
<a class="btn download" href="{src}" download="{h(name)}">{icon("download")}Download</a>
{neighbour(following, f'<span class="label">Next</span>{icon("next")}', "next")}
</div>"""
    return render_page(name, content)


def render_login(next_url: str, error: str | None = None, locked_for: int = 0) -> str:
    """The password form."""
    alert = ""
    if locked_for:
        minutes = max(1, math.ceil(locked_for / 60))
        alert = f'<p class="alert" role="alert">Too many failed attempts. Try again in {plural(minutes, "minute")}.</p>'
    elif error:
        alert = f'<p class="alert" role="alert">{h(error)}</p>'
    disabled = " disabled" if locked_for else ""
    form = f"""<form class="login-card" method="post" action="/login">
<h1>{icon("library")}Media Library</h1>
<label for="password">Password</label>
<input id="password" name="password" type="password" autocomplete="current-password" required autofocus{disabled}>
<input type="hidden" name="next" value="{h(next_url)}">
{alert}
<button class="btn primary" type="submit"{disabled}>Sign in</button>
</form>"""
    return render_page("Sign in", form, signed_in=False, main_class="login")


ERROR_MESSAGES = {
    404: ("Not found", "There is nothing here. It may have been moved or deleted."),
    405: ("Not allowed", "That request method is not supported here."),
    413: ("Too large", "That request was too large."),
}


def render_error(status_code: int, signed_in: bool) -> str:
    """A friendly error page."""
    title, message = ERROR_MESSAGES.get(status_code, ("Something went wrong", "The request could not be completed."))
    link = '<p><a class="btn" href="/">Back to the library</a></p>' if signed_in else ""
    return render_page(title, f'<div class="empty"><h1>{h(title)}</h1><p>{h(message)}</p>{link}</div>', signed_in=signed_in)


# --------------------------------------------------------------------------
# Middleware (pure ASGI: BaseHTTPMiddleware would buffer every video chunk
# through an extra queue)
# --------------------------------------------------------------------------


class SecurityHeadersMiddleware:
    """Adds CSP, nosniff and friends to every response, redirects and errors included."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        self.headers = [(k.lower().encode("latin-1"), v.encode("latin-1")) for k, v in SECURITY_HEADERS.items()]

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                existing = list(message.get("headers", []))
                present = {name.lower() for name, _ in existing}
                message["headers"] = existing + [pair for pair in self.headers if pair[0] not in present]
            await send(message)

        await self.app(scope, receive, send_with_headers)


class AuthMiddleware:
    """Redirects every request without a valid session to /login."""

    PUBLIC_PATHS = frozenset({"/login"})

    def __init__(self, app: ASGIApp, sessions: SessionManager) -> None:
        self.app = app
        self.sessions = sessions

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in self.PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return
        if self.sessions.is_valid(HTTPConnection(scope).cookies.get(SESSION_COOKIE)):
            await self.app(scope, receive, send)
            return
        location = "/login"
        if scope["method"] in ("GET", "HEAD") and scope["path"] != "/":
            # Come back here after logging in. raw_path keeps the exact
            # percent-encoding of the original request (some servers leave
            # the query string on it).
            raw_path = scope.get("raw_path") or quote(scope["path"]).encode()
            here = raw_path.split(b"?", 1)[0].decode("latin-1")
            if scope.get("query_string"):
                here += "?" + scope["query_string"].decode("latin-1")
            location += "?next=" + quote(here, safe="")
        await RedirectResponse(location, status_code=303)(scope, receive, send)


# --------------------------------------------------------------------------
# Application
# --------------------------------------------------------------------------


def icon_response(kind: str) -> Response:
    """Generic SVG thumbnail for when a real one cannot be made."""
    return Response(standalone_icon(kind), media_type="image/svg+xml", headers={"Cache-Control": "private, max-age=3600"})


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the ASGI app. Reads (and validates) the environment if settings is None."""
    settings = settings or load_settings_or_exit()
    library = MediaLibrary(settings.media_root)
    thumbs = ThumbnailService(settings.thumb_dir, settings.ffmpeg, settings.ffprobe)
    credential = settings.password_hash or settings.password
    sessions = SessionManager(settings.secret_key, credential)
    passwords = PasswordChecker(settings.password_hash or hash_password(settings.password))
    limiter = LoginRateLimiter()

    app = FastAPI(title="Media Library", docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(AuthMiddleware, sessions=sessions)
    app.add_middleware(SecurityHeadersMiddleware)  # added last = outermost
    app.state.library = library
    app.state.thumbs = thumbs
    app.state.limiter = limiter

    def client_of(request: Request) -> str:
        return client_key(request.client.host if request.client else None)

    def login_page(target: str, *, status_code: int = 200, error: str | None = None, locked_for: int = 0) -> Response:
        headers = {"Cache-Control": "no-store"}
        if locked_for:
            headers["Retry-After"] = str(locked_for)
        return html_page(render_login(target, error, locked_for), status_code, headers)

    @app.get("/login")
    def login_form(request: Request, next_url: str = Query("/", alias="next")) -> Response:
        target = safe_next(next_url)
        if sessions.is_valid(request.cookies.get(SESSION_COOKIE)):
            return RedirectResponse(target, status_code=303)
        return login_page(target, locked_for=limiter.retry_after(client_of(request)))

    @app.post("/login")
    async def login_submit(request: Request) -> Response:
        client = client_of(request)
        form = await read_form(request)
        target = safe_next(form.get("next"))
        wait = limiter.retry_after(client)
        if wait:
            return login_page(target, status_code=429, locked_for=wait)
        # Count the attempt before the slow check runs in a worker thread, so
        # parallel guesses cannot all get in ahead of the lockout.
        left = limiter.record_failure(client)
        if not await run_in_threadpool(passwords.verify, form.get("password", "")):
            if left == 0:
                log.warning("Locked out %s for %d minutes after %d failed logins", client, LOGIN_LOCKOUT_SECONDS // 60, LOGIN_MAX_FAILURES)
                return login_page(target, status_code=429, locked_for=LOGIN_LOCKOUT_SECONDS)
            log.warning("Failed login from %s (%s left)", client, plural(left, "attempt"))
            message = f"Wrong password. {plural(left, 'attempt')} left before a {LOGIN_LOCKOUT_SECONDS // 60}-minute lockout."
            return login_page(target, status_code=401, error=message)
        limiter.reset(client)
        log.info("Login from %s", client)
        response = RedirectResponse(target, status_code=303)
        response.set_cookie(
            SESSION_COOKIE,
            sessions.issue(),
            max_age=SESSION_MAX_AGE,
            expires=SESSION_MAX_AGE,
            path="/",
            # Secure whenever the site is reached over HTTPS (directly or via a
            # proxy's X-Forwarded-Proto). Over plain HTTP the browser would
            # drop a Secure cookie and nobody could ever log in.
            secure=request.url.scheme == "https",
            httponly=True,
            samesite="lax",
        )
        return response

    @app.api_route("/logout", methods=["GET", "POST"])
    def logout(request: Request) -> Response:
        response = RedirectResponse("/login", status_code=303)
        secure = request.url.scheme == "https"
        response.delete_cookie(SESSION_COOKIE, path="/", secure=secure, httponly=True, samesite="lax")
        return response

    @app.get("/")
    def home() -> Response:
        return browse("")

    @app.get("/browse/{rel:path}")
    def browse(rel: str) -> Response:
        directory = library.resolve(rel)
        if not directory.is_dir():
            raise NotFound()
        rel = clean_rel(rel)
        try:
            entries = library.list_dir(directory, rel)
        except OSError:
            raise NotFound() from None
        return html_page(render_browse(rel, entries, thumbs.video_enabled))

    @app.get("/watch/{rel:path}")
    def watch(rel: str) -> Response:
        path = library.resolve(rel)
        rel = clean_rel(rel)
        kind = media_kind(rel)
        if kind == "image":  # images live in the folder's lightbox
            folder, _, name = rel.rpartition("/")
            return RedirectResponse(f"{folder_url(folder)}#view={quote(name, safe='')}", status_code=303)
        if kind not in ("video", "audio") or not path.is_file():
            raise NotFound()
        folder = parent_rel(rel)
        try:
            siblings = [e for e in library.list_dir(library.resolve(folder), folder) if e.kind == kind]
            tracks = library.subtitles_for(rel) if kind == "video" else []
            mtime = path.stat().st_mtime
        except OSError:
            raise NotFound() from None
        position = next((i for i, e in enumerate(siblings) if e.rel == rel), None)
        previous = siblings[position - 1] if position else None
        following = siblings[position + 1] if position is not None and position + 1 < len(siblings) else None
        return html_page(render_player(rel, kind, mtime, tracks, previous, following, thumbs.video_enabled))

    @app.api_route("/file/{rel:path}", methods=["GET", "HEAD"])
    def media_file(rel: str, request: Request) -> Response:
        path = library.resolve(rel)
        media_type = MEDIA_TYPES.get(os.path.splitext(rel)[1].lower())
        if media_type is None:
            raise NotFound()
        try:
            info = path.stat()
        except OSError:
            raise NotFound() from None
        if not stat.S_ISREG(info.st_mode):
            raise NotFound()
        return file_response(request.headers, path, info, media_type)

    @app.get("/thumb/{rel:path}")
    async def thumbnail(rel: str) -> Response:
        path = await run_in_threadpool(library.resolve, rel)
        kind = media_kind(rel)
        if kind is None or not path.is_file():
            raise NotFound()
        found = await thumbs.get(path, kind)
        if found is None:
            return icon_response(kind)
        thumb_path, media_type = found
        return FileResponse(thumb_path, media_type=media_type, headers={"Cache-Control": "private, max-age=2592000"})

    @app.get("/subtitle/{rel:path}")
    def subtitle(rel: str) -> Response:
        path = library.resolve(rel)
        ext = os.path.splitext(rel)[1].lower()
        if ext not in SUBTITLE_EXTS or not path.is_file() or path.stat().st_size > MAX_SUBTITLE_BYTES:
            raise NotFound()
        data = path.read_bytes()
        text = srt_to_vtt(data) if ext == ".srt" else vtt_text(data)
        return Response(text, media_type="text/vtt", headers={"Cache-Control": "private, no-cache"})

    @app.exception_handler(HTTPException)
    async def http_error(request: Request, exc: HTTPException) -> Response:
        signed_in = sessions.is_valid(request.cookies.get(SESSION_COOKIE))
        return html_page(render_error(exc.status_code, signed_in), exc.status_code, exc.headers)

    log.info("Serving %s", settings.media_root)
    if thumbs.video_enabled:
        log.info("Video thumbnails via %s, cached in %s", settings.ffmpeg, settings.thumb_dir)
    elif settings.ffmpeg is None:
        log.warning("ffmpeg not found: videos will show a generic icon instead of a thumbnail")
    if settings.thumb_dir.resolve().is_relative_to(settings.media_root):
        log.warning("The app folder is inside MEDIA_ROOT; its hidden files are never served, but consider moving it")
    return app


# --------------------------------------------------------------------------
# Deployment: HTTPS certificates, the port-80 helper, systemd, setup questions
# --------------------------------------------------------------------------


class SetupError(Exception):
    """A problem the person running the command has to fix; the message says how."""


_TICK = "✓" if "utf" in (sys.stdout.encoding or "").lower() else "*"


def done(message: str) -> None:
    """Report a finished step."""
    say(f"  {_TICK} {message}", "green")


def own_addresses(*families: socket.AddressFamily) -> set[str]:
    """This machine's source addresses on its default routes (nothing is sent)."""
    targets = {socket.AF_INET: "192.0.2.1", socket.AF_INET6: "2001:db8::1"}  # documentation ranges
    found = set()
    for family in families or tuple(targets):
        with contextlib.suppress(OSError), socket.socket(family, socket.SOCK_DGRAM) as probe:
            probe.connect((targets[family], 9))
            found.add(probe.getsockname()[0])
    return found


def guess_server_ip() -> str:
    """An IPv4 address to show in the URL of a site without a domain."""
    return min(own_addresses(socket.AF_INET), default="localhost")


def listen_socket(host: str, port: int) -> socket.socket:
    """A listening TCP socket. host "" means every IPv4 and IPv6 address."""
    if not host and socket.has_dualstack_ipv6():
        return socket.create_server(("::", port), family=socket.AF_INET6, dualstack_ipv6=True)
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    return socket.create_server((host or "0.0.0.0", port), family=family)


def port_is_free(port: int, host: str = "") -> bool:
    """True if this process could listen on port right now."""
    try:
        listen_socket(host, port).close()
    except OSError:
        return False
    return True


def wait_until_listening(port: int, host: str = "", seconds: float = 20) -> bool:
    """True once something accepts connections on port (on this machine)."""
    hosts = [host] if host else ["127.0.0.1", "::1"]
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for address in hosts:
            with contextlib.suppress(OSError), socket.create_connection((address, port), timeout=1):
                return True
        time.sleep(0.5)
    return False


_ACME_PATH = "/.well-known/acme-challenge/"
_ACME_TOKEN = re.compile(r"[A-Za-z0-9_-]{1,256}")


class _DualStackHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer on every IPv4 and IPv6 address.

    IPv6 matters: when a domain has an AAAA record, Let's Encrypt validates
    over IPv6 first.
    """

    daemon_threads = True
    allow_reuse_port = False  # exclusive: a second listener on port 80 must fail, not share it

    def __init__(self, port: int, handler: type[BaseHTTPRequestHandler]) -> None:
        dual = socket.has_dualstack_ipv6()
        self.address_family = socket.AF_INET6 if dual else socket.AF_INET
        super().__init__(("::" if dual else "0.0.0.0", port), handler, bind_and_activate=False)
        try:
            if dual:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            self.server_bind()
            self.server_activate()
        except OSError:
            self.server_close()
            raise

    def server_bind(self) -> None:
        # Skip HTTPServer.server_bind's reverse-DNS lookup of the listen address.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "media-library", self.server_address[1]


def _port_80_handler(webroot: Path, redirect_to: str | None) -> type[BaseHTTPRequestHandler]:
    challenges = webroot / ".well-known" / "acme-challenge"

    class Handler(BaseHTTPRequestHandler):
        server_version = "media-library"
        sys_version = ""
        timeout = 15  # seconds a client gets to send its request

        def do_GET(self) -> None:  # noqa: N802 (http.server's naming)
            self.answer(with_body=True)

        def do_HEAD(self) -> None:  # noqa: N802
            self.answer(with_body=False)

        def answer(self, with_body: bool) -> None:
            path = self.path.split("?", 1)[0]
            if path.startswith(_ACME_PATH):
                token = path[len(_ACME_PATH) :]
                file = challenges / token
                if _ACME_TOKEN.fullmatch(token) and file.is_file():
                    self.reply(200, file.read_bytes(), with_body)
                else:
                    self.reply(404, b"Not found\n", with_body)
            elif redirect_to:
                self.reply(301, b"", with_body, location=redirect_to + (self.path if self.path.startswith("/") else "/"))
            else:
                self.reply(404, b"Not found\n", with_body)

        def reply(self, status: int, content: bytes, with_body: bool, location: str | None = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            if location:
                self.send_header("Location", location)
            self.end_headers()
            if with_body:
                self.wfile.write(content)

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002 (http.server's name)
            log.debug("port 80: %s %s", self.address_string(), format % args)

    return Handler


class PortEightyHelper:
    """Plain-HTTP helper on port 80 for an HTTPS site.

    Serves the Let's Encrypt HTTP-01 challenge files that certbot writes into
    ACME_WEBROOT, so certificates can be issued and renewed while the site
    runs, and redirects every other request to the HTTPS address.
    """

    def __init__(self, redirect_to: str | None, port: int = 80, webroot: Path = ACME_WEBROOT) -> None:
        self._server = _DualStackHTTPServer(port, _port_80_handler(webroot, redirect_to))  # OSError if taken
        self.port = self._server.server_address[1]
        threading.Thread(target=self._server.serve_forever, name="port-80", daemon=True).start()

    def close(self) -> None:
        """Stop listening."""
        self._server.shutdown()
        self._server.server_close()

    def __enter__(self) -> PortEightyHelper:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()


def certbot_path() -> Path:
    """certbot, installed into the same environment as the running Python."""
    return Path(sys.executable).with_name("certbot.exe" if os.name == "nt" else "certbot")


def certificate_files(domain: str) -> tuple[Path, Path]:
    """(fullchain.pem, privkey.pem) that certbot keeps current for domain."""
    live = CERTBOT_DIR / "config" / "live" / domain
    return live / "fullchain.pem", live / "privkey.pem"


def certbot_command(action: str, *options: str) -> list[str]:
    """A certbot command that keeps all of its state in .certbot next to this file."""
    return [
        str(certbot_path()),
        action,
        "--non-interactive",
        "--config-dir", str(CERTBOT_DIR / "config"),
        "--work-dir", str(CERTBOT_DIR / "work"),
        "--logs-dir", str(CERTBOT_DIR / "logs"),
        *options,
    ]  # fmt: skip


def certonly_command(site: SiteConfig) -> list[str]:
    """The certbot command that gets site.domain its certificate (webroot mode)."""
    options = [
        "--agree-tos",
        "--keep-until-expiring",
        "--webroot", "-w", str(ACME_WEBROOT),
        "--cert-name", site.domain,
        "-d", site.domain,
    ]  # fmt: skip
    options += ["-m", site.email] if site.email else ["--register-unsafely-without-email"]
    if site.acme_server:
        options += ["--server", site.acme_server]
    return certbot_command("certonly", *options)


def _tail(text: str, lines: int = 12) -> str:
    return "\n".join(f"    {line}" for line in text.strip().splitlines()[-lines:])


def _file_digest(path: Path) -> bytes | None:
    try:
        return hashlib.sha256(path.read_bytes()).digest()
    except OSError:
        return None


def certificate_expiry(cert: Path) -> str:
    """The certificate's expiry date, or "" if it cannot be read."""
    try:
        from cryptography import x509  # installed together with certbot

        certificate = x509.load_pem_x509_certificate(cert.read_bytes())
    except Exception:  # only used for messages
        return ""
    expires = getattr(certificate, "not_valid_after_utc", None) or certificate.not_valid_after
    return expires.strftime("%Y-%m-%d")


def resolve(domain: str) -> set[str]:
    """The addresses domain resolves to (empty if it does not resolve)."""
    try:
        return {info[4][0] for info in socket.getaddrinfo(domain, 80, proto=socket.IPPROTO_TCP)}
    except (socket.gaierror, UnicodeError):
        return set()


def probe_domain(domain: str) -> None:
    """Fetch a file through http://domain as Let's Encrypt will, and explain a failure."""
    token = secrets.token_urlsafe(16)
    probe = ACME_WEBROOT / ".well-known" / "acme-challenge" / token
    probe.parent.mkdir(parents=True, exist_ok=True)
    probe.write_text(token, encoding="utf-8")
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://{domain}{_ACME_PATH}{token}", timeout=10) as response:
            reachable = response.read().decode("utf-8", "replace") == token
    except (OSError, ValueError):
        reachable = False
    finally:
        probe.unlink(missing_ok=True)
    if reachable:
        done(f"http://{domain} reaches this server")
        return
    addresses, mine = resolve(domain), own_addresses()
    say(f"  Could not reach http://{domain} from this server itself.", "yellow")
    say(f"  {domain} points to {', '.join(sorted(addresses))}; this server uses {', '.join(sorted(mine)) or '?'}.", "yellow")
    if any(":" in a for a in addresses) and not any(":" in a for a in mine):
        say("  The domain has an IPv6 (AAAA) record but this server has no IPv6: delete that record.", "yellow")
    say("  Trying anyway (some networks cannot loop back to themselves)...", "yellow")


PORT_80_BUSY = (
    "Port 80 is used by another program (a web server such as nginx or apache?). Let's Encrypt "
    "checks the domain on port 80: stop that program (for example `systemctl stop nginx`), then run setup again."
)


def obtain_certificate(site: SiteConfig) -> None:
    """Get a certificate for site.domain, answering Let's Encrypt on port 80."""
    ACME_WEBROOT.mkdir(parents=True, exist_ok=True)
    try:
        helper = PortEightyHelper(redirect_to=None)
    except OSError:
        raise SetupError(PORT_80_BUSY) from None
    with helper:
        probe_domain(site.domain)
        say(f"  Asking Let's Encrypt for a certificate for {site.domain}...")
        result = subprocess.run(certonly_command(site), capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SetupError(
            f"Let's Encrypt did not issue the certificate:\n{_tail(result.stderr or result.stdout)}\n"
            "Check that the domain points to this server and that port 80 is open in every firewall, "
            "including your hosting provider's."
        )


def renew_certificate(site: SiteConfig, force: bool = False, right_away: bool = False) -> bool:
    """Run `certbot renew` (it renews only when due). True if the certificate changed.

    Unattended, certbot first sleeps a random few minutes so that renewals do
    not all hit Let's Encrypt at once; right_away skips that for manual runs.
    """
    cert, _ = certificate_files(site.domain)
    before = _file_digest(cert)
    options = ["--cert-name", site.domain]
    options += ["--force-renewal"] if force else []
    options += ["--no-random-sleep-on-renew"] if right_away else []
    command = certbot_command("renew", *options)
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SetupError(f"Renewing the certificate failed:\n{_tail(result.stderr or result.stdout)}")
    return _file_digest(cert) != before


class MediaServer(uvicorn.Server):
    """uvicorn.Server that keeps its Let's Encrypt certificate fresh.

    Twice a day it runs `certbot renew` (which renews only when due) and loads
    a renewed certificate into the live TLS context: no restart and no dropped
    connections. SIGHUP (`systemctl reload media-library`) reloads it too.
    """

    def __init__(self, config: uvicorn.Config, site: SiteConfig) -> None:
        super().__init__(config)
        self.site = site

    async def serve(self, sockets: list[socket.socket] | None = None) -> None:
        upkeep = None
        if self.site.tls:
            with contextlib.suppress(AttributeError, NotImplementedError, RuntimeError):  # no SIGHUP on Windows
                asyncio.get_running_loop().add_signal_handler(signal.SIGHUP, self.reload_certificate)
            upkeep = asyncio.create_task(self._renew_regularly())
        try:
            await super().serve(sockets=sockets)
        finally:
            if upkeep:
                upkeep.cancel()

    def reload_certificate(self) -> None:
        """Load the certificate files again into the running TLS context."""
        context = getattr(self.config, "ssl", None)  # set once uvicorn has loaded its config
        if context is None:
            return
        cert, key = certificate_files(self.site.domain)
        try:
            context.load_cert_chain(cert, key)
        except (OSError, ssl.SSLError) as exc:
            log.error("Could not load the certificate %s: %s", cert, exc)
        else:
            log.info("Loaded the certificate for %s (valid until %s)", self.site.domain, certificate_expiry(cert) or "?")

    async def _renew_regularly(self) -> None:
        await asyncio.sleep(60)  # soon after start, to catch up on renewals missed while stopped
        while True:
            try:
                if await asyncio.to_thread(renew_certificate, self.site):
                    self.reload_certificate()
            except (SetupError, OSError) as problem:
                if "already running" in str(problem):  # a manual `main.py renew` holds certbot's lock
                    log.info("certbot is busy elsewhere; checking the certificate again later")
                else:
                    log.warning("%s", problem)
            await asyncio.sleep(CERT_RENEW_INTERVAL)


def serve(site: SiteConfig | None) -> None:
    """Run the website in the foreground until Ctrl+C or SIGTERM."""
    app = create_app()  # validates MEDIA_ROOT/MEDIA_PASSWORD or config.json, exits with a message if wrong
    options: dict[str, object] = {
        # Trust X-Forwarded-For/-Proto only from a reverse proxy on this machine,
        # so the login rate limiter sees real client addresses.
        "proxy_headers": True,
        "forwarded_allow_ips": os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1"),
        "server_header": False,
    }
    if site is None:  # environment-variable mode, usually behind a reverse proxy
        try:
            port = int(os.environ.get("PORT", "8000"))
        except ValueError:
            raise SetupError(f"PORT must be a number, not {os.environ['PORT']!r}") from None
        uvicorn.run(app, host=os.environ.get("HOST", "127.0.0.1"), port=port, **options)
        return

    helper = None
    if site.tls:
        cert, key = certificate_files(site.domain)
        if not cert.exists():
            raise SetupError(f"There is no certificate for {site.domain} yet. Run: sudo python3 {SCRIPT} setup")
        options.update(ssl_certfile=str(cert), ssl_keyfile=str(key))
        try:
            helper = PortEightyHelper(redirect_to=site.public_url())
        except OSError:
            log.warning("Port 80 is taken: HTTP won't redirect to HTTPS and renewals will fail until it is free")
    try:
        sock = listen_socket(site.host, site.port)
    except OSError as exc:
        if helper:
            helper.close()
        raise SetupError(
            f"Cannot listen on port {site.port} ({exc.strerror}). Is it already running? "
            f"(systemctl status {SERVICE_NAME})"
        ) from None
    server = MediaServer(uvicorn.Config(app, host=site.host or "0.0.0.0", port=site.port, **options), site)
    log.info("Media Library is at %s", site.public_url())
    try:
        server.run(sockets=[sock])
    finally:
        if helper:
            helper.close()


def systemd_available() -> bool:
    """True when systemd runs this machine and we may install services."""
    return is_root() and shutil.which("systemctl") is not None and Path("/run/systemd/system").is_dir()


def systemctl(*args: str) -> subprocess.CompletedProcess[str]:
    """Run systemctl, capturing its output."""
    return subprocess.run(["systemctl", *args], capture_output=True, text=True, check=False)


def service_active() -> bool:
    """True if our systemd service is running."""
    return systemd_available() and systemctl("is-active", "--quiet", SERVICE_NAME).returncode == 0


def _unit_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
    return f'"{escaped}"'


def service_unit(python: str, script: Path) -> str:
    """The systemd unit that runs `main.py serve`."""
    return f"""[Unit]
Description=Media Library
After=network-online.target
Wants=network-online.target

[Service]
ExecStart={_unit_quote(python)} {_unit_quote(str(script))} serve
ExecReload=/bin/kill -HUP $MAINPID
WorkingDirectory={str(script.parent).replace("%", "%%")}
Restart=on-failure
RestartSec=5
# Root is needed for ports 80/443 and to read any media folder, but the
# service may not modify the system: /usr, /boot and /etc are read-only
# (except this app's own folder), and it cannot gain privileges, load kernel
# modules or keep other capabilities.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths={_unit_quote(str(script.parent))}
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_FOWNER CAP_CHOWN

[Install]
WantedBy=multi-user.target
"""


def _service_log() -> str:
    journal = subprocess.run(
        ["journalctl", "-u", SERVICE_NAME, "-n", "25", "--no-pager"], capture_output=True, text=True, check=False
    )
    return _tail(journal.stdout, 25)


def start_service(site: SiteConfig, *, restart: bool = False) -> None:
    """(Re)start the systemd service and wait until the site answers."""
    systemctl("restart" if restart else "start", SERVICE_NAME)
    if not wait_until_listening(site.port, site.host):
        raise SetupError(f"The {SERVICE_NAME} service did not start. Its log:\n{_service_log()}")


def install_service(site: SiteConfig) -> None:
    """Install the systemd service, enable it at boot and (re)start it."""
    SERVICE_FILE.write_text(service_unit(sys.executable, SCRIPT), encoding="utf-8")
    systemctl("daemon-reload")
    systemctl("enable", SERVICE_NAME)
    start_service(site, restart=True)


def uninstall_service() -> None:
    """Stop and remove the systemd service (files and settings stay)."""
    if not SERVICE_FILE.exists():
        say("The service is not installed.")
        return
    if not is_root():
        raise SetupError(f"Removing the service needs root: sudo python3 {SCRIPT} uninstall")
    systemctl("disable", "--now", SERVICE_NAME)
    SERVICE_FILE.unlink()
    systemctl("daemon-reload")
    done(f"Removed the {SERVICE_NAME} service. Settings, certificates and media in {APP_DIR} are untouched.")


def open_firewall(ports: Sequence[int]) -> None:
    """Allow ports through ufw or firewalld, whichever is active."""
    if not is_root():
        return
    listed = ", ".join(map(str, ports))
    if shutil.which("ufw") and "Status: active" in subprocess.run(
        ["ufw", "status"], capture_output=True, text=True, check=False
    ).stdout:
        for port in ports:
            subprocess.run(["ufw", "allow", f"{port}/tcp"], capture_output=True, check=False)
        done(f"Opened TCP {listed} in the ufw firewall")
    elif shutil.which("firewall-cmd") and subprocess.run(["firewall-cmd", "--state"], capture_output=True, check=False).returncode == 0:
        for port in ports:
            subprocess.run(["firewall-cmd", "--permanent", f"--add-port={port}/tcp"], capture_output=True, check=False)
        subprocess.run(["firewall-cmd", "--reload"], capture_output=True, check=False)
        done(f"Opened TCP {listed} in firewalld")


def ensure_ffmpeg() -> None:
    """Install ffmpeg (video thumbnails) if it is missing and we can."""
    if shutil.which("ffmpeg"):
        return
    say("  Installing ffmpeg for video thumbnails (can take a few minutes)...")
    if install_system_package("ffmpeg", "ffmpeg-free"):
        done("ffmpeg installed")
    else:
        say("  Could not install ffmpeg; videos will show an icon instead of a thumbnail.", "yellow")


# Setup questions --------------------------------------------------------------

_YES = {"y", "yes", "آره", "اره", "بله"}  # Persian answers are accepted too
_NO = {"n", "no", "نه", "خیر"}
_HOSTNAME = re.compile(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?")


def ask(question: str, default: str = "", check: Callable[[str], str] | None = None, optional: bool = False) -> str:
    """Ask until the answer passes check, which returns it cleaned up or raises ValueError."""
    suffix = f" [{default}]" if default else ""
    while True:
        try:
            answer = input(f"{question}{suffix}: ").strip() or default
        except EOFError:
            raise SetupError("Setup needs answers: run it in a terminal.") from None
        if not answer:
            if optional:
                return ""
            continue
        try:
            return check(answer) if check else answer
        except ValueError as problem:
            say(f"  {problem}", "yellow")


def ask_yes_no(question: str, default: bool) -> bool:
    """A yes/no question; Enter picks the default."""
    while True:
        answer = ask(f"{question} [{'Y/n' if default else 'y/N'}]", optional=True).lower()
        if not answer:
            return default
        if answer in _YES or answer in _NO:
            return answer in _YES
        say("  Please answer y or n.", "yellow")


def ask_password(current_hash: str) -> str:
    """Ask for the website password; returns its hash."""
    read = getpass.getpass if sys.stdin.isatty() else input
    hint = "Enter keeps the current one" if current_hash else "Enter makes one up"
    while True:
        try:
            first = read(f"Password for the website ({hint}): ")
            if not first:
                if current_hash:
                    return current_hash
                first = secrets.token_urlsafe(12)
                say(f"  Your password is: {first}   <- write it down", "bold")
                return hash_password(first)
            if len(first) < 8:
                say("  Use at least 8 characters.", "yellow")
            elif read("Type it again: ") != first:
                say("  The two didn't match; try again.", "yellow")
            else:
                return hash_password(first)
        except EOFError:
            raise SetupError("Setup needs answers: run it in a terminal.") from None


def check_media_folder(answer: str) -> str:
    """The media folder as an absolute path, created on request."""
    path = Path(answer).expanduser().absolute()
    if not path.exists():
        if not ask_yes_no(f"  {path} does not exist. Create it?", True):
            raise ValueError("Enter the folder your media is in.")
        try:
            path.mkdir(parents=True)
        except OSError as exc:
            raise ValueError(f"Cannot create {path}: {exc.strerror}") from None
    if not path.is_dir():
        raise ValueError(f"{path} is a file, not a folder.")
    return str(path.resolve())


def normalize_domain(answer: str) -> str:
    """"https://Media.Example.com/" -> "media.example.com"; non-Latin names become punycode."""
    domain = re.sub(r"^[a-z][a-z0-9+.-]*://", "", answer.strip(), flags=re.IGNORECASE)
    domain = domain.split("/")[0].split(":")[0].rstrip(".").lower()
    try:
        domain = domain.encode("idna").decode("ascii")
    except UnicodeError:
        raise ValueError("That is not a valid domain name.") from None
    try:
        ipaddress.ip_address(domain)
    except ValueError:
        pass
    else:
        raise ValueError("Let's Encrypt needs a domain name here, not an IP address.")
    if not _HOSTNAME.fullmatch(domain):
        raise ValueError("That is not a valid domain name (for example: media.example.com).")
    return domain


def check_domain(answer: str) -> str:
    """A domain name that already resolves (Let's Encrypt will look it up)."""
    domain = normalize_domain(answer)
    if not resolve(domain):
        raise ValueError(
            f"{domain} does not resolve yet. Point its A record at this server ({guess_server_ip()}), "
            "wait a few minutes and type it again (Ctrl+C to stop)."
        )
    return domain


def check_email(answer: str) -> str:
    """A plausible email address."""
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", answer):
        raise ValueError("That does not look like an email address.")
    return answer


def check_port(answer: str, tls: bool) -> str:
    """A port that can be used for the website."""
    try:
        port = int(answer)
    except ValueError:
        port = 0
    if not 1 <= port <= 65535:
        raise ValueError("Enter a number from 1 to 65535.")
    if tls and port == 80:
        raise ValueError("Port 80 stays free for Let's Encrypt and the redirect to HTTPS; 443 is the usual HTTPS port.")
    if port < 1024 and not is_root():
        raise ValueError("Ports below 1024 need root: run with sudo, or pick 1024 or higher (for example 8000).")
    if not port_is_free(port):
        raise ValueError(f"Port {port} is already used by another program; pick another.")
    return str(port)


def ask_questions(existing: SiteConfig | None, acme_server: str) -> tuple[SiteConfig, bool]:
    """The setup questions. Returns the answers and whether to install the systemd service."""
    say("\nMedia Library setup", "bold")
    say("Press Enter to accept the suggestion in [brackets].\n", "dim")
    old = existing or SiteConfig(media_root="", password_hash="", port=0)
    default_folder = old.media_root or ("/srv/media" if is_root() else str(Path.home() / "media"))
    media_root = ask("Folder with your videos, photos and music", default_folder, check=check_media_folder)
    password_hash = ask_password(old.password_hash)
    tls = ask_yes_no("Get a free HTTPS certificate (Let's Encrypt) for a domain?", old.tls)
    domain = email = ""
    if tls:
        if not is_root():
            raise SetupError(f"Getting a certificate needs port 80, which only root may use. Run: sudo python3 {SCRIPT} setup")
        if not port_is_free(80):
            raise SetupError(PORT_80_BUSY)
        domain = ask("Domain name (its DNS must already point to this server)", old.domain, check=check_domain)
        email = ask("Email for Let's Encrypt notices (optional, Enter to skip)", old.email, check=check_email, optional=True)
    port_default = old.port if old.port and old.tls == tls else (443 if tls else 8000)
    port = int(ask("Port for the website", str(port_default), check=lambda answer: check_port(answer, tls)))
    as_service = systemd_available() and ask_yes_no("Run it in the background and start it at boot (systemd service)?", True)
    site = SiteConfig(media_root, password_hash, port, domain=domain, email=email, acme_server=acme_server, host=old.host)
    return site, as_service


def setup(existing: SiteConfig | None, acme_server: str) -> None:
    """Ask the questions, install what is needed, get the certificate, start the site."""
    was_running = service_active()
    if was_running:
        say(f"Stopping the {SERVICE_NAME} service while it is reconfigured...", "dim")
        systemctl("stop", SERVICE_NAME)
    try:
        site, as_service = ask_questions(existing, acme_server)
        say("\nSetting up", "bold")
        ensure_ffmpeg()
        load_secret_key("", APP_DIR / ".secret_key")  # created now, while we may still write anywhere
        (APP_DIR / ".thumbs").mkdir(exist_ok=True)
        open_firewall([80, site.port] if site.tls else [site.port])
        if site.tls:
            if not certbot_path().exists():
                pip_install(CERTBOT_REQUIREMENT)
            obtain_certificate(site)
            done(f"Certificate for {site.domain}, valid until {certificate_expiry(certificate_files(site.domain)[0]) or '?'}")
        site.save()
    except BaseException:
        if was_running:  # nothing was changed: keep the site up with its old settings
            systemctl("start", SERVICE_NAME)
            say(f"The {SERVICE_NAME} service is running again with the previous settings.", "dim")
        raise
    done(f"Settings saved in {CONFIG_FILE}")
    if as_service:
        install_service(site)
        done(f"Service '{SERVICE_NAME}' is running and starts at boot")
    elif SERVICE_FILE.exists() and systemd_available():
        uninstall_service()  # asked not to run as a service any more
    say(f"\nYour media library: {site.public_url()}", "bold")
    if not site.tls:
        say("Without HTTPS the password travels unencrypted; run setup again to add a certificate.", "yellow")
    say("Cloud firewall (security group)? Allow TCP " + ("80 and " if site.tls else "") + f"{site.port} there too.", "dim")
    if as_service:
        say(f"Logs: journalctl -u {SERVICE_NAME} -f    Change settings: sudo python3 {SCRIPT} setup\n", "dim")
    else:
        say("Serving from this terminal; press Ctrl+C to stop.\n", "dim")
        serve(site)


def renew(site: SiteConfig | None, force: bool) -> None:
    """`main.py renew`: renew the certificate now and load it into the running site."""
    if site is None or not site.tls:
        raise SetupError(f"HTTPS is not set up. Run: sudo python3 {SCRIPT} setup")
    if not is_root():
        raise SetupError(f"Renewing needs root: sudo python3 {SCRIPT} renew")
    # The running site answers the challenge on port 80; otherwise do it here.
    helper = PortEightyHelper(redirect_to=None) if port_is_free(80) else None
    try:
        changed = renew_certificate(site, force, right_away=True)
    finally:
        if helper:
            helper.close()
    expiry = certificate_expiry(certificate_files(site.domain)[0]) or "?"
    if not changed:
        say(f"Not due for renewal yet (valid until {expiry}). Use --force to renew anyway.")
        return
    done(f"Renewed; valid until {expiry}")
    if service_active():
        systemctl("reload", SERVICE_NAME)
        done("The running service loaded the new certificate")
    else:
        say("Send SIGHUP to a server started by hand (or restart it) to load it.", "dim")


def main(argv: Sequence[str] | None = None) -> None:
    """Command line entry point."""
    parser = argparse.ArgumentParser(
        prog="main.py",
        description="Personal media library server.",
        epilog="Without a command, the first run sets everything up and later runs start the server.",
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="start",
        choices=("start", "setup", "serve", "renew", "uninstall"),
        help="setup: change the settings; serve: run without questions; renew: renew the HTTPS "
        "certificate now; uninstall: remove the systemd service",
    )
    parser.add_argument("--staging", action="store_true", help="setup: use Let's Encrypt's staging server (test certificates)")
    parser.add_argument("--acme-server", default="", metavar="URL", help="setup: directory URL of another ACME server")
    parser.add_argument("--force", action="store_true", help="renew: renew even if the certificate is not due yet")
    args = parser.parse_args(argv)
    acme_server = LETSENCRYPT_STAGING if args.staging else args.acme_server
    try:
        env_mode = "MEDIA_ROOT" in os.environ or "MEDIA_PASSWORD" in os.environ
        site = None if env_mode else SiteConfig.load()
        if args.command == "setup" or (args.command == "start" and site is None and not env_mode):
            setup(site, acme_server)
        elif args.command == "renew":
            renew(site, args.force)
        elif args.command == "uninstall":
            uninstall_service()
        elif args.command == "start" and site and SERVICE_FILE.exists() and systemd_available():
            start_service(site)
            say(f"Media Library is running at {site.public_url()} (service '{SERVICE_NAME}')", "green")
        else:
            serve(site)
    except (SetupError, ConfigError) as problem:
        say(f"\n{problem}", "red")
        raise SystemExit(1) from None
    except KeyboardInterrupt:
        say("\nCancelled.")
        raise SystemExit(130) from None


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

if not logging.getLogger().handlers:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(message)s")

if __name__ == "__main__":
    main()
else:
    # `uvicorn main:app`: settings come from environment variables or config.json.
    app = create_app()
