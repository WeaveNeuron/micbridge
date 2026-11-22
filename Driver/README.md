# MicBridge Microphone

A virtual microphone for macOS: an AudioServerPlugIn (HAL plug-in) that
Core Audio loads from `/Library/Audio/Plug-Ins/HAL`. Apps on this Mac record
from it; MicBridge writes the other Mac's microphone into it. It is the
only device MicBridge writes into.

| | |
|---|---|
| Device | “MicBridge Microphone”, UID `MicBridgeMicrophone_UID`, transport virtual |
| Streams | one input (what apps record), one output (what MicBridge writes) |
| Format | 48 kHz, 2 channels, 32-bit float, interleaved; nothing else is offered |
| Defaults | may be the default input; never the default output or alert device |
| Bundle | `MicBridgeMicrophone.driver`, ID `com.weaveneuron.MicBridge.Microphone`, version = `bundledDriverVersion` (Source/Domain/DriverStatus.swift) |

## How it works

- A 16384-frame ring buffer. Core Audio's mixed output for sample time T is
  written at T; input for sample time T reads it back. Input clears what it
  read, so once MicBridge stops writing, apps hear silence rather than the
  last stretch of sound repeating.
- The clock is the host clock: one zero time stamp per ring period.
- While any client runs IO the device is running, so Core Audio reports
  `kAudioDevicePropertyDeviceIsRunningSomewhere`. MicBridge uses that as its
  "an app is listening" signal.
- No controls, no stored settings, no files, no network.

Written from `<CoreAudio/AudioServerPlugIn.h>` only.

## Building and testing

`build.sh` compiles `MicBridgeMicrophone.c` with `-Wall -Wextra -Werror`,
fills in `Info.plist`, signs the bundle (Developer ID builds: hardened runtime and a timestamp) and puts it in
`MicBridge.app/Contents/PlugIns/`. Building installs nothing.

`MicBridge --self-test` loads that copy into its own process (`dlopen`)
and drives it the way Core Audio would, through a stand-in host:
properties, formats, the fixed rate, start/stop, the clock, and audio
written then read back once. coreaudiod never sees it.

## Installing

Installing always asks twice: MicBridge first explains what will happen
and the user confirms; then macOS asks for an administrator password.
MicBridge offers it in three places, only by a click:

- onboarding, when this Mac will use another Mac's microphone and has no
  virtual microphone;
- the panel, when the bridge stopped for want of one (“Install Virtual
  Microphone…”);
- Settings › Virtual microphone driver: install, update, reload, remove.

Behind the confirmation, the app runs its bundled `install-driver.sh` with
`do shell script … with administrator privileges`. The script checks the
bundle's name and signature, copies it into `/Library/Audio/Plug-Ins/HAL`
(replacing an older copy in one step), sets root:wheel ownership and
restarts coreaudiod. Sound on the Mac stops for a few seconds.

By hand, from the repository after `./build.sh`:

```sh
sudo /bin/sh Driver/install-driver.sh install MicBridge.app/Contents/PlugIns/MicBridgeMicrophone.driver
sudo /bin/sh Driver/install-driver.sh uninstall
```

The self-test runs the script too, but only into a scratch folder with
`--dest … --no-restart`, which the script refuses when run as root.
