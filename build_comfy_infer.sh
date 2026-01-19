#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build_comfy_infer.sh [options]

Options:
  --no-push              Do not push (default: push)
  --load                 Load into local docker (implies --no-push)
  --platform <plats>     Default: linux/amd64
  --no-cache             Disable build cache
  --prune                Safe-ish prune before build
  --prune-hard           Aggressive prune before build (docker system prune -af)

Tagging:
  --image <repo/name>    Default: markwelshboy/comfyui-inference
  --tag <tag>            Default: latest

Target stage:
  --target <stage>       Build a specific Dockerfile stage (optional).
                         If omitted, script will prefer 'final' if it exists,
                         otherwise builds the default final stage with no --target.

Metadata:
  --image-version <v>    Default: 0.1.0
  --build-date <iso>     Default: now UTC
  --vcs-ref <sha>        Default: git rev-parse --short HEAD or "unknown"

Pass-through:
  --build-arg KEY=VALUE  Repeatable.
  --dockerfile <path>    Default: Dockerfile

Examples:
  ./build_comfy_infer.sh
  ./build_comfy_infer.sh --no-push
  ./build_comfy_infer.sh --load
  ./build_comfy_infer.sh --target sanity --no-push
  ./build_comfy_infer.sh --dockerfile Dockerfile.sanity --no-push
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Defaults
IMAGE="markwelshboy/comfyui-inference"
TAG="latest"
DOCKERFILE="Dockerfile"

PUSH=true
LOAD=false
PLATFORM="linux/amd64"
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false

TARGET=""

IMAGE_VERSION="0.1.0"
BUILD_DATE=""
VCS_REF=""

EXTRA_BUILD_ARGS=()

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push) PUSH=false; shift ;;
    --load) LOAD=true; PUSH=false; shift ;;
    --platform) [[ -n "${2:-}" ]] || die "--platform requires a value"; PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --image) [[ -n "${2:-}" ]] || die "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --tag) [[ -n "${2:-}" ]] || die "--tag requires a value"; TAG="$2"; shift 2 ;;
    --dockerfile) [[ -n "${2:-}" ]] || die "--dockerfile requires a path"; DOCKERFILE="$2"; shift 2 ;;
    --target) [[ -n "${2:-}" ]] || die "--target requires a stage name"; TARGET="$2"; shift 2 ;;
    --image-version) [[ -n "${2:-}" ]] || die "--image-version requires a value"; IMAGE_VERSION="$2"; shift 2 ;;
    --build-date) [[ -n "${2:-}" ]] || die "--build-date requires a value"; BUILD_DATE="$2"; shift 2 ;;
    --vcs-ref) [[ -n "${2:-}" ]] || die "--vcs-ref requires a value"; VCS_REF="$2"; shift 2 ;;
    --build-arg) [[ -n "${2:-}" ]] || die "--build-arg requires KEY=VALUE"; EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

have_cmd docker || die "docker not found"
sudo docker buildx version >/dev/null 2>&1 || die "docker buildx not available"

# Metadata defaults
if [[ -z "${BUILD_DATE}" ]]; then
  BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
if [[ -z "${VCS_REF}" ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  else
    VCS_REF="unknown"
  fi
fi

# If user didn't specify --target, prefer "final" only if it exists.
# Otherwise, omit --target entirely (build default final stage = last stage).
detect_target_if_any() {
  [[ -n "${TARGET}" ]] && return 0

  # Look for stage names in the Dockerfile
  # e.g. "FROM ... AS final"
  local stages
  stages="$(grep -E '^[[:space:]]*FROM[[:space:]].*[[:space:]]+AS[[:space:]]+' "${DOCKERFILE}" \
    | sed -E 's/.*[[:space:]]+AS[[:space:]]+([A-Za-z0-9_.-]+).*/\1/I' \
    | tr '\r' '\n' \
    | tr -d ' ' \
    || true)"

  # Common preferences (only if present)
  for cand in final runtime comfy infer; do
    if echo "${stages}" | grep -qx "${cand}"; then
      TARGET="${cand}"
      return 0
    fi
  done

  # No target chosen => build last stage (best default)
  TARGET=""
}

detect_target_if_any

echo "== Build settings =="
echo "Image       : ${IMAGE}:${TAG}"
echo "Platform    : ${PLATFORM}"
echo "Push        : ${PUSH}"
echo "Load        : ${LOAD}"
echo "No-cache    : ${NO_CACHE}"
echo "Prune       : ${PRUNE}"
echo "Prune-hard  : ${PRUNE_HARD}"
echo "Dockerfile  : ${DOCKERFILE}"
echo "Target      : ${TARGET:-<default final stage>}"
echo "Build date  : ${BUILD_DATE}"
echo "VCS ref     : ${VCS_REF}"
echo "Version     : ${IMAGE_VERSION}"
echo ""

# Prune logic (optional)
if $PRUNE_HARD; then
  echo "== Aggressive prune (docker system prune -af) =="
  sudo docker system prune -af || true
elif $PRUNE; then
  echo "== Safe-ish prune (container/image/builder) =="
  sudo docker container prune -f || true
  sudo docker image prune -f || true
  sudo docker builder prune -f || true
fi

echo "== Disk usage (before) =="
sudo docker system df || true
df -h || true
echo ""

# Ensure buildx builder exists & is selected
if ! sudo docker buildx inspect >/dev/null 2>&1; then
  sudo docker buildx create --use --name default >/dev/null
fi

common_buildx_args=(
  -f "${DOCKERFILE}"
  --platform "${PLATFORM}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
)

if $NO_CACHE; then
  common_buildx_args+=(--no-cache)
fi

if $PUSH; then
  common_buildx_args+=(--push)
elif $LOAD; then
  common_buildx_args+=(--load)
else
  common_buildx_args+=(--load)
fi

# Only pass --target if we actually chose one
if [[ -n "${TARGET}" ]]; then
  common_buildx_args+=(--target "${TARGET}")
fi

echo ""
echo "================================================================================"
echo "== Building: ${IMAGE}:${TAG}"
echo "================================================================================"
echo ""

sudo docker buildx build \
  -t "${IMAGE}:${TAG}" \
  "${common_buildx_args[@]}" \
  "${EXTRA_BUILD_ARGS[@]}" \
  .

echo ""
echo "== Done =="
if $PUSH; then
  echo "Pushed: ${IMAGE}:${TAG}"
else
  echo "Built (local): ${IMAGE}:${TAG}"
fi

echo ""
echo "== Disk usage (after) =="
sudo docker system df || true
df -h || true
