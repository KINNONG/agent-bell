# Third-Party Notices

Agent Bell is licensed under the MIT License. The following products and
optional components are not relicensed by Agent Bell.

## OpenAI Codex

Agent Bell integrates with the Codex plugin and lifecycle-hook interfaces.
Codex is not bundled with this repository and remains subject to OpenAI's terms
and licenses. Agent Bell is an independent project and is not affiliated with
or endorsed by OpenAI.

## Microsoft Windows Speech Components

Lite mode uses the `System.Speech` APIs and installed Windows SAPI voices.
These components are supplied by Microsoft with Windows or the .NET Framework;
they are not distributed by Agent Bell and remain subject to Microsoft's
applicable license terms.

## Optional Qwen Voice Pack

The optional Voice Pack installs the following components into a
user-controlled local environment. Their packages and model weights are not
bundled with Agent Bell:

- `qwen-tts` 0.1.1 and `Qwen/Qwen3-TTS-12Hz-0.6B-Base`, pinned to revision
  `5d83992436eae1d760afd27aff78a71d676296fc`, by the Qwen team, Apache License
  2.0. Sources: https://github.com/QwenLM/Qwen3-TTS and
  https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base
- PyTorch 2.11.0+cu128, PyTorch contributors, BSD 3-Clause License. Source:
  https://pytorch.org/
- TorchAudio 2.11.0+cu128, copyright 2017 Facebook Inc. (Soumith Chintala),
  BSD 2-Clause License. Source: https://github.com/pytorch/audio

User-provided reference audio and generated voice prompts are private user
data and are not distributed with Agent Bell. Preserve all applicable upstream
licenses and notices when redistributing third-party components.

## Optional HTTP Voice Providers

Agent Bell can call a user-configured localhost TTS service. Such services,
models, and generated voices are installed separately and remain subject to
their own licenses, privacy policies, and voice-consent requirements.

## Test Dependencies

The development test suite may use Pester, which is installed separately and
is not bundled in Agent Bell release artifacts. See its upstream repository
for the applicable version and license:

- https://github.com/pester/Pester
