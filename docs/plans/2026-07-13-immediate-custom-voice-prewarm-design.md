# Immediate Custom-Voice Prewarm Design

**Goal:** Start preparing the exact custom-voice completion announcement as soon as a Codex turn begins thinking, and stop using a Windows prompt sound for an HTTP completion cache miss.

## Decision

`UserPromptSubmit` remains the turn-start signal. The detached helper first checks configuration, automation suppression, active-turn state, and the real Codex title immediately. When the title already exists, it proceeds directly to the existing resource gate and `/prewarm` request. When a new task has not received a real title yet, the helper waits up to the existing 10-second grace period, rechecks configuration and active state, then resolves the title once more. After resource collection it refreshes the title and active state again so a rename during those probes does not prepare stale text. This avoids the old unconditional delay without losing new-task preparation.

The completion path remains cache-only. A ready WAV plays immediately. A cache miss, unavailable service, or playback failure returns the privacy-safe diagnostic value `http-cache-miss` and stays silent; it does not call live synthesis, SAPI, delayed replay, or a Windows system sound. Permission and failure announcements keep their existing on-demand HTTP and SAPI fallback behavior. Lite mode is unchanged.

## Alternatives

- Setting the delay default to zero was rejected because a new task can begin before Codex writes its title, causing a permanent miss.
- Polling the title continuously or moving process launch into the hook was rejected because it adds repeated local reads and more concurrency for little benefit over one bounded retry.
- Keeping the Windows sound was rejected for this release because the requested custom-voice workflow explicitly removes that fallback. Resource rejection can therefore leave an HTTP completion silent; the documentation must state this honestly.

## Safety And Verification

The existing fail-closed RAM, CPU, GPU-memory, and GPU-utilization gate remains unchanged, as do the two helper slots, two-entry server queue, BelowNormal Voice Pack priority, automation suppression, localhost-only HTTP boundary, and final active-state recheck. Tests must prove that an existing title prewarms without the 10-second wait, a late title is retried, automation remains immediate and silent, resource denial sends no HTTP request, and an HTTP cache miss invokes no Windows system sound.
