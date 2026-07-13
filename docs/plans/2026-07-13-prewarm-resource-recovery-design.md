# Prewarm Resource Recovery Design

## Problem

Agent Bell v0.1.5 combined a fail-closed 2 GiB available-memory gate with a
silent completion cache miss. On a supported 16 GiB machine with Codex and the
Voice Pack already resident, available memory repeatedly stayed near 1.2-1.6
GiB. Prewarming was therefore skipped, and otherwise healthy long turns ended
without any announcement.

The hooks, trust state, localhost service, and cache playback path were healthy.
A controlled custom-voice preparation started with 1.57 GiB available, reached
a 1.04 GiB minimum, completed in 29.3 seconds, and played from the cache. This
showed that the 2 GiB runtime floor was incompatible with the documented 16 GiB
minimum once the model was already resident.

## Decision

- Lower the prewarm start floor from 2 GiB to 1.5 GiB. The measured run used
  about 0.53 GiB of additional available memory, so this keeps roughly 1 GiB of
  observed headroom instead of treating 1 GiB as a guaranteed runtime reserve.
- Keep the existing 75 percent CPU, 1.5 GiB free-VRAM, and 70 percent GPU-use
  limits.
- Check resources immediately, then retry at about 15, 45, and 75 seconds while
  the turn remains active. The last retry still leaves roughly 45 seconds for
  the measured 29.3-second generation on a two-minute turn. Re-read
  configuration and active-turn state before every retry.
- Release the two helper slots before either retry sleep. A helper waits up to
  three seconds for a slot only while probing resources or submitting prewarm,
  so two deferred turns do not permanently discard a third concurrent turn.
- Hold one of four separate waiter slots across title and resource delays. This
  bounds sleeping PowerShell helpers without reintroducing contention on the
  two active probe/submission slots.
- Keep completion playback cache-only and keep Windows prompt sounds disabled.
- Log only the privacy-safe attempt number, final reason, and request status.

This restores custom-voice availability on the minimum supported RAM class
without switching to unconditional generation. A turn that remains below the
hard floors still stays silent rather than competing with the user's workload.
