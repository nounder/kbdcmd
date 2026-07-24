# Keyboard Command

Command your Mac by jumping between windows and buttons like a ninja.

`kbdcmd` enables to assign windows and application to most useless key on the keyboard: the right command. Take a breath here, and think for a moment: when was the last time you used it? When you start using `kbdcmd` you will use it **all the time**!


## Installation

```sh
# this will install and open the app
# you will need Xcode installed
make setup
```

After you enable Permissions, as prompted on startup, open "Kbdcmd" app Applications directory or Spotlight .

## Usage

<kbd>right command</kbd> + <kbd>`</kbd> to assign a key to an app.

<kbd>right command</kbd> + <kbd>shift</kbd> + <kbd>`</kbd> to assign a key to a window.

<kbd>right command</kbd> + <kbd>[key]</kbd> to focus or cycle through the apps under a `[key]`.

holding <kbd>right command</kbd> will show all running applications with their key assigned.

## Dictation

Local, offline speech-to-text powered by NVIDIA's Parakeet TDT v3 model (25 languages) running on the Apple Neural Engine via CoreML. No third-party frameworks; model weights are downloaded once (~500 MB) from Hugging Face.

- **Hold <kbd>fn</kbd>** and speak — release to transcribe and paste into the focused app. A small waveform dot shows while recording.
- **Double-tap <kbd>fn</kbd>** for a hands-free session with live transcription in the overlay — press <kbd>fn</kbd> again to insert, <kbd>esc</kbd> to discard.

Setup:

```sh
# download the model up front (otherwise it downloads on first use)
kbdcmd dictation download

# test the pipeline on an audio file
kbdcmd dictation transcribe recording.wav
```

Recommended: set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**, so the emoji picker or Apple Dictation don't fight over the key. Microphone permission is requested on first use; dictation works best from the Kbdcmd app (the bare CLI daemon can't reliably prompt for mic access). Fn combos (<kbd>fn</kbd>+arrows etc.) pass through untouched.

The model loads once (at app launch when already downloaded) and stays in memory. Settings (menu bar → Settings) has the dictation on/off switch and the model download; `kbdcmd dictation status` shows the model cache state.



