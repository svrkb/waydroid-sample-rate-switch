#!/usr/bin/env bash
# Switch the Waydroid primary audio link between sample rates and bit depths.
# Modes:
#   48k16 : 48000 Hz 16-bit (explicit overlay, same bytes as factory)
#   48k24 : 48000 Hz 24-bit (S24_LE / PCM_8_24_BIT) - for 48k lossless
#   44k16 : 44100 Hz 16-bit - for CD lossless (44.1k)
#   44k24 : 44100 Hz 24-bit (S24_LE / PCM_8_24_BIT)
#   stock : remove overlay, back to factory 48kHz 16-bit
#   status: show current overlay + PipeWire + Waydroid state
#
# The stock HAL supports one rate and format at a time (48 kHz 16 bit).
# This script builds a checksum guarded overlay for audio.primary.waydroid.so
# (32 bit and 64 bit) plus audio_policy_configuration.xml, installs it under
# /var/lib/waydroid/overlay/vendor, and locks PipeWire to the matching rate
# so the host graph and USB DAC follow without an extra resample.
# Switching is manual. Pick the mode that matches the content you play.
#
# Run as your desktop user (not with sudo). sudo is used only for the
# overlay + container steps.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PATCHER="$SCRIPT_DIR/patch_waydroid_audio.py"
VENDOR_IMAGE=${VENDOR_IMAGE:-/var/lib/waydroid/images/vendor.img}
OVERLAY_ROOT=${OVERLAY_ROOT:-/var/lib/waydroid/overlay/vendor}
OVERLAY32="$OVERLAY_ROOT/lib/hw/audio.primary.waydroid.so"
OVERLAY64="$OVERLAY_ROOT/lib64/hw/audio.primary.waydroid.so"
OVERLAY_POLICY="$OVERLAY_ROOT/etc/audio_policy_configuration.xml"
CONFIG_HOME=${XDG_CONFIG_HOME:-"${HOME:-/root}/.config"}
PW_DIR="$CONFIG_HOME/pipewire/pipewire.conf.d"
PW_PULSE_DIR="$CONFIG_HOME/pipewire/pipewire-pulse.conf.d"
PW_FILE="$PW_DIR/10-clock-rate.conf"
PW_PULSE_FILE="$PW_PULSE_DIR/10-clock-rate.conf"
STATE_HOME=${XDG_STATE_HOME:-"${HOME:-/root}/.local/state"}
BACKUP_BASE=${BACKUP_BASE:-"$STATE_HOME/waydroid-sample-rate-switch/backups"}
FORCE=0

# Expected output hashes. Canonical table lives in patch_waydroid_audio.py
# OUTPUT_SHA256; tests/test_patch.py asserts every --dump-shell-hashes line
# below appears verbatim. HASH_48K16_* is explicit even though its bytes
# currently equal stock, so a future divergence cannot desync silently.
HASH_STOCK_32=cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2
HASH_STOCK_64=f44860755c9674289322cf1394477a1c840be312dc795a85b932ae98d487072d
HASH_STOCK_XML=b649d92f3fd2d3a08630da296d5c9ddac39d6978780ff268446623f959585c7b
HASH_48K16_32=cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2
HASH_48K16_64=f44860755c9674289322cf1394477a1c840be312dc795a85b932ae98d487072d
HASH_48K16_XML=b649d92f3fd2d3a08630da296d5c9ddac39d6978780ff268446623f959585c7b
HASH_48K24_32=8d4077ffe3bde575afc9f869439a76c367efe1278c36e4168849984fb5151ae2
HASH_48K24_64=b342600d08c817216a17dece75bb671d6bf92923d6acb50305ffad357d78cfe7
HASH_48K24_XML=2da7843566702955222af4879b5af576b0b7d00fa6086fc16f98050c882a7aec
HASH_44K16_32=a554a4015bcf5c28b1d56d3f0334e4cd1e4d16a802b57335dbe9dfb75243d13f
HASH_44K16_64=ad234c89f9656d0d8cd203cfe635738525dc286fd2caa8c77a7c2aec909dbee0
HASH_44K16_XML=ca1042fcb31ebb82dfdeee5f0558f7d6aae78c8e0dc1f2e9f71ecf1bc7d67c33
HASH_44K24_32=8f2048edb98855923f8ec91a4de2a1f8a2d8e21e5ed3fe5bc31f248507c8983d
HASH_44K24_64=766059256fad695b5a684abb638385f7a1ef1735cff2a7ba31c87a3452351851
HASH_44K24_XML=0b80b00ec79ce4088e8747d0d9e814305df63f375a198103a67affd6c002db12

usage() {
    cat <<'EOF'
Usage: waydroid-sample-rate.sh [--force] {48k16|48k24|44k16|44k24|stock|status}

  48k16  - Waydroid link 48kHz 16-bit (explicit overlay)
  48k24  - Waydroid link 48kHz 24-bit (for 48k content)
  44k16  - Waydroid link 44.1kHz 16-bit (for CD 44.1k content)
  44k24  - Waydroid link 44.1kHz 24-bit
  stock  - remove overlay and PipeWire locks, back to factory behavior
  status - show overlay, PipeWire and Waydroid state

  --force - replace or delete overlay files even when they contain
            unknown bytes (for example another tool's overlay).
            Without it the script refuses and prints the mismatch.

After switching, start Waydroid and play audio, then run
./waydroid-sample-rate.sh status to verify. Many USB DACs show the active rate
on a display or LED. Confirm 44100 vs 48000 there.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# Single helper for reading installed overlay bytes. Overlay paths are
# root owned, so every caller (refuse, verify, status) goes through sudo
# for consistent results. Prints the hex digest, or nothing when unreadable.
overlay_sha256() {
    sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

overlay_exists() {
    sudo test -f "$1" 2>/dev/null
}

hash_file() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

known_hashes_for() {
    case $1 in
        "$OVERLAY32") printf '%s\n' "$HASH_STOCK_32" "$HASH_48K16_32" "$HASH_48K24_32" "$HASH_44K16_32" "$HASH_44K24_32" ;;
        "$OVERLAY64") printf '%s\n' "$HASH_STOCK_64" "$HASH_48K16_64" "$HASH_48K24_64" "$HASH_44K16_64" "$HASH_44K24_64" ;;
        "$OVERLAY_POLICY") printf '%s\n' "$HASH_STOCK_XML" "$HASH_48K16_XML" "$HASH_48K24_XML" "$HASH_44K16_XML" "$HASH_44K24_XML" ;;
        *) return 1 ;;
    esac
}

is_known_path() {
    local path=$1 h
    h=$(overlay_sha256 "$path")
    [[ -n $h ]] || return 1
    known_hashes_for "$path" | grep -qxF "$h"
}

refuse_on_foreign_overlay() {
    local f h
    for f in "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY"; do
        if overlay_exists "$f"; then
            if ! is_known_path "$f"; then
                h=$(overlay_sha256 "$f")
                if [[ -z $h ]]; then
                    die "Refusing: $f exists but is unreadable even via sudo. Check permissions before retrying."
                fi
                if [[ $FORCE -ne 1 ]]; then
                    die "Refusing: $f contains unknown bytes (sha256=$h). It may belong to another tool. Re-run with --force to replace it, or back it up manually first."
                fi
                printf 'WARNING: replacing foreign bytes at %s (sha256=%s) due to --force.\n' "$f" "$h" >&2
            fi
        fi
    done
}

make_backup_dir() {
    local d
    d="$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p -- "$d/overlay/vendor/lib/hw" "$d/overlay/vendor/lib64/hw" "$d/overlay/vendor/etc" "$d/pipewire"
    printf '%s' "$d"
}

backup_overlay_tree() {
    local dest=$1 f rel
    for f in "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY"; do
        if sudo test -f "$f"; then
            rel=${f#"$OVERLAY_ROOT"/}
            sudo mkdir -p -- "$dest/overlay/vendor/$(dirname -- "$rel")"
            sudo cp -p -- "$f" "$dest/overlay/vendor/$rel"
        fi
    done
    sudo chown -R "$(id -u):$(id -g)" -- "$dest" 2>/dev/null || true
    printf 'Overlay backup: %s/overlay\n' "$dest"
}

backup_pipewire_tree() {
    local dest=$1
    [[ -f $PW_FILE ]] && cp -p -- "$PW_FILE" "$dest/pipewire/10-clock-rate.conf"
    [[ -f $PW_PULSE_FILE ]] && cp -p -- "$PW_PULSE_FILE" "$dest/pipewire/10-clock-rate-pulse.conf"
    printf 'PipeWire backup: %s/pipewire (if files existed)\n' "$dest"
}

validate_privileged_paths() {
    local p
    for p in "$OVERLAY_ROOT" "$VENDOR_IMAGE" "$BACKUP_BASE" "$CONFIG_HOME"; do
        [[ -n $p ]] || die "Refusing empty path."
        [[ $p == /* ]] || die "Refusing non absolute path: $p"
        [[ $p != */ ]] || die "Refusing path with trailing slash: $p"
        case $p in
            */../*|*/./*|*/..|*/.) die "Refusing path with dot segment: $p" ;;
        esac
    done
    [[ $OVERLAY_ROOT == / ]] && die "Refusing OVERLAY_ROOT=/"
    [[ $OVERLAY_ROOT == /var/lib ]] && die "Refusing OVERLAY_ROOT this broad: $OVERLAY_ROOT"
    [[ $OVERLAY_ROOT == /var/lib/waydroid ]] && die "Refusing OVERLAY_ROOT this broad: $OVERLAY_ROOT"
    case $OVERLAY_ROOT in
        /var/lib/waydroid/overlay/*|/tmp/*|/var/tmp/*) ;;
        *) die "Refusing OVERLAY_ROOT outside /var/lib/waydroid/overlay (or /tmp for tests): $OVERLAY_ROOT" ;;
    esac
}

stop_waydroid() {
    printf 'Stopping Waydroid session...\n'
    waydroid session stop >/dev/null 2>&1 || true
    printf 'Stopping Waydroid container (needs sudo)...\n'
    sudo systemctl stop waydroid-container.service >/dev/null 2>&1 || \
        sudo waydroid container stop >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 15); do
        findmnt /var/lib/waydroid/rootfs >/dev/null 2>&1 || return 0
        sleep 1
    done
    die "Waydroid rootfs still mounted. Run 'sudo waydroid container stop' manually."
}

install_overlay() {
    local srcdir=$1 f src dst
    printf 'Installing overlay to %s (needs sudo)...\n' "$OVERLAY_ROOT"
    # Pre-check all staged sources before any privileged mutation so a
    # missing file cannot leave a half replaced set behind.
    for f in \
        "$srcdir/vendor/lib/hw/audio.primary.waydroid.so:$OVERLAY32" \
        "$srcdir/vendor/lib64/hw/audio.primary.waydroid.so:$OVERLAY64" \
        "$srcdir/vendor/etc/audio_policy_configuration.xml:$OVERLAY_POLICY"; do
        src=${f%%:*}
        [[ -f $src ]] || die "Staged source missing: $src. Aborting before touching the overlay."
    done
    sudo mkdir -p "$OVERLAY_ROOT/lib/hw" "$OVERLAY_ROOT/lib64/hw" "$OVERLAY_ROOT/etc"
    local staging
    staging=".waydroid-sample-rate.new.$(id -u).$$.$RANDOM"
    # Stage all three files first, then rename. If a rename fails, the
    # next run recovers because every valid output hash is known; status
    # reports UNKNOWN until then. Retry is the documented recovery.
    for f in \
        "$srcdir/vendor/lib/hw/audio.primary.waydroid.so:$OVERLAY32" \
        "$srcdir/vendor/lib64/hw/audio.primary.waydroid.so:$OVERLAY64" \
        "$srcdir/vendor/etc/audio_policy_configuration.xml:$OVERLAY_POLICY"; do
        src=${f%%:*}; dst=${f##*:}
        sudo rm -f -- "$dst.$staging"
        sudo cp -f -- "$src" "$dst.$staging" || die "Failed staging $dst. Re-run the switch to recover; status will report UNKNOWN until then."
        sudo chmod 644 "$dst.$staging"
    done
    for f in "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY"; do
        sudo mv -f -- "$f.$staging" "$f" || die "Failed committing $f. Re-run the switch to recover; status will report UNKNOWN until then."
    done
    printf 'Overlay installed.\n'
}

remove_overlay() {
    printf 'Removing audio overlay (needs sudo)...\n'
    sudo rm -f -- "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY" || return 1
    printf 'Overlay removed; vendor image is now stock.\n'
}

verify_removed() {
    local f ok=1
    for f in "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY" "$PW_FILE" "$PW_PULSE_FILE"; do
        if [[ $f == "$OVERLAY32" || $f == "$OVERLAY64" || $f == "$OVERLAY_POLICY" ]]; then
            if sudo test -e "$f" 2>/dev/null; then
                printf 'REMOVE FAIL: still present: %s\n' "$f" >&2
                ok=0
            else
                printf 'Verified absent %s\n' "$f"
            fi
        else
            if [[ -e $f ]]; then
                printf 'REMOVE FAIL: still present: %s\n' "$f" >&2
                ok=0
            else
                printf 'Verified absent %s\n' "$f"
            fi
        fi
    done
    [[ $ok -eq 1 ]] || return 1
}

# The same lock content is written to both pipewire.conf.d and
# pipewire-pulse.conf.d. Whether the pulse server honors these clock keys
# identically is not proven from this repo alone. See README Verification
# for the manual pw-top and pactl matrix that confirms the active graph
# on the tested host. The pulse copy is kept for consistency until that
# matrix shows it is redundant.
set_pipewire_locked() {
    local rate=$1 template=$2
    printf 'Setting PipeWire to %s Hz...\n' "$rate"
    mkdir -p "$PW_DIR" "$PW_PULSE_DIR"
    cp -f -- "$SCRIPT_DIR/pipewire/$template" "$PW_FILE" || return 1
    cp -f -- "$SCRIPT_DIR/pipewire/$template" "$PW_PULSE_FILE" || return 1
    printf 'Wrote %s and %s\n' "$PW_FILE" "$PW_PULSE_FILE"
    if systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null; then
        printf 'PipeWire restarted.\n'
        return 0
    fi
    printf 'PipeWire restart failed; reboot or run:\n' >&2
    printf '  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service\n' >&2
    return 1
}

remove_pipewire_locks() {
    printf 'Removing PipeWire locks to restore factory behavior...\n'
    rm -f -- "$PW_FILE" "$PW_PULSE_FILE"
    rmdir -p --ignore-fail-on-non-empty "$PW_DIR" "$PW_PULSE_DIR" 2>/dev/null || true
    if systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null; then
        printf 'PipeWire restarted without locks.\n'
        return 0
    fi
    printf 'PipeWire restart failed; reboot or run:\n' >&2
    printf '  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service\n' >&2
    return 1
}

verify_installed() {
    # Manifest is nested JSON: {rel: {"sha256": hex}, "mode": name}.
    # Parse it with python3 (already a hard dependency) instead of
    # line oriented sed, which cannot pair keys with values.
    local manifest=$1
    python3 - "$manifest" "$OVERLAY_ROOT" <<'PY' || return 1
import json
import subprocess
import sys
manifest_path, root = sys.argv[1], sys.argv[2]
with open(manifest_path) as fh:
    data = json.load(fh)
ok = True
allowed = {
    "lib/hw/audio.primary.waydroid.so",
    "lib64/hw/audio.primary.waydroid.so",
    "etc/audio_policy_configuration.xml",
}
for rel, val in data.items():
    if rel == "mode":
        continue
    if rel not in allowed:
        print(f"VERIFY FAIL: unexpected manifest entry: {rel}",
              file=sys.stderr)
        ok = False
        continue
    exp = val["sha256"]
    path = root.rstrip("/") + "/" + rel
    r = subprocess.run(
        ["sudo", "sha256sum", "--", path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    got = r.stdout.decode(errors="replace").split()[0] if r.returncode == 0 else ""
    if got != exp:
        print(f"VERIFY FAIL: {path} got {got or 'missing'} expected {exp}",
              file=sys.stderr)
        ok = False
    else:
        print(f"Verified {rel} {got}")
sys.exit(0 if ok else 1)
PY
}

wait_for_pipewire() {
    # Require the wanted rate present and the other rate absent, so a
    # multi rate graph such as [44100, 48000] does not count as locked.
    local want=$1 other i out=""
    if [[ $want == 48000 ]]; then other=44100; else other=48000; fi
    for i in $(seq 1 10); do
        out=$(pw-metadata -n settings 2>/dev/null | grep -E "clock.rate|allowed-rates" || true)
        if printf '%s' "$out" | grep -q "$want" && ! printf '%s' "$out" | grep -q "$other"; then
            printf '%s\n' "$out"
            return 0
        fi
        sleep 1
    done
    printf '%s\n' "$out" >&2
    printf 'PipeWire did not report %s within timeout.\n' "$want" >&2
    return 1
}

do_switch() {
    local mode=$1 pw_rate pw_template is_stock=0
    case $mode in
        48k16) pw_rate=48000; pw_template=pipewire-48000.conf ;;
        48k24) pw_rate=48000; pw_template=pipewire-48000.conf ;;
        44k16) pw_rate=44100; pw_template=pipewire-44100.conf ;;
        44k24) pw_rate=44100; pw_template=pipewire-44100.conf ;;
        stock) is_stock=1 ;;
        *) die "unknown mode $mode" ;;
    esac
    need python3; need waydroid; need debugfs; need findmnt
    need sudo; need seq; need sha256sum
    need pw-metadata; need systemctl
    validate_privileged_paths
    [[ $VENDOR_IMAGE != -* ]] || die "Refusing VENDOR_IMAGE starting with dash: $VENDOR_IMAGE"
    [[ -f $PATCHER ]] || die "patcher missing: $PATCHER"
    [[ -f $VENDOR_IMAGE ]] || die "vendor image missing: $VENDOR_IMAGE"
    if [[ $is_stock -eq 0 ]]; then
        [[ -f $SCRIPT_DIR/pipewire/$pw_template ]] || die "PipeWire template missing: $SCRIPT_DIR/pipewire/$pw_template. Aborting before touching the overlay."
    fi
    if ! sudo -v; then
        die "sudo authentication failed before any change. Nothing was modified."
    fi
    # Interlock against concurrent switches sharing staging names.
    local lockdir lockfile
    lockdir="${BACKUP_BASE%/*}"
    mkdir -p -- "$lockdir"
    lockfile="$lockdir/.lock"
    exec 9>"$lockfile" || die "Cannot open lockfile $lockfile."
    if ! flock -n 9; then
        die "Another switch is running (lock $lockfile). Wait for it to finish."
    fi

    local tmp backup_dir
    # shellcheck disable=SC2064
    tmp=$(mktemp -d); trap "rm -rf -- $tmp" EXIT
    printf 'Building %s overlay from %s (checksum-guarded)...\n' "$mode" "$VENDOR_IMAGE"
    if [[ $is_stock -eq 1 ]]; then
        python3 "$PATCHER" --mode stock --vendor-image "$VENDOR_IMAGE" --output "$tmp/stock" >/dev/null \
            || die "Base image not supported (hash mismatch). Aborting."
    else
        python3 "$PATCHER" --mode "$mode" --vendor-image "$VENDOR_IMAGE" --output "$tmp/out" \
            || die "Patcher refused (image mismatch). Aborting before touching overlay."
        cat "$tmp/out/manifest.json"
    fi

    refuse_on_foreign_overlay
    backup_dir=$(make_backup_dir)
    backup_overlay_tree "$backup_dir"
    backup_pipewire_tree "$backup_dir"
    stop_waydroid
    if [[ $is_stock -eq 1 ]]; then
        remove_overlay || die "SWITCH INCOMPLETE: overlay removal failed. Inspect the paths above before starting Waydroid."
        remove_pipewire_locks || die "SWITCH INCOMPLETE: overlay removed but PipeWire locks could not be restarted. See output above before starting Waydroid."
        verify_removed || die "SWITCH INCOMPLETE: removal verification failed. Inspect the paths above before starting Waydroid."
    else
        install_overlay "$tmp/out"
        verify_installed "$tmp/out/manifest.json" || die "SWITCH INCOMPLETE: overlay verification failed. PipeWire was not changed. Inspect the paths above and re-run."
        set_pipewire_locked "$pw_rate" "$pw_template" || die "SWITCH INCOMPLETE: overlay installed and verified, but PipeWire restart failed. Graph may be at the old rate. Fix PipeWire manually or re-run."
        wait_for_pipewire "$pw_rate" || die "SWITCH INCOMPLETE: overlay installed and verified, but the live graph never reported $pw_rate. Do not trust the DAC indicator until pw-top agrees."
    fi

    cat <<EOF

Done: $mode active.
  Waydroid link : $mode
  Backup        : $backup_dir

Next:
  1. Start Waydroid:  waydroid session start
  2. Play audio in Android, then verify:  ./waydroid-sample-rate.sh status
  3. Check 'pw-top' RATE and FORMAT columns and your DAC rate indicator.

Note: this is manual switching, not auto-switching. Match the mode to
the track: 44k16/44k24 for 44.1k content, 48k16/48k24 for 48k content.
Other apps are resampled into the locked graph while locked.
EOF
    trap - EXIT; rm -rf -- "$tmp"
}


do_status() {
    local missing=""
    command -v sha256sum >/dev/null 2>&1 || missing="$missing sha256sum"
    command -v pw-metadata >/dev/null 2>&1 || missing="$missing pw-metadata"
    command -v pactl >/dev/null 2>&1 || missing="$missing pactl"
    command -v waydroid >/dev/null 2>&1 || missing="$missing waydroid"
    if [[ -n $missing ]]; then
        printf 'WARNING: missing tools:%s. Related sections below will be empty.\n\n' "$missing" >&2
    fi
    printf '== Waydroid overlay ==\n'
    local f h h32 h64 hxml
    for f in "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY"; do
        if overlay_exists "$f"; then
            h=$(overlay_sha256 "$f")
            if [[ -n $h ]]; then
                printf '%s\n  sha256=%s\n' "$f" "$h"
            else
                printf '%s\n  present but unreadable via sudo; check permissions\n' "$f"
            fi
        else
            printf '%s\n  (absent = stock)\n' "$f"
        fi
    done
    h32=$(overlay_sha256 "$OVERLAY32" || true)
    h64=$(overlay_sha256 "$OVERLAY64" || true)
    hxml=$(overlay_sha256 "$OVERLAY_POLICY" || true)
    printf 'Detected mode: '
    if [[ $h32 == "$HASH_48K24_32" && $h64 == "$HASH_48K24_64" && $hxml == "$HASH_48K24_XML" ]]; then
        printf '48k24\n'
    elif [[ $h32 == "$HASH_44K16_32" && $h64 == "$HASH_44K16_64" && $hxml == "$HASH_44K16_XML" ]]; then
        printf '44k16\n'
    elif [[ $h32 == "$HASH_44K24_32" && $h64 == "$HASH_44K24_64" && $hxml == "$HASH_44K24_XML" ]]; then
        printf '44k24\n'
    elif [[ $h32 == "$HASH_48K16_32" && $h64 == "$HASH_48K16_64" && $hxml == "$HASH_48K16_XML" ]]; then
        printf '48k16 (explicit overlay, stock bytes)\n'
    elif [[ -z $h32 && -z $h64 && -z $hxml ]]; then
        printf 'stock (no overlay)\n'
    else
        printf 'UNKNOWN (mixed/stale overlay or hires patch)\n'
    fi
    printf '\n== PipeWire ==\n'
    printf -- '-- %s --\n' "$PW_FILE"
    cat "$PW_FILE" 2>/dev/null || printf '(missing)\n'
    printf -- '-- %s --\n' "$PW_PULSE_FILE"
    cat "$PW_PULSE_FILE" 2>/dev/null || printf '(missing)\n'
    printf -- '-- live settings --\n'
    pw-metadata -n settings 2>/dev/null | grep -E "clock.rate|allowed-rates" || printf '(pw-metadata unavailable)\n'
    printf '\n== Waydroid ==\n'
    waydroid status 2>/dev/null || printf '(waydroid status failed)\n'
    printf '\n== Sinks (DAC rate/format) ==\n'
    pactl list sinks 2>/dev/null | grep -E "Name:|Sample Specification|alsa.resolution" | head -n 20 || true
    printf '\n== Waydroid sink-inputs (while playing) ==\n'
    pactl list sink-inputs 2>/dev/null | grep -E "Client:|media.name|Sample Specification|Format:" | head -n 40 || true
    printf '(empty when nothing is playing)\n'
    printf '\n== pw-top (run while playing to see Waydroid FORMAT/Hz) ==\n'
    printf "Run: pw-top  (look for 'Waydroid' row: e.g. S24LE 2 44100 vs F32LE 2 48000)\n"
    printf '\n== Android primary output (needs ADB-approved Waydroid running) ==\n'
    printf "If ADB is approved, try:\n"
    printf '  adb shell dumpsys media.audio_flinger | grep -A5 "Output thread"\n'
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || exit 0
fi
if [[ ${1:-} == "--force" ]]; then FORCE=1; shift; fi
[[ $# -eq 1 ]] || { usage; exit 2; }
case $1 in
    48k16|48k24|44k16|44k24|stock) do_switch "$1" ;;
    status) do_status ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
