#! /usr/bin/env bash
# shellcheck source-path=../../..

# Render the quadlet templates under quadlets/ and install them into the
# systemd user quadlet directory (~/.config/containers/systemd/), then
# reload systemd so the new units are visible.
#
# Re-run this whenever you change bind-mount paths, the listen IP/port,
# the data-path variables, or the image version in config/overleaf.rc.

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

QUADLET_SRC_DIR="$TOOLKIT_ROOT/contrib/podman-arm64/quadlets"
QUADLET_DST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

#### Sanity checks ####
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl is not on PATH (this script requires a systemd user session)." >&2
  exit 1
fi
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH." >&2
  exit 1
fi
if [[ ! -f "$TOOLKIT_ROOT/config/variables.env" ]]; then
  echo "ERROR: $TOOLKIT_ROOT/config/variables.env is missing. Run bin/init first." >&2
  exit 1
fi

read_image_version
read_config
read_mongo_version

#### Resolve paths the same way the toolkit's bin/docker-compose does ####
# (Inlined rather than calling canonicalize_data_paths from bin/docker-compose
# because that function is local to that script, not in shared-functions.sh.)
#
# mkdir -p first because GNU realpath errors on non-existent paths; the
# toolkit's bin/up handles this by running ensure_data_dirs_exist *before*
# invoking bin/docker-compose. We do it inline because we only know the
# paths after sourcing the user's config/overleaf.rc.
mkdir -p "$OVERLEAF_DATA_PATH" "$MONGO_DATA_PATH" "$REDIS_DATA_PATH"
OVERLEAF_DATA_PATH=$(cd "$TOOLKIT_ROOT" && realpath "$OVERLEAF_DATA_PATH")
MONGO_DATA_PATH=$(cd "$TOOLKIT_ROOT" && realpath "$MONGO_DATA_PATH")
REDIS_DATA_PATH=$(cd "$TOOLKIT_ROOT" && realpath "$REDIS_DATA_PATH")

# OVERLEAF_LISTEN_IP defaults to 0.0.0.0 if unset (matches the toolkit).
OVERLEAF_PORT="${OVERLEAF_PORT:-80}"
if [[ -z "${OVERLEAF_LISTEN_IP:-}" ]] || [[ "$OVERLEAF_LISTEN_IP" == "0.0.0.0" ]]; then
  PUBLISH_PORT_SPEC="${OVERLEAF_PORT}:80"
else
  PUBLISH_PORT_SPEC="${OVERLEAF_LISTEN_IP}:${OVERLEAF_PORT}:80"
fi

# Mongo image reference (split like the toolkit does).
MONGO_IMAGE_NAME=$(read_configuration MONGO_IMAGE)
MONGO_IMAGE_VERSION=$(read_configuration MONGO_VERSION)
if [[ -z "$MONGO_IMAGE_VERSION" ]]; then
  if [[ "$MONGO_IMAGE_NAME" == *:* ]]; then
    MONGO_IMAGE_VERSION="${MONGO_IMAGE_NAME##*:}"
    MONGO_IMAGE_NAME="${MONGO_IMAGE_NAME%:*}"
  else
    echo "ERROR: MONGO_VERSION unset and MONGO_IMAGE has no tag." >&2
    exit 1
  fi
fi
MONGO_IMAGE_FULL="${MONGO_IMAGE_NAME}:${MONGO_IMAGE_VERSION}"

REDIS_IMAGE_FULL=$(read_configuration REDIS_IMAGE)
if [[ -z "$REDIS_IMAGE_FULL" ]]; then
  echo "ERROR: REDIS_IMAGE is unset in config/overleaf.rc." >&2
  exit 1
fi

# Env-var prefix per image major (matches lib/docker-compose.vars.yml vs
# lib/docker-compose.vars-legacy.yml).
if [[ "$IMAGE_VERSION_MAJOR" -lt 5 ]]; then
  MONGO_ENV_VAR="SHARELATEX_MONGO_URL"
  REDIS_ENV_VAR="SHARELATEX_REDIS_HOST"
  IN_CONTAINER_DATA_PATH="/var/lib/sharelatex"
else
  MONGO_ENV_VAR="OVERLEAF_MONGO_URL"
  REDIS_ENV_VAR="OVERLEAF_REDIS_HOST"
  IN_CONTAINER_DATA_PATH="/var/lib/overleaf"
fi

# REDIS_COMMAND — match the toolkit's bin/docker-compose set_redis_vars.
if [[ -z "${REDIS_AOF_PERSISTENCE:-}" ]]; then
  REDIS_COMMAND="redis-server"
elif [[ "${REDIS_AOF_PERSISTENCE}" == "true" ]]; then
  REDIS_COMMAND="redis-server --appendonly yes"
else
  REDIS_COMMAND="redis-server"
fi

#### Pick the sharelatex image tag (base vs fulltex overlay) ####
# Build script produces:
#   sharelatex/sharelatex:${IMAGE_VERSION}-arm64          (always)
#   sharelatex/sharelatex:${IMAGE_VERSION}-arm64-fulltex  (only when --full-texlive)
#
# Selection rules:
#   - OVERLEAF_FULL_TEXLIVE=true  in env or config  → require the -fulltex tag (error if absent)
#   - OVERLEAF_FULL_TEXLIVE=false in env or config  → always use the base
#   - unset                                           → auto-detect: -fulltex if present, else base
OVERLEAF_FULL_TEXLIVE_OVERRIDE=$(read_configuration OVERLEAF_FULL_TEXLIVE || true)
BASE_TAG="${OVERLEAF_IMAGE_REGISTRY:-}sharelatex/sharelatex:${IMAGE_VERSION}-arm64"
FULLTEX_TAG="${BASE_TAG}-fulltex"

case "${OVERLEAF_FULL_TEXLIVE_OVERRIDE:-auto}" in
  true)
    if ! podman image exists "$FULLTEX_TAG" 2>/dev/null; then
      echo "ERROR: OVERLEAF_FULL_TEXLIVE=true but $FULLTEX_TAG is not in local podman storage." >&2
      echo "  Build it first:" >&2
      echo "    ./contrib/podman-arm64/bin/build-sharelatex-image.sh --full-texlive" >&2
      exit 1
    fi
    OVERLEAF_IMAGE_TAG="$FULLTEX_TAG"
    echo "==> Using full TeX image: $OVERLEAF_IMAGE_TAG"
    ;;
  false)
    OVERLEAF_IMAGE_TAG="$BASE_TAG"
    echo "==> Using base image (OVERLEAF_FULL_TEXLIVE=false): $OVERLEAF_IMAGE_TAG"
    ;;
  *)
    if podman image exists "$FULLTEX_TAG" 2>/dev/null; then
      OVERLEAF_IMAGE_TAG="$FULLTEX_TAG"
      echo "==> Detected full TeX image, using: $OVERLEAF_IMAGE_TAG"
    else
      OVERLEAF_IMAGE_TAG="$BASE_TAG"
      echo "==> Using base image: $OVERLEAF_IMAGE_TAG (run build with --full-texlive for the -fulltex overlay)"
    fi
    ;;
esac

#### Render templates ####
mkdir -p "$QUADLET_DST_DIR"

# Clean up stale quadlets from previous installs so removed templates don't
# linger and cause conflicts (e.g. an old overleaf.network creating a
# systemd-overleaf network instead of the plain 'overleaf' one we want).
echo "==> Cleaning up old overleaf quadlets from $QUADLET_DST_DIR"
find "$QUADLET_DST_DIR" -maxdepth 1 -name 'overleaf*' -print -delete

echo "==> Rendering quadlets into $QUADLET_DST_DIR"
for tmpl in "$QUADLET_SRC_DIR"/*; do
  fname=$(basename "$tmpl")
  echo "    - $fname"
  sed \
    -e "s|@OVERLEAF_DATA_PATH@|$OVERLEAF_DATA_PATH|g" \
    -e "s|@MONGO_DATA_PATH@|$MONGO_DATA_PATH|g" \
    -e "s|@REDIS_DATA_PATH@|$REDIS_DATA_PATH|g" \
    -e "s|@OVERLEAF_LISTEN_IP@|$OVERLEAF_LISTEN_IP|g" \
    -e "s|@OVERLEAF_PORT@|$OVERLEAF_PORT|g" \
    -e "s|@PUBLISH_PORT_SPEC@|$PUBLISH_PORT_SPEC|g" \
    -e "s|@OVERLEAF_IMAGE_TAG@|$OVERLEAF_IMAGE_TAG|g" \
    -e "s|@MONGO_IMAGE_FULL@|$MONGO_IMAGE_FULL|g" \
    -e "s|@REDIS_IMAGE_FULL@|$REDIS_IMAGE_FULL|g" \
    -e "s|@MONGO_ENV_VAR@|$MONGO_ENV_VAR|g" \
    -e "s|@REDIS_ENV_VAR@|$REDIS_ENV_VAR|g" \
    -e "s|@IN_CONTAINER_DATA_PATH@|$IN_CONTAINER_DATA_PATH|g" \
    -e "s|@REDIS_COMMAND@|$REDIS_COMMAND|g" \
    -e "s|@ENV_FILE@|$TOOLKIT_ROOT/config/variables.env|g" \
    -e "s|@MONGO_URL@|${MONGO_URL:-mongodb://mongo/sharelatex}|g" \
    -e "s|@REDIS_HOST@|${REDIS_HOST:-redis}|g" \
    -e "s|@MONGOSH@|${MONGOSH:-mongosh}|g" \
    "$tmpl" > "$QUADLET_DST_DIR/$fname"
done

# Sanity: no unsubstituted placeholders should remain.
if grep -R --include='*.container' --include='*.volume' --include='*.network' \
    -l '@[A-Z_]\+@' "$QUADLET_DST_DIR" >/dev/null 2>&1; then
  echo "ERROR: unsubstituted placeholders found in rendered quadlets:" >&2
  grep -RHn --include='*.container' --include='*.volume' --include='*.network' \
      '@[A-Z_]\+@' "$QUADLET_DST_DIR" >&2
  exit 1
fi

#### Ensure the podman network exists ####
# Creating it directly is more reliable than relying on the .network quadlet,
# whose systemd-generator behaviour varies across podman versions.
#
# First, tear down the old systemd-managed network if it lingers from a
# previous install that used a .network quadlet (it gets prefixed with
# 'systemd-' by the podman generator).
if podman network exists systemd-overleaf 2>/dev/null; then
  echo "==> Removing stale systemd-overleaf network"
  podman network rm systemd-overleaf
fi

# Create the network if it doesn't already exist.
if podman network exists overleaf 2>/dev/null; then
  echo "==> Network 'overleaf' already exists"
else
  echo "==> Creating podman network 'overleaf'"
  podman network create overleaf
fi

#### Reload systemd ####
echo "==> Reloading systemd user daemon"
systemctl --user daemon-reload

echo
echo "==> Installed. Available units:"
systemctl --user list-unit-files 'overleaf*' 2>/dev/null \
  | sed 's/^/    /'
echo
echo "Next steps:"
echo "    systemctl --user start overleaf-sharelatex.service"
echo "    journalctl --user -u overleaf-sharelatex -f"