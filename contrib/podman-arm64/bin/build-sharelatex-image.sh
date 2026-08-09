#! /usr/bin/env bash
# shellcheck source-path=../../..

# Build the sharelatex/sharelatex image natively for ARM64 from source,
# optionally extending it with the full TeX Live distribution.
#
# By default this builds from the main branch of overleaf/overleaf and tags
# the result with the version from config/version:
#   sharelatex/sharelatex:${IMAGE_VERSION}-arm64
#   sharelatex/sharelatex:${IMAGE_VERSION}-arm64-fulltex   (with --full-texlive)
#
# The overleaf/overleaf repo does not have per-release git tags, so the tag
# on the resulting image is for your local tracking — it matches whatever
# config/version says, not a git tag in the source repo.
#
# Usage:
#   build-sharelatex-image.sh
#   build-sharelatex-image.sh --full-texlive --low-memory
#   build-sharelatex-image.sh --ref=main                 # explicit ref (the default)
#   build-sharelatex-image.sh --ref=abc1234              # specific commit
#   build-sharelatex-image.sh --full-texlive --mirror-url=https://mirror.clientvps.com/CTAN/systems/texlive/tlnet/install-tl-unx.tar.gz
#
# Flags / env vars:
#   BUILD_FULL_TEXLIVE=true        --full-texlive
#   BUILD_LOW_MEMORY=true          --low-memory        (reduces NODE_OPTIONS + podman memory)
#   BUILD_REF=ref                  --ref=ref           (git ref to build; default: main)
#   TEXLIVE_MIRROR_URL=...         --mirror-url=URL    (mirror for fulltex overlay)
#   FORCE_ARM64_BUILD=true                             (allow cross-build on non-ARM64)

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

OVERLEAF_BUILD_DIR="$TOOLKIT_ROOT/contrib/podman-arm64/build/overleaf"
FULLTEX_CONTAINERFILE="$TOOLKIT_ROOT/contrib/podman-arm64/Containerfile.fulltex"
FULLTEX_CONTEXT_DIR="$TOOLKIT_ROOT/contrib/podman-arm64"

#### Parse flags ####
BUILD_FULL_TEXLIVE="${BUILD_FULL_TEXLIVE:-false}"
BUILD_LOW_MEMORY="${BUILD_LOW_MEMORY:-false}"
BUILD_REF="${BUILD_REF:-main}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-texlive)      BUILD_FULL_TEXLIVE=true ;;
    --no-full-texlive)   BUILD_FULL_TEXLIVE=false ;;
    --low-memory)        BUILD_LOW_MEMORY=true ;;
    --no-low-memory)     BUILD_LOW_MEMORY=false ;;
    --ref=*)             BUILD_REF="${1#*=}" ;;
    --mirror-url=*)      TEXLIVE_MIRROR_URL="${1#*=}" ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

#### Sanity checks ####
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH. Install podman >= 4.4 with quadlet support." >&2
  exit 1
fi

if [[ "$(uname -m)" != "aarch64" ]] && [[ "${FORCE_ARM64_BUILD:-false}" != "true" ]]; then
  echo "WARNING: host is $(uname -m), not aarch64." >&2
  echo "  Cross-building ARM64 on a non-ARM host requires qemu-user-static and is slow." >&2
  echo "  Set FORCE_ARM64_BUILD=true to continue anyway." >&2
  exit 1
fi

#### Read toolkit config ####
read_image_version
read_config

IMAGE_TAG="${OVERLEAF_IMAGE_REGISTRY:-}sharelatex/sharelatex:${IMAGE_VERSION}-arm64"
FULLTEX_TAG="${IMAGE_TAG}-fulltex"

echo "==> Image version : $IMAGE_VERSION"
echo "==> Server Pro    : $SERVER_PRO"
echo "==> Source ref    : $BUILD_REF"
echo "==> Target tag    : $IMAGE_TAG"
if [[ "$BUILD_FULL_TEXLIVE" == "true" ]]; then
  echo "==> Full TeX Live : $FULLTEX_TAG"
fi
if [[ "$BUILD_LOW_MEMORY" == "true" ]]; then
  echo "==> Low memory    : yes (podman will cap memory + NODE_OPTIONS=--max-old-space-size=2048)"
fi

#### Server Pro: bail out (private repo) ####
if [[ "$SERVER_PRO" == "true" ]]; then
  cat >&2 <<EOF
Server Pro source is private. To build the Server Pro image:

  1. Clone the Server Pro repo into:
       $OVERLEAF_BUILD_DIR
     at the commit matching config/version ($IMAGE_VERSION).
  2. Re-run this script — it will detect the existing clone and build from it.

This script will NOT try to fetch the private repo on your behalf.
EOF
  exit 1
fi

#### Community Edition: clone + checkout ####
if [[ ! -d "$OVERLEAF_BUILD_DIR/.git" ]]; then
  echo "==> Cloning https://github.com/overleaf/overleaf into $OVERLEAF_BUILD_DIR"
  mkdir -p "$(dirname "$OVERLEAF_BUILD_DIR")"
  git clone https://github.com/overleaf/overleaf.git "$OVERLEAF_BUILD_DIR"
fi

echo "==> Fetching latest from origin"
git -C "$OVERLEAF_BUILD_DIR" fetch origin --quiet

echo "==> Checking out ref '$BUILD_REF'"
if ! git -C "$OVERLEAF_BUILD_DIR" checkout --quiet --force "$BUILD_REF" 2>/dev/null; then
  echo "ERROR: ref '$BUILD_REF' not found in overleaf/overleaf." >&2
  echo "  Check that the ref is a valid branch, tag, or commit hash." >&2
  exit 1
fi

#### Build the base image first ####
# The overleaf/overleaf repo uses a two-stage Docker build:
#   1. server-ce/Dockerfile-base  →  sharelatex/sharelatex-base
#   2. server-ce/Dockerfile       →  sharelatex/sharelatex (FROM the base)
# Both use the monorepo root as the build context.
BASE_TAG="${OVERLEAF_IMAGE_REGISTRY:-}sharelatex/sharelatex-base:${IMAGE_VERSION}-arm64"
DOCKERFILE_BASE="$OVERLEAF_BUILD_DIR/server-ce/Dockerfile-base"
DOCKERFILE_COMMUNITY="$OVERLEAF_BUILD_DIR/server-ce/Dockerfile"

PODMAN_COMMON_ARGS=(--platform=linux/arm64 --pull=newer)
if [[ "$BUILD_LOW_MEMORY" == "true" ]]; then
  PODMAN_COMMON_ARGS+=(--memory=4g)
  export NODE_OPTIONS="--max-old-space-size=2048"
fi
if [[ -n "${TEXLIVE_MIRROR_URL:-}" ]]; then
  PODMAN_COMMON_ARGS+=(--build-arg "TEXLIVE_MIRROR=${TEXLIVE_MIRROR_URL}")
  echo "    TEXLIVE_MIRROR=$TEXLIVE_MIRROR_URL"
fi

echo "==> Building base image $BASE_TAG"
echo "    Context: $OVERLEAF_BUILD_DIR"
echo "    File:    $DOCKERFILE_BASE"
podman build \
  "${PODMAN_COMMON_ARGS[@]}" \
  --tag "$BASE_TAG" \
  -f "$DOCKERFILE_BASE" \
  "$OVERLEAF_BUILD_DIR"

echo "==> Building community image $IMAGE_TAG"
echo "    Context: $OVERLEAF_BUILD_DIR"
echo "    File:    $DOCKERFILE_COMMUNITY"
podman build \
  "${PODMAN_COMMON_ARGS[@]}" \
  --build-arg "OVERLEAF_BASE_TAG=${BASE_TAG}" \
  --tag "$IMAGE_TAG" \
  -f "$DOCKERFILE_COMMUNITY" \
  "$OVERLEAF_BUILD_DIR"

#### Optional fulltex overlay ####
if [[ "$BUILD_FULL_TEXLIVE" == "true" ]]; then
  if [[ ! -f "$FULLTEX_CONTAINERFILE" ]]; then
    echo "ERROR: $FULLTEX_CONTAINERFILE is missing." >&2
    exit 1
  fi

  echo "==> Building $FULLTEX_TAG with full TeX Live (this will take a long time — ~7 GB of TeX packages)"
  FULLTEX_BUILD_ARGS=(--build-arg "BASE_IMAGE=${IMAGE_TAG}")
  if [[ -n "${TEXLIVE_MIRROR_URL:-}" ]]; then
    FULLTEX_BUILD_ARGS+=(--build-arg "TEXLIVE_MIRROR_URL=${TEXLIVE_MIRROR_URL}")
    echo "    TEXLIVE_MIRROR_URL=$TEXLIVE_MIRROR_URL"
  fi

  PODMAN_FULLTEX_BUILD_ARGS=(
    --platform=linux/arm64
    --tag "$FULLTEX_TAG"
  )

  if [[ "$BUILD_LOW_MEMORY" == "true" ]]; then
    PODMAN_FULLTEX_BUILD_ARGS+=(--memory=4g)
  fi

  podman build \
    "${PODMAN_FULLTEX_BUILD_ARGS[@]}" \
    "${FULLTEX_BUILD_ARGS[@]}" \
    -f "$FULLTEX_CONTAINERFILE" \
    "$FULLTEX_CONTEXT_DIR"
fi

echo
echo "==> Done."
echo "    Base image  : $IMAGE_TAG"
if [[ "$BUILD_FULL_TEXLIVE" == "true" ]]; then
  echo "    Full TeX img: $FULLTEX_TAG"
fi
echo
echo "Next steps:"
echo "    ./contrib/podman-arm64/bin/pull-deps.sh"
echo "    ./contrib/podman-arm64/bin/install-quadlets.sh"