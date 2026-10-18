"""Regression tests for the patch builder.

Run with: python3 -m unittest discover -s tests -v
No Waydroid install required. Real vendor bytes are never stored here.
Synthetic blobs stand in for the image; hash constants are monkeypatched
per test so the real SOURCE_SHA256 table is never weakened.
"""
import hashlib
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import patch_waydroid_audio as P


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def synthetic_blob(fill: int = 0x3000) -> bytearray:
    return bytearray(b"\x00" * fill)


def seed_blob(data: bytearray, edits: dict) -> bytes:
    for off, (exp_hex, _new_hex) in edits.items():
        exp = bytes.fromhex(exp_hex)
        data[off:off + len(exp)] = exp
    return bytes(data)


class TestEditsFor(unittest.TestCase):
    def test_stock_and_48k16_have_no_edits(self):
        for is64 in (True, False):
            self.assertEqual(P.edits_for("stock", is64), {})
            self.assertEqual(P.edits_for("48k16", is64), {})

    def test_48k24_touches_only_format_sites(self):
        e64 = P.edits_for("48k24", True)
        self.assertEqual(len(e64), 3)
        self.assertIn(0x2185, e64)
        self.assertIn(0x21FC, e64)
        self.assertIn(0x2220, e64)

    def test_44k16_touches_only_rate_sites(self):
        e64 = P.edits_for("44k16", True)
        self.assertEqual(len(e64), 4)
        for off in (0x0D84, 0x219A, 0x21ED, 0x221A):
            self.assertIn(off, e64)

    def test_44k24_touches_all_sites(self):
        self.assertEqual(len(P.edits_for("44k24", True)), 7)
        self.assertEqual(len(P.edits_for("44k24", False)), 7)

    def test_32bit_log_edit_is_single_byte(self):
        e32 = P.edits_for("48k24", False)
        self.assertIn(0x1DD3, e32)
        old, new = e32[0x1DD3]
        self.assertEqual((old, new), ("02", "06"))
        self.assertEqual(len(bytes.fromhex(old)), 1)


class TestPatchBinary(unittest.TestCase):
    def _with_synthetic_source(self, mode, is64):
        edits = P.edits_for(mode, is64)
        # Seed every known offset with its expected old bytes so the
        # per-site check passes; size covers the largest offset.
        size = max(P.OFFSETS_64 + P.OFFSETS_32) + 16
        blob = synthetic_blob(size)
        # Seed all offsets that this mode will check.
        seed_blob(blob, edits)
        # Also seed no-op sites? Not needed; only checked sites matter.
        rel = "lib64/hw/audio.primary.waydroid.so" if is64 else "lib/hw/audio.primary.waydroid.so"
        return rel, bytes(blob)

    def test_applies_edits(self):
        orig_source = P.SOURCE_SHA256.copy()
        try:
            for mode, is64 in (("48k24", True), ("44k16", True), ("44k24", False)):
                rel, src = self._with_synthetic_source(mode, is64)
                P.SOURCE_SHA256[rel] = sha(src)
                out = P.patch_binary(rel, src, mode)
                edits = P.edits_for(mode, is64)
                for off, (_old_hex, new_hex) in edits.items():
                    new = bytes.fromhex(new_hex)
                    self.assertEqual(out[off:off + len(new)], new)
        finally:
            P.SOURCE_SHA256.update(orig_source)

    def test_refuses_wrong_hash(self):
        with self.assertRaises(ValueError):
            P.patch_binary("lib64/hw/audio.primary.waydroid.so", b"too short", "48k24")

    def test_refuses_unexpected_bytes(self):
        rel = "lib64/hw/audio.primary.waydroid.so"
        edits = P.edits_for("48k24", True)
        size = max(P.OFFSETS_64) + 16
        blob = synthetic_blob(size)
        seed_blob(blob, edits)
        # Corrupt one site.
        blob[0x2185] ^= 0xFF
        src = bytes(blob)
        orig = P.SOURCE_SHA256[rel]
        try:
            P.SOURCE_SHA256[rel] = sha(src)
            with self.assertRaises(ValueError):
                P.patch_binary(rel, src, "48k24")
        finally:
            P.SOURCE_SHA256[rel] = orig


class TestPatchPolicy(unittest.TestCase):
    def _synthetic_policy(self):
        prefix = b"<mixPort>" * 10
        suffix = b"</mixPort>" * 10
        return prefix + P.POLICY_OLD + suffix

    def test_rewrites_each_mode(self):
        src = self._synthetic_policy()
        orig = P.POLICY_SOURCE_SHA256
        try:
            P.POLICY_SOURCE_SHA256 = sha(src)
            self.assertEqual(P.patch_policy(src, "stock"), src)
            self.assertEqual(P.patch_policy(src, "48k16"), src)
            for mode, marker in (
                ("48k24", b'PCM_8_24_BIT"\n                             samplingRates="48000"'),
                ("44k16", b'PCM_16_BIT"\n                             samplingRates="44100"'),
                ("44k24", b'PCM_8_24_BIT"\n                             samplingRates="44100"'),
            ):
                out = P.patch_policy(src, mode)
                self.assertIn(marker, out)
                self.assertNotIn(P.POLICY_OLD, out)
        finally:
            P.POLICY_SOURCE_SHA256 = orig

    def test_refuses_missing_profile(self):
        orig = P.POLICY_SOURCE_SHA256
        try:
            bad = b"<empty/>"
            P.POLICY_SOURCE_SHA256 = sha(bad)
            with self.assertRaises(ValueError):
                P.patch_policy(bad, "48k24")
        finally:
            P.POLICY_SOURCE_SHA256 = orig


class TestBuild(unittest.TestCase):
    def _install_synthetic_image(self):
        # Build synthetic sources that satisfy the real per-site checks,
        # then point the module hash tables at them.
        size = max(P.OFFSETS_64 + P.OFFSETS_32) + 16
        sources = {}
        for rel, offs in (("lib/hw/audio.primary.waydroid.so", P.OFFSETS_32),
                           ("lib64/hw/audio.primary.waydroid.so", P.OFFSETS_64)):
            blob = synthetic_blob(size)
            # Roles by position: [rate, SND, rate, rate, Android, rate, SND]
            roles = [P.RATE_48K, P.SND_S16, P.RATE_48K, P.RATE_48K,
                     P.AND_16, P.RATE_48K, P.SND_S16]
            for off, old_hex in zip(offs, roles):
                old = bytes.fromhex(old_hex)
                blob[off:off + len(old)] = old
            # 32-bit log site is 1 byte; trim the seeded 4 byte value.
            if rel.startswith("lib/hw"):
                blob[offs[6] + 1:offs[6] + 4] = b"\x00\x00\x00"
                # Restore zero fill beyond the single byte (already zero).
            sources[rel] = bytes(blob)
        # Synthetic policy containing exactly one OLD profile.
        policy = b"<root>" + P.POLICY_OLD + b"</root>"
        return sources, policy

    def test_build_writes_manifest_schema_and_outputs(self):
        import tempfile
        sources, policy = self._install_synthetic_image()
        orig_src, orig_pol = P.SOURCE_SHA256.copy(), P.POLICY_SOURCE_SHA256
        orig_out = {m: dict(v) for m, v in P.OUTPUT_SHA256.items()}
        orig_extract = P.extract
        try:
            for rel, data in sources.items():
                P.SOURCE_SHA256[rel] = sha(data)
            P.POLICY_SOURCE_SHA256 = sha(policy)
            by_rel = dict(sources)
            by_rel[P.POLICY_PATH] = policy

            def fake_extract(_image, rel, allow_fallback=False):
                return by_rel[rel]
            P.extract = fake_extract  # type: ignore
            # Recompute expected outputs from the patched bytes.
            for mode in ("stock", "48k16", "48k24", "44k16", "44k24"):
                for rel, is64 in (("lib/hw/audio.primary.waydroid.so", False),
                                   ("lib64/hw/audio.primary.waydroid.so", True)):
                    P.OUTPUT_SHA256[mode][rel] = sha(
                        P.patch_binary(rel, by_rel[rel], mode))
                P.OUTPUT_SHA256[mode][P.POLICY_PATH] = sha(
                    P.patch_policy(policy, mode))
            with tempfile.TemporaryDirectory() as td:
                man = P.build(Path("/fake/vendor.img"), Path(td) / "out", "44k24")
                self.assertEqual(man["mode"], "44k24")
                for rel in list(P.SOURCE_SHA256) + [P.POLICY_PATH]:
                    self.assertIn(rel, man)
                    self.assertIn("sha256", man[rel])
                import json
                on_disk = json.loads((Path(td) / "out" / "manifest.json").read_text())
                self.assertEqual(on_disk, man)
        finally:
            P.SOURCE_SHA256.update(orig_src)
            P.POLICY_SOURCE_SHA256 = orig_pol
            for m, v in orig_out.items():
                P.OUTPUT_SHA256[m] = v
            P.extract = orig_extract  # type: ignore

    def test_build_rejects_unknown_output(self):
        import tempfile
        sources, policy = self._install_synthetic_image()
        orig_src, orig_pol = P.SOURCE_SHA256.copy(), P.POLICY_SOURCE_SHA256
        orig_out = {m: dict(v) for m, v in P.OUTPUT_SHA256.items()}
        orig_extract = P.extract
        try:
            for rel, data in sources.items():
                P.SOURCE_SHA256[rel] = sha(data)
            P.POLICY_SOURCE_SHA256 = sha(policy)
            by_rel = dict(sources)
            by_rel[P.POLICY_PATH] = policy

            def fake_extract(_image, rel, allow_fallback=False):
                return by_rel[rel]
            P.extract = fake_extract  # type: ignore
            # Poison one expected output so build must refuse.
            P.OUTPUT_SHA256["44k16"]["lib/hw/audio.primary.waydroid.so"] = "0" * 64
            with tempfile.TemporaryDirectory() as td:
                with self.assertRaises(ValueError):
                    P.build(Path("/fake/vendor.img"), Path(td) / "out", "44k16")
        finally:
            P.SOURCE_SHA256.update(orig_src)
            P.POLICY_SOURCE_SHA256 = orig_pol
            for m, v in orig_out.items():
                P.OUTPUT_SHA256[m] = v
            P.extract = orig_extract  # type: ignore


class TestShellHashSync(unittest.TestCase):
    def _dump_lines(self):
        dump = subprocess.run(
            [sys.executable, str(ROOT / "patch_waydroid_audio.py"),
             "--mode", "stock", "--output", "/tmp/waydroid-hash-sync-probe",
             "--dump-shell-hashes"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            timeout=30)
        self.assertEqual(dump.returncode, 0, dump.stderr.decode()[:500])
        return [l.strip() for l in dump.stdout.decode().splitlines() if l.strip()]

    def test_shell_contains_patcher_hashes(self):
        shell = (ROOT / "waydroid-sample-rate.sh").read_text()
        for line in self._dump_lines():
            self.assertIn(line, shell)

    def test_patcher_contains_shell_hashes(self):
        # Bidirectional: every HASH_*= assignment in the shell must come
        # from --dump-shell-hashes. Catches stale shell entries.
        import re
        shell = (ROOT / "waydroid-sample-rate.sh").read_text()
        dumped = set(self._dump_lines())
        for m in re.finditer(r"^(HASH_[A-Z0-9_]+)=([0-9a-f]{64})$", shell, re.M):
            self.assertIn(f"{m.group(1)}={m.group(2)}", dumped)

    def test_explicit_48k16_hashes_present(self):
        # stock and 48k16 are byte identical today, but the shell must name
        # 48k16 explicitly so a future divergence cannot desync silently.
        shell = (ROOT / "waydroid-sample-rate.sh").read_text()
        for var in ("HASH_48K16_32=", "HASH_48K16_64=", "HASH_48K16_XML="):
            self.assertIn(var, shell)
        self.assertEqual(P.OUTPUT_SHA256["stock"], P.OUTPUT_SHA256["48k16"])


if __name__ == "__main__":
    unittest.main()
