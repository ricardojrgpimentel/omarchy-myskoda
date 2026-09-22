#!/usr/bin/env python3
"""Local adversarial HTTP tests; no vehicle credentials or external network."""
import concurrent.futures
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
import unittest
import zlib

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("transfer", REPO / "bin/myskoda-transfer.py")
transfer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transfer)


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def png(width=256, raw=None, metadata=b""):
    if raw is None:
        raw = b"\0" * (256 * (1 + 256 * 3))
    return (transfer.PNG_SIGNATURE
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, 256, 8, 2, 0, 0, 0))
            + metadata + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


GOOD_PNG = png()
GOOD_BODY = (REPO / "tests/public-api-ev.json").read_bytes()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.close_connection = True
        route = self.path.split("?")[0].split("/")[1]
        self.send_response(200)
        if route == "headers":
            for _ in range(12):
                self.send_header("X-Fill", "x" * 8192)
        body = {
            "vehicle": GOOD_BODY,
            "tile": GOOD_PNG,
            "invalid-json": b"{broken",
            "invalid-tile": b"<html>not a PNG</html>",
            "dimensions": png(width=100000),
            "bomb": png(raw=b"\0" * (2 * 1024 * 1024)),
            "truncated": GOOD_PNG[:-6],
            "metadata": png(metadata=chunk(b"zTXt", b"comment\0\0" + zlib.compress(b"x" * 2000000))),
            "headers": GOOD_BODY,
        }.get(route, b"x" * (4 * 1024 * 1024))
        # Exercise both chunked and EOF-delimited responses without Content-Length.
        chunked = route != "eof"
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        try:
            for offset in range(0, len(body), 4096):
                part = body[offset:offset + 4096]
                if chunked:
                    self.wfile.write(f"{len(part):x}\r\n".encode() + part + b"\r\n")
                else:
                    self.wfile.write(part)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


class TransferTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("MYSKODA_")}
        self.env.update(XDG_CACHE_HOME=str(self.root / "cache"), XDG_CONFIG_HOME=str(self.root / "config"),
                        MYSKODA_API_KEY="test-key", MYSKODA_VIN="TMBJB9NY5RF999999", NO_PROXY="127.0.0.1")

    def helper(self, *args, route=None):
        env = dict(self.env)
        if route:
            env["MYSKODA_API_BASE"] = f"{self.base}/{route}"
        result = subprocess.run([str(REPO / "bin/myskoda"), *args], env=env,
                                capture_output=True, text=True, timeout=30, check=True)
        return json.loads(result.stdout)

    def transfer_tile(self, route, x=0):
        cache = self.root / "direct-cache"
        result = subprocess.run(["python3", str(REPO / "bin/myskoda-transfer.py"), "tile", str(cache),
                                 f"{self.base}/{route}/{{z}}/{{x}}/{{y}}", "4", str(x), "0"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        return result, cache

    def test_valid_vehicle_and_stale_fallback(self):
        self.assertTrue(self.helper("car", route="vehicle")["ok"])
        for route in ("oversized", "eof", "headers", "invalid-json"):
            with self.subTest(route=route):
                reading = self.helper("car", route=route)
                self.assertTrue(reading["stale"])
                self.assertEqual(reading["vin"], "TMBJB9NY5RF999999")
                self.assertFalse(list((self.root / "cache").rglob("read.*")))

    def test_rejected_vehicle_leaves_no_response_files(self):
        for route in ("oversized", "eof", "headers", "invalid-json"):
            with self.subTest(route=route):
                self.assertFalse(self.helper("car", route=route)["ok"])
                self.assertFalse(list((self.root / "cache").rglob("*.json")))
                self.assertFalse(list((self.root / "cache").rglob("read.*")))

    def test_limits_exact_boundary_and_no_content_length(self):
        for route in ("oversized", "eof"):
            with self.subTest(route=route), self.assertRaises(ValueError):
                transfer.download(f"{self.base}/{route}", 1024, 5)
        body, _, status = transfer.download(f"{self.base}/tile", len(GOOD_PNG), 5)
        self.assertEqual((body, status), (GOOD_PNG, "200"))
        with self.assertRaises(ValueError):
            transfer.download(f"{self.base}/tile", len(GOOD_PNG) - 1, 5)

    def test_invalid_tiles_never_cached(self):
        for route in ("oversized", "eof", "headers", "invalid-tile", "dimensions", "bomb", "truncated"):
            with self.subTest(route=route):
                result, cache = self.transfer_tile(route)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list(cache.rglob("*.png")))
                self.assertFalse(list(cache.rglob("*.part")))

    def test_optional_compressed_metadata_removed(self):
        result, _ = self.transfer_tile("metadata")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()).read_bytes(), GOOD_PNG)

    def test_corrupt_cached_tile_is_replaced(self):
        result, _ = self.transfer_tile("tile")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        path.write_bytes(b"not a PNG")
        result, _ = self.transfer_tile("tile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), GOOD_PNG)
        path.write_bytes(b"x" * (transfer.TILE_LIMIT + 1))
        result, _ = self.transfer_tile("tile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), GOOD_PNG)

    def test_cache_quota_eviction_and_concurrent_writers(self):
        tiles = self.root / "direct-cache/tiles/old"
        tiles.mkdir(parents=True)
        for index in range(70):
            path = tiles / f"{index}.png"
            path.write_bytes(b"x" * transfer.TILE_LIMIT)
            os.utime(path, (index + 1, index + 1))
        (tiles / "abandoned.part").write_bytes(b"incomplete")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda x: self.transfer_tile("tile", x), range(4)))
        for result, cache in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(result.stdout.strip()).read_bytes(), GOOD_PNG)
        files = list((cache / "tiles").rglob("*.png"))
        self.assertLessEqual(sum(path.stat().st_size for path in files), transfer.CACHE_LIMIT)
        self.assertFalse((tiles / "0.png").exists())
        self.assertTrue((tiles / "69.png").exists())
        self.assertFalse(list(cache.rglob("*.part")))

    def test_cache_entry_limit(self):
        root = self.root / "tiles"
        root.mkdir()
        for index in range(transfer.CACHE_ENTRIES + 3):
            (root / f"{index}.png").write_bytes(b"x")
        transfer.prune_cache(root, reserve=100, entries=1)
        self.assertEqual(len(list(root.iterdir())), transfer.CACHE_ENTRIES - 1)

    def test_png_crc_and_filters(self):
        corrupt = bytearray(GOOD_PNG)
        corrupt[-1] ^= 1
        for data in (bytes(corrupt), png(raw=b"\x05" * (256 * 769)), GOOD_PNG + b"trailing"):
            with self.assertRaises(ValueError):
                transfer.validate_png(data)

    def test_map_and_argument_bounds(self):
        plan = self.helper("--tile-url", f"{self.base}/tile/{{z}}/{{x}}/{{y}}", "map", "38", "-9", "16", "380", "240")
        self.assertTrue(plan["ok"])
        self.assertTrue(plan["tiles"])
        for tile in plan["tiles"]:
            self.assertEqual(Path(tile["path"]).read_bytes(), GOOD_PNG)
        self.assertFalse(self.helper("map", "38", "-9", "16", "999999", "240")["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
