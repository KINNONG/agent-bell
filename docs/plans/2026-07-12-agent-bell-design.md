# Agent Bell v0.1 Design

## Product

Agent Bell is a Windows-first Codex plugin that calls the user back to the
computer when a Codex turn completes, needs permission, or appears to fail.
The public default works with Windows SAPI. A separately installed local voice
pack can clone a user-authorized reference voice without uploading it.

## Confirmed Scope

- Codex only. Claude Code is deferred.
- Windows only for v0.1.
- One-sentence, agent-assisted setup with explicit Codex plugin and hook trust.
- Lite mode is immediately usable with Windows SAPI.
- Custom Voice Pack is optional and local-only.
- Completion, permission request, and conservative failure announcements.
- Permission and failure announcements are immediate.
- Completion uses smart mode: speak when the turn ran for at least 60 seconds
  or Windows has been idle for at least 45 seconds; otherwise show a Windows
  notification.
- Use the latest Codex conversation title with a privacy-safe fallback.
- Do not overwrite Codex `notify` or unrelated hooks.

## Event Model

Codex exposes `UserPromptSubmit`, `PermissionRequest`, and `Stop`. It does not
currently expose a dedicated failure hook. Agent Bell records the prompt-start
timestamp, announces permission requests directly, and classifies only explicit
failure wording in the final assistant message as a best-effort failure. All
other `Stop` events are treated as completion.

The public wording remains configurable. The initial Chinese defaults are:

- Complete: `主人，{title} 任务已完成，请回来查看了。`
- Permission: `主人，{title} 正在等待您的确认，请回来处理。`
- Failure: `主人，{title} 执行遇到问题，请回来查看。`

## Runtime Architecture

1. A plugin hook receives Codex JSON on stdin.
2. The hook creates one sanitized JSON event file atomically and starts a hidden
   one-shot worker. It returns immediately and never performs speech synthesis.
3. A named mutex allows only one worker to drain the queue at a time.
4. The worker resolves the latest title, applies dedupe and smart-mode rules,
   then uses the configured voice provider.
5. A local HTTP voice provider may return a WAV. Any provider error falls back
   to Windows SAPI.
6. State, logs, reference audio, and cache live under the stable local directory
   `%LOCALAPPDATA%\AgentBell` so setup commands and hooks share one configuration.
   `AGENT_BELL_DATA` may override this location.

## Privacy and Safety

- Queue events never store the user prompt, transcript, tool command, or full
  assistant response.
- Logs omit titles and session IDs by default.
- Reference audio is copied only to the local Agent Bell data directory after the user confirms
  they have permission to use it.
- Hook output is event-specific and always exits zero. `Stop` always receives
  valid JSON on stdout.
- Plugin installation does not imply hook trust. Agent Bell never writes a
  trusted hash or uses a hook-trust bypass.

## Deferred

Claude Code, macOS/Linux, mobile push, tray UI, cloud TTS, voice marketplace,
automatic semantic task-completion detection, and a full notification history
UI are outside v0.1.
