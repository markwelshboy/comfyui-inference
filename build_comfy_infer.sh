#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# build_comfy_infer.sh — buildx builder for ComfyUI inference container
#
# Usage:
#   ./build_comfy_infer.sh                 # builds & pushes :latest (default)
#
# Options:
#   --no-push              Do not push (default: push)
#   --load                 Load into local docker (implies --no-push)
#   --platform <plats>     Default: linux/amd64
#   --no-cache             Disable build cache
#   --prune                Safe-ish prune before build
#   --prune-hard           Aggressive prune before build (docker system prune -af)
#
# Tagging:
#   --tag <tag>            Override tag (default: latest)
#
# Metadata:
#   --image-version <v>    Default: 0.1.0
#   --build-date <iso>     Default: now (UTC)
#   --vcs-ref <sha>        Default: git rev-parse --short HEAD or "unknown"
#
# Pins (build args):
#   --torch <ver>          Default matches constraints.txt
#   --torchvision <ver>    Default matches constraints.txt
#   --torch-index <url>    Default: nightly cu128
#   --comfy-ref <ref>      Default: v0.9.2
#
# Pass-through build args:
#   --build-arg KEY=VALUE  Repeatable
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  ./build_comfy_infer.sh [options]

Options:
  --no-push              Do not push (default is push)
  --load                 Load into local docker (implies --no-push)
  --platform <plats>     Default: linux/amd64 (e.g. linux/amd64,linux/arm64)
  --no-cache             Disable build cache
  --prune                Safe-ish prune (container/image/builder)
  --prune-hard           Aggressive prune (docker system prune -af)

Tagging:
  --tag <tag>            Override tag (default: latest)

Metadata:
  --image-version <v>    Default: 0.1.0
  --build-date <iso>     Default: now UTC if omitted
  --vcs-ref <sha>        Default: git rev-parse --short HEAD or "unknown"

Pins:
  --torch <ver>          Torch version (default pinned nightly)
  --torchvision <ver>    TorchVision version (default pinned nightly)
  --torch-index <url>    Torch index URL (default: nightly cu128)
  --comfy-ref <ref>      ComfyUI git ref/tag/sha (default: v0.9.2)

Pass-through:
  --build-arg KEY=VALUE  Repeatable.

Examples:
  ./build_comfy_infer.sh
  ./build_comfy_infer.sh --no-push --load
  ./build_comfy_infer.sh --tag dev --no-push
  ./build_comfy_infer.sh --prune --torch 2.10.0.dev20251114+cu128 --torchvision 0.25.0.dev20251118+cu128
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Build behavior
PUSH=true
LOAD=false
PLATFORM="linux/amd64"
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false

# Image/tag (default :latest)
IMAGE="markwelshboy/comfyui-inference"
TAG="latest"

# Metadata
IMAGE_VERSION="0.1.0"
BUILD_DATE=""
VCS_REF=""

# Pins (defaults must match constraints.txt)
TORCH_INDEX="https://download.pytorch.org/whl/nightly/cu128"
TORCH_VER="2.10.0.dev20251114+cu128"
TORCHVISION_VER="0.25.0.dev20251118+cu128"
COMFYUI_REF="v0.9.2"

# Extra args
EXTRA_BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push) PUSH=false; shift ;;
    --load) LOAD=true; PUSH=false; shift ;;
    --platform) [[ -n "${2:-}" ]] || die "--platform requires a value"; PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --tag) [[ -n "${2:-}" ]] || die "--tag requires a value"; TAG="$2"; shift 2 ;;

    --image-version) [[ -n "${2:-}" ]] || die "--image-version requires a value"; IMAGE_VERSION="$2"; shift 2 ;;
    --build-date) [[ -n "${2:-}" ]] || die "--build-date requires a value"; BUILD_DATE="$2"; shift 2 ;;
    --vcs-ref) [[ -n "${2:-}" ]] || die "--vcs-ref requires a value"; VCS_REF="$2"; shift 2 ;;

    --torch) [[ -n "${2:-}" ]] || die "--torch requires a value"; TORCH_VER="$2"; shift 2 ;;
    --torchvision) [[ -n "${2:-}" ]] || die "--torchvision requires a value"; TORCHVISION_VER="$2"; shift 2 ;;
    --torch-index) [[ -n "${2:-}" ]] || die "--torch-index requires a value"; TORCH_INDEX="$2"; shift 2 ;;
    --comfy-ref) [[ -n "${2:-}" ]] || die "--comfy-ref requires a value"; COMFYUI_REF="$2"; shift 2 ;;

    --build-arg) [[ -n "${2:-}" ]] || die "--build-arg requires KEY=VALUE"; EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;

    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

have_cmd docker || die "docker not found"
sudo docker buildx version >/dev/null 2>&1 || die "docker buildx not available"

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

echo "== Build settings =="
echo "Image       : ${IMAGE}:${TAG}"
echo "Platform    : ${PLATFORM}"
echo "Push        : ${PUSH}"
echo "Load        : ${LOAD}"
echo "No-cache    : ${NO_CACHE}"
echo "Prune       : ${PRUNE}"
echo "Prune-hard  : ${PRUNE_HARD}"
echo "Build date  : ${BUILD_DATE}"
echo "VCS ref     : ${VCS_REF}"
echo "Version     : ${IMAGE_VERSION}"
echo "Pins        :"
echo "  TORCH_INDEX     = ${TORCH_INDEX}"
echo "  TORCH_VER       = ${TORCH_VER}"
echo "  TORCHVISION_VER = ${TORCHVISION_VER}"
echo "  COMFYUI_REF      = ${COMFYUI_REF}"
echo ""

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
  --platform "${PLATFORM}"
  --target "final"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
  --build-arg "BUILD_GIT_SHA=${VCS_REF}"
  --build-arg "IMAGE_TAG=${TAG}"

  --build-arg "TORCH_INDEX=${TORCH_INDEX}"
  --build-arg "TORCH_VER=${TORCH_VER}"
  --build-arg "TORCHVISION_VER=${TORCHVISION_VER}"
  --build-arg "COMFYUI_REF=${COMFYUI_REF}"
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
