#!/usr/bin/env python3
"""Build checksum-guarded Waydroid audio overlays for lossless switching.

Modes:
  stock : 48kHz 16-bit (factory, removes overlay)
  48k16 : 48kHz 16-bit (explicit overlay, same bytes as stock)
  48k24 : 48kHz 24-bit (S24_LE / PCM_8_24_BIT)
  44k16 : 44.1kHz 16-bit
  44k24 : 44.1kHz 24-bit (S24_LE / PCM_8_24_BIT)

Reads the stock blobs from the vendor image via debugfs (falls back to
the mounted rootfs), applies byte-exact patches, and writes an overlay
tree + manifest. Refuses to build if the base image hashes do not match
the tested Waydroid build.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

# Stock hashes (tested Waydroid 1.6.2, Android 13 MAINLINE x86_64)
SOURCE_SHA256 = {
    "lib/hw/audio.primary.waydroid.so": "cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2",
    "lib64/hw/audio.primary.waydroid.so": "f44860755c9674289322cf1394477a1c840be312dc795a85b932ae98d487072d",
}
POLICY_PATH = "etc/audio_policy_configuration.xml"
POLICY_SOURCE_SHA256 = "b649d92f3fd2d3a08630da296d5c9ddac39d6978780ff268446623f959585c7b"

# Canonical expected outputs per mode. This table is the single source of
# truth for status classification. The shell script keeps a copy for fast
# local checks, and tests/test_patch.py asserts the two copies match.
# Update this table first when adding a vendor build, then sync the shell.
OUTPUT_SHA256 = {
    "stock": {
        "lib/hw/audio.primary.waydroid.so": "cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2",
        "lib64/hw/audio.primary.waydroid.so": "f44860755c9674289322cf1394477a1c840be312dc795a85b932ae98d487072d",
        "etc/audio_policy_configuration.xml": "b649d92f3fd2d3a08630da296d5c9ddac39d6978780ff268446623f959585c7b",
    },
    "48k16": {
        "lib/hw/audio.primary.waydroid.so": "cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2",
        "lib64/hw/audio.primary.waydroid.so": "f44860755c9674289322cf1394477a1c840be312dc795a85b932ae98d487072d",
        "etc/audio_policy_configuration.xml": "b649d92f3fd2d3a08630da296d5c9ddac39d6978780ff268446623f959585c7b",
    },
    "48k24": {
        "lib/hw/audio.primary.waydroid.so": "8d4077ffe3bde575afc9f869439a76c367efe1278c36e4168849984fb5151ae2",
        "lib64/hw/audio.primary.waydroid.so": "b342600d08c817216a17dece75bb671d6bf92923d6acb50305ffad357d78cfe7",
        "etc/audio_policy_configuration.xml": "2da7843566702955222af4879b5af576b0b7d00fa6086fc16f98050c882a7aec",
    },
    "44k16": {
        "lib/hw/audio.primary.waydroid.so": "a554a4015bcf5c28b1d56d3f0334e4cd1e4d16a802b57335dbe9dfb75243d13f",
        "lib64/hw/audio.primary.waydroid.so": "ad234c89f9656d0d8cd203cfe635738525dc286fd2caa8c77a7c2aec909dbee0",
        "etc/audio_policy_configuration.xml": "ca1042fcb31ebb82dfdeee5f0558f7d6aae78c8e0dc1f2e9f71ecf1bc7d67c33",
    },
    "44k24": {
        "lib/hw/audio.primary.waydroid.so": "8f2048edb98855923f8ec91a4de2a1f8a2d8e21e5ed3fe5bc31f248507c8983d",
        "lib64/hw/audio.primary.waydroid.so": "766059256fad695b5a684abb638385f7a1ef1735cff2a7ba31c87a3452351851",
        "etc/audio_policy_configuration.xml": "0b80b00ec79ce4088e8747d0d9e814305df63f375a198103a67affd6c002db12",
    },
}

# Byte constants (little-endian)
RATE_48K = "80bb0000"   # 48000
RATE_44K = "44ac0000"   # 44100
SND_S16 = "02000000"    # SND_PCM_FORMAT_S16_LE (old ALSA enum = 2)
SND_S24 = "06000000"    # SND_PCM_FORMAT_S24_LE (old enum = 6)
AND_16 = "01000000"     # AUDIO_FORMAT_PCM_16_BIT = 1
AND_24 = "04000000"     # AUDIO_FORMAT_PCM_8_24_BIT = 4

# File offsets (from hires project, verified against disassembly)
# lib64: .rodata rate, text SND, text rate-cmp, text rate-movabs,
#        text Android fmt, text log-rate, text log-SND
OFFSETS_64 = [0x0D84, 0x2185, 0x219A, 0x21ED, 0x21FC, 0x221A, 0x2220]
# lib32: same logical set, last log-SND is a 1-byte push imm
OFFSETS_32 = [0x0894, 0x1D4C, 0x1D59, 0x1DAA, 0x1DB1, 0x1DCE, 0x1DD3]

POLICY_OLD = (
    b'format="AUDIO_FORMAT_PCM_16_BIT"\n'
    b'                             samplingRates="48000" '
    b'channelMasks="AUDIO_CHANNEL_OUT_STEREO"'
)
POLICY_48K16 = POLICY_OLD  # explicit 48k16 overlay, same bytes as stock
POLICY_48K24 = (
    b'format="AUDIO_FORMAT_PCM_8_24_BIT"\n'
    b'                             samplingRates="48000" '
    b'channelMasks="AUDIO_CHANNEL_OUT_STEREO"'
)
POLICY_44K16 = (
    b'format="AUDIO_FORMAT_PCM_16_BIT"\n'
    b'                             samplingRates="44100" '
    b'channelMasks="AUDIO_CHANNEL_OUT_STEREO"'
)
POLICY_44K24 = (
    b'format="AUDIO_FORMAT_PCM_8_24_BIT"\n'
    b'                             samplingRates="44100" '
    b'channelMasks="AUDIO_CHANNEL_OUT_STEREO"'
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract(vendor_image: Path, relative: str, allow_fallback: bool = False) -> bytes:
    if str(vendor_image).startswith("-"):
        raise ValueError(f"Refusing path starting with dash: {vendor_image}")
    try:
        r = subprocess.run(
            ["debugfs", "-R", f"cat /{relative}", str(vendor_image)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            timeout=30)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"debugfs timed out reading /{relative}: {e}")
    if r.returncode == 0 and r.stdout.lstrip()[:4] != b"debug":
        # debugfs prints "debugfs 1.xx" to stdout on some versions when
        # reading fails; guard by checking ELF/XML magic
        if r.stdout[:4] == b"\x7fELF" or r.stdout[:5] == b"<?xml":
            print(f"extract: {relative} from vendor image", file=sys.stderr)
            return r.stdout
        # debugfs may prepend nothing; if output looks binary and long enough, accept
        if len(r.stdout) > 1000:
            print(f"extract: {relative} from vendor image (unverified magic)", file=sys.stderr)
            return r.stdout
    # Fallback reads the live mounted tree, which may already contain an
    # overlay, so it is opt-in and always logged.
    if not allow_fallback:
        raise RuntimeError(
            f"Could not read /{relative} from vendor image: "
            f"{r.stderr.decode().strip()}. "
            "Pass --allow-rootfs-fallback only for debugging.")
    fallback = Path("/var/lib/waydroid/rootfs/vendor") / relative
    if fallback.is_file():
        print(f"extract: {relative} from rootfs fallback (may include overlay)", file=sys.stderr)
        return fallback.read_bytes()
    raise RuntimeError(f"Could not read /{relative}: {r.stderr.decode().strip()}")


def edits_for(mode: str, is64: bool) -> dict[int, tuple[str, str]]:
    if mode in ("stock", "48k16"):
        return {}
    if mode == "48k24":
        rate_old, rate_new = RATE_48K, RATE_48K  # rate unchanged
        snd_old, snd_new = SND_S16, SND_S24
        and_old, and_new = AND_16, AND_24
    elif mode == "44k16":
        rate_old, rate_new = RATE_48K, RATE_44K
        snd_old, snd_new = SND_S16, SND_S16  # format unchanged
        and_old, and_new = AND_16, AND_16
    elif mode == "44k24":
        rate_old, rate_new = RATE_48K, RATE_44K
        snd_old, snd_new = SND_S16, SND_S24
        and_old, and_new = AND_16, AND_24
    else:
        raise ValueError(f"unknown mode {mode}")

    offs = OFFSETS_64 if is64 else OFFSETS_32
    # Order: [rodata-rate, SND, rate-cmp, rate-movabs, Android, log-rate, log-SND]
    edits: dict[int, tuple[str, str]] = {}
    # rodata rate
    edits[offs[0]] = (rate_old, rate_new)
    # SND format (4 bytes, except 32-bit log which is 1 byte handled below)
    edits[offs[1]] = (snd_old, snd_new)
    edits[offs[2]] = (rate_old, rate_new)
    edits[offs[3]] = (rate_old, rate_new)
    edits[offs[4]] = (and_old, and_new)
    edits[offs[5]] = (rate_old, rate_new)
    # log SND: 4 bytes on 64-bit, 1 byte on 32-bit
    if is64:
        edits[offs[6]] = (snd_old, snd_new)
    else:
        # single-byte push: "02" -> "06"
        edits[offs[6]] = (snd_old[:2], snd_new[:2])
    # Drop no-op edits (old == new) so stock-rate modes don't touch those bytes
    return {k: v for k, v in edits.items() if v[0] != v[1]}


def patch_binary(relative: str, source: bytes, mode: str) -> bytes:
    exp = SOURCE_SHA256[relative]
    if sha256(source) != exp:
        raise ValueError(
            f"Unsupported {relative}: expected {exp}, found {sha256(source)}. "
            "Update Waydroid images first / re-verify offsets.")
    is64 = "lib64" in relative
    edits = edits_for(mode, is64)
    data = bytearray(source)
    for off, (exp_hex, new_hex) in sorted(edits.items()):
        exp_b = bytes.fromhex(exp_hex)
        new_b = bytes.fromhex(new_hex)
        if len(exp_b) != len(new_b):
            raise ValueError(f"Patch length mismatch at 0x{off:x}")
        act = bytes(data[off:off+len(exp_b)])
        if act != exp_b:
            raise ValueError(
                f"Unexpected bytes at 0x{off:x} in {relative}: "
                f"expected {exp_b.hex()}, found {act.hex()}")
        data[off:off+len(exp_b)] = new_b
    return bytes(data)


def patch_policy(source: bytes, mode: str) -> bytes:
    if sha256(source) != POLICY_SOURCE_SHA256:
        raise ValueError(
            f"Unsupported {POLICY_PATH}: expected {POLICY_SOURCE_SHA256}, "
            f"found {sha256(source)}")
    if source.count(POLICY_OLD) != 1:
        raise ValueError("Could not find the expected primary output profile")
    if mode in ("stock", "48k16"):
        return source
    new = {
        "48k24": POLICY_48K24,
        "44k16": POLICY_44K16,
        "44k24": POLICY_44K24,
    }[mode]
    return source.replace(POLICY_OLD, new, 1)


def build(vendor_image: Path, output: Path, mode: str, allow_fallback: bool = False) -> dict[str, object]:
    if mode not in ("stock", "48k16", "48k24", "44k16", "44k24"):
        raise ValueError(f"unknown mode {mode}")
    if mode not in OUTPUT_SHA256:
        raise ValueError(f"no expected output table entry for mode {mode}")
    blobs: dict[str, bytes] = {}
    for rel in SOURCE_SHA256:
        blobs[rel] = patch_binary(rel, extract(vendor_image, rel, allow_fallback), mode)
    blobs[POLICY_PATH] = patch_policy(extract(vendor_image, POLICY_PATH, allow_fallback), mode)
    expected = OUTPUT_SHA256[mode]
    for rel, data in blobs.items():
        got = sha256(data)
        if got != expected[rel]:
            raise ValueError(
                f"Output hash mismatch for {rel} in mode {mode}: "
                f"got {got}, expected {expected[rel]}. "
                "Offsets and shell tables need review.")

    manifest: dict[str, object] = {"mode": mode}
    for rel, data in blobs.items():
        dest = output / "vendor" / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        dest.chmod(0o644)
        manifest[rel] = {"sha256": sha256(data)}
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=["stock", "48k16", "48k24", "44k16", "44k24"], required=True)
    p.add_argument("--vendor-image", type=Path,
                   default=Path("/var/lib/waydroid/images/vendor.img"))
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--allow-rootfs-fallback", action="store_true",
                   help="Allow reading from the live rootfs when debugfs fails (debugging only)")
    p.add_argument("--dump-shell-hashes", action="store_true",
                   help="Print HASH_* assignments for the shell status check and exit")
    return p.parse_args()


def print_shell_hashes() -> None:
    names = {
        ("stock", "lib/hw/audio.primary.waydroid.so"): "HASH_STOCK_32",
        ("stock", "lib64/hw/audio.primary.waydroid.so"): "HASH_STOCK_64",
        ("stock", "etc/audio_policy_configuration.xml"): "HASH_STOCK_XML",
        ("48k16", "lib/hw/audio.primary.waydroid.so"): "HASH_48K16_32",
        ("48k16", "lib64/hw/audio.primary.waydroid.so"): "HASH_48K16_64",
        ("48k16", "etc/audio_policy_configuration.xml"): "HASH_48K16_XML",
        ("48k24", "lib/hw/audio.primary.waydroid.so"): "HASH_48K24_32",
        ("48k24", "lib64/hw/audio.primary.waydroid.so"): "HASH_48K24_64",
        ("48k24", "etc/audio_policy_configuration.xml"): "HASH_48K24_XML",
        ("44k16", "lib/hw/audio.primary.waydroid.so"): "HASH_44K16_32",
        ("44k16", "lib64/hw/audio.primary.waydroid.so"): "HASH_44K16_64",
        ("44k16", "etc/audio_policy_configuration.xml"): "HASH_44K16_XML",
        ("44k24", "lib/hw/audio.primary.waydroid.so"): "HASH_44K24_32",
        ("44k24", "lib64/hw/audio.primary.waydroid.so"): "HASH_44K24_64",
        ("44k24", "etc/audio_policy_configuration.xml"): "HASH_44K24_XML",
    }
    for (mode, rel), var in sorted(names.items(), key=lambda kv: kv[1]):
        print(f"{var}={OUTPUT_SHA256[mode][rel]}")


def main() -> int:
    a = parse_args()
    if a.dump_shell_hashes:
        print_shell_hashes()
        return 0
    try:
        m = build(a.vendor_image, a.output, a.mode,
                  allow_fallback=a.allow_rootfs_fallback)
    except (FileNotFoundError, OSError, RuntimeError, ValueError) as e:
        print(f"Refusing to build the overlay: {e}")
        return 1
    for k, v in sorted(m.items()):
        print(f"{k}: {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
