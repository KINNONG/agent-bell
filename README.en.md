# Agent Bell

[![test](https://github.com/KINNONG/agent-bell/actions/workflows/test.yml/badge.svg)](https://github.com/KINNONG/agent-bell/actions/workflows/test.yml)

Agent Bell is a Windows-first, Codex-only voice notification plugin. You can leave the computer while Codex handles a longer turn, then hear when that turn stops, needs permission, or explicitly appears to have failed.

> v0.1 scope: Windows, Codex, Windows SAPI Lite mode, and an optional experimental local Qwen Voice Pack. Claude Code, macOS, Linux, mobile push, and a tray application are out of scope.

Agent Bell is an unofficial open-source project. It is not affiliated with or endorsed by OpenAI.

## What It Reports

| State | Source | Default behavior |
| --- | --- | --- |
| Complete | Codex Stop hook | Speak every time by default |
| Permission required | Codex PermissionRequest hook | Speak immediately |
| Execution problem | Explicit failure wording in the final Stop message | Conservatively infer failure and speak immediately |

The UserPromptSubmit hook records only the start time of the turn. It does not speak or persist the user prompt. With the local Voice Pack enabled, it also starts completion preparation when thinking begins, without blocking Codex or the main notification queue.

Scheduled Codex automation runs are silent by default, including completion, failure, and permission events. Agent Bell uses the local rollout's `thread_source=automation` metadata rather than guessing from the title. Normal user-started or resumed threads still notify.

Default Chinese templates:

- Complete: 主人，{title} 任务已完成，请回来查看了。
- Permission: 主人，{title} 正在等待您的确认，请回来处理。
- Failure: 主人，{title} 执行遇到问题，请回来查看。

### What “Complete” Means

Stop means that one Codex turn stopped. It does not prove that an entire project completed successfully. The public wording is configurable.

Codex does not currently expose a dedicated failure hook. Agent Bell classifies a Stop as failure only when the final assistant message contains explicit, unresolved failure wording. Ambiguous warnings and failures that were later fixed are not classified as failures. This is a conservative inference, not an audit of the result.

## Architecture

~~~text
Codex hook
  -> sanitize and atomically enqueue a minimal event
  -> return immediately without waiting for speech
  -> hidden one-shot worker drains the queue
  -> resolve the latest title, deduplicate, and apply the notification policy
  -> immediately attempt custom completion pre-generation when thinking begins
  -> Windows SAPI or a localhost HTTP Voice Pack
  -> use the configured SAPI fallback when custom completion audio is not ready
~~~

Plugin files contain read-only code. To ensure setup commands and hooks always read the same settings, configuration, queue files, state, logs, and cache live under `%LOCALAPPDATA%\AgentBell`. Private reference audio for an optional Voice Pack should also stay there, never in plugin source. Advanced users may override the location with `AGENT_BELL_DATA`.

## Requirements

- Windows
- A Codex version that supports Plugins and Hooks
- Windows PowerShell 5.1
- A working audio output device
- At least one installed Windows SAPI voice for Lite mode

Lite mode does not require Python, a GPU, model files, or an API key.

## One-Sentence Agent-First Installation

Send this sentence to Codex:

~~~text
Install Agent Bell v0.1.7 in Lite mode from https://github.com/KINNONG/agent-bell. Audit the repository, run codex plugin marketplace add KINNONG/agent-bell --ref v0.1.7 and codex plugin add agent-bell@agent-bell, and install only the base plugin: do not install the Qwen Voice Pack or download any model. Ask me to confirm any required Plugins prompt, locate the installed plugin root, and run Initialize, Test, and Doctor. Preserve my existing notify configuration and unrelated hooks, and do not bypass the /hooks trust review.
~~~

There are two intentional confirmations:

1. Confirm installing or enabling Agent Bell in the Codex Plugins interface.
2. Open /hooks, inspect the Agent Bell command, and trust that hook.

These are Codex security boundaries. Installing a plugin does not automatically trust bundled hooks, and Agent Bell never writes trust hashes or bypasses the review.

## Initialize and Verify

The following commands assume the installed plugin root is known:

~~~powershell
$pluginRoot = "<installed agent-bell plugin root>"
$setup = Join-Path $pluginRoot "scripts\setup.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Initialize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Doctor
~~~

- Initialize creates or completes the local data directory and default config.
- Test plays a real test announcement.
- Doctor checks Windows, required plugin files, hook definitions, runtime config, and the user hooks.json.

For documentation checks or CI, add -DryRun to Test:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Test -DryRun
~~~

Add -AsJson when a machine-readable Doctor result is needed.

## Lite SAPI Mode

Lite is the default public v0.1 mode:

- Everything runs locally.
- Agent Bell first tries the configured SAPI voice.
- If that voice is unavailable, it tries another zh-CN voice and then the Windows default.
- It downloads no model, uploads no title, and calls no external API.

The defaults are documented in [config.example.json](plugins/agent-bell/config.example.json). Initialize creates the active config.json under the Agent Bell data directory.

Common settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| mode | always | Completion notification policy |
| duration_threshold_seconds | 60 | Speak after a turn reaches this duration |
| idle_threshold_seconds | 45 | Speak after Windows reaches this idle duration |
| stop_debounce_seconds | 5 | Wait for another Stop hook to continue the task before announcing |
| max_title_characters | 60 | Maximum spoken title length |
| voice.sapi_voice | Microsoft Huihui Desktop | Preferred SAPI voice |
| voice.rate | 0 | SAPI rate from -10 to 10 |
| voice.volume | 100 | SAPI volume from 0 to 100 |
| voice.http.timeout_seconds | 30 | Fall back to SAPI after a local voice timeout |
| notifications.automation_runs | none | Keep automation runs silent; normal restores notifications |

## Notification Policies

The default `always` mode speaks every Complete event. To reduce interruptions from short turns, set `mode` to `smart`; its rules are:

- Permission and conservatively inferred failure events always speak immediately.
- Complete speaks when the turn ran for at least 60 seconds.
- Complete speaks when Windows has been idle for at least 45 seconds.
- Otherwise Complete shows a Windows notification to avoid interrupting the user after every short turn.

`threshold` mode considers only turn duration.

## Optional Local Qwen Voice Pack

The repository includes an optional experimental [Qwen Voice Pack](plugins/agent-bell/voice-pack/README.md). It uses the local Qwen3-TTS 0.6B Base model to create a custom voice from user-authorized reference audio and implements the localhost HTTP contract below. Model weights, the Python environment, and private audio stay outside the plugin repository.

This is a large, separate, optional installation: expect a `5.5–6 GB` download and approximately `7.8 GB` installed, with at least `12 GiB` (about `12.9 GB`) free on the destination drive before a new installation. The hardware minimum is `16 GiB` of system RAM and `6 GiB` of NVIDIA VRAM; `32 GiB` of RAM and `8 GiB` of VRAM are recommended. Python 3.12, CUDA, bfloat16, and compute capability 8.0 or newer are also required. Lite mode requires none of these and downloads no model.

The model loads before the Voice Pack becomes ready and remains resident in VRAM while the service runs. After UserPromptSubmit, the background helper immediately tries to resolve the real title. If it is already available, the helper checks CPU, RAM, and GPU headroom and submits preparation at once; if a new title has not been written yet, it retries once after 10 seconds. Prewarming requires at least 1.5 GiB of system memory before generation starts and retains the CPU, free-VRAM, and GPU-utilization guards. When the first resource check is denied, an active turn gets three bounded retries at about 15, 45, and 75 seconds without holding an active prewarm slot while it waits. At most four deferred helpers may wait, and at most two may probe or submit concurrently; excess parallel turns skip that preparation. If all four checks fail, completion still avoids live synthesis, delayed replay, and Windows prompt sounds; when `fallback_provider` is `sapi`, it uses system speech at completion, while `none` keeps the miss silent. The generation process uses lower priority and a bounded queue, but it can still contend with video editors, games, or other local AI workloads; the 16 GiB minimum can still page under pressure, and 32 GiB is recommended. Permission and failure announcements still use on-demand synthesis with a 30-second timeout and SAPI fallback.

### One-Sentence Custom-Voice Installation

Only when a custom voice is needed, replace the two placeholders below with authorized material and send the sentence to Codex:

~~~text
Install the optional local Qwen custom voice for Agent Bell v0.1.7. Before any download or write, show me and explain that the expected download is 5.5–6 GB, the installed size is approximately 7.8 GB, and a new installation requires at least 12 GiB (about 12.9 GB) free on the destination drive. Explain that the hardware minimum is 16 GiB of system RAM and 6 GiB of NVIDIA VRAM, while 32 GiB of RAM and 8 GiB of VRAM are recommended. Wait for my explicit approval of the large download before continuing or passing -ConfirmLargeDownload. Use "<absolute path to audio that I own or am explicitly authorized to use>" as the reference audio and "<exact word-for-word transcript matching the reference audio>" as its transcript; ask me to confirm the voice rights before passing -ConfirmVoiceRights. Warn me that the reference path and transcript remain visible in this Codex task and its tool-call history; do not commit them to the repository or write them to Agent Bell logs. Locate and run voice-pack\install.ps1 under the installed plugin, let the installer complete its read-only hardware and capacity preflight, and continue downloading and installing to a drive with sufficient space only if that preflight passes. Start the local service after installation and verify its health and synthesis checks; change provider to http only after they pass, then run Agent Bell Test and Doctor. Do not bypass resource protections, and retain `fallback_provider: sapi` so completion, permission, and failure events still have system speech when the custom voice is unavailable.
~~~

The v0.1.7 installer uses the official Hugging Face model repository at a pinned revision. Hugging Face downloads may be slow from Mainland China. Although Qwen documents ModelScope as a download route for Mainland China, this installer does not yet expose a ModelScope switch. Use model-free Lite mode when the download path is unsuitable, and do not substitute an unverified third-party mirror; a future version can add a verified mirror source.

The service must:

- Bind only to a loopback address, not a LAN or public interface. The client rejects non-loopback endpoints and HTTP redirects.
- `/synthesize` accepts POST JSON containing `text` and `voice_id` and generates `audio/wav` on demand.
- `/prewarm` accepts a background preparation request immediately; `/cached` returns only an already prepared WAV and never generates on demand.
- Prepared audio uses a bounded memory-only cache that is cleared when the service stops.

Example configuration:

~~~json
{
  "voice": {
    "provider": "http",
    "fallback_provider": "sapi",
    "http": {
      "endpoint": "http://127.0.0.1:17863/synthesize",
      "timeout_seconds": 30,
      "voice_id": "default"
    }
  }
}
~~~

### Upgrading an Existing Voice Pack

`v0.1.3` introduced the `/prewarm` and `/cached` low-latency path, `v0.1.4` further bounded background resource pressure, `v0.1.5` starts preparation as soon as thinking begins, `v0.1.6` adjusts the memory floor for 16 GiB machines and adds bounded resource retries, and `v0.1.7` honors the configured SAPI fallback on a completion cache miss. Upgrading from `v0.1.5` or `v0.1.6` to `v0.1.7` does not require another Voice Pack runtime update; users upgrading from an earlier version still need the one-time update below.

Stop the current Voice Pack and confirm that `127.0.0.1:17863` is no longer listening, then run this from the installed plugin root:

~~~powershell
$updater = Join-Path $pluginRoot "voice-pack\update.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -InstallRoot "D:\AgentBell\voice-pack"
~~~

Omit `-InstallRoot` for the default location. The updater never terminates a pre-existing process. It replaces only `server.py`, `start.ps1`, and `requirements.txt`; it does not touch `.venv`, models, or private voices. It starts the service hidden and verifies the low-latency protocol, and attempts to restore and restart the previous runtime if the update fails.

Completion announcements still read only the prepared cache and never use live synthesis, delayed replay, or Windows prompt sounds. A cache miss or unavailable service follows `fallback_provider`: `sapi` speaks through Windows, while `none` stays silent. Permission and failure announcements use the same fallback when the service is unavailable, times out, or returns an invalid WAV. Change provider to http only after the Voice Pack has been installed separately and passed a local test.

Use only reference audio that you own or have explicit permission to use. Agent Bell provides no public voice library and does not upload reference audio in local mode.

## Privacy

- Lite mode requires no network access.
- Queue files contain only the minimum local metadata needed for processing. They do not persist prompts, transcripts, tool arguments, or full assistant responses.
- The final Stop message is examined in memory for conservative failure classification and is not written to the queue.
- Operational logs omit conversation titles and session IDs by default.
- Titles are resolved and spoken locally. With an HTTP provider, the final announcement text is sent to the configured local endpoint; the Voice Pack preparation cache exists only in memory.
- Remove {title} from the templates when conversation names may be sensitive.
- Setup and uninstall preserve Codex notify configuration and unrelated hooks.

See [SECURITY.md](SECURITY.md) for the security boundaries.

## Tests

Run the complete Pester suite:

~~~powershell
Invoke-Pester .\tests
~~~

Run a silent dry run through the compatibility entry point:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-voice-notifier.ps1 -TestSessionId "00000000-0000-0000-0000-000000000001" -TestTurnId "readme-dry-run" -DryRun
~~~

The suite covers title sanitization, all three templates, smart boundaries, conservative failure classification, privacy-safe logs, state pruning, queue deduplication, non-blocking hook behavior, completion prewarming, and the Voice Pack localhost HTTP cache contract.

## Doctor

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Doctor
~~~

Doctor checks Windows, required plugin files, all three hook events, runtime config, and the user hooks.json. When an HTTP Voice Pack is configured, it also verifies the low-latency protocol through a no-redirect, size-bounded health probe with a true two-second deadline. It does not infer hook trust; instead, it returns an instruction to review /hooks. Add -AsJson for structured output, and still review it for private local paths before sharing it. Use Test to verify the audio path.

## Uninstall

For a marketplace installation:

1. Disable or uninstall Agent Bell in Codex Plugins.
2. Confirm that /hooks no longer loads the Agent Bell hook.
3. Local data is retained by default for a later reinstall. Use Doctor to identify the data directory before removing it.

Source-development wiring is for contributors only:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action EnableLocalDevelopment
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action UninstallLocalDevelopment
~~~

UninstallLocalDevelopment preserves local data by default. Add -PurgeData only after confirming that the configuration, cache, and private audio are no longer needed.

Do not run EnableLocalDevelopment for a normal marketplace installation. Source uninstall removes only the Agent Bell entry it merged. It never deletes the entire ~/.codex/hooks.json, changes config.toml or notify, or writes hook trust state.

## Known Limitations

- v0.1 supports Windows and Codex only.
- Stop is a turn-level event, not a reliable project-completion signal.
- If another Stop hook continues work only after the 5-second grace period, Agent Bell can still announce early; `stop_debounce_seconds` may be raised to at most 120 seconds.
- Failure is conservatively inferred from explicit wording.
- Titles come from local Codex state and use a safe fallback when unavailable.
- Custom voices require a separately installed and verified experimental Qwen localhost service and a compatible NVIDIA GPU.
- A new title that is not yet present in Codex state gets one retry after 10 seconds. A denied resource gate gets three more checks while the turn remains active. A task shorter than generation, a later title change, or four denied checks can leave the custom voice unavailable, so completion follows `fallback_provider`.
- Agent Bell is not a task-result verifier and does not replace tests, logs, or human review.

## License

Agent Bell is available under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party information.
