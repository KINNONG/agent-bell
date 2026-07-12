import importlib.util
import json
import socket
import threading
import time
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
        self.prewarm_calls = []
        self.cached_wavs = {}

    @staticmethod
    def wav_bytes() -> bytes:
        return (
            b"RIFF"
            + (36).to_bytes(4, "little")
            + b"WAVEfmt "
            + (16).to_bytes(4, "little")
            + b"\x01\x00\x01\x00\xc0\x5d\x00\x00\x80\xbb\x00\x00\x02\x00\x10\x00"
            + b"data\x00\x00\x00\x00"
        )

    def synthesize(self, text: str, voice_id: str) -> bytes:
        if voice_id != "default":
            raise KeyError(voice_id)
        self.calls.append((text, voice_id))
        return self.wav_bytes()

    def prewarm(self, text: str, voice_id: str) -> str:
        if voice_id != "default":
            raise KeyError(voice_id)
        self.prewarm_calls.append((text, voice_id))
        return "accepted"

    def get_cached(self, text: str, voice_id: str) -> bytes | None:
        if voice_id != "default":
            raise KeyError(voice_id)
        return self.cached_wavs.get((text, voice_id))


class ControlledVoiceService(SERVER.VoiceService):
    def __init__(self, *, block_generation: bool = False) -> None:
        self._prompts = {"default": object()}
        self.generation_lock = threading.Lock()
        self.calls = []
        self.generation_started = threading.Event()
        self.release_generation = threading.Event()
        if not block_generation:
            self.release_generation.set()
        self._initialize_prewarm()

    def _generate_uncached(self, text: str, prompt: object) -> bytes:
        self.calls.append((text, prompt))
        self.generation_started.set()
        if not self.release_generation.wait(timeout=2):
            raise TimeoutError("test generation was not released")
        return FakeVoiceService.wav_bytes()


class VoiceServiceCacheTests(unittest.TestCase):
    def wait_for_cached(
        self, service: ControlledVoiceService, text: str, timeout: float = 2
    ) -> bytes:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            wav_bytes = service.get_cached(text, "default")
            if wav_bytes is not None:
                return wav_bytes
            time.sleep(0.01)
        self.fail("prewarmed WAV did not reach the cache")

    def test_prewarm_returns_immediately_and_coalesces_duplicates(self) -> None:
        service = ControlledVoiceService(block_generation=True)
        try:
            started_at = time.monotonic()
            self.assertEqual(service.prewarm("private title", "default"), "accepted")
            self.assertLess(time.monotonic() - started_at, 0.2)
            self.assertTrue(service.generation_started.wait(timeout=1))
            self.assertEqual(service.prewarm("private title", "default"), "pending")
            self.assertIsNone(service.get_cached("private title", "default"))
            self.assertTrue(
                all(
                    len(key) == 64 and "private title" not in key
                    for key in service._pending_prewarm
                )
            )

            service.release_generation.set()
            self.assertTrue(
                self.wait_for_cached(service, "private title").startswith(b"RIFF")
            )
            self.assertEqual(service.prewarm("private title", "default"), "cached")
            self.assertEqual(len(service.calls), 1)
        finally:
            service.release_generation.set()
            service.close()

    def test_synthesize_reuses_the_in_memory_cache(self) -> None:
        service = ControlledVoiceService()
        try:
            first = service.synthesize("repeatable", "default")
            second = service.synthesize("repeatable", "default")
            self.assertEqual(first, second)
            self.assertEqual(len(service.calls), 1)
        finally:
            service.close()

    def test_prewarm_rejects_an_unknown_voice_without_generation(self) -> None:
        service = ControlledVoiceService()
        try:
            with self.assertRaises(KeyError):
                service.prewarm("hello", "missing")
            self.assertEqual(service.calls, [])
        finally:
            service.close()

    def test_close_drains_private_work_and_waits_for_active_generation(self) -> None:
        service = ControlledVoiceService(block_generation=True)
        closer = threading.Thread(target=service.close)
        try:
            self.assertEqual(service.prewarm("active title", "default"), "accepted")
            self.assertTrue(service.generation_started.wait(timeout=1))
            self.assertEqual(service.prewarm("queued title", "default"), "accepted")

            closer.start()
            self.assertTrue(service._closing.wait(timeout=1))
            self.assertTrue(closer.is_alive())
            service.release_generation.set()
            closer.join(timeout=2)

            self.assertFalse(closer.is_alive())
            self.assertEqual(len(service.calls), 1)
            self.assertTrue(service._prewarm_queue.empty())
            self.assertEqual(service._pending_prewarm, set())
            active_key = service._cache_key("active title", "default")
            self.assertIsNone(service._cache.get(active_key))
            with self.assertRaises(SERVER.ServiceBusy):
                service.prewarm("after close", "default")
            with self.assertRaises(SERVER.ServiceBusy):
                service.get_cached("after close", "default")
            with self.assertRaises(SERVER.ServiceBusy):
                service.synthesize("after close", "default")
        finally:
            service.release_generation.set()
            if closer.ident is not None:
                closer.join(timeout=2)
            elif not service._closing.is_set():
                service.close()

    def test_cache_is_lru_byte_bounded_and_expires(self) -> None:
        now = [100.0]
        cache = SERVER.WavMemoryCache(
            max_entries=2,
            max_bytes=100,
            ttl_seconds=10,
            clock=lambda: now[0],
        )
        self.assertTrue(cache.put("a", b"aa"))
        self.assertTrue(cache.put("b", b"bb"))
        self.assertEqual(cache.get("a"), b"aa")
        self.assertTrue(cache.put("c", b"cc"))
        self.assertIsNone(cache.get("b"))
        self.assertEqual(cache.get("a"), b"aa")
        self.assertEqual(cache.get("c"), b"cc")

        byte_bounded = SERVER.WavMemoryCache(
            max_entries=3,
            max_bytes=4,
            ttl_seconds=10,
            clock=lambda: now[0],
        )
        self.assertTrue(byte_bounded.put("a", b"aa"))
        self.assertTrue(byte_bounded.put("b", b"bb"))
        self.assertTrue(byte_bounded.put("c", b"cc"))
        self.assertIsNone(byte_bounded.get("a"))
        self.assertFalse(byte_bounded.put("oversized", b"12345"))

        now[0] += 11
        cache.prune()
        byte_bounded.prune()
        self.assertEqual(cache._entries, {})
        self.assertEqual(byte_bounded._entries, {})

        self.assertTrue(cache.put("clearable", b"aa"))
        cache.clear()
        self.assertEqual(cache._entries, {})
        self.assertEqual(cache._total_bytes, 0)


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
        self.assertEqual(payload["protocol_version"], 1)
        self.assertEqual(
            payload["capabilities"], ["synthesize", "prewarm", "cached"]
        )
        self.assertEqual(payload["voices"], ["default"])
        self.assertNotIn("path", payload)
        self.assertNotIn("reference_text", payload)

    def test_generation_has_a_bounded_notification_token_budget(self) -> None:
        self.assertEqual(SERVER.MAX_NEW_TOKENS, 1_024)

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

    def test_prewarm_returns_without_waiting_for_audio(self) -> None:
        before = len(self.service.prewarm_calls)
        request = self.request_json(
            "/prewarm", {"text": "  private   title  ", "voice_id": "default"}
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            payload = json.load(response)
        self.assertEqual(response.status, 202)
        self.assertEqual(payload, {"status": "accepted"})
        self.assertEqual(len(self.service.prewarm_calls), before + 1)
        self.assertEqual(self.service.prewarm_calls[-1], ("private title", "default"))

    def test_cached_returns_wav_or_a_quick_cache_miss(self) -> None:
        text = "cached title"
        request = self.request_json(
            "/cached", {"text": text, "voice_id": "default"}
        )
        before_synthesis = len(self.service.calls)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=2)
        self.assertEqual(caught.exception.code, 404)
        self.assertEqual(json.load(caught.exception), {"error": "cache_miss"})
        self.assertEqual(len(self.service.calls), before_synthesis)

        self.service.cached_wavs[(text, "default")] = self.service.wav_bytes()
        with urllib.request.urlopen(request, timeout=2) as response:
            body = response.read()
        self.assertEqual(response.headers.get_content_type(), "audio/wav")
        self.assertTrue(body.startswith(b"RIFF"))

    def test_rejects_unknown_fields_before_any_voice_operation(self) -> None:
        before_synthesis = len(self.service.calls)
        before_prewarm = len(self.service.prewarm_calls)
        for path in ("/synthesize", "/prewarm", "/cached"):
            with self.subTest(path=path):
                request = self.request_json(
                    path,
                    {"text": "hello", "voice_id": "default", "private": "no"},
                )
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request, timeout=2)
                self.assertEqual(caught.exception.code, 400)
        self.assertEqual(len(self.service.calls), before_synthesis)
        self.assertEqual(len(self.service.prewarm_calls), before_prewarm)

    def test_unknown_voice_returns_not_found_for_each_endpoint(self) -> None:
        for path in ("/synthesize", "/prewarm", "/cached"):
            with self.subTest(path=path):
                request = self.request_json(
                    path, {"text": "hello", "voice_id": "missing"}
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
