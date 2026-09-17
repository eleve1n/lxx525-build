#!/bin/bash
set -Eeuo pipefail

# ============================================================
# LXX525 LineageOS 22.1 - Crave Build Script
#
# Usage:
#   bash lxx525-22.1.sh update
#
# Crave:
#   crave run --no-patch -- \
#     "curl -fsSL https://raw.githubusercontent.com/eleve1n/lxx525-build/main/lxx525-22.1.sh | bash -s -- update"
#
# NOTE: All device repositories are synced by the LOCAL MANIFEST
# (eleve1n/local_manifests) via `repo sync`. This script does NOT
# manually clone anything — manual clones conflict with
# repo-managed checkouts ("unsupported checkout state" /
# "'origin' does not appear to be a git repository").
#
# The kernel repo (eleve1n/android_device_lava_LXX525-kernel)
# must exist on branch lineage-22.1 and be listed in the local
# manifest before this build can produce a boot image.
# ============================================================

DEVICE="LXX525"
BRANCH="lineage-22.1"
LUNCH_TARGET="lineage_LXX525-ap3a-userdebug"

DEVICE_DIR="device/lava/LXX525"
VENDOR_DIR="vendor/lava/LXX525"

MODE="${1:-update}"

# ============================================================
# Sync main LineageOS source (Crave cache)
# ============================================================

echo "==> Syncing source..."
/opt/crave/resync.sh

# ============================================================
# GitHub / local manifest
# ============================================================

MANIFEST_REPO="https://github.com/eleve1n/local_manifests.git"
MANIFEST_BRANCH="main"
MANIFEST_FILE="local_manifests.xml"

# Set UPLOAD=1 to create/update a GitHub Release.
UPLOAD="${UPLOAD:-0}"
UPLOAD_REPO="${UPLOAD_REPO:-}"
UPLOAD_TAG="${UPLOAD_TAG:-}"
UPLOAD_PRERELEASE="${UPLOAD_PRERELEASE:-0}"

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
# Local manifest
# ============================================================

echo
echo "============================================================"
echo " Updating local manifest"
echo "============================================================"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download the local manifest."
    exit 1
fi
mkdir -p ".repo/local_manifests"

MANIFEST_URL="https://raw.githubusercontent.com/eleve1n/local_manifests/${MANIFEST_BRANCH}/${MANIFEST_FILE}"

curl -fsSL "$MANIFEST_URL"     -o ".repo/local_manifests/${MANIFEST_FILE}"

echo "[OK] Local manifest:"
echo "     ${MANIFEST_URL}"
echo "     -> .repo/local_manifests/${MANIFEST_FILE}"

echo
echo "============================================================"
echo " Syncing repositories from local manifest"
echo "============================================================"

# -c = current branch only (faster)
repo sync -c --force-sync --no-clone-bundle --no-tags -j"$(nproc --all)"

# NOTE: Do NOT manually git-clone/fetch the device, vendor,
# sepolicy or hardware repos here — they are owned by the
# local manifest + repo sync. Manual management of these
# directories causes checkout-state conflicts on the next
# build.

# ============================================================
# Verify required directories
# ============================================================

echo
echo "============================================================"
echo " Verifying repositories"
echo "============================================================"

REQUIRED=(
    "$DEVICE_DIR"
    "$DEVICE_DIR/prebuilt/kernel"
    "$DEVICE_DIR/prebuilt/dtb"
    "$VENDOR_DIR"
    "hardware/mediatek"
    "device/mediatek/sepolicy_vndr"
)

for DIR in "${REQUIRED[@]}"; do

    if [[ -d "$DIR" ]]; then
        echo "[OK] $DIR"
    else
        echo "[FAIL] Missing: $DIR"
        if [[ "$DIR" == "$DEVICE_DIR/prebuilt/kernel" ]]; then
            echo
            echo "The prebuilt kernel image is missing from the device tree."
            echo "Expected: $DEVICE_DIR/prebuilt/kernel"
        elif [[ "$DIR" == "$DEVICE_DIR/prebuilt/dtb" ]]; then
            echo
            echo "The prebuilt DTB directory is missing from the device tree."
            echo "Expected: $DEVICE_DIR/prebuilt/dtb"
            echo "Upload the split .dtb file(s) there."
        fi
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

KERNEL_IMAGE="$DEVICE_DIR/prebuilt/kernel"

if [[ ! -f "$KERNEL_IMAGE" ]]; then
    echo "ERROR: Prebuilt kernel Image not found:"
    echo "$KERNEL_IMAGE"
    exit 1
fi

echo "[OK] Prebuilt kernel:"
echo "     $KERNEL_IMAGE"

# Optional kernel directories
if [[ -n "$(ls -A "$DEVICE_DIR/prebuilt/dtb" 2>/dev/null)" ]]; then
    echo "[OK] dtb directory has files"
else
    echo "[WARN] dtb directory is empty"
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
# GitHub Release / checksums / changelog
# ============================================================

generate_release() {
    local OUT_DIR="$1"

    echo
    echo "============================================================"
    echo " Preparing GitHub Release"
    echo "============================================================"

    if [[ "$UPLOAD" != "1" ]]; then
        echo "Upload disabled (UPLOAD=${UPLOAD})."
        return 0
    fi

    if [[ -z "$UPLOAD_REPO" ]]; then
        echo "ERROR: UPLOAD_REPO is required when UPLOAD=1."
        echo "Example:"
        echo "  UPLOAD=1 UPLOAD_REPO=eleve1n/LXX525-LineageOS $0 update"
        exit 1
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: GitHub CLI (gh) is required for uploads."
        echo "Install it and run: gh auth login"
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: GitHub CLI is not authenticated."
        echo "Run: gh auth login"
        exit 1
    fi

    local RELEASE_DATE
    local RELEASE_TAG
    local RELEASE_TITLE
    RELEASE_DATE="$(date '+%Y-%m-%d')"
    RELEASE_TAG="${UPLOAD_TAG:-LXX525-LineageOS-22.1-$(date '+%Y%m%d-%H%M%S')}"
    RELEASE_TITLE="LXX525 • LineageOS 22.1 • ${RELEASE_DATE}"

    local RELEASE_DIR="${OUT_DIR}/release"
    mkdir -p "$RELEASE_DIR"

    local CHANGELOG="${RELEASE_DIR}/CHANGELOG.md"
    local CHECKSUMS="${RELEASE_DIR}/SHA256SUMS.txt"

    echo "Release tag   : $RELEASE_TAG"
    echo "Release title : $RELEASE_TITLE"
    echo "Repository    : $UPLOAD_REPO"

    # Collect artifacts without modifying the original output directory.
    local ARTIFACTS=()
    while IFS= read -r -d '' file; do
        ARTIFACTS+=("$file")
    done < <(
        find "$OUT_DIR" -maxdepth 1 -type f \
            \( -name "*.zip" \
            -o -name "boot.img" \
            -o -name "recovery.img" \
            -o -name "vendor_boot.img" \
            -o -name "dtbo.img" \
            -o -name "vbmeta.img" \
            -o -name "vbmeta_system.img" \) \
            -print0
    )

    if [[ "${#ARTIFACTS[@]}" -eq 0 ]]; then
        echo "ERROR: No ROM/image artifacts found in:"
        echo "       $OUT_DIR"
        exit 1
    fi

    # SHA256 checksums.
    : > "$CHECKSUMS"
    for file in "${ARTIFACTS[@]}"; do
        sha256sum "$file" >> "$CHECKSUMS"
    done

    echo
    echo "SHA256 checksums:"
    cat "$CHECKSUMS"

    # Generate changelog from the repositories that are actually present.
    {
        echo "# ${RELEASE_TITLE}"
        echo
        echo "## Build Information"
        echo
        echo "- Device: \`${DEVICE}\`"
        echo "- Android branch: \`${BRANCH}\`"
        echo "- Build target: \`${LUNCH_TARGET}\`"
        echo "- Build date: \`${START_DATE}\`"
        echo "- Release tag: \`${RELEASE_TAG}\`"
        echo
        echo "## Artifacts"
        echo
        for file in "${ARTIFACTS[@]}"; do
            echo "- \`$(basename "$file")\`"
        done
        echo "- \`SHA256SUMS.txt\`"
        echo
        echo "## Recent Changes"
        echo

        add_git_log() {
            local label="$1"
            local path="$2"

            if [[ -d "$path/.git" ]]; then
                echo "### ${label}"
                echo
                git -C "$path" log -10 --pretty=format:'- `%h` %s' 2>/dev/null || true
                echo
                echo
            fi
        }

        add_git_log "Device Tree" "$DEVICE_DIR"
        add_git_log "Vendor" "$VENDOR_DIR"

        echo "## Checksums"
        echo
        echo '```text'
        cat "$CHECKSUMS"
        echo '```'
    } > "$CHANGELOG"

    # Copy release metadata into the release asset directory.
    cp "$CHECKSUMS" "$RELEASE_DIR/SHA256SUMS.txt"

    local RELEASE_ASSETS=()
    for file in "${ARTIFACTS[@]}"; do
        RELEASE_ASSETS+=("$file")
    done
    RELEASE_ASSETS+=("$CHECKSUMS" "$CHANGELOG")

    echo
    echo "Creating/updating GitHub Release..."

    if gh release view "$RELEASE_TAG" --repo "$UPLOAD_REPO" >/dev/null 2>&1; then
        gh release edit "$RELEASE_TAG" \
            --repo "$UPLOAD_REPO" \
            --title "$RELEASE_TITLE" \
            --notes-file "$CHANGELOG" \
            $( [[ "$UPLOAD_PRERELEASE" == "1" ]] && echo "--prerelease" || true )
    else
        local CREATE_ARGS=(
            "$RELEASE_TAG"
            --repo "$UPLOAD_REPO"
            --title "$RELEASE_TITLE"
            --notes-file "$CHANGELOG"
        )

        if [[ "$UPLOAD_PRERELEASE" == "1" ]]; then
            CREATE_ARGS+=(--prerelease)
        fi

        gh release create "${CREATE_ARGS[@]}"
    fi

    echo
    echo "Uploading artifacts..."

    gh release upload \
        "$RELEASE_TAG" \
        "${RELEASE_ASSETS[@]}" \
        --repo "$UPLOAD_REPO" \
        --clobber

    echo
    echo "============================================================"
    echo " GitHub Release Published"
    echo "============================================================"
    echo " Release : $RELEASE_TAG"
    echo " Repo    : $UPLOAD_REPO"
    echo "============================================================"
}

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

# Publish GitHub release (no-op when UPLOAD is not 1).
generate_release "$OUT"

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
