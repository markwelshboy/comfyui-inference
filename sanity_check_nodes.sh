#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# sanity_check_nodes.sh — CPU sanity test for:
#  - ComfyUI @ COMFY_REF
#  - custom_nodes from a manifest list
#  - pip installs under constraints
#  - import-time sanity
#
# Run example:
#   docker run --rm -it \
#     -v "/home/markr/git/pod-runtime:/pod-runtime:ro" \
#     -e COMFY_REF="v0.9.2" \
#     -e MANIFEST_PATH="/pod-runtime/default_custom_nodes_manifest.list" \
#     -e CONSTRAINTS_PATH="/pod-runtime/constraints.txt" \
#     comfy-sanity:latest
# -----------------------------------------------------------------------------

COMFY_REF="${COMFY_REF:-v0.9.2}"

MANIFEST_PATH="${MANIFEST_PATH:-}"
MANIFEST_URL="${MANIFEST_URL:-}"

CONSTRAINTS_PATH="${CONSTRAINTS_PATH:-}"
WORKROOT="${WORKROOT:-/workspace}"   # fixed default for consistency

RUNROOT="${WORKROOT}/run"
COMFY_DIR="${RUNROOT}/ComfyUI"
CUSTOM_DIR="${COMFY_DIR}/custom_nodes"
LOGDIR="${WORKROOT}/logs"

mkdir -p "${RUNROOT}" "${LOGDIR}"

echo "== Settings =="
echo "COMFY_REF       : ${COMFY_REF}"
echo "MANIFEST_PATH   : ${MANIFEST_PATH}"
echo "MANIFEST_URL    : ${MANIFEST_URL}"
echo "CONSTRAINTS     : ${CONSTRAINTS_PATH}"
echo "WORKROOT        : ${WORKROOT}"
echo "RUNROOT         : ${RUNROOT}"
echo ""

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ -z "${MANIFEST_PATH}" && -z "${MANIFEST_URL}" ]]; then
  die "Set MANIFEST_PATH (preferred) or MANIFEST_URL"
fi

# Fetch manifest into container-visible location
MANIFEST_FILE="${WORKROOT}/manifest.list"
if [[ -n "${MANIFEST_PATH}" ]]; then
  [[ -f "${MANIFEST_PATH}" ]] || die "MANIFEST_PATH not found inside container: ${MANIFEST_PATH} (did you mount it?)"
  cp -f "${MANIFEST_PATH}" "${MANIFEST_FILE}"
else
  curl -fsSL "${MANIFEST_URL}" -o "${MANIFEST_FILE}"
fi

[[ -s "${MANIFEST_FILE}" ]] || die "Manifest empty: ${MANIFEST_FILE}"

# Constraints args
CARGS=()
if [[ -n "${CONSTRAINTS_PATH}" ]]; then
  [[ -f "${CONSTRAINTS_PATH}" ]] || die "CONSTRAINTS_PATH not found inside container: ${CONSTRAINTS_PATH} (did you mount it?)"
  CARGS=(-c "${CONSTRAINTS_PATH}")
  echo "Using constraints: ${CONSTRAINTS_PATH}"
else
  echo "No constraints provided (CONSTRAINTS_PATH empty) — continuing without constraints"
fi

echo ""
echo "== Reset run directory =="
echo "Cleaning: ${RUNROOT}"
rm -rf --one-file-system "${RUNROOT}"
mkdir -p "${RUNROOT}"

 # prove it
 if [[ -d "${COMFY_DIR}" ]]; then
   echo "ERROR: ${COMFY_DIR} still exists after cleanup" >&2
   ls -la "${COMFY_DIR}" | head -n 50 || true
   exit 99
 fi

echo ""
echo "== Clone ComfyUI @ ${COMFY_REF} =="
git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFY_DIR}" 2>&1 | tee "${LOGDIR}/clone_ComfyUI.log"
pushd "${COMFY_DIR}" >/dev/null
git fetch --tags >/dev/null 2>&1 || true
git checkout "${COMFY_REF}" 2>&1 | tee "${LOGDIR}/checkout_ComfyUI.log"

echo ""
echo "== Install ComfyUI requirements (filter torchaudio) =="
python - <<'PY'
from pathlib import Path
src = Path("requirements.txt").read_text().splitlines()
out = []
for line in src:
    s = line.strip()
    if not s or s.startswith("#"):
        out.append(line); continue
    if s.split()[0].lower().startswith("torchaudio"):
        continue
    out.append(line)
Path("/tmp/requirements.noaudio.txt").write_text("\n".join(out) + "\n")
print("Wrote /tmp/requirements.noaudio.txt (torchaudio removed)")
PY

python -m pip install "${CARGS[@]}" -r /tmp/requirements.noaudio.txt 2>&1 | tee "${LOGDIR}/pip_comfy_requirements.log"
popd >/dev/null

echo ""
echo "== Clone custom nodes from manifest =="
FAIL_CLONE=0

mkdir -p "${CUSTOM_DIR}"

# manifest format: "<repo_url> <dir> [--recursive]"
while IFS= read -r line; do
  line="${line%%$'\r'}"
  [[ -z "${line// }" ]] && continue
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  repo="$(awk '{print $1}' <<<"${line}")"
  dir="$(awk '{print $2}' <<<"${line}")"
  flag="$(awk '{print $3}' <<<"${line}" || true)"

  [[ -z "${repo}" || -z "${dir}" ]] && continue

  echo ""
  echo "-> ${dir}  (${repo}) ${flag:-}"

  rm -rf "${CUSTOM_DIR:?}/${dir}"

  if [[ "${flag:-}" == "--recursive" ]]; then
    if ! git clone --recursive "${repo}" "${CUSTOM_DIR}/${dir}" 2>&1 | tee "${LOGDIR}/clone_${dir}.log"; then
      echo "!! CLONE FAILED: ${dir}" >&2
      FAIL_CLONE=1
      continue
    fi
  else
    if ! git clone "${repo}" "${CUSTOM_DIR}/${dir}" 2>&1 | tee "${LOGDIR}/clone_${dir}.log"; then
      echo "!! CLONE FAILED: ${dir}" >&2
      FAIL_CLONE=1
      continue
    fi
  fi
done < "${MANIFEST_FILE}"

if [[ "${FAIL_CLONE}" -ne 0 ]]; then
  echo ""
  echo "Some clones failed. See logs in: ${LOGDIR}" >&2
fi

echo ""
echo "== Install requirements for each custom node (if present) =="
FAIL_REQ=0

while IFS= read -r line; do
  line="${line%%$'\r'}"
  [[ -z "${line// }" ]] && continue
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  dir="$(awk '{print $2}' <<<"${line}")"
  [[ -z "${dir}" ]] && continue

  req="${CUSTOM_DIR}/${dir}/requirements.txt"
  if [[ -f "${req}" ]]; then
    echo ""
    echo "-- requirements: ${dir}"
    if ! python -m pip install "${CARGS[@]}" -r "${req}" 2>&1 | tee "${LOGDIR}/pip_${dir}.log"; then
      echo "!! REQUIREMENTS FAILED: ${dir}" >&2
      FAIL_REQ=1
    fi
  fi
done < "${MANIFEST_FILE}"

echo ""
echo "== Import sanity (best-effort) =="
python - <<PY 2>&1 | tee "${LOGDIR}/import_sanity.log"
import sys
from pathlib import Path

root = Path(${COMFY_DIR@Q})
sys.path.insert(0, str(root))

# 1) Comfy core import
import nodes
print("[OK] import ComfyUI nodes")

# 2) Best-effort import of each custom node folder
custom = root / "custom_nodes"
fails = []

for pkg in sorted(custom.iterdir()):
    if not pkg.is_dir():
        continue

    cand = []
    init = pkg / "__init__.py"
    if init.exists():
        cand.append(init)
    cand.extend(sorted(pkg.glob("*.py")))

    ok = False
    for pyf in cand[:50]:  # guardrail: don't try thousands of files
        mod = f"custom_nodes.{pkg.name}.{pyf.stem}"
        try:
            __import__(mod)
            ok = True
            break
        except Exception:
            pass

    if ok:
        print(f"[OK]  {pkg.name}")
    else:
        # Many repos are GPU-only at import time; treat as warning
        print(f"[WARN] {pkg.name} (import failed; could be GPU-only or missing deps)")
        fails.append(pkg.name)

print("\\nSummary:")
print("  custom_nodes total:", len([p for p in custom.iterdir() if p.is_dir()]))
print("  warnings:", len(fails))
if fails:
    print("  warn list:", ", ".join(fails))
PY

echo ""
echo "== pip check (informational) =="
python -m pip check 2>&1 | tee "${LOGDIR}/pip_check.log" || true

echo ""
echo "== Finished =="
echo "Clone failures     : ${FAIL_CLONE}"
echo "Requirements fails : ${FAIL_REQ}"
echo "Logs directory     : ${LOGDIR}"
echo ""

# Make the container exit non-zero only if clone/requirements failed (imports may warn on CPU)
if [[ "${FAIL_CLONE}" -ne 0 || "${FAIL_REQ}" -ne 0 ]]; then
  exit 2
fi
