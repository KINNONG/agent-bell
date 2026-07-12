# Low-Latency Custom Voice Implementation Plan

> Implementation checklist for Agent Bell v0.1.3.

**Goal:** Make long Codex tasks announce with the existing custom voice almost immediately, while very short tasks play one prompt sound instead of waiting for synthesis.

**Architecture:** `UserPromptSubmit` launches a helper outside the main worker mutex. The helper immediately uses an existing real Codex title, or retries after seven seconds when a new title is not yet available, then asks the loopback Voice Pack to pre-generate the exact completion sentence into a bounded memory-only cache. `Stop` requests only cached audio; a miss, in-flight generation, or provider error plays the Windows informational sound immediately and never waits for or replays the full sentence.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4, Python 3.12, `ThreadingHTTPServer`, Qwen3-TTS, Windows `System.Media`.

---

### Task 1: Add the Voice Pack memory cache contract

**Files:**
- Modify: `plugins/agent-bell/voice-pack/server.py`
- Modify: `tests/test_voice_pack.py`

**Steps:**
1. Add failing tests for `/prewarm`, `/cached`, duplicate prewarm requests, misses, and cache bounds.
2. Add a single background generation queue and a TTL/LRU WAV cache keyed by a hash of `voice_id` plus normalized text.
3. Keep text and WAV bytes in memory only; never expose cache keys, text, paths, or reference data from HTTP responses or logs.
4. Preserve the existing `/synthesize` behavior and the single GPU generation slot.
5. Run `python -m unittest discover -s tests -p "test_*.py" -v` and expect all tests to pass.

### Task 2: Add delayed prewarming outside the notification worker

**Files:**
- Create: `plugins/agent-bell/scripts/prewarm.ps1`
- Modify: `plugins/agent-bell/scripts/AgentBell.Core.psm1`
- Modify: `plugins/agent-bell/scripts/worker.ps1`
- Modify: `tests/AgentBell.Core.Tests.ps1`
- Modify: `tests/Hook.Tests.ps1`

**Steps:**
1. Add failing tests for real-title-only lookup, active-turn tracking, automation suppression, and delayed helper launch.
2. On a user prompt, record the start and launch `prewarm.ps1` hidden without waiting for it.
3. Use an existing real Codex title immediately. If a new thread has no title yet, retry after seven seconds; exit when the turn already ended, otherwise POST the exact completion announcement to `/prewarm`.
4. On `Stop`, remove the active turn before notification so short tasks cannot trigger wasteful late prewarming.
5. For HTTP completion speech, request `/cached` with a two-second maximum. Play a cache hit; on any miss or error, play one Windows informational sound and do not call `/synthesize`.
6. Leave permission and failure announcements on the existing provider path.
7. Run all Pester tests and expect them to pass.

### Task 3: Wire setup, documentation, and release metadata

**Files:**
- Modify: `plugins/agent-bell/scripts/setup.ps1`
- Create: `plugins/agent-bell/voice-pack/update.ps1`
- Review: `plugins/agent-bell/config.example.json` (no new user setting is required)
- Modify: `plugins/agent-bell/.codex-plugin/plugin.json`
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `plugins/agent-bell/voice-pack/README.md`

**Steps:**
1. Make Doctor verify the prewarm helper and the Voice Pack low-latency protocol when HTTP voice is enabled.
2. Add a runtime-only updater for existing private Voice Pack installations without touching voices, models, or the virtual environment.
3. Document that long tasks use pre-generated custom audio and short-task cache misses use one prompt sound.
4. Explain that the cache is bounded, memory-only, and cleared when the Voice Pack stops.
5. Bump the plugin to `0.1.3` and update the one-line install instruction.

### Task 4: Verify and install locally

**Steps:**
1. Run Pester, Python contract tests, PowerShell parser checks, JSON validation, and `git diff --check`.
2. Install the updated Voice Pack server and restart it.
3. Verify `/prewarm` returns immediately, `/cached` misses immediately, and a completed prewarm returns a valid WAV.
4. Measure a real cached completion from request to playback start and confirm the fast path is below two seconds.
5. Verify an automation start/stop creates no prewarm request and no sound.
6. Release `v0.1.3`, upgrade the installed plugin, run Initialize/Test/Doctor, and confirm all hooks remain trusted.
