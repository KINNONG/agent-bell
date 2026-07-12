# Resource-Aware Voice Pack Implementation Plan

> **For implementation agents:** Execute this plan task by task and keep the Lite path model-free.

**Goal:** Keep Agent Bell lightweight by default and make optional Qwen custom-voice installation and prewarming safe on resource-constrained Windows machines.

**Architecture:** The Lite plugin remains SAPI-only until a user explicitly runs the separate Voice Pack installer. The installer performs non-destructive hardware and capacity checks before downloads, while the detached prewarm helper waits ten seconds and submits work only when local RAM, CPU, and GPU headroom are healthy.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4, Python 3.12, CUDA PyTorch, Qwen3-TTS, `nvidia-smi`, Windows process priority APIs.

---

### Task 1: Add pure resource-policy contracts

**Files:**
- Modify: `plugins/agent-bell/scripts/AgentBell.Core.psm1`
- Modify: `tests/AgentBell.Core.Tests.ps1`

**Steps:**
1. Add failing tests for the exact RAM, CPU, free-VRAM, and GPU-utilization boundaries.
2. Add a test proving missing critical metrics fail closed.
3. Implement a pure decision function returning `allowed` and a privacy-safe reason code.
4. Implement the Windows snapshot collector separately so policy tests do not depend on machine load.
5. Run `Invoke-Pester tests/AgentBell.Core.Tests.ps1` and expect all tests to pass.

### Task 2: Gate and delay detached prewarming

**Files:**
- Modify: `plugins/agent-bell/scripts/prewarm.ps1`
- Modify: `tests/Hook.Tests.ps1`

**Steps:**
1. Add a failing test that an already-titled turn still waits when the default delay is used.
2. Add tests that `DelaySeconds 0` keeps deterministic test execution.
3. Add tests that a denied resource snapshot sends no HTTP request and logs only a reason.
4. Wait ten seconds before title lookup, then re-read config and active-turn state.
5. Collect the snapshot, apply the pure policy, and exit normally on denial.
6. Run `Invoke-Pester tests/Hook.Tests.ps1` and expect all tests to pass.

### Task 3: Bound Voice Pack runtime pressure

**Files:**
- Modify: `plugins/agent-bell/voice-pack/server.py`
- Modify: `tests/test_voice_pack.py`

**Steps:**
1. Add a failing test that the prewarm queue accepts at most two pending jobs.
2. Add a test for best-effort BelowNormal priority setup on Windows.
3. Reduce the prewarm queue constant from eight to two.
4. Set BelowNormal process priority before model loading without adding a dependency.
5. Run `python -m unittest discover -s tests -p "test_*.py" -v` and expect all tests to pass.

### Task 4: Reject unsuitable installs before downloads

**Files:**
- Modify: `plugins/agent-bell/voice-pack/install.ps1`
- Modify: `tests/Setup.Tests.ps1`

**Steps:**
1. Add tests for the new explicit large-download confirmation.
2. Add pure preflight tests for Windows, NVIDIA availability, compute capability, VRAM, RAM, and free disk boundaries.
3. Prove preflight occurs before marker, venv, or app files are created.
4. Add `--no-cache-dir` to every pip install operation.
5. Keep the existing post-install PyTorch CUDA and bfloat16 validation.
6. Run `Invoke-Pester tests/Setup.Tests.ps1` and expect all tests to pass.

### Task 5: Split Lite and custom-voice onboarding

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `plugins/agent-bell/voice-pack/README.md`
- Modify: `plugins/agent-bell/.codex-plugin/plugin.json`

**Steps:**
1. Make the primary one-sentence install explicitly Lite-only and model-free.
2. Add a separate copyable Codex instruction for custom voice with placeholders for authorized audio and exact reference text.
3. Disclose 5.5-6 GB download, approximately 7.8 GB installed size, 12 GiB free-space requirement, and recommended 32 GiB RAM / 8 GiB VRAM.
4. Document automatic resource fallback and Mainland China download considerations.
5. Bump the plugin version to `0.1.4`.

### Task 6: Verify, release, and install

**Steps:**
1. Run all Pester and Python tests.
2. Run PowerShell, Python, and JSON syntax checks plus `git diff --check`.
3. Run a privacy scan for the private reference-audio path and text.
4. Exercise a denied prewarm on the busy local machine and confirm no generation request is sent.
5. Run Doctor against the updated Voice Pack.
6. Commit, push, wait for GitHub Actions, tag and release `v0.1.4`.
7. Upgrade the installed plugin and verify the three trusted hooks resolve to `0.1.4`.
