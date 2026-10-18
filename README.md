# Waydroid Sample Rate Switch

Switch the Waydroid primary audio link between common sample rates and bit depths.

Stock Waydroid hardcodes its host audio link to 48 kHz 16 bit. This project
builds a checksum guarded overlay from your own vendor image to select
48 kHz or 44.1 kHz at 16 bit or 24 bit, and locks PipeWire to match.
Switching is manual. Pick the mode that matches the content you play.

No binaries are stored in this repo. The patcher reads your installed
`vendor.img` and refuses to build if the hashes do not match a tested build.

## Modes

| Mode   | Rate    | Depth  | PipeWire lock | Notes                                  |
| ------ | ------- | ------ | ------------- | -------------------------------------- |
| 48k16  | 48000   | 16 bit | 48000         | Explicit overlay, same bytes as stock  |
| 48k24  | 48000   | 24 bit | 48000         | 24 bit in 32 bit word                  |
| 44k16  | 44100   | 16 bit | 44100         | CD rate                                 |
| 44k24  | 44100   | 24 bit | 44100         | 24 bit in 32 bit word                  |
| stock  | 48000   | 16 bit | removed       | Removes overlay and PipeWire locks     |
| status | -       | -      | -             | Shows overlay, PipeWire, Waydroid state |

Depth note: 24 bit modes use `SND_PCM_FORMAT_S24_LE` with
`AUDIO_FORMAT_PCM_8_24_BIT`. A 24 bit link carries 16 bit content without
loss by padding. A 16 bit link truncates 24 bit content. For mixed depth at
one rate, prefer the 24 bit mode.

Rate note: one primary HAL supports one rate at a time. Mixed 44100 plus
48000 content cannot both pass without a resample. Pick the majority rate
or split material by rate.

## Requirements

- Linux with Waydroid installed and initialized
- `waydroid`, `python3`, `debugfs`, `findmnt`, `pactl`, `pw-top`, `pw-metadata`
- `sudo` access for overlay install and container control
- PipeWire with WirePlumber, or PulseAudio on PipeWire

Tested with:

- Waydroid 1.6.2, Android 13 MAINLINE x86_64 GAPPS image
- PipeWire 1.6.2, WirePlumber 0.5.x
- x86_64 host with a USB DAC

Other vendor builds are rejected by hash check until their offsets are added.

## Files

- `waydroid-sample-rate.sh` - main script
- `patch_waydroid_audio.py` - checksum guarded patch builder
- `pipewire/pipewire-44100.conf` - locked graph template for 44100
- `pipewire/pipewire-48000.conf` - locked graph template for 48000
- `LICENSE` - MIT license
- `tests/test_patch.py` - stdlib unit tests, no Waydroid needed
- `docs/offset-evidence.md` - disassembly excerpts for the patched offsets
- `.github/workflows/smoke.yml` - bash syntax, compile, and test check

## Usage

Run as your desktop user. Do not run the whole script with `sudo`.
It calls `sudo` only for overlay and container steps.

```bash
chmod +x waydroid-sample-rate.sh patch_waydroid_audio.py
./waydroid-sample-rate.sh 44k16
./waydroid-sample-rate.sh 44k24
./waydroid-sample-rate.sh 48k16
./waydroid-sample-rate.sh 48k24
./waydroid-sample-rate.sh stock
./waydroid-sample-rate.sh status
```

Each switch does this:

1. Checks `sudo` up front, then builds the overlay to a temp dir from `/var/lib/waydroid/images/vendor.img`. The patcher asserts both input and output hashes.
2. Backs up existing overlay and PipeWire files under `~/.local/state/waydroid-sample-rate-switch/backups/<timestamp>`.
3. Refuses when overlay files contain unknown bytes unless `--force` is given. Use `./waydroid-sample-rate.sh --force <mode>` only to replace another tool's overlay on purpose.
4. Stops the Waydroid session and container, waiting for the rootfs to unmount.
5. Installs or removes these overlay files:
   - `/var/lib/waydroid/overlay/vendor/lib/hw/audio.primary.waydroid.so`
   - `/var/lib/waydroid/overlay/vendor/lib64/hw/audio.primary.waydroid.so`
   - `/var/lib/waydroid/overlay/vendor/etc/audio_policy_configuration.xml`
6. Verifies installed bytes against `manifest.json` before touching audio services.
7. For rate modes, writes PipeWire locks:
   - `~/.config/pipewire/pipewire.conf.d/10-clock-rate.conf`
   - `~/.config/pipewire/pipewire-pulse.conf.d/10-clock-rate.conf`
   For `stock`, removes both locks to restore factory behavior.
8. Restarts `pipewire.service`, `pipewire-pulse.service`, `wireplumber.service` and polls `pw-metadata` for the expected rate.

Then start Waydroid again:

```bash
waydroid session start
```

Play audio in Android and verify with `status`.

## Verification

While audio is playing:

```bash
./waydroid-sample-rate.sh status
pw-top
pactl list sinks | grep -E "Name:|Sample Specification"
pactl list sink-inputs | grep -E "media.name|Sample|Format"
```

Expected:

- `pw-top` Waydroid row `RATE` matches the mode (`44100` or `48000`)
- DAC sink `Sample Specification` matches the same rate
- `status` reports the same mode you selected

Android side, with container access:

```bash
sudo waydroid shell dumpsys media.audio_flinger | grep -A150 "AudioOut_D" | grep -B2 -A20 "Tracks"
sudo waydroid shell dumpsys media.audio_flinger | grep -E "Sample rate|HAL format|Master volume|Effect Chains"
```

Look for:

- `Sample rate` equal to the mode rate
- `HAL format 0x1` for 16 bit modes, `0x4` for 24 bit modes
- Track `SRate` equal to HAL rate (no AudioFlinger resample)
- `0 Effect Chains`, `Master volume 1.0` for a clean path

If the track rate stays fixed while you change HAL rate, the app outputs
a fixed rate and the 44.1 kHz modes will not help that app.

## How it works

Upstream `audio/audio_hw.c` in `android_hardware_waydroid` sets:

```c
out->config.rate = 48000;
out->config.format = SND_PCM_FORMAT_S16_LE;
```

and the stock policy advertises only `PCM_16_BIT` at `48000`.
AudioFlinger therefore mixes everything to that format.

The patcher changes the rate and format immediates in both HAL libraries
and rewrites the single primary profile in the policy. Offsets were found
with `objdump -d` and cover rate compare, rate store, SND format, Android
format, and log arguments:

- 64 bit: `0x0D84, 0x2185, 0x219A, 0x21ED, 0x21FC, 0x221A, 0x2220`
- 32 bit: `0x0894, 0x1D4C, 0x1D59, 0x1DAA, 0x1DB1, 0x1DCE, 0x1DD3`

Byte values use the old ALSA enum in this HAL: `02` is `S16_LE`,
`06` is `S24_LE`. Android values: `01` is `PCM_16_BIT`,
`04` is `PCM_8_24_BIT`. Rates: `80bb0000` is 48000, `44ac0000` is 44100.

The Waydroid overlay mount makes these files override `vendor.img`
without modifying the image. PipeWire locking keeps the host graph at the
same rate so the DAC does not see a second resample. The same lock content
is written to both `pipewire.conf.d` and `pipewire-pulse.conf.d` for
consistency. Whether the pulse server honors these clock keys identically
is not proven from this repo alone. Confirm with the `pw-top` and `pactl`
matrix above on your host before treating the pulse copy as required.

## Limitations

- Manual switching only. There is no automatic rate following.
- Primary mixer path only. There is no `DIRECT` or offload output, so
  playback still passes the AudioFlinger mixer. Apps that do not follow
  the HAL rate will still be resampled by Android.
- While locked, other desktop apps are resampled into the locked graph.
- Hash guarded to one vendor build family. Unknown images are refused.
- Volume and mute still apply. Keep Android music at maximum and control
  listening level on the host or DAC for the cleanest path.

## Testing

```bash
python3 -m unittest discover -s tests -v
bash tests/test_shell.sh
bash -n waydroid-sample-rate.sh
python3 -m py_compile patch_waydroid_audio.py
```

Tests cover edit tables per mode and arch, synthetic patch round trips
including refusal on wrong bytes, policy rewrites, build manifest schema,
and shell hash sync between `patch_waydroid_audio.py OUTPUT_SHA256` and the `HASH_*` block in
`waydroid-sample-rate.sh`. Shell harness `tests/test_shell.sh` covers the
verifier pass and corrupt cases, PipeWire exit codes, and foreign overlay
refuse logic with stubbed `sudo`, `systemctl`, and `pw-metadata`. CI runs the same commands on push.

## Troubleshooting

- Patcher refuses: the vendor image does not match tested hashes. Run
  `stock`, update Waydroid, then check for a project update. Do not force
  unknown offsets.
- Rootfs still mounted: run `sudo waydroid container stop`, confirm with
  `findmnt /var/lib/waydroid/rootfs`, then retry.
- No Waydroid stream in `pactl` while the app says playing: restart the
  session with `waydroid session stop` and `waydroid session start`.
- DAC stays at the old rate: confirm `status` shows the new PipeWire lock
  and that `pw-metadata -n settings` lists the expected `clock.rate`.
- Mixed playlists: see rate and depth notes under Modes. Split by rate
  for exact matching.

## Updates and uninstall

Remove the overlay before Waydroid image updates:

```bash
./waydroid-sample-rate.sh stock
```

Update Waydroid, then select the mode again. `stock` already removes both
the overlay and the PipeWire locks. Backups from each run stay under
`~/.local/state/waydroid-sample-rate-switch/backups/` if you need to
restore a prior file manually.

## Contributing

To support a new vendor build:

1. Record `sha256sum` for both HAL libraries and the policy XML
2. Locate the same rate and format immediates with `objdump -d`
3. Add a new hash and offset set to `patch_waydroid_audio.py`
4. Test all four modes with `status`, `pw-top`, and `dumpsys`

## License

MIT. See `LICENSE`.
