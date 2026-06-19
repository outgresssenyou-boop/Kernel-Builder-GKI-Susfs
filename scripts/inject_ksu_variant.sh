#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace
[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

VARIANT=$1
MANAGER_DIR="KernelSU"
rm -rf "${MANAGER_DIR}"

echo "=== Integrating ${VARIANT} ==="
echo ">>> Cloning custom pipeline branch: ${KSU_VARIANT_REF}..."
git clone "${KSU_VARIANT_REPO_URL}" -b "${KSU_VARIANT_REF}" "${MANAGER_DIR}"

# Setup.sh runs cleanly because OWNER is patched at the source level
echo ">>> Executing native setup.sh..."
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"

# Route the URL and default branch based on the variant
if [[ "${VARIANT}" == "KernelSU" ]]; then
    UPSTREAM_REPO="tiann/KernelSU"
    UPSTREAM_BRANCH="main"
elif [[ "${VARIANT}" == "KernelSU-Next" ]]; then
    UPSTREAM_REPO="KernelSU-Next/KernelSU-Next"
    UPSTREAM_BRANCH="dev"
elif [[ "${VARIANT}" == "SukiSU-Ultra" ]]; then
    UPSTREAM_REPO="SukiSU-Ultra/SukiSU-Ultra"
    UPSTREAM_BRANCH="main"
elif [[ "${VARIANT}" == "ReSukiSU" ]]; then
    UPSTREAM_REPO="ReSukiSU/ReSukiSU"
    UPSTREAM_BRANCH="main"
else
    UPSTREAM_REPO="tiann/KernelSU"
    UPSTREAM_BRANCH="main"
fi

echo ">>> Locating official upstream sync point..."
# Fetch the official upstream branch to find the divergence point
git -C "${MANAGER_DIR}" fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${UPSTREAM_BRANCH}"

# Dynamically calculate the exact upstream commit before your custom commits began
UPSTREAM_HASH=$(git -C "${MANAGER_DIR}" merge-base HEAD FETCH_HEAD)
SHORT_HASH=${UPSTREAM_HASH:0:7}

# Export the exact sync commit to the GitHub Env for the artifact fetcher
echo "UPSTREAM_HASH=${UPSTREAM_HASH}" >> $GITHUB_ENV

echo ">>> Severing Kbuild Git dependencies for Kleaf Sandbox..."
TARGET_KBUILD="${MANAGER_DIR}/kernel/Kbuild"

if [ -f "$TARGET_KBUILD" ]; then
    # Calculate the exact values outside the sandbox
    CALCULATED_COUNT=$(git -C "${MANAGER_DIR}" rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git -C "${MANAGER_DIR}" describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v3.2.0")
    
    # Prepend GNU Make immutable overrides to the very top of Kbuild.
    # This natively forces Make to ignore all $(shell git...) commands downstream.
    {
        echo "override KSU_GIT_VERSION_VALID := 1"
        echo "override KSU_GIT_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_GIT_TAG := ${CALCULATED_TAG}"
        echo "override KSU_TAG_NAME := ${CALCULATED_TAG}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}"
        cat "$TARGET_KBUILD"
    } > "${TARGET_KBUILD}.tmp" && mv "${TARGET_KBUILD}.tmp" "$TARGET_KBUILD"
    
    echo "  -> Prepend Immutable Gatekeeper: TRUE"
    echo "  -> Prepend Immutable Count: ${CALCULATED_COUNT}"
    echo "  -> Prepend Immutable Tag: ${CALCULATED_TAG}"
    echo "  -> Prepend Immutable SHA: ${SHORT_HASH}"
fi

echo ">>> Injecting Bazel symlink..."
DRIVER_ROOT="common/drivers"
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} architecture locked, sanitized and integrated!"
