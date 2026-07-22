#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PROJECT = REPOSITORY_ROOT / "CurlSafariServer.xcodeproj"


class CurlSafariServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = Path(
            tempfile.mkdtemp(prefix="curl-safari-tests-", dir="/private/tmp")
        )
        cls.products = cls.temporary_directory / "products"
        cls.derived_data = cls.temporary_directory / "derived-data"
        cls.socket_path = cls.temporary_directory / "server.sock"
        subprocess.run(
            [
                "xcodebuild",
                "-quiet",
                "-project",
                str(PROJECT),
                "-scheme",
                "CurlSafariServer",
                "-configuration",
                "Debug",
                "-derivedDataPath",
                str(cls.derived_data),
                "-destination",
                "platform=macOS",
                f"CONFIGURATION_BUILD_DIR={cls.products}",
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            cwd=REPOSITORY_ROOT,
            check=True,
        )

        cls.binary = (
            cls.products
            / "CurlSafariServer.app/Contents/MacOS/curl-safari-server"
        )

        cls.environment = os.environ.copy()
        cls.environment.update(
            {
                "CURL_SAFARI_SOCKET_PATH": str(cls.socket_path),
                "CURL_SAFARI_CLIENT_TIMEOUT_SECONDS": "1",
            }
        )
        cls.server = subprocess.Popen(
            [str(cls.binary)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=cls.environment,
        )
        deadline = time.monotonic() + 5
        while not cls.socket_path.exists() and time.monotonic() < deadline:
            if cls.server.poll() is not None:
                stdout, stderr = cls.server.communicate()
                raise RuntimeError(f"server exited early: {stdout}\n{stderr}")
            time.sleep(0.02)
        if not cls.socket_path.exists():
            raise RuntimeError("server did not create its socket")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.terminate()
        try:
            cls.server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait(timeout=3)
        shutil.rmtree(cls.temporary_directory)

    @classmethod
    def request(cls, payload: dict[str, object]) -> dict[str, object]:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(str(cls.socket_path))
            client.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
            response = bytearray()
            while b"\n" not in response:
                chunk = client.recv(65_536)
                if not chunk:
                    break
                response.extend(chunk)
        return json.loads(bytes(response).partition(b"\n")[0])

    def test_socket_is_private(self) -> None:
        socket_stat = self.socket_path.stat()
        self.assertTrue(stat.S_ISSOCK(socket_stat.st_mode))
        self.assertEqual(stat.S_IMODE(socket_stat.st_mode), 0o600)

    def test_ping_uses_newline_delimited_json(self) -> None:
        response = self.request({"op": "ping"})
        self.assertTrue(response["ok"])
        self.assertEqual(response["socket"], str(self.socket_path))
        self.assertIsInstance(response["server_pid"], int)

    def test_fetch_requires_domain(self) -> None:
        response = self.request({"op": "fetch"})
        self.assertFalse(response["ok"])
        self.assertIn("fetch requires domain", response["error"])

    def test_unknown_operation_is_rejected(self) -> None:
        response = self.request({"op": "delete_everything"})
        self.assertFalse(response["ok"])
        self.assertIn("unsupported operation", response["error"])

    def test_server_refuses_to_replace_regular_file(self) -> None:
        blocked_path = self.temporary_directory / "not-a-socket"
        blocked_path.write_text("keep me", encoding="utf-8")
        environment = self.environment | {
            "CURL_SAFARI_SOCKET_PATH": str(blocked_path),
        }
        completed = subprocess.run(
            [str(self.binary)],
            capture_output=True,
            text=True,
            env=environment,
            timeout=3,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("refusing to remove non-socket path", completed.stderr)
        self.assertEqual(blocked_path.read_text(encoding="utf-8"), "keep me")


if __name__ == "__main__":
    unittest.main()
