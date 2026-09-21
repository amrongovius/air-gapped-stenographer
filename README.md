# Air-Gapped Digital Stenographer

Turn spoken voice memos into structured Markdown notes using local AI — fully offline, on the old Intel Mac in your drawer.

You record (or already have) a voice memo. This pipeline transcribes it and organizes it into a proper note — Executive Summary, Core Insights, Action Items — with no data ever leaving your Mac. The only time this setup touches the internet at all is the one-time download step below.

## Table of contents

- [Why this exists](#why-this-exists)
- [How it works](#how-it-works)
- [Hardware requirements](#hardware-requirements)
- [Setup (step by step)](#setup-step-by-step)
- [Using it day to day](#using-it-day-to-day)
- [Editing prompts / adding your own](#editing-prompts--adding-your-own)
- [Troubleshooting & known gotchas](#troubleshooting--known-gotchas)
- [Known limits](#known-limits)
- [Security](#security)
- [Credits & attribution](#credits--attribution)
- [License](#license)

## Why this exists

Some recordings shouldn't leave your machine — a journal entry, a family story, a meeting with sensitive information, or the kernel of a truly original idea. Send that audio to a cloud transcription or AI service and it's on someone else's servers, under someone else's retention policy, whatever the fine print says.

It was also built deliberately to run on the old consumer tech people already have sitting at home. Mainstream local-AI tooling is moving the opposite direction: Ollama requires macOS 14 (Sonoma) or later; a 2017 Intel MacBook Pro tops out at macOS 13. Homebrew's installer now refuses fresh installs on any Intel Mac at all. Both changes happened within about a week of each other, in September 2026.

This guide builds `whisper.cpp` and `llama.cpp` from source, with Metal GPU support turned off, because that's what actually works on old Intel hardware.

## How it works

```
Voice Memos (.m4a), or any audio file
        │
        │  you drag it into ~/Stenographer/inbox — that's the only step you do
        ▼
┌─────────────────────┐
│   queue_watcher.sh   │   woken by launchd: instantly on file arrival,
└──────────┬───────────┘   and every 120s regardless, as a safety net
           │  claims the file, calls dictate.sh
           ▼
┌───────────────┐        ┌────────────────────┐
│    ffmpeg      │──────▶│    whisper.cpp       │   audio → transcript
│ (→ 16kHz WAV)  │        │   (whisper-cli)      │
└───────────────┘        └──────────┬─────────┘
                                     │ transcript.txt
                                     ▼
                         ┌────────────────────┐
                         │     llama.cpp        │   transcript → structured
                         │   (llama-server)     │   Markdown note
                         └──────────┬─────────┘
                                    ▼
                  ~/Stenographer/notes/*.md
                  (Executive Summary, Core Insights, Action Items, ...)

   original file → ~/Stenographer/archive/   (or → failed/ if something
                                                broke — check logs/)
```

Everything after the one-time setup runs locally: no account, no API key, no network call once your models are downloaded. `llama.cpp` runs in background "server" mode (`llama-server`) rather than its interactive chat mode — see [Troubleshooting](#troubleshooting--known-gotchas) for why.

The audio is processed **one file at a time**, oldest first, however many are waiting — this is tuned for machines with limited RAM and 2 CPU cores, where running two language-model requests at once would make both slower rather than getting more done.

## Hardware requirements

| | Tested | Notes |
|---|---|---|
| Mac | 2017 Intel MacBook Pro (Intel x86_64) | Should work on any Intel Mac; Apple Silicon Macs can follow this guide too (skip the Intel-specific steps) but haven't been tested by this project yet — if you try it, an issue report is welcome |
| macOS | 12.7.6 Monterey | Likely fine on 11 (Big Sur) or later; not verified below Monterey |
| RAM | 8GB | Workable at 8GB; watch Activity Monitor on long recordings (see [Known limits](#known-limits)) |
| CPU | Dual-core Intel i7 | GPU acceleration (Metal) is deliberately **disabled** — required on some older Intel Macs, which can kernel-panic with it left on |
| Disk | ~4GB free | Build artifacts + a ~140MB speech model + a ~1.9GB language model |
| Internet | Only during setup | Nothing is sent anywhere once you're transcribing |

## Setup (step by step)

Run each block below in Terminal, in order.

### Step 1 — Xcode Command Line Tools

These give you `git`, `make`, and a C++ compiler — everything below needs them.

```bash
xcode-select --install
```

A system dialog will pop up. Click through it and let it finish (a few minutes) before continuing to Step 2.

### Step 2 — cmake

**If you're on Apple Silicon** and already have (or are happy to install) Homebrew:

```bash
brew install cmake
```

**If you're on an Intel Mac**, Homebrew's installer refuses fresh installs as of September 2026. Install cmake directly instead, no package manager involved:

```bash
TMP_CMAKE="$(mktemp -d)"
curl -fL -o "$TMP_CMAKE/cmake.tar.gz" \
  "https://github.com/Kitware/CMake/releases/download/v3.30.3/cmake-3.30.3-macos-universal.tar.gz"
tar -xzf "$TMP_CMAKE/cmake.tar.gz" -C "$TMP_CMAKE"
# This step needs your Mac login password (for `sudo`) — that's expected.
sudo cp -R "$TMP_CMAKE/cmake-3.30.3-macos-universal/CMake.app/Contents/bin/"* /usr/local/bin/
sudo mkdir -p /usr/local/share
sudo cp -R "$TMP_CMAKE/cmake-3.30.3-macos-universal/CMake.app/Contents/share/cmake-3.30" /usr/local/share/
rm -rf "$TMP_CMAKE"
cmake --version   # should print a version number, not "command not found"
```

### Step 3 — whisper.cpp (speech-to-text)

```bash
git clone https://github.com/ggml-org/whisper.cpp.git ~/whisper.cpp
cd ~/whisper.cpp

# Pin to a known-good version rather than the constantly-moving "main"
# branch. Check https://github.com/ggml-org/whisper.cpp/releases for the
# current latest tag — as of Sept 2026 it's b4938 — and use that instead
# if it's newer:
git checkout b4938

cmake -B build -DGGML_METAL=OFF
cmake --build build --config Release

# Download the speech-recognition model (~140MB)
bash ./models/download-ggml-model.sh base.en
```

`-DGGML_METAL=OFF` is required — see [Known limits](#known-limits) for why.

`base.en` is the English-only version of the `base` model — smaller and faster to run than its multilingual counterpart, which matters on old, low-RAM hardware. See the [whisper.cpp model list](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md) for alternatives — just swap the name in the `download-ggml-model.sh` command above and update `WHISPER_MODEL` in `config.sh` to match.

### Step 4 — llama.cpp (note structuring)

```bash
git clone https://github.com/ggml-org/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp

# Same reasoning as Step 3 — check
# https://github.com/ggml-org/llama.cpp/releases for the current tag;
# as of Sept 2026 it's b10456.
git checkout b10456

cmake -B build -DGGML_METAL=OFF
cmake --build build --config Release

# Download the language model (~1.9GB — this is the slow step)
curl -fL -o ~/llama.cpp/llama-3.2-3b.gguf \
  "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
```

### Step 5 — ffmpeg (audio format conversion)

Needed to read anything that isn't already a `.wav` file — Voice Memos exports `.m4a`, for example.

**Apple Silicon with Homebrew:**

```bash
brew install ffmpeg
```

**Intel Macs**: install a static binary directly, from the same site the official ffmpeg.org downloads page itself links to for macOS.

```bash
curl -fLO https://evermeet.cx/ffmpeg/getrelease/zip
unzip -o zip -d /tmp/ffmpeg-extract
sudo cp /tmp/ffmpeg-extract/ffmpeg /usr/local/bin/ffmpeg
sudo chmod +x /usr/local/bin/ffmpeg
rm -rf zip /tmp/ffmpeg-extract
ffmpeg -version   # should print a version, not "command not found"
```

That `sudo` is placing a binary into a system folder (`/usr/local/bin`) — worth knowing what it's doing rather than pasting blind. See [Security](#security) for a note on verifying this download.

### Step 6 — Project files

```bash
mkdir -p ~/Stenographer/{inbox,processing,archive,failed,notes,logs,prompts,bin}

# Adjust this path if you cloned this repo somewhere other than ~/Downloads
REPO=~/Downloads/air-gapped-stenographer

cp "$REPO"/bin/*.sh ~/Stenographer/bin/
cp "$REPO"/prompts/*.txt ~/Stenographer/prompts/
chmod +x ~/Stenographer/bin/dictate.sh ~/Stenographer/bin/queue_watcher.sh
```

*(If you're setting this up from a fresh `git clone` of this repo rather than a downloaded folder, replace the `REPO=` line with wherever you cloned it.)*

### Step 7 — The background watcher

This fills in the `launchd` template with the real paths on your Mac and registers it as a background agent that watches `~/Stenographer/inbox` — from here on, dropping a file into that folder in Finder is all it takes, with no Terminal window open.

```bash
sed \
  -e "s#__STENO_BIN__#$HOME/Stenographer/bin#g" \
  -e "s#__STENO_INBOX__#$HOME/Stenographer/inbox#g" \
  -e "s#__STENO_LOGS__#$HOME/Stenographer/logs#g" \
  "$REPO/com.stenographer.watcher.plist" > ~/Library/LaunchAgents/com.stenographer.watcher.plist

launchctl unload ~/Library/LaunchAgents/com.stenographer.watcher.plist >/dev/null 2>&1
launchctl load -w ~/Library/LaunchAgents/com.stenographer.watcher.plist

# Confirm it's installed and idle (a "-" for PID is normal — it means
# "waiting", not "broken"):
launchctl list | grep stenographer
```

### Step 8 — Test it

Drag a short Voice Memo audio file into `~/Stenographer/inbox` using Finder. Within a couple of minutes, a structured `.md` note should appear in `~/Stenographer/notes`.

If it doesn't, see [Troubleshooting](#troubleshooting--known-gotchas).

## Using it day to day

Drop one or more audio files into `~/Stenographer/inbox`, any time. They queue up automatically and get processed one at a time, oldest first — drop in a whole day's recordings and let it work through them, including overnight.

- Structured notes land in `~/Stenographer/notes/`
- Successfully processed originals move to `~/Stenographer/archive/`
- Anything that failed moves to `~/Stenographer/failed/` — check `~/Stenographer/logs/` for why

To process a file in the Terminal instead of dropping it in the inbox (useful for picking a different prompt — see below):

```bash
~/Stenographer/bin/dictate.sh /path/to/audio.m4a --prompt meeting
```

## Editing prompts / adding your own

Three prompt templates are included in `~/Stenographer/prompts/`:

| Name | Produces |
|---|---|
| `general` (default) | Executive Summary, Core Insights & Key Themes, Action Items (if applicable) |
| `meeting` | Executive Summary, Decisions Made, Action Items (owner + deadline) |
| `interview` | Summary, Key Topics, Notable Quotes, Follow-up Questions |

The background watcher always uses `general`. To use a different one, run `dictate.sh` directly:

```bash
~/Stenographer/bin/dictate.sh /path/to/audio.m4a --prompt meeting
```

**To edit an existing template:** they're plain text files — open one in any text editor, change the prompt, and save.

**To add a new one:** create a new `.txt` file in `~/Stenographer/prompts/` and reference it by name (without `.txt`).

## Troubleshooting & known gotchas

**Homebrew won't install on Intel Macs.** Its fresh-install script (as of v7.0.0, September 2026) refuses to run on them at all. Existing Homebrew installs on Intel are downgraded to "Tier 3" (degraded support, no guaranteed pre-built packages) ahead of Intel support being removed entirely around September 2027. This guide avoids Homebrew entirely on Intel — see Steps 2 and 5 above.

**A second file dropped moments after the first one seems to just sit there.** This is a known `launchd` `WatchPaths` limitation — it can miss or merge file-change events that happen close together. The plist in this repo includes `StartInterval`, a 120-second timer sweep, as a safety net: even if that happens, the file gets picked up within two minutes.

**`ffmpeg: command not found`, but only when files are dropped automatically, not when run by hand.** Background jobs launched by `launchd` get a smaller `PATH` than Terminal does. `config.sh` already accounts for this — it only comes up if that line gets edited out.

**Don't call `llama-cli` directly from a script.** It renders an interactive chat display that redirecting with `>` can't capture. `dictate.sh` instead talks to `llama-server` over HTTP, which has no display and is fully scriptable — use `llama-cli` only if you want to chat with the model yourself, interactively.

## Known limits

- **Recording length:** the language model needs enough context to hold the entire transcript plus the note it writes. `LLAMA_CTX_SIZE` in `config.sh` defaults to 16384 tokens — by rough estimate (~150 spoken words/minute, ~1.3 tokens/word), that covers roughly a 60–75 minute recording. If `llama-server`'s log mentions context or the KV cache, the recording exceeded this — raise `LLAMA_CTX_SIZE` if you have RAM to spare, or lower it if the machine starts swapping heavily.
- **Queue ordering** is best-effort (oldest-first by file modification time), not a strict guarantee.
- **Single-file processing only**, by design — see [How it works](#how-it-works).

## Security

No secrets are stored anywhere in this project. A few things worth knowing before you run it:

- **No encryption at rest.** Notes, transcripts, and archived audio are stored as plain, unencrypted files under `~/Stenographer/`. Turn on [FileVault](https://support.apple.com/en-us/108837) (macOS's built-in full-disk encryption) if that matters to you — this pipeline doesn't provide it itself.
- **The local API has no login and must stay on localhost.** `llama-server` (used internally by `dictate.sh`) has no authentication at all. It's launched bound to `127.0.0.1` only, so nothing else on your network can reach it as shipped — don't add a `--host 0.0.0.0` or port-forward it without adding your own auth in front of it.
- **Pin what you build.** The setup step downloads and compiles code from third parties — pin to a tagged release rather than `main`, as shown above, rather than trusting a constantly-moving branch.

## Credits & attribution

This project is a thin layer of scripts (and a lot of testing) around other people's work, and wouldn't exist without it:

- **[whisper.cpp](https://github.com/ggml-org/whisper.cpp)** (MIT License) — the speech-to-text engine, a C/C++ port of OpenAI's Whisper model, by Georgi Gerganov and contributors.
- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** (MIT License) — the local language-model inference engine, also by Georgi Gerganov and contributors.
- **[Llama 3.2 3B Instruct](https://www.llama.com/llama3_2/license/)** — the language model itself, by Meta, under the Llama 3.2 Community License. That license requires displaying "Built with Llama" (included below) and, for anyone building on top of it, prefixing derivative model names with "Llama"; it does not restrict personal use like this project's. This repo never bundles or redistributes the model weights — the setup steps above download them directly from Meta's model, via a third-party GGUF conversion.
- **[GGUF quantization by bartowski](https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF)** — the specific pre-quantized file this guide downloads, credited per common convention for community model conversions.
- **[Static ffmpeg build for macOS by Helmut K. C. Tessarek (evermeet.cx)](https://evermeet.cx/ffmpeg/)** — used on Intel Macs where Homebrew is no longer an option. ffmpeg itself is licensed GPL/LGPL depending on build configuration.

**Built with Llama.**

If you build on this project and it includes or improves on the bundled language model, the same attribution requirement carries forward — see Meta's license linked above.

## License

The scripts and prompt templates in this repository (everything under `bin/` and `prompts/`, plus this README) are © 2026 Alice Mrongovius, licensed under the MIT License — see [`LICENSE`](LICENSE).

This license covers only the original scripts and documentation here. It does **not** cover, and this repo does not redistribute, the Whisper model, the Llama 3.2 model, or ffmpeg — each of those is downloaded directly from its own source under its own license, per the setup steps above.
