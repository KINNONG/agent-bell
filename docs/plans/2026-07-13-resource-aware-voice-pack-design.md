# Resource-Aware Voice Pack Design

## Decision

Agent Bell remains a sub-megabyte Lite plugin by default. Installing or enabling
the optional Qwen Voice Pack is a separate, explicit user decision. The default
Codex installation instruction must never download Python, CUDA PyTorch, model
weights, or a reference voice.

Users who choose a custom voice receive a second copyable instruction for Codex.
That instruction must disclose the expected 5.5-6 GB first download, roughly
7.8 GB installed footprint, recommended hardware, and voice-rights requirement
before the agent runs the installer.

## Chosen Approach

Use a resource-aware local mode rather than making Qwen the default or moving
voice data to a cloud service. This preserves local privacy and the approved
custom voice while ensuring low-resource machines fall back to the existing
single prompt sound.

Two alternatives were rejected:

- Always prewarm: simplest, but wastes GPU time for short turns and can slow
  local builds, video tools, games, or other CUDA workloads.
- Cloud custom voice: removes local model cost, but adds credentials, usage
  cost, network dependency, and a new privacy boundary.

## Installation Boundary

The Lite install and custom-voice install are separate journeys:

1. Lite installs only the Codex plugin and initializes the existing SAPI
   configuration. It must state that no model is downloaded.
2. Custom voice runs only after an explicit large-download confirmation and
   voice-rights confirmation.
3. Before any virtual environment or package download, the installer checks:
   Windows, NVIDIA driver availability, compute capability 8.0 or newer,
   at least 6 GiB total VRAM, at least 16 GiB physical RAM, and 12 GiB free
   disk space for a new installation.
4. Existing complete installations may be refreshed with 2 GiB free space.
5. Pip uses no-cache mode so multi-gigabyte wheels are not retained globally.

The published recommendation is 32 GiB RAM and 8 GiB or more VRAM. The hard
minimum is intentionally lower so a 16 GiB / 6 GiB machine can opt in, while
runtime protection remains conservative.

## Runtime Policy

Custom-voice prewarming uses a fixed 10-second grace period for every turn.
After the grace period, the detached helper confirms that the turn is still
active and that a real Codex title exists. It then takes a resource snapshot.

Prewarming is skipped when any required snapshot cannot be read, or when:

- available physical memory is below 2 GiB;
- total CPU use is above 75 percent;
- free GPU memory is below 1.5 GiB; or
- GPU utilization is above 70 percent.

Skipping is a normal outcome, not an error. Completion then follows the current
cache-miss behavior and plays one prompt sound with no delayed replay. The
resource log records only a reason code, never a title, prompt, session ID, or
announcement text.

The Voice Pack keeps one GPU generation slot, reduces the queued prewarm limit
from eight to two, and runs at BelowNormal CPU priority on Windows. Active model
generation is not forcibly cancelled because interruption is not known to be
safe in the current Qwen wrapper; the grace period and resource gate prevent
most waste before generation starts.

## Compatibility And Verification

Existing Lite users are unchanged. Existing HTTP users gain the resource gate
after updating the plugin; no new user-editable configuration is required.
Permissions and failure announcements retain their existing on-demand provider
and SAPI fallback behavior.

Verification must cover:

- Lite installation documentation contains no Voice Pack command;
- custom-voice installation requires both explicit confirmations;
- hardware and disk checks run before venv or pip activity;
- resource-policy boundaries and unavailable-metric behavior;
- the 10-second helper delay remains detached from Codex;
- automation runs remain silent;
- queue capacity and Windows process priority;
- full Pester and Python suites, syntax checks, Doctor, and a live busy-resource
  fallback test on the local machine.
