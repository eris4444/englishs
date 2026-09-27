#!/usr/bin/env python3
"""Personal media library server in a single file.

Serves the videos, images and audio files below ``MEDIA_ROOT`` to a browser,
behind one shared password::

    MEDIA_ROOT=/srv/media MEDIA_PASSWORD='a long passphrase' python main.py

README.md lists every environment variable and has an nginx example.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import html
import ipaddress
import logging
import math
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, deque
from dataclasses import dataclass
from datetime import timezone
from email.utils import formatdate, parsedate_to_datetime
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence, Union
from urllib.parse import parse_qs, quote, urlsplit

import anyio
import uvicorn
from fastapi import FastAPI, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response
from itsdangerous import BadData, URLSafeTimedSerializer
from PIL import Image, ImageOps
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import Headers
from starlette.exceptions import HTTPException
from starlette.requests import HTTPConnection
from starlette.types import ASGIApp, Message, Receive, Scope, Send

log = logging.getLogger("media")

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

APP_DIR = Path(__file__).resolve().parent

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
    """The environment does not describe a server that can start."""


@dataclass(frozen=True)
class Settings:
    """Runtime configuration, normally built from the environment by ``from_env``."""

    media_root: Path
    password: str
    secret_key: str
    thumb_dir: Path = APP_DIR / ".thumbs"
    ffmpeg: str | None = None
    ffprobe: str | None = None

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None, app_dir: Path = APP_DIR) -> Settings:
        """Read and validate the environment, reporting every problem at once."""
        env = os.environ if environ is None else environ
        problems: list[str] = []

        media_root: Path | None = None
        raw_root = env.get("MEDIA_ROOT", "").strip()
        if not raw_root:
            problems.append("MEDIA_ROOT is not set. Point it at the folder to serve, e.g. MEDIA_ROOT=/srv/media")
        else:
            try:
                media_root = check_media_root(raw_root)
            except ConfigError as exc:
                problems.append(str(exc))

        password = env.get("MEDIA_PASSWORD", "")
        if not password.strip():
            problems.append("MEDIA_PASSWORD is not set. Export the password that unlocks the library.")

        if problems:
            raise ConfigError("\n".join(problems))
        assert media_root is not None

        return cls(
            media_root=media_root,
            password=password,
            secret_key=load_secret_key(env.get("SECRET_KEY", ""), app_dir / ".secret_key"),
            thumb_dir=app_dir / ".thumbs",
            ffmpeg=shutil.which("ffmpeg"),
            ffprobe=shutil.which("ffprobe"),
        )


def check_media_root(raw: str) -> Path:
    """Resolve MEDIA_ROOT and check that it is a readable directory."""
    try:
        root = Path(raw).expanduser().resolve(strict=True)
    except FileNotFoundError:
        raise ConfigError(f"MEDIA_ROOT={raw} does not exist.") from None
    except (OSError, RuntimeError) as exc:
        raise ConfigError(f"MEDIA_ROOT={raw} cannot be opened: {exc}") from None
    if not root.is_dir():
        raise ConfigError(f"MEDIA_ROOT={raw} is not a directory.")
    if not os.access(root, os.R_OK | os.X_OK):
        raise ConfigError(f"MEDIA_ROOT={raw} is not readable by this user.")
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


class PasswordChecker:
    """Timing-safe password verification.

    Both the configured and the submitted password are reduced to fixed-length
    HMAC digests before ``hmac.compare_digest`` sees them, so the comparison
    time reveals neither the password's contents nor its length.
    """

    def __init__(self, password: str) -> None:
        self._key = secrets.token_bytes(32)
        self._expected = self._digest(password)

    def _digest(self, candidate: str) -> bytes:
        data = candidate.encode("utf-8", "surrogateescape")
        return hmac.new(self._key, data, hashlib.sha256).digest()

    def verify(self, candidate: str) -> bool:
        """True if candidate is the configured password."""
        return hmac.compare_digest(self._digest(candidate), self._expected)


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

    def __init__(self, secret_key: str, password: str, max_age: int = SESSION_MAX_AGE) -> None:
        # The password is folded into the signing salt, so changing
        # MEDIA_PASSWORD invalidates every existing session.
        fingerprint = hashlib.sha256(password.encode("utf-8", "surrogateescape")).hexdigest()
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
    sessions = SessionManager(settings.secret_key, settings.password)
    passwords = PasswordChecker(settings.password)
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
        if not passwords.verify(form.get("password", "")):
            left = limiter.record_failure(client)
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
            secure=True,
            httponly=True,
            samesite="lax",
        )
        return response

    @app.api_route("/logout", methods=["GET", "POST"])
    def logout() -> Response:
        response = RedirectResponse("/login", status_code=303)
        response.delete_cookie(SESSION_COOKIE, path="/", secure=True, httponly=True, samesite="lax")
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
# Entry point
# --------------------------------------------------------------------------

if not logging.getLogger().handlers:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(message)s")

# Built at import so that both `python main.py` and `uvicorn main:app` check
# the configuration before serving anything.
app = create_app()


def main() -> None:
    """``python main.py``: serve the app with Uvicorn on HOST:PORT."""
    host = os.environ.get("HOST", "127.0.0.1")
    try:
        port = int(os.environ.get("PORT", "8000"))
    except ValueError:
        print(f"PORT must be a number, not {os.environ['PORT']!r}", file=sys.stderr)
        raise SystemExit(2) from None
    uvicorn.run(
        app,
        host=host,
        port=port,
        # Trust X-Forwarded-For/-Proto only from the reverse proxy, so the
        # login rate limiter sees real client addresses.
        proxy_headers=True,
        forwarded_allow_ips=os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1"),
        server_header=False,
    )


if __name__ == "__main__":
    main()
