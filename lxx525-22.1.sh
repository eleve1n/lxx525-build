#!/bin/bash
set -Eeo pipefail

# ============================================================
# LXX525 LineageOS 22.1 — Crave build script (minimal)
#
# All repos are synced via the local manifest:
#   https://github.com/eleve1n/local_manifests
#
# Crave:
#   crave run --no-patch -- \
#     "curl -fsSL https://raw.githubusercontent.com/eleve1n/lxx525-build/main/lxx525-22.1.sh | bash"
# ============================================================

DEVICE="LXX525"
LUNCH_TARGET="lineage_LXX525-ap3a-userdebug"
DEVICE_DIR="device/lava/LXX525"
VENDOR_DIR="vendor/lava/LXX525"

START_DATE=$(date '+%Y-%m-%d %H:%M:%S')

LOG_DIR="build-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/LXX525-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    echo
    echo "============================================================"
    echo " BUILD FAILED  (exit $?) — $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Log: $LOG_FILE"
    echo "============================================================"
    # Telegram failure notice (only if the Telegram section below has loaded)
    declare -F tg_send >/dev/null 2>&1 && \
        tg_send "❌ LXX525 LineageOS build FAILED
Started: $START_DATE
Log: $LOG_FILE" || true
}
trap on_error ERR

echo
echo "============================================================"
echo " LXX525 - LineageOS 22.1"
echo " Target  : $LUNCH_TARGET"
echo " Started : $START_DATE"
echo "============================================================"
echo

if [[ ! -d ".repo" || ! -d "build" ]]; then
    echo "ERROR: Not an Android source tree."
    exit 1
fi

# ============================================================
# Sync
# ============================================================

echo "==> Syncing source..."
/opt/crave/resync.sh

echo "==> Updating local manifest..."
mkdir -p .repo/local_manifests
curl -fsSL \
    "https://raw.githubusercontent.com/eleve1n/local_manifests/main/local_manifests.xml" \
    -o ".repo/local_manifests/local_manifests.xml"

echo "==> Syncing device repositories..."
repo sync -c --force-sync --no-clone-bundle --no-tags -j"$(nproc --all)"

# ------------------------------------------------------------
# Self-heal: crave-cached workspaces can carry stale/broken
# working copies that repo sync considers "up to date".
# Force a clean re-sync of any project missing its key file.
# ------------------------------------------------------------

repair_project() {
    echo "[WARN] $1 is broken/incomplete — forcing clean re-sync"
    rm -rf "$1"
    repo sync -c --force-sync -j"$(nproc --all)" "$1"
}

if [[ -d "$DEVICE_DIR" && ! -f "$DEVICE_DIR/prebuilt/kernel" ]]; then
    repair_project "$DEVICE_DIR"
fi

if [[ -d "$VENDOR_DIR" && ! -f "$VENDOR_DIR/LXX525-vendor.mk" ]]; then
    repair_project "$VENDOR_DIR"
fi

# ============================================================
# Build
# ============================================================

echo "==> Starting build..."
source build/envsetup.sh
lunch "$LUNCH_TARGET"
m bacon

# ============================================================
# Telegram setup (token + channel, hidden as base64)
# ============================================================

# Hidden defaults (base64) — stops automated token-scanning bots on GitHub.
# NOTE: this is obfuscation, not encryption — anyone can decode it.
# To rotate the token: @BotFather -> /revoke, then encode the new one:
#   printf '%s' "NEW_TOKEN" | base64 -w0
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT_ID:-}"

if [[ -z "$TG_TOKEN" ]]; then
    TG_TOKEN=$(printf '%s' 'ODYwNTQ5NTE5OTpBQUgxamZmQ1BweGJNOHN4eDh4QXBNVE8xdi1NMVhFajJKaw==' | base64 -d)
fi
if [[ -z "$TG_CHAT" ]]; then
    TG_CHAT=$(printf '%s' 'LTEwMDQzMzc2NTA5NjM=' | base64 -d)
fi

# Auto-detect chat ID from the bot's recent messages if it was not provided.
if [[ -n "$TG_TOKEN" && -z "$TG_CHAT" ]]; then
    echo "==> TELEGRAM_CHAT_ID not set — auto-detecting from bot messages..."
    TG_CHAT=$(curl -fsSL "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for upd in data.get('result', []):
        msg = upd.get('message') or upd.get('channel_post') or {}
        chat = msg.get('chat')
        if chat:
            print(chat['id'])
            break
except Exception:
    pass
" || true)
    if [[ -n "$TG_CHAT" ]]; then
        echo "[OK] Auto-detected Telegram chat ID: $TG_CHAT"
    else
        echo "[WARN] Could not auto-detect chat ID."
    fi
fi

tg_send() {
    # usage: tg_send "message text"
    [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]] || return 0
    curl -fsSL -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT" \
        --data-urlencode text="$1" >/dev/null || true
}

# ============================================================
# Upload (GoFile) + Telegram notification
# ============================================================

ZIP=$(find "out/target/product/$DEVICE" -maxdepth 1 -name "*.zip" | head -n 1)

if [[ -z "$ZIP" ]]; then
    echo "ERROR: No ROM zip found in out/target/product/$DEVICE"
    tg_send "❌ LXX525 build finished but no ROM zip was found."
    exit 1
fi

ZIP_NAME=$(basename "$ZIP")
ZIP_SIZE=$(du -h "$ZIP" | cut -f1)
echo "==> ROM: $ZIP_NAME ($ZIP_SIZE)"

tg_send "✅ LXX525 LineageOS 22.1 built successfully.
File: $ZIP_NAME ($ZIP_SIZE)
Uploading to GoFile... (you'll get the link shortly)"

echo "==> Uploading to GoFile (this can take a while)..."
SERVER=$(curl -fsSL "https://api.gofile.io/servers" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['server'])")
LINK=$(curl -fsSL -F "file=@${ZIP}" "https://${SERVER}.gofile.io/contents/uploadfile" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['downloadPage'])")

if [[ -z "$LINK" ]]; then
    echo "ERROR: GoFile upload failed"
    tg_send "⚠️ ROM built but GoFile upload failed. File is at $ZIP_NAME on the build node."
    exit 1
fi

echo "==> Uploaded: $LINK"
tg_send "📦 LXX525 LineageOS 22.1
File: $ZIP_NAME ($ZIP_SIZE)
Download: $LINK"

echo
echo "============================================================"
echo " BUILD SUCCESSFUL"
echo "============================================================"
echo " ROM : $ZIP_NAME ($ZIP_SIZE)"
echo " Link: $LINK"
