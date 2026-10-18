# Offset evidence (stock vendor build)

Source: `/var/lib/waydroid/images/vendor.img` read via
`patch_waydroid_audio.py --mode stock` on the tested host.
Provenance lines from the patcher confirm vendor image reads.

## Stock hashes

- `lib/hw/audio.primary.waydroid.so`: `cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2`
- `lib64/hw/audio.primary.waydroid.so`: `f44860755c9674289322cf1394477a1c840be312dc795a85b932ae98d487072d`
- `etc/audio_policy_configuration.xml`: `b649d92f3fd2d3a08630da296d5c9ddac39d6978780ff268446623f959585c7b`

## 64 bit disassembly (stock)

Excerpt from `objdump -d` on the extracted stock `lib64` HAL:

```text
317f: c7 83 80 01 00 00 02  movl $0x2,0x180(%rbx)      # file 0x2185 SND format
3197: 41 81 3f 80 bb 00 00  cmpl $0xbb80,(%r15)        # file 0x219A rate compare
31eb: 48 b8 80 bb 00 00 03  movabs $0x30000bb80,%rax   # file 0x21ED rate store
31f8: 41 c7 47 08 01 00 00  movl $0x1,0x8(%r15)        # file 0x21FC Android format
3218: 41 b8 80 bb 00 00     mov $0xbb80,%r8d           # file 0x221A log rate
321e: 41 b9 02 00 00 00     mov $0x2,%r9d              # file 0x2220 log SND
```

File `0x0D84` holds `80 bb 00 00` (48000) in `.rodata` as element 1 of
`[2, 48000, 1024, 4]`. The 16 byte vector at `0x0D80` is copied with
`movaps`/`movups` into the stream config, then format is set by the
immediate at `0x2185`.

## 32 bit disassembly (stock)

Excerpt from `objdump -d` on the extracted stock `lib` HAL:

```text
2d46: c7 86 b8 00 00 00 02  movl $0x2,0xb8(%esi)       # file 0x1D4C SND format
2d57: 81 3a 80 bb 00 00     cmpl $0xbb80,(%edx)        # file 0x1D59 rate compare
2da8: c7 02 80 bb 00 00     movl $0xbb80,(%edx)        # file 0x1DAA rate store
2dae: c7 42 08 01 00 00 00  movl $0x1,0x8(%edx)        # file 0x1DB1 Android format
2dcd: 68 80 bb 00 00        push $0xbb80               # file 0x1DCE log rate
2dd2: 6a 02                 push $0x2                 # file 0x1DD3 log SND (1 byte)
```

## How to regenerate

```bash
python3 patch_waydroid_audio.py --mode stock --output /tmp/wrs-evidence-stock
objdump -d /tmp/wrs-evidence-stock/vendor/lib64/hw/audio.primary.waydroid.so | grep -E "bb80|b8 80|b9 02|C7 47 08"
objdump -d /tmp/wrs-evidence-stock/vendor/lib/hw/audio.primary.waydroid.so | grep -E "bb80|68 80|6a 02|c7 86 b8"
python3 patch_waydroid_audio.py --mode 44k24 --output /tmp/wrs-evidence-44k24
# patched files must match OUTPUT_SHA256 in patch_waydroid_audio.py
```

If any line above differs on a new vendor image, do not update offsets
blindly. Treat it as an unsupported build until the full mapping is redone.
