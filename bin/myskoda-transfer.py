#!/usr/bin/env python3
"""Bound untrusted HTTP input before it reaches disk, jq, or Qt."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import sys
import time
import zlib

BODY_LIMIT = 1024 * 1024
HEADER_LIMIT = 64 * 1024
TILE_LIMIT = 512 * 1024
CACHE_LIMIT = 32 * 1024 * 1024
CACHE_ENTRIES = 2048
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def bounded_file(path, limit):
    with open(path, "rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file exceeds byte limit")
    return data


def download(url, limit, timeout, vehicle=False):
    """Drain separate curl pipes with hard cumulative limits, including chunked HTTP."""
    header_read, header_write = os.pipe()
    process = None
    buffers = {"body": bytearray(), "headers": bytearray()}
    deadline = time.monotonic() + timeout + 2
    try:
        command = ["curl", "-q", "-sS", "--max-time", str(timeout),
                   "--proto", "=http,https", "--dump-header", f"/dev/fd/{header_write}",
                   "--output", "-"]
        if vehicle:
            command += ["--header", "@-", "--header", "Accept: application/json"]
        else:
            command += ["--fail", "--user-agent", "omarchy-myskoda/0.2 (read-only desktop widget)"]
        command += ["--url", url]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=None if vehicle else subprocess.DEVNULL,
                                   pass_fds=(header_write,))
        os.close(header_write)
        header_write = None
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "body")
            selector.register(header_read, selectors.EVENT_READ, "headers")
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("download timed out")
                for key, _ in selector.select(min(remaining, 0.5)):
                    chunk = os.read(key.fd, 16384)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    target = buffers[key.data]
                    ceiling = limit if key.data == "body" else HEADER_LIMIT
                    if len(target) + len(chunk) > ceiling:
                        raise ValueError("response exceeds byte limit")
                    target.extend(chunk)
        if process.wait(timeout=max(0.1, deadline - time.monotonic())) != 0:
            raise ValueError("download failed")
        statuses = re.findall(rb"^HTTP/\S+ ([0-9]{3})(?:[ \r]|$)", buffers["headers"], re.M)
        if not statuses:
            raise ValueError("missing HTTP status")
        return bytes(buffers["body"]), bytes(buffers["headers"]), statuses[-1].decode("ascii")
    finally:
        if header_write is not None:
            os.close(header_write)
        os.close(header_read)
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()


def validate_json(data):
    # Limit input before invoking any JSON parser, including this one.
    if len(data) > BODY_LIMIT or not isinstance(json.loads(data), dict):
        raise ValueError("expected a JSON object")


def vehicle(url, body_path, headers_path):
    body_path, headers_path = Path(body_path), Path(headers_path)
    try:
        fixture = os.environ.get("MYSKODA_API_FIXTURE")
        if fixture:
            body = bounded_file(fixture, BODY_LIMIT)
            header_fixture = os.environ.get("MYSKODA_API_HEADERS_FIXTURE")
            headers = bounded_file(header_fixture, HEADER_LIMIT) if header_fixture else b""
            status = os.environ.get("MYSKODA_API_STATUS", "200")
        else:
            body, headers, status = download(url, BODY_LIMIT, 45, vehicle=True)
        # Error responses may be empty, but nonempty responses must be valid JSON.
        if body or status == "200":
            validate_json(body)
        body_path.write_bytes(body)
        headers_path.write_bytes(headers)
        print(status)
    except Exception:
        body_path.unlink(missing_ok=True)
        headers_path.unlink(missing_ok=True)
        raise


def validate_png(data):
    """Validate bounded, noninterlaced 256px PNG; drop optional metadata before Qt."""
    if len(data) > TILE_LIMIT or not data.startswith(PNG_SIGNATURE):
        raise ValueError("invalid PNG")
    offset = 8
    chunks = []
    compressed = bytearray()
    seen = []
    palette_entries = 0
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("truncated PNG")
        size, kind = struct.unpack_from(">I4s", data, offset)
        end = offset + 12 + size
        if end > len(data):
            raise ValueError("truncated PNG chunk")
        payload = data[offset + 8:end - 4]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("invalid PNG checksum")
        if not seen and kind != b"IHDR":
            raise ValueError("missing PNG header")
        if kind == b"IHDR":
            if seen or size != 13:
                raise ValueError("invalid PNG header")
            width, height, depth, color, method, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            if (width, height) != (256, 256) or depth not in depths.get(color, ()) or any((method, filtering, interlace)):
                raise ValueError("unsupported PNG dimensions or format")
            channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
            stride = (width * channels * depth + 7) // 8 + 1
        elif kind == b"PLTE":
            if kind in seen or b"IDAT" in seen or color in (0, 4) or not size or size % 3 or size > 768:
                raise ValueError("invalid PNG palette")
            palette_entries = size // 3
            if color == 3 and palette_entries > 2 ** depth:
                raise ValueError("invalid PNG palette depth")
        elif kind == b"tRNS":
            if kind in seen or b"IDAT" in seen or not (
                (color == 0 and size == 2) or (color == 2 and size == 6)
                or (color == 3 and 0 < size <= palette_entries)
            ):
                raise ValueError("invalid PNG transparency")
        elif kind == b"IDAT":
            if (b"IDAT" in seen and seen[-1] != b"IDAT") or (color == 3 and not palette_entries):
                raise ValueError("invalid PNG image chunks")
            compressed.extend(payload)
        elif kind == b"IEND":
            if size or b"IDAT" not in seen or end != len(data):
                raise ValueError("invalid PNG end")
        elif not re.fullmatch(rb"[A-Za-z]{4}", kind) or not kind[0] & 32:
            raise ValueError("unknown PNG critical chunk")
        # Optional metadata (including compressed profiles/text and animation) never reaches Qt.
        if kind in (b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND"):
            chunks.append(data[offset:end])
        seen.append(kind)
        offset = end
    if not seen or seen[-1] != b"IEND":
        raise ValueError("missing PNG end")
    expected = height * stride
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed, expected + 1)
    if len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("invalid or oversized PNG pixel data")
    if any(pixels[row * stride] > 4 for row in range(height)):
        raise ValueError("invalid PNG row filter")
    return PNG_SIGNATURE + b"".join(chunks)


def prune_cache(root, reserve=0, entries=0):
    files = []
    for directory, _, names in os.walk(root, topdown=False):
        for name in names:
            path = Path(directory) / name
            if path.is_symlink() or path.suffix != ".png":
                path.unlink(missing_ok=True)
            else:
                stat = path.stat()
                if stat.st_size > TILE_LIMIT or stat.st_size == 0:
                    path.unlink()
                else:
                    files.append((stat.st_mtime_ns, path, stat.st_size))
        if Path(directory) != root:
            with contextlib.suppress(OSError):
                Path(directory).rmdir()
    total = sum(item[2] for item in files)
    count = len(files)
    for _, path, size in sorted(files):
        if total + reserve <= CACHE_LIMIT and count + entries <= CACHE_ENTRIES:
            break
        path.unlink()
        total -= size
        count -= 1


def tile(cache, template, z, x, y):
    z, x, y = int(z), int(x), int(y)
    if not (0 <= z <= 19 and 0 <= x < 2 ** z and 0 <= y < 2 ** z):
        raise ValueError("invalid tile coordinates")
    root = Path(cache) / "tiles"
    root.mkdir(parents=True, exist_ok=True)
    # Serialize lookup, eviction, and insertion across simultaneous widget processes.
    with open(Path(cache) / "tiles.lock", "a") as lock:
        deadline = time.monotonic() + 25
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("tile cache busy")
                time.sleep(0.05)
        prune_cache(root)
        fingerprint = hashlib.sha256(template.encode()).hexdigest()[:10]
        path = root / fingerprint / str(z) / str(x) / f"{y}.png"
        if path.exists():
            try:
                data = validate_png(bounded_file(path, TILE_LIMIT))
            except (ValueError, OSError, zlib.error):
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(data)
                os.utime(path, None)
                print(path)
                return
        url = template.replace("{z}", str(z)).replace("{x}", str(x)).replace("{y}", str(y))
        body, _, status = download(url, TILE_LIMIT, 20)
        if status != "200":
            raise ValueError("unexpected tile status")
        data = validate_png(body)
        prune_cache(root, reserve=len(data), entries=1)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".part")
        try:
            temporary.write_bytes(data)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
        print(path)


def main():
    os.umask(0o077)
    command, *args = sys.argv[1:]
    if command == "vehicle":
        vehicle(*args)
    elif command == "tile":
        tile(*args)
    elif command == "json":
        validate_json(bounded_file(args[0], BODY_LIMIT))
    else:
        raise ValueError("unknown transfer command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RecursionError, zlib.error, subprocess.SubprocessError):
        print("Response rejected or transfer failed.", file=sys.stderr)
        sys.exit(1)
