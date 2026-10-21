#!/usr/bin/env bash
set -euo pipefail

mkdir -p /workspace /workspace/logs

runtime_dir="${POD_RUNTIME_DIR:-/workspace/pod-runtime}"
runtime_repo="${POD_RUNTIME_REPO:-https://github.com/markwelshboy/pod-runtime.git}"
runtime_ref="${POD_RUNTIME_REF:-main}"
runtime_entrypoint="${POD_RUNTIME_ENTRYPOINT:-start.sh}"

if [[ -d "${runtime_dir}/.git" ]]; then
  echo "[bootstrap] Updating pod-runtime (${runtime_ref})..."
  git -C "${runtime_dir}" remote set-url origin "${runtime_repo}" || true
else
  echo "[bootstrap] Initializing pod-runtime checkout in ${runtime_dir}..."
  rm -rf "${runtime_dir}"
  mkdir -p "${runtime_dir}"
  git -C "${runtime_dir}" init
  git -C "${runtime_dir}" remote add origin "${runtime_repo}"
fi

git -C "${runtime_dir}" fetch --depth=1 origin "${runtime_ref}"
git -C "${runtime_dir}" checkout --detach FETCH_HEAD

export POD_RUNTIME_DIR="${runtime_dir}"

entrypoint_path="${POD_RUNTIME_DIR}/${runtime_entrypoint}"
[[ -f "${entrypoint_path}" ]] || {
  echo "[fatal] pod-runtime entrypoint not found: ${entrypoint_path}" >&2
  exit 1
}
chmod +x "${entrypoint_path}" || true

echo "[bootstrap] CUDA profile: ${CUDA_VARIANT:-unknown}"
echo "[bootstrap] pod-runtime: ${runtime_ref} -> ${runtime_entrypoint}"
exec "${entrypoint_path}"
