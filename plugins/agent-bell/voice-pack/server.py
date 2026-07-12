"""Loopback-only Qwen3-TTS voice service for Agent Bell."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import queue
import re
import socket
import sys
import threading
import time
from collections import OrderedDict
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


SERVICE_NAME = "agent-bell-qwen-voice-pack"
PROTOCOL_VERSION = 1
CAPABILITIES = ("synthesize", "prewarm", "cached")
MODEL_ID = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
MODEL_REVISION = "5d83992436eae1d760afd27aff78a71d676296fc"
MODEL_DIRECTORY_NAME = "Qwen3-TTS-12Hz-0.6B-Base"
BIND_HOST = "127.0.0.1"
PORT = 17863

MAX_REQUEST_BYTES = 16 * 1024
REQUEST_BODY_TIMEOUT_SECONDS = 5.0
MAX_TEXT_CHARACTERS = 300
MAX_TEXT_BYTES = 2 * 1024
MAX_VOICE_ID_CHARACTERS = 64
MAX_REFERENCE_TEXT_CHARACTERS = 2_000
MAX_REFERENCE_TEXT_BYTES = 16 * 1024
MAX_REFERENCE_AUDIO_BYTES = 50 * 1024 * 1024
MAX_WAV_BYTES = 25 * 1024 * 1024
MAX_NEW_TOKENS = 1_024
MAX_VOICES = 16
MAX_CACHE_ENTRIES = 32
MAX_CACHE_BYTES = 64 * 1024 * 1024
CACHE_TTL_SECONDS = 2 * 60 * 60
CACHE_SWEEP_SECONDS = 60
MAX_PREWARM_QUEUE_ENTRIES = 8

VOICE_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
REFERENCE_AUDIO_EXTENSIONS = (".wav", ".mp3", ".flac", ".ogg")


class RequestRejected(Exception):
    """The HTTP request does not satisfy the service contract."""


class ServiceBusy(Exception):
    """The single GPU inference slot is already occupied."""


class ResponseTooLarge(Exception):
    """The generated audio exceeds the response limit."""


class WavMemoryCache:
    """A small process-local WAV cache that never persists synthesis data."""

    def __init__(
        self,
        *,
        max_entries: int,
        max_bytes: int,
        ttl_seconds: float,
        clock: Any = time.monotonic,
    ) -> None:
        self.max_entries = max_entries
        self.max_bytes = max_bytes
        self.ttl_seconds = ttl_seconds
        self._clock = clock
        self._entries: OrderedDict[str, tuple[float, bytes]] = OrderedDict()
        self._total_bytes = 0
        self._lock = threading.Lock()

    def get(self, key: str) -> bytes | None:
        now = self._clock()
        with self._lock:
            self._remove_expired(now)
            entry = self._entries.pop(key, None)
            if entry is None:
                return None
            expires_at, wav_bytes = entry
            self._entries[key] = (expires_at, wav_bytes)
            return wav_bytes

    def put(self, key: str, wav_bytes: bytes) -> bool:
        if not wav_bytes or len(wav_bytes) > self.max_bytes:
            return False

        now = self._clock()
        with self._lock:
            self._remove_expired(now)
            replaced = self._entries.pop(key, None)
            if replaced is not None:
                self._total_bytes -= len(replaced[1])
            self._entries[key] = (now + self.ttl_seconds, wav_bytes)
            self._total_bytes += len(wav_bytes)
            while (
                len(self._entries) > self.max_entries
                or self._total_bytes > self.max_bytes
            ):
                _oldest_key, (_expires_at, oldest_wav) = self._entries.popitem(
                    last=False
                )
                self._total_bytes -= len(oldest_wav)
            return key in self._entries

    def prune(self) -> None:
        with self._lock:
            self._remove_expired(self._clock())

    def clear(self) -> None:
        with self._lock:
            self._entries.clear()
            self._total_bytes = 0

    def _remove_expired(self, now: float) -> None:
        expired = [
            key
            for key, (expires_at, _wav_bytes) in self._entries.items()
            if expires_at <= now
        ]
        for key in expired:
            _expires_at, wav_bytes = self._entries.pop(key)
            self._total_bytes -= len(wav_bytes)


def configure_local_environment(install_root: Path, *, offline: bool) -> None:
    hf_home = install_root / "hf-home"
    hf_home.mkdir(parents=True, exist_ok=True)
    os.environ["HF_HOME"] = str(hf_home)
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    if offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    else:
        os.environ.pop("HF_HUB_OFFLINE", None)


def model_directory(install_root: Path) -> Path:
    return install_root / "models" / MODEL_DIRECTORY_NAME


def download_model(install_root: Path) -> None:
    configure_local_environment(install_root, offline=False)
    destination = model_directory(install_root)
    destination.mkdir(parents=True, exist_ok=True)

    from huggingface_hub import snapshot_download

    snapshot_download(repo_id=MODEL_ID, revision=MODEL_REVISION, local_dir=str(destination))
    required_files = (
        destination / "config.json",
        destination / "model.safetensors",
        destination / "speech_tokenizer" / "config.json",
    )
    if any(not item.is_file() for item in required_files):
        raise RuntimeError("The official Qwen3-TTS model download is incomplete.")


def prepare_voice(install_root: Path, voice_id: str) -> None:
    if not VOICE_ID_PATTERN.fullmatch(voice_id):
        raise RuntimeError("The voice ID is invalid.")
    voice_root = install_root / "voices"
    voice_directory = voice_root / voice_id
    ensure_path_is_inside(voice_directory, voice_root)
    reference_text_path = voice_directory / "reference.txt"
    audio_candidates = [
        voice_directory / f"reference{extension}"
        for extension in REFERENCE_AUDIO_EXTENSIONS
        if (voice_directory / f"reference{extension}").is_file()
    ]
    if not reference_text_path.is_file() or len(audio_candidates) != 1:
        raise RuntimeError("The voice reference is incomplete or ambiguous.")
    if reference_text_path.stat().st_size > MAX_REFERENCE_TEXT_BYTES:
        raise RuntimeError("The reference text file is too large.")

    source_audio = audio_candidates[0]
    ensure_path_is_inside(reference_text_path, voice_root)
    ensure_path_is_inside(source_audio, voice_root)
    if source_audio.stat().st_size <= 0 or source_audio.stat().st_size > MAX_REFERENCE_AUDIO_BYTES:
        raise RuntimeError("The reference audio size is invalid.")

    import librosa
    import numpy as np
    import soundfile as sf

    samples, _sample_rate = librosa.load(str(source_audio), sr=24_000, mono=True)
    duration_seconds = len(samples) / 24_000
    if not np.isfinite(samples).all() or duration_seconds < 1.0 or duration_seconds > 60.0:
        raise RuntimeError("Reference audio must contain 1 to 60 seconds of finite audio.")

    destination = voice_directory / "reference.wav"
    temporary = voice_directory / f".reference-{os.getpid()}.tmp.wav"
    try:
        sf.write(str(temporary), samples, 24_000, format="WAV", subtype="PCM_16")
        os.replace(temporary, destination)
        if source_audio != destination and source_audio.exists():
            source_audio.unlink()
    finally:
        if temporary.exists():
            temporary.unlink()


def ensure_path_is_inside(path: Path, root: Path) -> None:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise RuntimeError("A voice asset resolves outside the voice directory.") from exc


class VoiceService:
    def __init__(self, install_root: Path, requested_model: str | None = None) -> None:
        local_model = model_directory(install_root)
        if requested_model is None:
            model_source = str(local_model)
            offline = True
        elif requested_model == MODEL_ID:
            model_source = MODEL_ID
            offline = False
        else:
            requested_path = Path(requested_model).expanduser().resolve()
            if not requested_path.is_dir():
                raise RuntimeError("Model must be the official Hugging Face ID or an existing local directory.")
            model_source = str(requested_path)
            local_model = requested_path
            offline = True

        configure_local_environment(install_root, offline=offline)
        self.install_root = install_root
        self.voice_root = install_root / "voices"
        self.voice_root.mkdir(parents=True, exist_ok=True)
        self.generation_lock = threading.Lock()

        if offline and not (local_model / "config.json").is_file():
            raise RuntimeError("The local Qwen3-TTS model is not installed.")

        import torch
        from qwen_tts import Qwen3TTSModel

        if not torch.cuda.is_available():
            raise RuntimeError("A CUDA-capable PyTorch runtime is required.")
        if not torch.cuda.is_bf16_supported():
            raise RuntimeError("This Voice Pack requires a CUDA GPU with bfloat16 support.")

        torch.cuda.set_device(0)
        torch.set_grad_enabled(False)
        self._torch = torch
        model_options: dict[str, Any] = {
            "device_map": "cuda:0",
            "dtype": torch.bfloat16,
        }
        if model_source == MODEL_ID:
            model_options["revision"] = MODEL_REVISION
        self._model = Qwen3TTSModel.from_pretrained(
            model_source,
            **model_options,
        )
        self._prompts = self._load_voice_prompts()
        if not self._prompts:
            raise RuntimeError("No valid local voice is configured.")
        self._initialize_prewarm()

    @property
    def voice_ids(self) -> tuple[str, ...]:
        return tuple(sorted(self._prompts))

    def _load_voice_prompts(self) -> dict[str, Any]:
        prompts: dict[str, Any] = {}
        voice_directories = [
            item
            for item in sorted(self.voice_root.iterdir(), key=lambda candidate: candidate.name)
            if item.is_dir() and VOICE_ID_PATTERN.fullmatch(item.name)
        ]
        if len(voice_directories) > MAX_VOICES:
            raise RuntimeError(f"At most {MAX_VOICES} local voices can be loaded.")

        for voice_directory in voice_directories:

            ensure_path_is_inside(voice_directory, self.voice_root)
            reference_text_path = voice_directory / "reference.txt"
            audio_candidates = [
                voice_directory / f"reference{extension}"
                for extension in REFERENCE_AUDIO_EXTENSIONS
                if (voice_directory / f"reference{extension}").is_file()
            ]
            if not reference_text_path.is_file() or len(audio_candidates) != 1:
                raise RuntimeError(f"Voice '{voice_directory.name}' is incomplete or ambiguous.")

            reference_audio_path = audio_candidates[0]
            ensure_path_is_inside(reference_text_path, self.voice_root)
            ensure_path_is_inside(reference_audio_path, self.voice_root)
            if reference_text_path.stat().st_size > MAX_REFERENCE_TEXT_BYTES:
                raise RuntimeError(f"Voice '{voice_directory.name}' has an oversized reference text file.")
            if (
                reference_audio_path.stat().st_size <= 0
                or reference_audio_path.stat().st_size > MAX_REFERENCE_AUDIO_BYTES
            ):
                raise RuntimeError(f"Voice '{voice_directory.name}' has an invalid reference audio file.")

            reference_text = reference_text_path.read_text(encoding="utf-8-sig").strip()
            if not reference_text or len(reference_text) > MAX_REFERENCE_TEXT_CHARACTERS:
                raise RuntimeError(f"Voice '{voice_directory.name}' has invalid reference text.")

            with self._torch.inference_mode():
                prompts[voice_directory.name] = self._model.create_voice_clone_prompt(
                    ref_audio=str(reference_audio_path),
                    ref_text=reference_text,
                    x_vector_only_mode=False,
                )
        return prompts

    def _initialize_prewarm(self) -> None:
        self._cache = WavMemoryCache(
            max_entries=MAX_CACHE_ENTRIES,
            max_bytes=MAX_CACHE_BYTES,
            ttl_seconds=CACHE_TTL_SECONDS,
        )
        self._prewarm_queue: queue.Queue[tuple[str, str, str] | None] = queue.Queue(
            maxsize=MAX_PREWARM_QUEUE_ENTRIES
        )
        self._pending_prewarm: set[str] = set()
        self._pending_lock = threading.Lock()
        self._closing = threading.Event()
        self._prewarm_thread = threading.Thread(
            target=self._run_prewarm,
            name="AgentBellVoicePrewarm",
            daemon=True,
        )
        self._prewarm_thread.start()

    @staticmethod
    def _cache_key(text: str, voice_id: str) -> str:
        material = (voice_id + "\0" + text).encode("utf-8")
        return hashlib.sha256(material).hexdigest()

    def get_cached(self, text: str, voice_id: str) -> bytes | None:
        if voice_id not in self._prompts:
            raise KeyError(voice_id)
        if self._closing.is_set():
            raise ServiceBusy
        return self._cache.get(self._cache_key(text, voice_id))

    def prewarm(self, text: str, voice_id: str) -> str:
        if voice_id not in self._prompts:
            raise KeyError(voice_id)
        key = self._cache_key(text, voice_id)

        with self._pending_lock:
            if self._closing.is_set():
                raise ServiceBusy
            if self._cache.get(key) is not None:
                return "cached"
            if key in self._pending_prewarm:
                return "pending"
            try:
                self._prewarm_queue.put_nowait((key, text, voice_id))
            except queue.Full as exc:
                raise ServiceBusy from exc
            self._pending_prewarm.add(key)
        return "accepted"

    def _run_prewarm(self) -> None:
        while True:
            try:
                item = self._prewarm_queue.get(timeout=CACHE_SWEEP_SECONDS)
            except queue.Empty:
                self._cache.prune()
                if self._closing.is_set():
                    return
                continue
            if item is None:
                self._prewarm_queue.task_done()
                return
            key, text, voice_id = item
            try:
                self._synthesize_with_lock(text, voice_id, blocking=True)
            except Exception as exc:  # Never expose synthesis text in diagnostics.
                print(
                    f"[agent-bell-voice-pack] prewarm failed ({type(exc).__name__})",
                    file=sys.stderr,
                    flush=True,
                )
            finally:
                with self._pending_lock:
                    self._pending_prewarm.discard(key)
                self._prewarm_queue.task_done()
                # Do not retain the previous announcement while the worker is idle.
                item = None
                key = text = voice_id = ""

    def close(self) -> None:
        with self._pending_lock:
            self._closing.set()
            while True:
                try:
                    discarded = self._prewarm_queue.get_nowait()
                except queue.Empty:
                    break
                self._prewarm_queue.task_done()
                discarded = None
            self._pending_prewarm.clear()
            self._prewarm_queue.put_nowait(None)

        # Model generation cannot be cancelled safely. Wait for any in-flight
        # request, then clear all announcement audio before returning.
        self._prewarm_thread.join()
        self.generation_lock.acquire()
        try:
            self._cache.clear()
        finally:
            self.generation_lock.release()

    def synthesize(self, text: str, voice_id: str) -> bytes:
        return self._synthesize_with_lock(text, voice_id, blocking=False)

    def _synthesize_with_lock(
        self, text: str, voice_id: str, *, blocking: bool
    ) -> bytes:
        prompt = self._prompts.get(voice_id)
        if prompt is None:
            raise KeyError(voice_id)
        if self._closing.is_set():
            raise ServiceBusy
        key = self._cache_key(text, voice_id)
        wav_bytes = self._cache.get(key)
        if wav_bytes is not None:
            return wav_bytes
        if not self.generation_lock.acquire(blocking=blocking):
            raise ServiceBusy

        try:
            if self._closing.is_set():
                raise ServiceBusy
            wav_bytes = self._cache.get(key)
            if wav_bytes is None:
                wav_bytes = self._generate_uncached(text, prompt)
                self._cache.put(key, wav_bytes)
            return wav_bytes
        finally:
            self.generation_lock.release()

    def _generate_uncached(self, text: str, prompt: Any) -> bytes:
        with self._torch.inference_mode():
            waveforms, sample_rate = self._model.generate_voice_clone(
                text=text,
                language="Auto",
                voice_clone_prompt=prompt,
                non_streaming_mode=True,
                max_new_tokens=MAX_NEW_TOKENS,
            )
        if len(waveforms) != 1 or int(sample_rate) <= 0:
            raise RuntimeError("The model returned an invalid audio result.")

        import soundfile as sf

        output = io.BytesIO()
        sf.write(output, waveforms[0], int(sample_rate), format="WAV", subtype="PCM_16")
        wav_bytes = output.getvalue()
        if len(wav_bytes) < 44:
            raise RuntimeError("The model returned an empty WAV payload.")
        if len(wav_bytes) > MAX_WAV_BYTES:
            raise ResponseTooLarge
        return wav_bytes


class VoiceRequestHandler(BaseHTTPRequestHandler):
    service: VoiceService
    server_version = "AgentBellVoicePack"
    sys_version = ""

    def log_message(self, _format: str, *args: object) -> None:
        # Request logging is disabled so synthesis text never reaches logs.
        return

    def version_string(self) -> str:
        return self.server_version

    def _send_headers(self, status: HTTPStatus, content_type: str, content_length: int) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
        self._send_headers(status, "application/json; charset=utf-8", len(body))
        self.wfile.write(body)

    def _send_wav(self, body: bytes) -> None:
        self._send_headers(HTTPStatus.OK, "audio/wav", len(body))
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        target = urlsplit(self.path)
        if target.path != "/health" or target.query or target.fragment:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        self._send_json(
            HTTPStatus.OK,
            {
                "service": SERVICE_NAME,
                "status": "ready",
                "protocol_version": PROTOCOL_VERSION,
                "capabilities": list(CAPABILITIES),
                "model": MODEL_ID,
                "model_revision": MODEL_REVISION,
                "voices": list(self.service.voice_ids),
            },
        )

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        target = urlsplit(self.path)
        if (
            target.path not in ("/synthesize", "/prewarm", "/cached")
            or target.query
            or target.fragment
        ):
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return

        try:
            text, voice_id = self._read_synthesis_request()
            if target.path == "/prewarm":
                status = self.service.prewarm(text, voice_id)
                response_status = (
                    HTTPStatus.OK if status == "cached" else HTTPStatus.ACCEPTED
                )
                self._send_json(response_status, {"status": status})
                return
            if target.path == "/cached":
                wav_bytes = self.service.get_cached(text, voice_id)
                if wav_bytes is None:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "cache_miss"})
                    return
            else:
                wav_bytes = self.service.synthesize(text, voice_id)
        except RequestRejected:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
            return
        except KeyError:
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "voice_not_found"})
            return
        except ServiceBusy:
            self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "service_busy"})
            return
        except ResponseTooLarge:
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "response_too_large"})
            return
        except Exception as exc:  # Keep model errors and private text out of responses and logs.
            print(
                f"[agent-bell-voice-pack] request failed ({type(exc).__name__})",
                file=sys.stderr,
                flush=True,
            )
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "synthesis_failed"})
            return

        self._send_wav(wav_bytes)

    def _read_synthesis_request(self) -> tuple[str, str]:
        if self.headers.get("Transfer-Encoding"):
            raise RequestRejected
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise RequestRejected

        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise RequestRejected
        try:
            content_length = int(raw_length)
        except ValueError as exc:
            raise RequestRejected from exc
        if content_length <= 0 or content_length > MAX_REQUEST_BYTES:
            raise RequestRejected

        deadline = time.monotonic() + REQUEST_BODY_TIMEOUT_SECONDS
        body_parts: list[bytes] = []
        remaining = content_length
        try:
            while remaining > 0:
                remaining_seconds = deadline - time.monotonic()
                if remaining_seconds <= 0:
                    raise RequestRejected
                self.connection.settimeout(remaining_seconds)
                chunk = self.rfile.read1(min(remaining, 8 * 1024))
                if not chunk:
                    raise RequestRejected
                body_parts.append(chunk)
                remaining -= len(chunk)
        except (TimeoutError, socket.timeout) as exc:
            raise RequestRejected from exc
        finally:
            self.connection.settimeout(30.0)
        body = b"".join(body_parts)
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RequestRejected from exc
        if not isinstance(payload, dict) or set(payload) != {"text", "voice_id"}:
            raise RequestRejected

        text = payload.get("text")
        voice_id = payload.get("voice_id")
        if not isinstance(text, str) or not isinstance(voice_id, str):
            raise RequestRejected
        text = " ".join(text.split())
        if not text or len(text) > MAX_TEXT_CHARACTERS:
            raise RequestRejected
        if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
            raise RequestRejected
        if len(voice_id) > MAX_VOICE_ID_CHARACTERS or not VOICE_ID_PATTERN.fullmatch(voice_id):
            raise RequestRejected
        return text, voice_id


class LocalVoiceHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False
    request_queue_size = 8


def serve(install_root: Path, requested_model: str | None = None) -> None:
    server = LocalVoiceHTTPServer((BIND_HOST, PORT), VoiceRequestHandler)
    service: VoiceService | None = None
    actual_host, actual_port = server.server_address[:2]
    if actual_host != BIND_HOST or actual_port != PORT:
        server.server_close()
        raise RuntimeError("Refusing to serve on an unexpected address.")

    try:
        # Reserve the fixed loopback port before loading the model so duplicate
        # launches cannot consume GPU memory at the same time.
        service = VoiceService(install_root, requested_model=requested_model)
        VoiceRequestHandler.service = service
        print(
            f"[agent-bell-voice-pack] ready on http://{BIND_HOST}:{PORT} "
            f"with {len(service.voice_ids)} local voice(s)",
            flush=True,
        )
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if service is not None:
            service.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Agent Bell local Qwen3-TTS voice service")
    parser.add_argument("--install-root", required=True, help="Private Voice Pack installation directory")
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--download-model",
        action="store_true",
        help="Download the official model into the installation directory and exit",
    )
    action.add_argument(
        "--prepare-voice",
        action="store_true",
        help="Normalize one installed reference voice to a 24 kHz mono WAV and exit",
    )
    parser.add_argument("--voice-id", help="Voice ID used with --prepare-voice")
    parser.add_argument(
        "--model",
        help="Official Hugging Face model ID or local model directory; defaults to InstallRoot/models",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    install_root = Path(args.install_root).expanduser().resolve()
    install_root.mkdir(parents=True, exist_ok=True)
    if args.download_model:
        download_model(install_root)
        return 0
    if args.prepare_voice:
        if not args.voice_id:
            raise RuntimeError("--prepare-voice requires --voice-id.")
        prepare_voice(install_root, args.voice_id)
        return 0
    serve(install_root, requested_model=args.model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
