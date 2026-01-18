#!/usr/bin/env bash
set -euo pipefail

# Repo that holds .env, helpers.sh, start.sh
RUNTIME_REPO_URL="${RUNTIME_REPO_URL:-https://github.com/markwelshboy/pod-runtime.git}"
RUNTIME_DIR="${RUNTIME_DIR:-/workspace/pod-runtime}"

mkdir -p /workspace

if [ -d "$RUNTIME_DIR/.git" ]; then
  echo "[start_script] Updating runtime repo in $RUNTIME_DIR..."
  git -C "$RUNTIME_DIR" pull --rebase --autostash || true
else
  echo "[start_script] Cloning runtime repo into $RUNTIME_DIR..."
  git clone --depth 1 "$RUNTIME_REPO_URL" "$RUNTIME_DIR"
fi

cd "$RUNTIME_DIR"

# install small helpers into /root
# Capture repo root dynamically
TMP="/root/.bashrc.temp"
# Copy the repo version
cp .bashrc "$TMP"
# Replace the placeholder
sed -i "s|REPO_ROOT=<CHANGEME>|REPO_ROOT=\"$RUNTIME_DIR\"|" "$TMP"
# Install into place
install -m 0644 "$TMP" /root/.bashrc
# Clean up
rm -f "$TMP"

install -m 0644 .bash_functions /root/.bash_functions
install -m 0644 .bash_aliases /root/.bash_aliases

if [ ! -x ./start.sh ]; then
  chmod +x ./start.sh
fi

echo "[start_script] Handing off to runtime start.sh..."
exec ./start.sh
