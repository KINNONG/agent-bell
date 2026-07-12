# Security Policy

Agent Bell runs local commands from Codex lifecycle hooks. Review the installed
hook definition before trusting it, and install releases only from this
repository.

## Supported Versions

Security fixes are applied to the latest released `0.1.x` version. Development
snapshots on the default branch are supported on a best-effort basis.

## Reporting a Vulnerability

Do not disclose vulnerabilities in a public issue. Use GitHub's private
vulnerability reporting for this repository. If that option is unavailable,
open a public issue containing no exploit details and ask the maintainer for a
private contact channel.

Include the affected version, Windows and Codex versions, reproduction steps,
impact, and any suggested mitigation. Remove conversation titles, session IDs,
reference audio, credentials, and other private data before attaching logs.

## Security Boundaries

- Agent Bell never bypasses Codex hook trust or writes trusted hook hashes.
- Lite mode uses Windows SAPI and does not require network access.
- The optional HTTP voice provider must bind to loopback only. Do not expose it
  to a LAN or the public internet.
- Hook payloads are treated as untrusted input. Titles and paths must be
  validated before use and must never be interpolated into executable code.
- Logs omit conversation titles and session IDs by default and must never
  contain prompts, transcripts, tool commands, or assistant responses.
- Setup and uninstall operations must preserve unrelated Codex hooks and the
  user's existing `notify` configuration.

## Voice Safety

Only use reference audio that you own or have explicit permission to use.
Agent Bell does not include a public voice library and must not upload reference
audio in local mode.

Reports about upstream Codex, Windows, or optional TTS packages should also be
sent to the relevant upstream security contact.
