#!/usr/bin/env bash
# Shell regression tests. No Waydroid or PipeWire needed.
# Run: bash tests/test_shell.sh
set -u
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STUBBIN=$(mktemp -d)
trap 'rm -rf -- "$STUBBIN"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# Stub sudo: drop the word and exec the rest unprivileged.
cat > "$STUBBIN/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == "-v" ]]; then exit 0; fi
exec "$@"
EOF
chmod +x "$STUBBIN/sudo"

# Stub systemctl: exit code from env.
cat > "$STUBBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_SYSTEMCTL_EXIT:-0}"
EOF
chmod +x "$STUBBIN/systemctl"

# Stub pw-metadata: print env-provided settings.
cat > "$STUBBIN/pw-metadata" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${STUB_PW_METADATA:-}"
EOF
chmod +x "$STUBBIN/pw-metadata"

export PATH="$STUBBIN:$PATH"

ISO=$(mktemp -d)
export OVERLAY_ROOT="$ISO/overlay/vendor"
export BACKUP_BASE="$ISO/backups"
# shellcheck disable=SC1091
source "$ROOT/waydroid-sample-rate.sh"

# --- verify_installed: pass case ---
mkdir -p "$ISO/src/vendor/lib/hw" "$ISO/src/vendor/lib64/hw" "$ISO/src/vendor/etc"
printf 'aaa' > "$ISO/src/vendor/lib/hw/audio.primary.waydroid.so"
printf 'bbb' > "$ISO/src/vendor/lib64/hw/audio.primary.waydroid.so"
printf 'ccc' > "$ISO/src/vendor/etc/audio_policy_configuration.xml"
H1=$(sha256sum "$ISO/src/vendor/lib/hw/audio.primary.waydroid.so" | awk '{print $1}')
H2=$(sha256sum "$ISO/src/vendor/lib64/hw/audio.primary.waydroid.so" | awk '{print $1}')
H3=$(sha256sum "$ISO/src/vendor/etc/audio_policy_configuration.xml" | awk '{print $1}')
python3 - "$ISO/src/manifest.json" "$H1" "$H2" "$H3" <<'PY'
import json, sys
out, h1, h2, h3 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({"mode": "test",
           "lib/hw/audio.primary.waydroid.so": {"sha256": h1},
           "lib64/hw/audio.primary.waydroid.so": {"sha256": h2},
           "etc/audio_policy_configuration.xml": {"sha256": h3}},
          open(out, "w"), indent=2, sort_keys=True)
PY
mkdir -p "$OVERLAY_ROOT/lib/hw" "$OVERLAY_ROOT/lib64/hw" "$OVERLAY_ROOT/etc"
cp -p "$ISO/src/vendor/lib/hw/audio.primary.waydroid.so" "$OVERLAY32"
cp -p "$ISO/src/vendor/lib64/hw/audio.primary.waydroid.so" "$OVERLAY64"
cp -p "$ISO/src/vendor/etc/audio_policy_configuration.xml" "$OVERLAY_POLICY"
if verify_installed "$ISO/src/manifest.json" >/dev/null 2>&1; then ok "verify pass"; else bad "verify pass"; fi

# --- verify_installed: corrupt case must fail ---
printf 'tampered' > "$OVERLAY64"
if verify_installed "$ISO/src/manifest.json" >/dev/null 2>&1; then bad "verify corrupt fails"; else ok "verify corrupt fails"; fi
cp -p "$ISO/src/vendor/lib64/hw/audio.primary.waydroid.so" "$OVERLAY64"

# --- wait_for_pipewire codes ---
STUB_PW_METADATA="clock.rate value:'48000'" wait_for_pipewire "48000" >/dev/null 2>&1 \
    && ok "wait pipewire success" || bad "wait pipewire success"
STUB_PW_METADATA="clock.rate value:'44100'" wait_for_pipewire "48000" >/dev/null 2>&1 \
    && bad "wait pipewire timeout fails" || ok "wait pipewire timeout fails"

# --- set_pipewire_locked propagates restart failure ---
export STUB_SYSTEMCTL_EXIT=1
if set_pipewire_locked "48000" "pipewire-48000.conf" >/dev/null 2>&1; then bad "pipewire restart failure fatal"; else ok "pipewire restart failure fatal"; fi
export STUB_SYSTEMCTL_EXIT=0

# --- wait_for_pipewire exact lock ---
STUB_PW_METADATA="clock.rate value:'48000' allowed-rates value:'[ 44100, 48000 ]'" wait_for_pipewire "48000" >/dev/null 2>&1 \
    && bad "wait rejects multi rate graph" || ok "wait rejects multi rate graph"
STUB_PW_METADATA="clock.rate value:'48000' allowed-rates value:'[ 48000 ]'" wait_for_pipewire "48000" >/dev/null 2>&1 \
    && ok "wait accepts single rate lock" || bad "wait accepts single rate lock"

# --- verify_removed ---
rm -f -- "$OVERLAY32" "$OVERLAY64" "$OVERLAY_POLICY" "$PW_FILE" "$PW_PULSE_FILE"
if verify_removed >/dev/null 2>&1; then ok "verify removed pass"; else bad "verify removed pass"; fi
printf 'stale' > "$OVERLAY32"
if verify_removed >/dev/null 2>&1; then bad "verify removed fails on stale"; else ok "verify removed fails on stale"; fi
rm -f -- "$OVERLAY32"

# --- validate_privileged_paths matrix ---
OVERLAY_ROOT="/var/lib/waydroid/overlay/vendor" VENDOR_IMAGE="/var/lib/waydroid/images/vendor.img" BACKUP_BASE="$ISO/backups" CONFIG_HOME="$ISO/cfg"
if ( validate_privileged_paths >/dev/null 2>&1 ); then ok "paths accept production"; else bad "paths accept production"; fi
OVERLAY_ROOT="relative/path" VENDOR_IMAGE="/var/lib/waydroid/images/vendor.img" BACKUP_BASE="$ISO/backups" CONFIG_HOME="$ISO/cfg"
if ( validate_privileged_paths >/dev/null 2>&1 ); then bad "paths reject relative"; else ok "paths reject relative"; fi
OVERLAY_ROOT="/var/lib/waydroid/overlay/vendor/" VENDOR_IMAGE="/var/lib/waydroid/images/vendor.img" BACKUP_BASE="$ISO/backups" CONFIG_HOME="$ISO/cfg"
if ( validate_privileged_paths >/dev/null 2>&1 ); then bad "paths reject trailing slash"; else ok "paths reject trailing slash"; fi
OVERLAY_ROOT="/var/lib/waydroid/overlay/vendor" VENDOR_IMAGE="/var/lib/waydroid/images/vendor.img" BACKUP_BASE="$ISO/backups" CONFIG_HOME="/"
if ( validate_privileged_paths >/dev/null 2>&1 ); then bad "paths reject config root"; else ok "paths reject config root"; fi
OVERLAY_ROOT="/"
if ( validate_privileged_paths >/dev/null 2>&1 ); then bad "paths reject broad root"; else ok "paths reject broad root"; fi

# --- status classification with canned hashes ---
overlay_sha256() {
    case $1 in
        "$OVERLAY32") printf '%s' "$CANNED32" ;;
        "$OVERLAY64") printf '%s' "$CANNED64" ;;
        "$OVERLAY_POLICY") printf '%s' "$CANNEDXML" ;;
    esac
}
overlay_exists() { return 0; }
waydroid() { printf 'Session:\tSTOPPED\n'; }
pactl() { return 0; }
CANNED32="$HASH_44K24_32" CANNED64="$HASH_44K24_64" CANNEDXML="$HASH_44K24_XML"
do_status > /tmp/dbg44.txt 2>&1
if grep -q "Detected mode: 44k24" /tmp/dbg44.txt; then ok "status classifies 44k24"; else bad "status classifies 44k24"; fi
CANNED32="$HASH_48K16_32" CANNED64="$HASH_48K16_64" CANNEDXML="$HASH_48K16_XML"
do_status > /tmp/dbg48.txt 2>&1
if grep -q "48k16" /tmp/dbg48.txt; then ok "status classifies explicit 48k16"; else bad "status classifies explicit 48k16"; fi
CANNED32="0" CANNED64="0" CANNEDXML="0"
do_status > /tmp/dbgunk.txt 2>&1
if grep -q "UNKNOWN" /tmp/dbgunk.txt; then ok "status reports mixed UNKNOWN"; else bad "status reports mixed UNKNOWN"; fi

rm -rf -- "$ISO"
printf '\npass=%d fail=%d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
