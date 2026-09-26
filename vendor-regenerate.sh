#!/bin/bash
set -e

# ============================================================
# LXX525 vendor tree regeneration (v3 — hardened)
#
# 1. Downloads stock partition images from your firmware release
# 2. Extracts them (mount -> fsck.erofs -> 7z, with reporting)
# 3. Runs extract-files.py + setup-makefiles.py (official tools)
# 4. If GITHUB_TOKEN is set: pushes the new tree to your vendor repo
#
# Requirements (committed to the device tree repo first):
#   device/lava/LXX525/extract-files.py
#   device/lava/LXX525/setup-makefiles.py
#   device/lava/LXX525/proprietary-files.txt
# ============================================================

SRC=/tmp/src/android
DUMP=/tmp/lxx525-dump
IMG=/tmp/lxx525-images
REL=https://github.com/eleve1n/LXX525_blobs_extractor/releases/download/firmware
VENDOR_REPO=eleve1n/android_vendor_lava_LXX525

# --- 1. Download the partition images ----------------------
mkdir -p "$IMG" && cd "$IMG"
for a in vendor_a.img system_ext_a.img; do
    if [ -s "$a" ]; then
        echo "[OK] $a already downloaded ($(du -h "$a" | cut -f1))"
    else
        echo "==> Downloading $a (~1 GB, this takes a few minutes)..."
        curl -fL --retry 3 -o "$a" "$REL/$a"
        if [ ! -s "$a" ]; then
            echo "!! Download of $a failed — check the firmware release:"
            echo "   $REL"
            exit 1
        fi
        echo "[OK] $a downloaded ($(du -h "$a" | cut -f1))"
    fi
done

# --- 2. Extract the images -----------------------------------
mkdir -p "$DUMP"

detect_fs() {  # $1=image -> prints "erofs" or "ext4" or "unknown"
    local magic
    magic=$(dd if="$1" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$magic" in
        e0f5e1e2) echo "erofs" ;;
        *) echo "ext4-or-raw" ;;
    esac
}

extract_img() {  # $1=image  $2=destination dir
    local img="$1" dest="$2"
    mkdir -p "$dest"
    if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "[OK] $(basename "$dest")/ already extracted, skipping"
        return 0
    fi
    echo "==> Extracting $(basename "$img") (format: $(detect_fs "$img"))..."

    # Method 1: loop-mount (works for erofs AND ext4, needs root)
    if mount -o ro,loop "$img" "$dest" 2>/dev/null; then
        local tmp="${dest}_copy"
        mkdir -p "$tmp"
        cp -r "$dest/." "$tmp"/
        umount "$dest"
        rm -rf "$dest"; mv "$tmp" "$dest"
        echo "[OK] extracted via loop mount"
        return 0
    fi

    # Method 2: fsck.erofs (install if missing)
    if ! command -v fsck.erofs >/dev/null 2>&1; then
        echo "--> installing erofs-utils..."
        apt-get update 2>&1 | tail -1 || true
        apt-get install -y erofs-utils 2>&1 | tail -1 || true
        echo "--> fsck.erofs: $(command -v fsck.erofs || echo 'still missing')"
    fi
    if command -v fsck.erofs >/dev/null 2>&1; then
        echo "--> trying fsck.erofs..."
        fsck.erofs --extract="$dest" "$img" >/dev/null 2>&1 || true
        if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
            echo "[OK] extracted via fsck.erofs"
            return 0
        fi
    fi

    # Method 3: old p7zip (ext4 only)
    if command -v 7z >/dev/null 2>&1; then
        echo "--> trying 7z (p7zip)..."
        7z x -y -o"$dest" "$img" >/dev/null 2>&1 || true
        if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
            echo "[OK] extracted via 7z"
            return 0
        fi
    fi

    # Method 4: new 7-Zip 24.05+ (supports EROFS) — install if possible
    if ! command -v 7zz >/dev/null 2>&1; then
        echo "--> installing 7zip (new, EROFS-capable)..."
        apt-get install -y 7zip 2>&1 | tail -1 || true
        echo "--> 7zz: $(command -v 7zz || echo 'not available')"
    fi
    if command -v 7zz >/dev/null 2>&1; then
        echo "--> trying 7zz (7-Zip, EROFS-capable)..."
        7zz x -y -o"$dest" "$img" >/dev/null 2>&1 || true
        if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
            echo "[OK] extracted via 7zz"
            return 0
        fi
    fi

    echo "!! FAILED to extract $(basename "$img") with any method."
    echo "   Available tools: mount=$(command -v mount), fsck.erofs=$(command -v fsck.erofs || echo 'missing'), 7z=$(command -v 7z || echo 'missing')"
    return 1
}

extract_img "$IMG/vendor_a.img"     "$DUMP/vendor"
extract_img "$IMG/system_ext_a.img" "$DUMP/system_ext"

# --- 3. Regenerate the vendor tree ---------------------------
cd "$SRC/device/lava/LXX525"
for f in extract-files.py setup-makefiles.py proprietary-files.txt; do
    if [ ! -f "$f" ]; then
        echo "!! $f missing — upload it to the device tree repo first"
        exit 1
    fi
done

echo "==> Clearing old vendor tree..."
(cd "$SRC/vendor/lava/LXX525" 2>/dev/null && \
    find . -mindepth 1 -not -path './.git*' -delete) || true

echo "==> Running official extraction (takes a while)..."
PYTHONPATH=../../../tools/extract-utils python3 extract-files.py "$DUMP"

echo "==> Regenerating vendor makefiles..."
PYTHONPATH=../../../tools/extract-utils python3 setup-makefiles.py

# --- 4. Publish ----------------------------------------------
if [ -n "$GITHUB_TOKEN" ]; then
    echo "==> Pushing new vendor tree to GitHub..."
    cd "$SRC/vendor/lava/LXX525"
    git config user.name  "eleve1n"
    git config user.email "hdhehdh21@gmail.com"
    git add -A
    git commit -qm "Regenerate vendor tree with extract-utils (module-based)" || true
    git push --force \
        "https://x-access-token:${GITHUB_TOKEN}@github.com/${VENDOR_REPO}.git" \
        HEAD:lineage-22.1
    echo ""
    echo "============================================================"
    echo " DONE — new vendor tree pushed to $VENDOR_REPO (lineage-22.1)"
    echo "============================================================"
else
    cd "$SRC"
    rm -f /tmp/lxx525-vendor-regenerated.zip
    zip -qr /tmp/lxx525-vendor-regenerated.zip vendor/lava/LXX525
    echo ""
    echo "============================================================"
    echo " DONE — tree generated, zip saved"
    echo "============================================================"
    ls -lh /tmp/lxx525-vendor-regenerated.zip
fi
