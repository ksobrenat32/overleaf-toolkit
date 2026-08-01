#! /usr/bin/env bash
# shellcheck source-path=../../..

# One-shot reporter: shows the three relevant systemd services and the
# matching podman containers, plus a hint when something is down. No
# mutations.

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

echo "==> systemd unit status"
systemctl --user status --no-pager \
  overleaf-sharelatex.service \
  overleaf-mongo.service \
  overleaf-redis.service \
  2>&1 || true

echo
echo "==> podman containers"
if command -v podman >/dev/null 2>&1; then
  podman ps -a \
    --filter name=sharelatex \
    --filter name=mongo \
    --filter name=redis \
    --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}" \
    2>&1 || true
else
  echo "(podman not installed)"
fi

# Hint when something isn't running.
if ! systemctl --user is-active --quiet overleaf-sharelatex.service 2>/dev/null; then
  echo
  echo "overleaf-sharelatex is not active. To start the stack:"
  echo "    systemctl --user start overleaf-sharelatex.service"
fi