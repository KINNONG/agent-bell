# Agent Bell v0.1 Implementation Plan

**Goal:** Turn the existing personal Codex speech hook into a testable, non-blocking, Windows-first Codex plugin with SAPI fallback and an optional local custom-voice provider.

**Architecture:** Plugin hooks sanitize and atomically enqueue Codex events, then launch a hidden one-shot PowerShell worker. The worker owns title resolution, state, dedupe, smart notification policy, provider fallback, and privacy-safe logs. The repository ships a Codex marketplace entry, lifecycle setup commands, tests, and open-source documentation; model weights and private voices stay outside Git.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4-compatible tests, Codex plugin hooks, System.Speech, optional localhost HTTP TTS provider, Python 3.12 for the optional Qwen3 voice pack.

---

### Task 1: Establish the Open-Source Repository Skeleton

**Files:**
- Create: `.agents/plugins/marketplace.json`
- Create: `plugins/agent-bell/.codex-plugin/plugin.json`
- Create: `plugins/agent-bell/config.example.json`
- Modify: `.gitignore`
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `THIRD_PARTY_NOTICES.md`

**Steps:**
1. Add a local repo marketplace that exposes `plugins/agent-bell`.
2. Add the Codex plugin manifest with MIT metadata and bundled hooks/skill paths.
3. Define a versioned config schema containing smart thresholds, templates,
   SAPI settings, optional HTTP voice settings, and privacy defaults.
4. Ignore runtime data, private audio, model weights, virtual environments, and
   generated audio.
5. Run `Get-Content ... | ConvertFrom-Json` for every JSON file and expect no
   parse errors.

### Task 2: Write Core Tests Before the Runtime

**Files:**
- Create: `tests/AgentBell.Core.Tests.ps1`
- Create: `tests/fixtures/session_index.jsonl`

**Steps:**
1. Add failing tests for title normalization and length bounds.
2. Add failing tests for completion, permission, and conservative failure text.
3. Add failing tests for smart-mode decisions at 60-second duration and
   45-second idle boundaries.
4. Add failing tests for dedupe pruning and privacy-safe log records.
5. Run `Invoke-Pester tests/AgentBell.Core.Tests.ps1` and verify failures are
   caused by the missing module.

### Task 3: Implement the PowerShell Core Module

**Files:**
- Create: `plugins/agent-bell/scripts/AgentBell.Core.psm1`

**Steps:**
1. Implement config loading with defaults and schema validation.
2. Implement atomic JSON read/write helpers and bounded JSONL log rotation.
3. Implement Codex title lookup from `session_index.jsonl`, with SQLite and cwd
   fallbacks and no transcript parsing.
4. Implement sanitized event conversion and conservative failure detection.
5. Implement smart-mode policy, announcement templates, and bounded state.
6. Implement SAPI speech, local HTTP WAV synthesis, WAV playback, SAPI fallback,
   and Windows notification fallback.
7. Run the core Pester tests and expect all to pass.

### Task 4: Add the Non-Blocking Hook and Queue Worker

**Files:**
- Create: `plugins/agent-bell/hooks/hooks.json`
- Create: `plugins/agent-bell/hooks/enqueue.ps1`
- Create: `plugins/agent-bell/scripts/worker.ps1`
- Modify: `codex-voice-notifier.ps1`

**Steps:**
1. Register `UserPromptSubmit`, `PermissionRequest`, and `Stop` command hooks.
2. Make `enqueue.ps1` read stdin, discard private text after classification,
   atomically write one event file, start the worker hidden, and return the
   correct stdout shape for each event.
3. Make the worker acquire a named mutex, drain events in capture order until a
   short quiescence window passes, update state, and speak or notify.
4. Replace the trusted local prototype script with a compatibility wrapper that
   keeps the installed hook command unchanged while invoking the new hook.
5. Measure hook runtime with a dry event and require it to return in under two
   seconds without waiting for speech.

### Task 5: Add Safe Setup, Test, Doctor, and Uninstall Actions

**Files:**
- Create: `plugins/agent-bell/scripts/setup.ps1`
- Create: `plugins/agent-bell/skills/setup/SKILL.md`
- Create: `tests/Setup.Tests.ps1`

**Steps:**
1. Write tests using temporary Codex homes proving setup and uninstall preserve
   unrelated hook entries and `notify` configuration.
2. Implement `Initialize`, `Test`, `Doctor`, `EnableLocalDevelopment`, and
   `UninstallLocalDevelopment` actions as idempotent structured-JSON edits.
3. Never write hook trust hashes. Report the required `/hooks` review instead.
4. Preserve user voice data by default; delete it only with an explicit purge.
5. Run setup tests and a doctor command against the local machine.

### Task 6: Add and Validate the Optional Custom Voice Pack

**Files:**
- Create if the Windows lab succeeds: `plugins/agent-bell/voice-pack/README.md`
- Create if the Windows lab succeeds: `plugins/agent-bell/voice-pack/server.py`
- Create if the Windows lab succeeds: `plugins/agent-bell/voice-pack/install.ps1`
- Create if the Windows lab succeeds: `plugins/agent-bell/voice-pack/start.ps1`
- Create if the Windows lab succeeds: `plugins/agent-bell/voice-pack/requirements.txt`

**Steps:**
1. Build an isolated Python 3.12 environment outside the repository runtime.
2. Install the official Qwen3-TTS package and 0.6B Base model.
3. Generate the exact completion phrase from the supplied authorized reference
   audio and record startup time, generation time, and GPU memory.
4. If successful, expose localhost-only `/health` and `/synthesize` endpoints,
   add SHA-pinned dependency guidance, and configure the local Agent Bell data.
5. If native Windows is not reliable, keep the generic HTTP provider and
   document Custom Voice Pack as experimental rather than shipping a broken
   installer.
6. Test provider failure and confirm automatic SAPI fallback.

### Task 7: Write User Documentation and Run End-to-End Verification

**Files:**
- Rewrite: `README.md`
- Create: `README.en.md`
- Remove or replace: legacy root `hooks.json`

**Steps:**
1. Document the one-sentence Codex-assisted installation flow and its two honest
   confirmations: plugin install and hook trust.
2. Document Lite mode, optional custom voice, privacy, troubleshooting, doctor,
   update, and surgical uninstall.
3. Run JSON validation, all Pester tests, PowerShell parser checks, and doctor.
4. Replay fixtures for prompt start, permission request, short active stop,
   long stop, idle stop, failure stop, duplicate stop, missing title, and broken
   custom provider.
5. Trigger a real test announcement on the local audio device and inspect the
   privacy-safe log.
6. Run `git status --short` and review every changed file before delivery.
