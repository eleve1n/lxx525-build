#!/usr/bin/env bash

# ============================================================
# LXX525 - LineageOS 22.1 Crave Build Script
#
# Usage:
#   bash lxx525-22.1.sh first
#   bash lxx525-22.1.sh update
#
# Or:
#   BUILD_MODE=update bash lxx525-22.1.sh
#
# Environment:
#   CLEAN_BUILD=yes    -> run installclean before building
#   BUILD=yes          -> build after syncing (default: yes)
# ============================================================

set -Eeuo pipefail

# -----------------------------
# Configuration
# -----------------------------

DEVICE="LXX525"
VENDOR="lava"
BRANCH="lineage-22.1"
LUNCH_TARGET="lineage_LXX525-ap3a-userdebug"

DEVICE_DIR="device/${VENDOR}/${DEVICE}"
VENDOR_DIR="vendor/${VENDOR}/${DEVICE}"

DEVICE_REPO="https://github.com/eleve1n/android_device_lava_LXX525-lineage"
VENDOR_REPO="https://github.com/eleve1n/android_vendor_lava_LXX525"

MODE="${BUILD_MODE:-${1:-first}}"
CLEAN_BUILD="${CLEAN_BUILD:-yes}"
BUILD="${BUILD:-yes}"

LOG_DIR="${ANDROID_BUILD_TOP:-$PWD}/build-logs"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/lxx525-$(date '+%Y%m%d-%H%M%S').log"

# -----------------------------
# Logging
# -----------------------------

exec > >(tee -a "$LOG_FILE") 2>&1

timestamp() {
    date '+[%Y-%m-%d %H:%M:%S]'
}

log() {
    echo "$(timestamp) $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

# -----------------------------
# Basic checks
# -----------------------------

log "=============================================="
log " LXX525 LineageOS 22.1 Build"
log "=============================================="
log "Mode:          $MODE"
log "Device:        $DEVICE"
log "Branch:        $BRANCH"
log "Lunch target:  $LUNCH_TARGET"
log "Log:           $LOG_FILE"
log "=============================================="

case "$MODE" in
    first|update)
        ;;
    *)
        die "Invalid mode: $MODE (use 'first' or 'update')"
        ;;
esac

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [[ ! -f "build/envsetup.sh" ]]; then
    die "This does not look like an Android source tree."
fi

# -----------------------------
# Git helpers
# -----------------------------

clone_repo() {
    local repo="$1"
    local branch="$2"
    local path="$3"

    log "Cloning $repo"
    log "Branch: $branch"
    log "Path:   $path"

    mkdir -p "$(dirname "$path")"

    git clone \
        --depth 1 \
        --single-branch \
        -b "$branch" \
        "$repo" \
        "$path"
}

update_repo() {
    local path="$1"

    if [[ ! -d "$path/.git" ]]; then
        return 1
    fi

    log "Updating: $path"

    git -C "$path" fetch \
        --depth 1 \
        origin

    # Keep the existing branch when possible.
    local branch
    branch="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)"

    if [[ -n "$branch" ]]; then
        git -C "$path" reset --hard "origin/$branch"
    else
        log "WARNING: Could not determine branch for $path"
    fi

    git -C "$path" clean -fd
}

# -----------------------------
# Device/vendor trees
# -----------------------------

prepare_main_trees() {

    if [[ "$MODE" == "first" ]]; then

        log "Fresh setup requested."

        log "Removing old device/vendor trees..."
        rm -rf "$DEVICE_DIR"
        rm -rf "$VENDOR_DIR"

        clone_repo \
            "$DEVICE_REPO" \
            "$BRANCH" \
            "$DEVICE_DIR"

        clone_repo \
            "$VENDOR_REPO" \
            "$BRANCH" \
            "$VENDOR_DIR"

    else

        log "Update setup requested."

        if ! update_repo "$DEVICE_DIR"; then
            log "Device tree not found. Cloning it..."
            clone_repo \
                "$DEVICE_REPO" \
                "$BRANCH" \
                "$DEVICE_DIR"
        fi

        if ! update_repo "$VENDOR_DIR"; then
            log "Vendor tree not found. Cloning it..."
            clone_repo \
                "$VENDOR_REPO" \
                "$BRANCH" \
                "$VENDOR_DIR"
        fi
    fi
}

# -----------------------------
# lineage.dependencies support
# -----------------------------

process_dependencies() {

    log "=============================================="
    log " Checking lineage.dependencies"
    log "=============================================="

    local dependency_files=()

    [[ -f "$DEVICE_DIR/lineage.dependencies" ]] && \
        dependency_files+=("$DEVICE_DIR/lineage.dependencies")

    [[ -f "$VENDOR_DIR/lineage.dependencies" ]] && \
        dependency_files+=("$VENDOR_DIR/lineage.dependencies")

    if [[ ${#dependency_files[@]} -eq 0 ]]; then
        log "No lineage.dependencies found."
        log "No additional repositories detected automatically."
        return 0
    fi

    for depfile in "${dependency_files[@]}"; do

        log "Reading: $depfile"

        python3 - "$depfile" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

for dep in data:
    repo = dep.get("repository", "")
    target = dep.get("target_path", "")
    branch = dep.get("branch", "")

    if not repo or not target:
        continue

    print(
        repo.replace("https://github.com/", "").replace(".git", ""),
        "|",
        target,
        "|",
        branch
    )
PY

    done | while IFS='|' read -r repo target branch; do

        repo="$(echo "$repo" | xargs)"
        target="$(echo "$target" | xargs)"
        branch="$(echo "$branch" | xargs)"

        [[ -z "$repo" ]] && continue
        [[ -z "$target" ]] && continue

        # Default to the main Lineage branch when the dependency
        # does not specify one.
        if [[ -z "$branch" ]]; then
            branch="$BRANCH"
        fi

        # Normalize github repositories.
        if [[ "$repo" != https://* ]]; then
            repo="https://github.com/${repo}"
        fi

        log "Dependency detected:"
        log "  Repository: $repo"
        log "  Target:     $target"
        log "  Branch:     $branch"

        if [[ -d "$target/.git" ]]; then

            if [[ "$MODE" == "update" ]]; then
                update_repo "$target" || \
                    log "WARNING: Could not update $target"
            else
                log "Dependency already exists: $target"
            fi

        elif [[ -e "$target" ]]; then

            log "WARNING: $target exists but is not a Git repository."
            log "Skipping automatic clone."

        else

            clone_repo \
                "$repo" \
                "$branch" \
                "$target"
        fi

    done
}

# -----------------------------
# Setup
# -----------------------------

prepare_main_trees
process_dependencies

# -----------------------------
# Verify important files
# -----------------------------

log "=============================================="
log " Verifying device tree"
log "=============================================="

if [[ ! -d "$DEVICE_DIR" ]]; then
    die "Device tree missing: $DEVICE_DIR"
fi

if [[ ! -d "$VENDOR_DIR" ]]; then
    die "Vendor tree missing: $VENDOR_DIR"
fi

log "Device tree: OK"
log "Vendor tree: OK"

# -----------------------------
# Android build environment
# -----------------------------

log "=============================================="
log " Loading Android build environment"
log "=============================================="

source build/envsetup.sh

log "Selecting lunch target:"
log "$LUNCH_TARGET"

lunch "$LUNCH_TARGET"

# -----------------------------
# Build cleanup
# -----------------------------

if [[ "$CLEAN_BUILD" == "yes" ]]; then

    log "=============================================="
    log " Running installclean"
    log "=============================================="

    # installclean is much less destructive than 'm clean'
    # and is appropriate when rebuilding after source changes.
    m installclean
fi

# -----------------------------
# Build
# -----------------------------

if [[ "$BUILD" == "yes" ]]; then

    log "=============================================="
    log " Starting ROM build"
    log "=============================================="

    log "Target: $LUNCH_TARGET"
    log "Command: m bacon"

    START_TIME=$(date +%s)

    m bacon

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    log "=============================================="
    log " BUILD SUCCESSFUL"
    log "=============================================="
    log "Build time: ${ELAPSED} seconds"

else

    log "BUILD=no - source preparation completed."
fi

log "Log saved to:"
log "$LOG_FILE"

exit 0