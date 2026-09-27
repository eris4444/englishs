"""Tests for main.py. Run with: pip install pytest httpx && pytest"""

from __future__ import annotations

import base64
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import anyio
import pytest
from fastapi.testclient import TestClient
from PIL import Image

# main.py builds its app at import time from the environment.
os.environ.update(MEDIA_ROOT=tempfile.mkdtemp(), MEDIA_PASSWORD="import-only", SECRET_KEY="import-only")
import main  # noqa: E402

PASSWORD = "correct horse battery staple"
VIDEO_BYTES = bytes(range(256)) * 400  # 102400 bytes with a recognisable pattern


@pytest.fixture
def media(tmp_path: Path) -> Path:
    """A small library with the awkward cases: hidden files, escaping symlinks, odd names."""
    root = tmp_path / "media"
    (root / "Movies" / "Action").mkdir(parents=True)
    (root / "Shows").mkdir()
    (root / "Photos").mkdir()
    (root / ".hidden").mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()

    (root / "Movies" / "Film.mp4").write_bytes(VIDEO_BYTES)
    (root / "Movies" / "Film.srt").write_text("1\n00:00:01,000 --> 00:00:02,500\nHello & <i>bye</i>\n")
    (root / "Movies" / "Film.en.vtt").write_text("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n")
    (root / "Movies" / "Film.en.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nignored\n")
    (root / "Movies" / "<img src=x onerror=alert(1)>.mp4").write_bytes(b"x")
    for n in (10, 2, 1):
        (root / "Shows" / f"Episode {n}.mkv").write_bytes(b"x")
    (root / "notes.txt").write_text("not media")
    (root / ".secret.mp4").write_bytes(b"hidden")
    (root / ".hidden" / "clip.mp4").write_bytes(b"hidden")
    Image.new("RGB", (1600, 1200), "orange").save(root / "Photos" / "big.jpg")
    Image.new("RGBA", (64, 64), (0, 0, 0, 0)).save(root / "Photos" / "clear.png")
    (root / "Photos" / "broken.jpg").write_bytes(b"not an image")

    (outside / "secret.mp4").write_bytes(b"OUTSIDE")
    (root / "Movies" / "escape.mp4").symlink_to(outside / "secret.mp4")
    (root / "Movies" / "escape-dir").symlink_to(outside)
    (root / "Movies" / "Alias.mp4").symlink_to(root / "Movies" / "Film.mp4")
    (root / "Movies" / "loop.mp4").symlink_to(root / "Movies" / "loop.mp4")
    return root


@pytest.fixture
def settings(media: Path, tmp_path: Path) -> main.Settings:
    return main.Settings(
        media_root=media.resolve(),
        password=PASSWORD,
        secret_key="test-secret",
        thumb_dir=tmp_path / "thumbs",
        ffmpeg=None,
        ffprobe=None,
    )


def make_client(settings: main.Settings, login: bool = True) -> TestClient:
    # https: the session cookie is Secure, so the client only sends it over TLS.
    client = TestClient(main.create_app(settings), base_url="https://testserver", follow_redirects=False)
    if login:
        response = client.post("/login", data={"password": PASSWORD, "next": "/"})
        assert response.status_code == 303
    return client


@pytest.fixture
def client(settings: main.Settings) -> TestClient:
    return make_client(settings)


@pytest.fixture
def anon(settings: main.Settings) -> TestClient:
    return make_client(settings, login=False)


# --------------------------------------------------------------------------- config


def test_missing_config_lists_every_problem() -> None:
    with pytest.raises(main.ConfigError) as err:
        main.Settings.from_env({})
    assert "MEDIA_ROOT is not set" in str(err.value)
    assert "MEDIA_PASSWORD is not set" in str(err.value)


@pytest.mark.parametrize("make_root, message", [(lambda p: p / "nope", "does not exist"), (lambda p: p / "f", "is not a directory")])
def test_bad_media_root(tmp_path: Path, make_root, message: str) -> None:
    (tmp_path / "f").write_text("file")
    with pytest.raises(main.ConfigError, match=message):
        main.Settings.from_env({"MEDIA_ROOT": str(make_root(tmp_path)), "MEDIA_PASSWORD": "x"}, app_dir=tmp_path)


def test_startup_without_media_root_exits_with_message_not_traceback() -> None:
    env = {k: v for k, v in os.environ.items() if k not in ("MEDIA_ROOT", "MEDIA_PASSWORD")}
    result = subprocess.run([sys.executable, main.__file__], env=env, capture_output=True, text=True, timeout=60)
    assert result.returncode == 2
    assert "MEDIA_ROOT is not set" in result.stderr
    assert "Traceback" not in result.stderr


def test_secret_key_is_generated_once_and_persisted(tmp_path: Path) -> None:
    key_file = tmp_path / ".secret_key"
    first = main.load_secret_key("", key_file)
    assert len(first) >= 32
    assert key_file.stat().st_mode & 0o777 == 0o600
    assert main.load_secret_key("", key_file) == first
    assert main.load_secret_key("from-env", key_file) == "from-env"


# --------------------------------------------------------------------------- auth


def test_everything_redirects_to_login_when_signed_out(anon: TestClient) -> None:
    for path in ("/", "/browse/Movies", "/file/Movies/Film.mp4", "/thumb/Photos/big.jpg", "/no/such/page"):
        response = anon.get(path)
        assert response.status_code == 303, path
        assert response.headers["location"].startswith("/login")
    assert anon.get("/watch/Movies/Film.mp4?t=1").headers["location"] == "/login?next=%2Fwatch%2FMovies%2FFilm.mp4%3Ft%3D1"


def test_login_sets_hardened_cookie_and_returns_to_next(anon: TestClient) -> None:
    response = anon.post("/login", data={"password": PASSWORD, "next": "/browse/Movies"})
    assert response.status_code == 303
    assert response.headers["location"] == "/browse/Movies"
    cookie = response.headers["set-cookie"].lower()
    for attribute in ("httponly", "secure", "samesite=lax", "max-age=2592000", "path=/"):
        assert attribute in cookie
    assert anon.get("/").status_code == 200


def test_wrong_password_and_tampered_cookie(anon: TestClient) -> None:
    assert anon.post("/login", data={"password": "nope"}).status_code == 401
    anon.cookies.set("media_session", "forged.value.here", domain="testserver")
    assert anon.get("/").status_code == 303


def test_password_is_compared_as_fixed_length_digests(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = []
    real = main.hmac.compare_digest
    monkeypatch.setattr(main.hmac, "compare_digest", lambda a, b: seen.append((len(a), len(b))) or real(a, b))
    checker = main.PasswordChecker("secret")
    assert checker.verify("secret") and not checker.verify("secre") and not checker.verify("secret" * 100)
    assert seen == [(32, 32)] * 3


def test_sessions_expire_and_die_with_a_password_change(monkeypatch: pytest.MonkeyPatch) -> None:
    sessions = main.SessionManager("key", "pw1")
    token = sessions.issue()
    assert sessions.is_valid(token)
    assert not main.SessionManager("key", "pw2").is_valid(token)
    real_time = main.time.time
    monkeypatch.setattr("itsdangerous.timed.time.time", lambda: real_time() + 31 * 86400)
    assert not sessions.is_valid(token)


def test_logout_clears_the_cookie(client: TestClient) -> None:
    response = client.post("/logout")
    assert response.status_code == 303 and response.headers["location"] == "/login"
    assert 'media_session=""' in response.headers["set-cookie"]
    assert client.get("/").status_code == 303


@pytest.mark.parametrize("target", ["//evil.com", "/\\evil.com", "https://evil.com", "/\t/evil.com", "evil.com", "", "/login"])
def test_next_cannot_redirect_off_site(target: str) -> None:
    assert main.safe_next(target) == "/"


def test_lockout_after_five_failures(anon: TestClient) -> None:
    for _ in range(4):
        assert anon.post("/login", data={"password": "bad"}).status_code == 401
    locked = anon.post("/login", data={"password": "bad"})
    assert locked.status_code == 429 and locked.headers["retry-after"] == "900"
    # Even the right password is refused while locked out.
    assert anon.post("/login", data={"password": PASSWORD}).status_code == 429


def test_lockout_expires_after_fifteen_minutes() -> None:
    now = [1000.0]
    limiter = main.LoginRateLimiter(clock=lambda: now[0])
    for _ in range(4):
        assert limiter.record_failure("1.2.3.4") > 0
    assert limiter.record_failure("1.2.3.4") == 0
    assert limiter.retry_after("1.2.3.4") == 900
    assert limiter.retry_after("5.6.7.8") == 0
    now[0] += 900
    assert limiter.retry_after("1.2.3.4") == 0


def test_ipv6_clients_are_grouped_by_64() -> None:
    assert main.client_key("2001:db8::1") == main.client_key("2001:db8::ffff") == "2001:db8::/64"
    assert main.client_key("2001:db8:0:1::1") != main.client_key("2001:db8::1")
    assert main.client_key("::ffff:10.0.0.1") == "10.0.0.1"


# --------------------------------------------------------------------------- path safety


@pytest.mark.parametrize(
    "rel",
    [
        "../outside/secret.mp4",
        "Movies/../../outside/secret.mp4",
        "/etc/passwd",
        "Movies/escape.mp4",  # symlink to a file outside the root
        "Movies/escape-dir/secret.mp4",  # symlink to a folder outside the root
        "Movies/loop.mp4",
        ".secret.mp4",
        ".hidden/clip.mp4",
        "Movies/./Film.mp4",
        "Movies\\..\\..\\outside\\secret.mp4",
        "Movies/Film.mp4\x00.txt",
        "Movies/missing.mp4",
    ],
)
def test_resolve_rejects_escapes(settings: main.Settings, rel: str) -> None:
    with pytest.raises(main.NotFound):
        main.MediaLibrary(settings.media_root).resolve(rel)


def test_resolve_allows_symlinks_that_stay_inside(settings: main.Settings) -> None:
    library = main.MediaLibrary(settings.media_root)
    assert library.resolve("Movies/Alias.mp4") == settings.media_root / "Movies" / "Film.mp4"


@pytest.mark.parametrize(
    "path",
    [
        "/file/%2e%2e/outside/secret.mp4",
        "/file/Movies/%2e%2e%2f%2e%2e%2foutside%2fsecret.mp4",
        "/file/%2Fetc%2Fpasswd",
        "/file/Movies/escape.mp4",
        "/file/.secret.mp4",
        "/file/notes.txt",
        "/file/Movies/Film.srt",
        "/browse/%2e%2e",
        "/browse/Movies/escape-dir",
        "/thumb/Movies/escape.mp4",
        "/subtitle/%2e%2e/outside/secret.mp4",
        "/subtitle/Movies/Film.mp4",
        "/watch/Movies/escape.mp4",
    ],
)
def test_http_endpoints_404_on_escapes(client: TestClient, path: str) -> None:
    response = client.get(path)
    assert response.status_code == 404
    assert b"OUTSIDE" not in response.content


# --------------------------------------------------------------------------- browsing


def test_listing_order_filtering_and_escaping(client: TestClient) -> None:
    names = lambda html: re.findall(r'<li data-name="([^"]*)"', html)  # noqa: E731
    assert names(client.get("/").text) == ["Movies", "Photos", "Shows"]
    movies = client.get("/browse/Movies").text
    # Folders first; escaping symlinks, loops, subtitles and non-media are left out.
    assert names(movies) == ["Action", "&lt;img src=x onerror=alert(1)&gt;.mp4", "Alias.mp4", "Film.mp4"]
    assert "<img src=x" not in movies
    assert names(client.get("/browse/Shows").text) == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"]
    photos = client.get("/browse/Photos").text
    assert photos.count('loading="lazy"') == 3 and 'id="filter"' in photos and 'id="lightbox"' in photos


def test_every_response_has_security_headers(client: TestClient, anon: TestClient) -> None:
    responses = [anon.get("/"), anon.get("/login"), client.get("/"), client.get("/missing"), client.get("/file/Movies/Film.mp4")]
    for response in responses:
        assert response.headers["x-content-type-options"] == "nosniff"
        assert "default-src 'none'" in response.headers["content-security-policy"]


def test_csp_hashes_match_the_inline_script_and_style(client: TestClient) -> None:
    response = client.get("/")
    csp = response.headers["content-security-policy"]
    for tag in ("script", "style"):
        body = re.search(rf"<{tag}>(.*?)</{tag}>", response.text, re.S).group(1)
        digest = base64.b64encode(hashlib.sha256(body.encode()).digest()).decode()
        assert f"'sha256-{digest}'" in csp
    assert "unsafe-inline" not in csp


# --------------------------------------------------------------------------- range requests


@pytest.mark.parametrize(
    "header, first, last",
    [("bytes=0-99", 0, 99), ("bytes=1000-", 1000, len(VIDEO_BYTES) - 1), ("bytes=-500", len(VIDEO_BYTES) - 500, len(VIDEO_BYTES) - 1),
     ("bytes=100-99999999999", 100, len(VIDEO_BYTES) - 1), ("BYTES = 5-5", 5, 5)],
)
def test_range_206(client: TestClient, header: str, first: int, last: int) -> None:
    response = client.get("/file/Movies/Film.mp4", headers={"Range": header})
    assert response.status_code == 206
    assert response.headers["content-range"] == f"bytes {first}-{last}/{len(VIDEO_BYTES)}"
    assert response.headers["content-length"] == str(last - first + 1)
    assert response.headers["accept-ranges"] == "bytes"
    assert response.content == VIDEO_BYTES[first : last + 1]


@pytest.mark.parametrize(
    "header",
    ["bytes=102400-", "bytes=abc", "bytes=5-1", "items=0-1", "bytes=", "bytes=-", "bytes=--1", "bytes=+1-2", "bytes=²-³", "bytes=-0",
     "bytes 0-1", "bytes=0-1,2", "bytes=" + ",".join(["0-0"] * 17)],
)
def test_range_416(client: TestClient, header: str) -> None:
    response = client.get("/file/Movies/Film.mp4", headers={"Range": header.encode("latin-1")})
    assert response.status_code == 416
    assert response.headers["content-range"] == f"bytes */{len(VIDEO_BYTES)}"


def test_full_file_head_and_validators(client: TestClient) -> None:
    full = client.get("/file/Movies/Film.mp4")
    assert full.status_code == 200 and full.content == VIDEO_BYTES
    assert full.headers["accept-ranges"] == "bytes" and full.headers["content-type"] == "video/mp4"
    head = client.head("/file/Movies/Film.mp4", headers={"Range": "bytes=0-9"})
    assert head.status_code == 206 and head.headers["content-length"] == "10" and head.content == b""
    etag = full.headers["etag"]
    assert client.get("/file/Movies/Film.mp4", headers={"If-None-Match": etag}).status_code == 304
    assert client.get("/file/Movies/Film.mp4", headers={"Range": "bytes=0-9", "If-Range": etag}).status_code == 206
    stale = client.get("/file/Movies/Film.mp4", headers={"Range": "bytes=0-9", "If-Range": '"old"'})
    assert stale.status_code == 200 and len(stale.content) == len(VIDEO_BYTES)


def test_multiple_ranges_are_multipart(client: TestClient) -> None:
    response = client.get("/file/Movies/Film.mp4", headers={"Range": "bytes=0-9, 200-209"})
    assert response.status_code == 206
    assert response.headers["content-type"].startswith("multipart/byteranges; boundary=")
    assert int(response.headers["content-length"]) == len(response.content)
    assert b"Content-Range: bytes 0-9/102400\r\n\r\n" + VIDEO_BYTES[0:10] in response.content
    assert b"Content-Range: bytes 200-209/102400\r\n\r\n" + VIDEO_BYTES[200:210] in response.content


def test_range_parser_merges_overlaps_and_keeps_request_order() -> None:
    assert main.parse_range_header("bytes=50-60,0-10", 100) == [(50, 60), (0, 10)]
    assert main.parse_range_header("bytes=0-50,40-60", 100) == [(0, 60)]
    assert main.parse_range_header("bytes=500-,0-1", 100) == [(0, 1)]  # unsatisfiable parts are dropped
    with pytest.raises(main.RangeNotSatisfiable):  # int() would happily accept these digits
        main.parse_range_header("bytes=\u0661-\u0662", 100)


def _sparse_file(tmp_path: Path, size: int) -> Path:
    path = tmp_path / "huge.mkv"
    with open(path, "wb") as fh:
        fh.truncate(size)
    return path


def test_streams_in_bounded_chunks(tmp_path: Path) -> None:
    path = _sparse_file(tmp_path, 3 * main.STREAM_CHUNK_SIZE + 5)
    response = main.FileStreamResponse(path, [(0, path.stat().st_size)], status_code=200, headers={}, media_type="video/x-matroska")
    chunks: list[int] = []

    async def receive() -> dict:
        await anyio.sleep_forever()

    async def send(message: dict) -> None:
        if message["type"] == "http.response.body":
            chunks.append(len(message["body"]))

    anyio.run(response, {"type": "http", "method": "GET"}, receive, send)
    assert max(chunks) <= main.STREAM_CHUNK_SIZE
    assert sum(chunks) == path.stat().st_size


def test_streaming_stops_when_the_client_disconnects(tmp_path: Path) -> None:
    """Seeking aborts the browser's range request; the server must stop reading."""
    path = _sparse_file(tmp_path, 4 * 1024**3)
    response = main.FileStreamResponse(path, [(0, path.stat().st_size)], status_code=200, headers={}, media_type="video/x-matroska")
    sent: list[int] = []
    gone = anyio.Event()

    async def receive() -> dict:
        await gone.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:  # like Uvicorn: silently accepts sends after a disconnect
        if message["type"] == "http.response.body":
            sent.append(len(message["body"]))
            if len(sent) == 3:
                gone.set()
        await anyio.sleep(0)

    anyio.run(response, {"type": "http", "method": "GET"}, receive, send)
    assert sum(sent) < 10 * main.STREAM_CHUNK_SIZE


# --------------------------------------------------------------------------- subtitles


def test_player_page_attaches_subtitles_preferring_vtt(client: TestClient) -> None:
    page = client.get("/watch/Movies/Film.mp4").text
    assert '<video id="player" controls preload="metadata"' in page
    tracks = re.findall(r'<track kind="subtitles" src="([^"]+)"', page)
    assert tracks == ["/subtitle/Movies/Film.srt", "/subtitle/Movies/Film.en.vtt"]


def test_srt_is_converted_to_webvtt(client: TestClient) -> None:
    response = client.get("/subtitle/Movies/Film.srt")
    assert response.headers["content-type"] == "text/vtt; charset=utf-8"
    assert response.text == "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500\nHello &amp; <i>bye</i>\n"


def test_srt_conversion_edge_cases() -> None:
    srt = "1\r\n0:00:05,5 --> 00:00:08,000 X1:1\r\n{\\an8}<font color=red>I <3 you</font>\r\n".encode("cp1252")
    assert main.srt_to_vtt(srt) == "WEBVTT\n\n1\n00:00:05.500 --> 00:00:08.000\nI &lt;3 you\n"
    assert "Français" in main.srt_to_vtt("1\n00:00:01,000 --> 00:00:02,000\nFrançais\n".encode("cp1252"))


# --------------------------------------------------------------------------- thumbnails


def _snapshot(root: Path) -> set[str]:
    return {str(p.relative_to(root)) for p in root.rglob("*")}


def test_image_thumbnails_are_downscaled_and_cached_outside_media_root(client: TestClient, settings: main.Settings) -> None:
    before = _snapshot(settings.media_root)
    jpeg = client.get("/thumb/Photos/big.jpg")
    assert jpeg.headers["content-type"] == "image/jpeg"
    with Image.open(io.BytesIO(jpeg.content)) as im:
        assert max(im.size) == main.THUMB_EDGE
    assert client.get("/thumb/Photos/clear.png").headers["content-type"] == "image/png"
    broken = client.get("/thumb/Photos/broken.jpg")
    assert broken.status_code == 200 and broken.headers["content-type"] == "image/svg+xml"
    cached = [p.suffix for p in settings.thumb_dir.rglob("*") if p.is_file()]
    assert sorted(cached) == [".failed", ".jpg", ".png"]
    assert _snapshot(settings.media_root) == before


def test_video_without_ffmpeg_gets_an_icon(client: TestClient) -> None:
    response = client.get("/thumb/Movies/Film.mp4")
    assert response.status_code == 200 and response.headers["content-type"] == "image/svg+xml"
    assert "/thumb/Movies/Film.mp4" not in client.get("/browse/Movies").text  # no <img> to fail


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="ffmpeg not installed")
def test_video_thumbnail_with_ffmpeg(settings: main.Settings, tmp_path: Path) -> None:
    video = settings.media_root / "Movies" / "real.mp4"
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=10", "-t", "3", "-pix_fmt", "yuv420p", str(video)],
        check=True,
    )
    with_ffmpeg = main.Settings(**{**settings.__dict__, "ffmpeg": shutil.which("ffmpeg"), "ffprobe": shutil.which("ffprobe")})
    client = make_client(with_ffmpeg)
    response = client.get("/thumb/Movies/real.mp4")
    assert response.headers["content-type"] == "image/jpeg"
    with Image.open(io.BytesIO(response.content)) as im:
        assert im.size == (480, 270)
