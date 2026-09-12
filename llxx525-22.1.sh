#!/bin/bash
set -Eeuo pipefail

# ============================================================
# LXX525 LineageOS 22.1 - Crave Build Script
#
# Usage:
#   bash lxx525.sh first
#   bash lxx525.sh update
#
# Crave:
#   crave run --no-patch -- \
#     "bash lxx525.sh first"
#
# ============================================================

DEVICE="LXX525"
BRANCH="lineage-22.1"
LUNCH_TARGET="lineage_LXX525-ap3a-userdebug"

DEVICE_DIR="device/lava/LXX525"
KERNEL_DIR="device/lava/LXX525-kernel"
VENDOR_DIR="vendor/lava/LXX525"

DEPENDENCIES="${DEVICE_DIR}/lineage.dependencies"

MODE="${1:-update}"

START_TIME=$(date +%s)
START_DATE=$(date '+%Y-%m-%d %H:%M:%S')

LOG_DIR="build-logs"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/LXX525-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

# ============================================================
# Error handling
# ============================================================

on_error() {
    local code=$?

    echo
    echo "============================================================"
    echo " BUILD FAILED"
    echo " Exit code : $code"
    echo " Time      : $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Log       : $LOG_FILE"
    echo "============================================================"

    exit "$code"
}

trap on_error ERR

# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo " LXX525 - LineageOS 22.1"
echo "============================================================"
echo " Device    : $DEVICE"
echo " Branch    : $BRANCH"
echo " Target    : $LUNCH_TARGET"
echo " Mode      : $MODE"
echo " Started   : $START_DATE"
echo "============================================================"
echo

# ============================================================
# Validate mode
# ============================================================

case "$MODE" in
    first|update)
        ;;
    *)
        echo "Usage:"
        echo "  $0 first"
        echo "  $0 update"
        exit 1
        ;;
esac

# ============================================================
# Validate Android source tree
# ============================================================

if [[ ! -d ".repo" || ! -d "build" ]]; then
    echo "ERROR: Not an Android source tree."
    echo "Run this script from the LineageOS source directory."
    exit 1
fi

# ============================================================
# Repository helper
# ============================================================

sync_repo() {
    local URL="$1"
    local BRANCH_NAME="$2"
    local DEST="$3"

    echo
    echo "------------------------------------------------------------"
    echo "Repository"
    echo " URL    : $URL"
    echo " Branch : $BRANCH_NAME"
    echo " Path   : $DEST"
    echo "------------------------------------------------------------"

    if [[ "$MODE" == "first" ]]; then

        rm -rf "$DEST"

        git clone \
            --depth 1 \
            -b "$BRANCH_NAME" \
            "$URL" \
            "$DEST"

    else

        if [[ -d "$DEST/.git" ]]; then

            git -C "$DEST" fetch \
                --depth 1 \
                origin "$BRANCH_NAME"

            git -C "$DEST" checkout -B "$BRANCH_NAME" \
                "origin/$BRANCH_NAME"

            git -C "$DEST" reset --hard \
                "origin/$BRANCH_NAME"

            git -C "$DEST" clean -fd

        else

            rm -rf "$DEST"

            git clone \
                --depth 1 \
                -b "$BRANCH_NAME" \
                "$URL" \
                "$DEST"

        fi
    fi
}

# ============================================================
# Device tree
# ============================================================

sync_repo \
    "https://github.com/eleve1n/android_device_lava_LXX525-lineage.git" \
    "$BRANCH" \
    "$DEVICE_DIR"

# ============================================================
# Read lineage.dependencies
# ============================================================

if [[ ! -f "$DEPENDENCIES" ]]; then
    echo "ERROR: lineage.dependencies not found:"
    echo "$DEPENDENCIES"
    exit 1
fi

echo
echo "============================================================"
echo " Detecting dependencies"
echo "============================================================"

python3 <<'PY'
import json
import os
import subprocess
import sys

dep_file = "device/lava/LXX525/lineage.dependencies"

with open(dep_file, "r", encoding="utf-8") as f:
    deps = json.load(f)

custom = {
    "android_device_lava_LXX525-kernel":
        "https://github.com/eleve1n/android_device_lava_LXX525-kernel.git",

    "android_vendor_lava_LXX525":
        "https://github.com/eleve1n/android_vendor_lava_LXX525.git",
}

for dep in deps:

    repo = dep.get("repository")
    target = dep.get("target_path")
    branch = dep.get("branch") or dep.get("revision")

    if not repo or not target:
        print("Skipping malformed dependency:", dep)
        continue

    if not branch:
        branch = "lineage-22.1"

    url = custom.get(
        repo,
        f"https://github.com/LineageOS/{repo}.git"
    )

    print()
    print("Dependency:")
    print("  Repository:", repo)
    print("  Branch:    ", branch)
    print("  Target:    ", target)
    print("  URL:       ", url)

    parent = os.path.dirname(target)

    if parent:
        os.makedirs(parent, exist_ok=True)

    if os.path.isdir(os.path.join(target, ".git")):

        print("  Action: UPDATE")

        subprocess.run(
            ["git", "-C", target, "fetch",
             "--depth", "1", "origin", branch],
            check=True
        )

        subprocess.run(
            ["git", "-C", target, "checkout", "-B",
             branch, f"origin/{branch}"],
            check=True
        )

        subprocess.run(
            ["git", "-C", target, "reset", "--hard",
             f"origin/{branch}"],
            check=True
        )

        subprocess.run(
            ["git", "-C", target, "clean", "-fd"],
            check=True
        )

    else:

        print("  Action: CLONE")

        if os.path.exists(target):
            import shutil
            shutil.rmtree(target)

        subprocess.run(
            ["git", "clone",
             "--depth", "1",
             "-b", branch,
             url,
             target],
            check=True
        )

PY

# ============================================================
# Verify required directories
# ============================================================

echo
echo "============================================================"
echo " Verifying repositories"
echo "============================================================"

REQUIRED=(
    "$DEVICE_DIR"
    "$KERNEL_DIR"
    "$VENDOR_DIR"
    "hardware/mediatek"
    "device/mediatek/sepolicy_vndr"
)

for DIR in "${REQUIRED[@]}"; do

    if [[ -d "$DIR" ]]; then
        echo "[OK] $DIR"
    else
        echo "[FAIL] Missing: $DIR"
        exit 1
    fi

done

# ============================================================
# Verify PREBUILT kernel
# ============================================================

echo
echo "============================================================"
echo " Verifying prebuilt kernel"
echo "============================================================"

KERNEL_IMAGE="$KERNEL_DIR/Image"

if [[ ! -f "$KERNEL_IMAGE" ]]; then
    echo "ERROR: Prebuilt kernel Image not found:"
    echo "$KERNEL_IMAGE"
    exit 1
fi

echo "[OK] Prebuilt kernel:"
echo "     $KERNEL_IMAGE"

# Optional kernel directories
if [[ -d "$KERNEL_DIR/dtb" ]]; then
    echo "[OK] dtb directory found"
else
    echo "[WARN] dtb directory not found"
fi

if [[ -d "$KERNEL_DIR/modules" ]]; then
    echo "[OK] modules directory found"
else
    echo "[WARN] modules directory not found"
fi

# ============================================================
# Build environment
# ============================================================

echo
echo "============================================================"
echo " Initializing build environment"
echo "============================================================"

source build/envsetup.sh

# ============================================================
# Lunch
# ============================================================

echo
echo "============================================================"
echo " Selecting target"
echo "============================================================"

lunch "$LUNCH_TARGET"

# ============================================================
# Build cleanup
# ============================================================

echo
echo "============================================================"
echo " Cleaning previous build artifacts"
echo "============================================================"

m installclean

# ============================================================
# Build
# ============================================================

echo
echo "============================================================"
echo " Starting ROM build"
echo "============================================================"
echo
echo "Target: $LUNCH_TARGET"
echo

m bacon

# ============================================================
# Result
# ============================================================

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

OUT="out/target/product/$DEVICE"

echo
echo "============================================================"
echo " BUILD SUCCESSFUL"
echo "============================================================"
echo " Device    : $DEVICE"
echo " Target    : $LUNCH_TARGET"
echo " Duration  : ${ELAPSED}s"
echo " Log       : $LOG_FILE"
echo

if [[ -d "$OUT" ]]; then
    echo "Output files:"
    find "$OUT" -maxdepth 1 -type f \
        \( -name "*.zip" -o -name "*.img" -o -name "*.json" \) \
        -printf "  %f\n" 2>/dev/null || true
fi

echo
echo "============================================================"
echo " DONE"
echo "============================================================"