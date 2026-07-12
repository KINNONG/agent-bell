---
name: setup
description: Initialize, test, diagnose, or surgically remove Agent Bell on Windows without overwriting unrelated Codex settings.
---

# Agent Bell Setup

Use this skill when the user asks to set up, test, diagnose, or uninstall Agent Bell.

## Safety rules

- Resolve the installed Agent Bell plugin root before running the setup script.
- Never edit Codex `notify`, `config.toml`, hook trust hashes, or unrelated hooks.
- Never claim that plugin installation implies hook trust.
- After installing or changing hooks, ask the user to open `/hooks`, review the exact command, and trust it explicitly.
- Default to model-free Lite mode. Never run `voice-pack\install.ps1`, install its Python dependencies, or download Qwen unless the user explicitly asks for a custom voice.
- For a custom voice, follow `voice-pack\README.md`: disclose the download and hardware requirements, then wait for separate large-download and voice-rights confirmations.
- Keep private voice data by default. Use `-PurgeData` only after the user explicitly asks to delete it.
- Do not upload reference audio or logs.

## Actions

Run commands with Windows PowerShell 5.1 or later:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\scripts\setup.ps1" -Action Initialize
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\scripts\setup.ps1" -Action Test
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\scripts\setup.ps1" -Action Doctor
```

`Test` plays a real announcement. Add `-DryRun` when audio must not be played. Add `-AsJson` when another program needs structured output.

An installed marketplace plugin already provides its bundled hooks. Do not run `EnableLocalDevelopment` for a normal plugin installation.

For a source checkout only:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\scripts\setup.ps1" -Action EnableLocalDevelopment
```

This action merges Agent Bell handlers into the user-level `hooks.json` without replacing other events or handlers. It is idempotent. Tell the user to review the new definitions in `/hooks`.

To remove only the source-checkout integration:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\scripts\setup.ps1" -Action UninstallLocalDevelopment
```

This keeps local configuration, logs, cache, and voices. After explicit confirmation, add `-PurgeData` to delete the marked Agent Bell data directory. Marketplace plugins should be uninstalled from the Codex Plugins screen after any desired data cleanup.

## Completion checks

1. Confirm the requested action returned `Success: true`.
2. For setup, run `Test`, then `Doctor`.
3. Report the data directory without exposing its contents.
4. State whether the user still needs to review hooks in `/hooks`.
