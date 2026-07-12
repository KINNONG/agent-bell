import importlib.util
import json
import socket
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "plugins" / "agent-bell" / "voice-pack" / "server.py"
SPEC = importlib.util.spec_from_file_location("agent_bell_voice_server", SERVER_PATH)
SERVER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SERVER)


class FakeVoiceService:
    voice_ids = ("default",)

    def __init__(self) -> None:
        self.calls = []

    def synthesize(self, text: str, voice_id: str) -> bytes:
        if voice_id != "default":
            raise KeyError(voice_id)
        self.calls.append((text, voice_id))
        return b"RIFF" + (36).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(
            4, "little"
        ) + b"\x01\x00\x01\x00\xc0\x5d\x00\x00\x80\xbb\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00"


class VoicePackHttpContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.service = FakeVoiceService()
        SERVER.VoiceRequestHandler.service = cls.service
        cls.httpd = SERVER.LocalVoiceHTTPServer(
            ("127.0.0.1", 0), SERVER.VoiceRequestHandler
        )
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.httpd.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=2)

    def request_json(self, path: str, payload: dict) -> urllib.request.Request:
        return urllib.request.Request(
            self.base_url + path,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

    def test_health_does_not_expose_private_voice_data(self) -> None:
        with urllib.request.urlopen(self.base_url + "/health", timeout=2) as response:
            payload = json.load(response)
        self.assertEqual(payload["status"], "ready")
        self.assertEqual(payload["voices"], ["default"])
        self.assertNotIn("path", payload)
        self.assertNotIn("reference_text", payload)

    def test_synthesize_returns_wav_and_normalizes_whitespace(self) -> None:
        request = self.request_json(
            "/synthesize", {"text": "  Agent   Bell  ", "voice_id": "default"}
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            body = response.read()
            content_type = response.headers.get_content_type()
        self.assertEqual(content_type, "audio/wav")
        self.assertTrue(body.startswith(b"RIFF"))
        self.assertEqual(self.service.calls[-1], ("Agent Bell", "default"))

    def test_rejects_unknown_fields_before_synthesis(self) -> None:
        before = len(self.service.calls)
        request = self.request_json(
            "/synthesize",
            {"text": "hello", "voice_id": "default", "private": "no"},
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=2)
        self.assertEqual(caught.exception.code, 400)
        self.assertEqual(len(self.service.calls), before)

    def test_unknown_voice_returns_not_found(self) -> None:
        request = self.request_json(
            "/synthesize", {"text": "hello", "voice_id": "missing"}
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=2)
        self.assertEqual(caught.exception.code, 404)

    def test_partial_request_body_has_a_total_deadline(self) -> None:
        original_timeout = SERVER.REQUEST_BODY_TIMEOUT_SECONDS
        SERVER.REQUEST_BODY_TIMEOUT_SECONDS = 0.2
        try:
            with socket.create_connection(("127.0.0.1", self.httpd.server_port), timeout=2) as client:
                client.settimeout(2)
                client.sendall(
                    b"POST /synthesize HTTP/1.1\r\n"
                    b"Host: 127.0.0.1\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: 100\r\n\r\n{"
                )
                response = client.recv(4096)
            self.assertIn(b" 400 ", response)
        finally:
            SERVER.REQUEST_BODY_TIMEOUT_SECONDS = original_timeout


if __name__ == "__main__":
    unittest.main()
