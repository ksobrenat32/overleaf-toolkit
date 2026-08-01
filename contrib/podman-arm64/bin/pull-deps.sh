#! /usr/bin/env bash
# shellcheck source-path=../../..

# Pull the mongo + redis images for ARM64. Both projects publish multi-arch
# images on Docker Hub, so no source build is needed.
#
# Reads MONGO_IMAGE / MONGO_VERSION / REDIS_IMAGE from config/overleaf.rc
# (same vars the toolkit's compose fragments use).

set -euo pipefail

#### Detect Toolkit Project Root ####
command -v realpath >/dev/null 2>&1 || realpath() {
  [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
TOOLKIT_ROOT="$(realpath "$SCRIPT_DIR/../../..")"
if [[ ! -d "$TOOLKIT_ROOT/bin" ]] || [[ ! -d "$TOOLKIT_ROOT/config" ]]; then
  echo "ERROR: could not find root of overleaf-toolkit project (inferred project root as '$TOOLKIT_ROOT')" >&2
  exit 1
fi

source "$TOOLKIT_ROOT/lib/shared-functions.sh"

#### Sanity checks ####
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH." >&2
  exit 1
fi

read_image_version
read_config

#### Resolve image references (same logic as the toolkit) ####
# MONGO_IMAGE may be "mongo" or "mongo:6.0" — split it. The toolkit's
# read_mongo_version does the same; we re-implement minimally here so this
# script doesn't fail on a missing MONGO_VERSION.
MONGO_IMAGE_NAME=$(read_configuration MONGO_IMAGE)
MONGO_IMAGE_VERSION=$(read_configuration MONGO_VERSION)
if [[ -z "$MONGO_IMAGE_VERSION" ]]; then
  # fallback: split MONGO_IMAGE on the last colon
  if [[ "$MONGO_IMAGE_NAME" == *:* ]]; then
    MONGO_IMAGE_VERSION="${MONGO_IMAGE_NAME##*:}"
    MONGO_IMAGE_NAME="${MONGO_IMAGE_NAME%:*}"
  else
    echo "ERROR: MONGO_VERSION is unset and MONGO_IMAGE=$MONGO_IMAGE_NAME has no :tag." >&2
    echo "  Set MONGO_VERSION in config/overleaf.rc (e.g. MONGO_VERSION=6.0)." >&2
    exit 1
  fi
fi
MONGO_IMAGE_REF="${MONGO_IMAGE_NAME}:${MONGO_IMAGE_VERSION}"

REDIS_IMAGE_REF=$(read_configuration REDIS_IMAGE)
if [[ -z "$REDIS_IMAGE_REF" ]]; then
  echo "ERROR: REDIS_IMAGE is not set in config/overleaf.rc." >&2
  exit 1
fi

echo "==> Pulling mongo ($MONGO_IMAGE_REF) for linux/arm64"
podman pull --platform=linux/arm64 "$MONGO_IMAGE_REF"

echo "==> Pulling redis ($REDIS_IMAGE_REF) for linux/arm64"
podman pull --platform=linux/arm64 "$REDIS_IMAGE_REF"

echo
echo "==> Done."
echo "Next step:"
echo "    ./contrib/podman-arm64/bin/install-quadlets.sh"