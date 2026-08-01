#! /usr/bin/env bash
# shellcheck source-path=../../..

# Build the sharelatex/sharelatex image natively for ARM64 from source,
# optionally extending it with the full TeX Live distribution.
#
# - For Community Edition (SERVER_PRO=false) it clones
#   https://github.com/overleaf/overleaf at the tag matching config/version
#   and runs `podman build --platform=linux/arm64`.
# - For Server Pro it stops here — the source is in a private repo that you
#   must clone yourself (see the message printed below).
#
# The base image is tagged:
#   sharelatex/sharelatex:${IMAGE_VERSION}-arm64
#
# When --full-texlive is set, an additional overlay (Containerfile.fulltex)
# is built on top and tagged:
#   sharelatex/sharelatex:${IMAGE_VERSION}-arm64-fulltex
#
# install-quadlets.sh picks the -fulltex tag automatically when it exists
# locally, otherwise falls back to the base.
#
# Usage:
#   build-sharelatex-image.sh
#   build-sharelatex-image.sh --full-texlive
#   build-sharelatex-image.sh --full-texlive --mirror-url=https://mirror.clientvps.com/CTAN/systems/texlive/tlnet/install-tl-unx.tar.gz
#
# Environment / build-arg equivalents:
#   BUILD_FULL_TEXLIVE=true        same as --full-texlive
#   TEXLIVE_MIRROR_URL=...         mirror URL for install-tl-unx.tar.gz

set -euo pipefail

#### Detect Toolkit Project Root ####
# if realpath is not available, create a semi-equivalent function
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full-texlive)      BUILD_FULL_TEXLIVE=true ;;
    --no-full-texlive)   BUILD_FULL_TEXLIVE=false ;;
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

IMAGE_TAG="sharelatex/sharelatex:${IMAGE_VERSION}-arm64"
FULLTEX_TAG="${IMAGE_TAG}-fulltex"

echo "==> Image version : $IMAGE_VERSION"
echo "==> Server Pro    : $SERVER_PRO"
echo "==> Target tag    : $IMAGE_TAG"
if [[ "$BUILD_FULL_TEXLIVE" == "true" ]]; then
  echo "==> Full TeX Live : $FULLTEX_TAG"
fi

#### Server Pro: bail out (private repo) ####
if [[ "$SERVER_PRO" == "true" ]]; then
  cat >&2 <<EOF
Server Pro source is private. To build the Server Pro image:

  1. Clone the Server Pro repo into:
       $OVERLEAF_BUILD_DIR
     at the tag/commit matching config/version ($IMAGE_VERSION).
  2. Re-run this script — it will detect the existing clone and build from it.

This script will NOT try to fetch the private repo on your behalf.
EOF
  exit 1
fi

#### Community Edition: clone + build ####
if [[ ! -d "$OVERLEAF_BUILD_DIR/.git" ]]; then
  echo "==> Cloning https://github.com/overleaf/overleaf into $OVERLEAF_BUILD_DIR"
  mkdir -p "$(dirname "$OVERLEAF_BUILD_DIR")"
  git clone https://github.com/overleaf/overleaf.git "$OVERLEAF_BUILD_DIR"
fi

echo "==> Checking out tag $IMAGE_VERSION"
# tags in overleaf/overleaf are like "v6.2.2" — try with and without the "v" prefix
if ! git -C "$OVERLEAF_BUILD_DIR" fetch --tags --quiet; then
  echo "WARNING: failed to fetch tags (offline?). Will rely on local tags only." >&2
fi

if git -C "$OVERLEAF_BUILD_DIR" checkout --quiet "tags/$IMAGE_VERSION" 2>/dev/null; then
  CHECKED_OUT_REF="tag $IMAGE_VERSION"
elif git -C "$OVERLEAF_BUILD_DIR" checkout --quiet "tags/v$IMAGE_VERSION" 2>/dev/null; then
  CHECKED_OUT_REF="tag v$IMAGE_VERSION"
else
  # Modern Overleaf CE releases are not tagged in github.com/overleaf/overleaf —
  # only a handful of historic releases are. Fall back to the default branch
  # (origin/HEAD, or "main") so the build still produces an image; the result
  # may not match config/version exactly.
  DEFAULT_BRANCH="$(git -C "$OVERLEAF_BUILD_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  if [[ -z "$DEFAULT_BRANCH" ]]; then
    DEFAULT_BRANCH="main"
  fi

  if ! git -C "$OVERLEAF_BUILD_DIR" checkout --quiet "$DEFAULT_BRANCH" 2>/dev/null; then
    echo "ERROR: tag '$IMAGE_VERSION' (or 'v$IMAGE_VERSION') not found in overleaf/overleaf," >&2
    echo "  and could not check out default branch '$DEFAULT_BRANCH' either." >&2
    exit 1
  fi

  echo "WARNING: tag '$IMAGE_VERSION' (or 'v$IMAGE_VERSION') is not published on github.com/overleaf/overleaf;" >&2
  echo "  falling back to default branch '$DEFAULT_BRANCH'. The resulting image may not match config/version exactly." >&2
  CHECKED_OUT_REF="branch $DEFAULT_BRANCH"
fi

echo "    HEAD: $(git -C "$OVERLEAF_BUILD_DIR" rev-parse --short HEAD) ($CHECKED_OUT_REF)"

echo "==> Building $IMAGE_TAG (this will take a while — TeX Live base image is large)"
# BuildKit is the default in modern podman; --platform forces ARM64 even on
# x86 hosts (with qemu) so the resulting image is portable.
podman build \
  --platform=linux/arm64 \
  --tag "$IMAGE_TAG" \
  --pull=newer \
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

  podman build \
    --platform=linux/arm64 \
    --tag "$FULLTEX_TAG" \
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