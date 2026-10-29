#!/usr/bin/env python3
"""Exercise the production Swift cookie code with generated binary fixtures."""
from __future__ import annotations

import json
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC_EPOCH = 978_307_200


def cookie_record(domain="example.test", name="session", path="/", value="synthetic",
                  flags=0, expires=0, created=100):
    record = bytearray(56)
    struct.pack_into("<I", record, 8, flags)
    for offset, field in zip((16, 20, 24, 28), (domain, name, path, value)):
        struct.pack_into("<I", record, offset, len(record))
        record.extend(field.encode() + b"\0")
    struct.pack_into("<I", record, 0, len(record))
    struct.pack_into("<dd", record, 40, expires, created)
    return bytes(record)


def cookie_file(*pages):
    encoded_pages = []
    for records in pages:
        page = bytearray(b"\x00\x00\x01\x00" + struct.pack("<I", len(records)))
        position = 12 + 4 * len(records)
        for record in records:
            page.extend(struct.pack("<I", position))
            position += len(record)
        page.extend(b"\0" * 4)
        page.extend(b"".join(records))
        encoded_pages.append(bytes(page))
    return (b"cook" + struct.pack(">I", len(pages))
            + b"".join(struct.pack(">I", len(page)) for page in encoded_pages)
            + b"".join(encoded_pages))


class CookieTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="curl-safari-cookie-tests-", dir="/private/tmp")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "cookie-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-module-cache-path",
            str(Path(cls.temp.name) / "module-cache"),
            str(ROOT / "CurlSafariServer/Cookies.swift"),
            str(ROOT / "tests/cookie_test_driver.swift"), "-o", str(cls.binary),
        ], check=True, capture_output=True, text=True)

    def inspect(self, data, domain="example.test", url="https://example.test/", scope="url",
                expect_error=False):
        with tempfile.NamedTemporaryFile(dir=self.temp.name) as file:
            file.write(data)
            file.flush()
            result = subprocess.run([str(self.binary), file.name, domain, url, scope],
                                    capture_output=True, text=True, timeout=5)
        if expect_error:
            self.assertEqual(result.returncode, 1, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_multiple_pages_and_cookie_fields(self):
        data = cookie_file([cookie_record(name="first", flags=5, expires=4_000_000_000)],
                           [cookie_record(name="second", value="", path="/account")])
        result = self.inspect(data)
        self.assertEqual(len(result["parsed"]), 2)
        first, second = result["parsed"]
        self.assertEqual(first, dict(domain="example.test", name="first", path="/",
                                    value="synthetic", secure=True, httpOnly=True,
                                    expiresAt=4_000_000_000 + MAC_EPOCH, createdAt=100 + MAC_EPOCH))
        self.assertEqual(second["value"], "")
        self.assertEqual(second["expiresAt"], 0)

    def test_exact_hosts_subdomains_and_suffix_boundaries(self):
        data = cookie_file([cookie_record(domain="example.test", name="host"),
                            cookie_record(domain=".example.test", name="domain")])
        for host, names in [("example.test", {"host", "domain"}),
                            ("sub.example.test", {"domain"}),
                            ("badexample.test", set()), ("example.test.attacker.test", set())]:
            with self.subTest(host=host):
                result = self.inspect(data, host, f"https://{host}/")
                self.assertEqual(set(result["selected"]), names)
        self.assertEqual(set(self.inspect(data, "EXAMPLE.TEST")["selected"]), {"host", "domain"})

    def test_path_boundaries_and_encoded_slashes(self):
        data = cookie_file([cookie_record(path="/account", name="account"),
                            cookie_record(path="/account/", name="slash"),
                            cookie_record(path="/", name="root")])
        for path, names in [("/", {"root"}), ("/account", {"root", "account"}),
                            ("/account/item", {"root", "account", "slash"}),
                            ("/accounting", {"root"}), ("/account%2Fitem", {"root"})]:
            with self.subTest(path=path):
                self.assertEqual(set(self.inspect(data, url="https://example.test"+path)["selected"]), names)

    def test_secure_cookies_and_expiration(self):
        past = time.time() - MAC_EPOCH - 60
        future = time.time() - MAC_EPOCH + 3600
        data = cookie_file([cookie_record(name="secure", flags=1),
                            cookie_record(name="session"), cookie_record(name="future", expires=future),
                            cookie_record(name="expired", expires=past)])
        self.assertEqual(set(self.inspect(data)["selected"]), {"secure", "session", "future"})
        self.assertEqual(set(self.inspect(data, url="http://example.test/")["selected"]), {"session", "future"})

    def test_host_scope_preserves_redirect_cookies_and_attributes(self):
        data = cookie_file([cookie_record(name="secure", path="/account", flags=5),
                            cookie_record(name="other", domain="other.test"),
                            cookie_record(name="expired", expires=1)])
        result = self.inspect(data, url="http://example.test/", scope="host")
        self.assertEqual(result["selected"], ["secure"])
        self.assertIn("#HttpOnly_example.test\tFALSE\t/account\tTRUE\t0\tsecure\tsynthetic\n", result["jar"])
        self.assertEqual(self.inspect(data, url="http://example.test/")["selected"], [])

    def test_cookie_jar_domain_flag_and_sorting(self):
        data = cookie_file([cookie_record(name="root", domain=".example.test"),
                            cookie_record(name="deep", domain=".example.test", path="/account")])
        result = self.inspect(data, scope="host")
        self.assertEqual(result["selected"], ["deep", "root"])
        self.assertIn(".example.test\tTRUE\t/account\tFALSE\t0\tdeep\tsynthetic\n", result["jar"])

    def test_invalid_headers_and_truncated_pages_are_errors(self):
        valid = cookie_file([cookie_record()])
        for data in (b"", b"invalid", b"cook\0\0\0\xff", valid[:10], valid[:-1]):
            with self.subTest(length=len(data)):
                self.inspect(data, expect_error=True)

    def test_invalid_record_offsets_sizes_and_strings_are_skipped(self):
        valid = cookie_record()
        malformed = []
        for offset, value in [(0, 1), (0, len(valid)+100), (16, 0), (20, 999999), (28, 40)]:
            record = bytearray(valid)
            struct.pack_into("<I", record, offset, value)
            malformed.append(bytes(record))
        malformed.append(valid[:-1] + b"x")  # Missing string terminator.
        for record in malformed:
            with self.subTest(record=record[:32].hex()):
                self.assertEqual(self.inspect(cookie_file([record]))["parsed"], [])
        data = bytearray(cookie_file([valid]))
        struct.pack_into("<I", data, 20, 999999)  # Page cookie offset.
        self.assertEqual(self.inspect(bytes(data))["parsed"], [])

    def test_invalid_dates_and_jar_delimiters_are_skipped(self):
        for record in (cookie_record(expires=float("nan")), cookie_record(expires=float("inf")),
                       cookie_record(expires=1e100), cookie_record(created=float("nan")),
                       cookie_record(value="injected\nrow"), cookie_record(name="bad\tname")):
            self.assertEqual(self.inspect(cookie_file([record]))["parsed"], [])

    def test_invalid_scope_or_request_target_is_rejected(self):
        data = cookie_file([cookie_record()])
        for domain, url, scope in [("example.test", "https://other.test/", "host"),
                                   ("example.test", "not a URL", "url"),
                                   ("example.test", "ftp://example.test/", "host"),
                                   ("example.test", "https://example.test/", "all")]:
            self.inspect(data, domain, url, scope, expect_error=True)


if __name__ == "__main__":
    unittest.main()
