#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-markwelshboy/comfyui-inference-next}"
TAG=""
TAG_EXPLICIT=false
CUDA_VARIANT=""
COMFYUI_REF_REQUESTED="${COMFYUI_REF:-v0.42.0}"
DOCKERFILE="Dockerfile"
BUILDER="${BUILDX_BUILDER:-buildkit-scratch}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH=true
LOAD=false
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false
ALLOW_PROTECTED_PUSH=false
TARGET="final"
IMAGE_VERSION=""
BUILD_DATE=""
VCS_REF=""
EXTRA_BUILD_ARGS=()

usage() {
  cat <<'USAGE'
Usage: ./build_comfy-inference.sh --cuda <cu128|cu130> [options]

CUDA profile (required):
  --cuda cu128            CUDA 12.8.1 + PyTorch 2.11 cu128 compatibility image
  --cuda cu130            CUDA 13.0.3 + PyTorch 2.11 cu130 primary image

ComfyUI:
  --comfyui-ref REF       Default: v0.42.0. Branches/tags are resolved to an
                          immutable upstream commit SHA before the build.

Build/output:
  --builder NAME          Buildx builder; default: buildkit-scratch
  --platform PLATFORM     Default: linux/amd64
  --load                  Load into local Docker instead of pushing
  --no-push               Build/cache only; do not push or load
  --no-cache              Disable BuildKit cache
  --prune                 Prune stopped containers and dangling Docker images
  --prune-hard            Aggressively prune the selected Buildx builder cache
  --target STAGE          Default: final

Tagging / migration safety:
  --image REPO/NAME       Default: markwelshboy/comfyui-inference-next
  --tag TAG               Default: <cuda>-dev, e.g. cu130-dev
  --allow-protected-push  Explicitly permit pushing :latest or :dev to the
                          protected production image names. Normally refused.

Metadata:
  --image-version VALUE   Default: final image tag
  --build-date ISO        Default: current source commit timestamp
  --vcs-ref SHA           Default: current source commit

Pass-through:
  --build-arg KEY=VALUE   Repeatable additional Docker build argument
  --dockerfile PATH       Default: Dockerfile

Examples:
  ./build_comfy-inference.sh --cuda cu130
  ./build_comfy-inference.sh --cuda cu128
  ./build_comfy-inference.sh --cuda cu130 --tag cu130-test --no-push
  ./build_comfy-inference.sh --cuda cu128 --load
  ./build_comfy-inference.sh --cuda cu130 --comfyui-ref master
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cuda) CUDA_VARIANT="${2:?--cuda requires cu128 or cu130}"; shift 2 ;;
    --comfyui-ref) COMFYUI_REF_REQUESTED="${2:?--comfyui-ref requires a value}"; shift 2 ;;
    --builder) BUILDER="${2:?--builder requires a value}"; shift 2 ;;
    --platform) PLATFORM="${2:?--platform requires a value}"; shift 2 ;;
    --load) PUSH=false; LOAD=true; shift ;;
    --no-push) PUSH=false; LOAD=false; shift ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --image) IMAGE="${2:?--image requires a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a value}"; TAG_EXPLICIT=true; shift 2 ;;
    --allow-protected-push) ALLOW_PROTECTED_PUSH=true; shift ;;
    --target) TARGET="${2:?--target requires a value}"; shift 2 ;;
    --image-version) IMAGE_VERSION="${2:?--image-version requires a value}"; shift 2 ;;
    --build-date) BUILD_DATE="${2:?--build-date requires a value}"; shift 2 ;;
    --vcs-ref) VCS_REF="${2:?--vcs-ref requires a value}"; shift 2 ;;
    --build-arg) EXTRA_BUILD_ARGS+=(--build-arg "${2:?--build-arg requires KEY=VALUE}"); shift 2 ;;
    --dockerfile) DOCKERFILE="${2:?--dockerfile requires a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ -n "${CUDA_VARIANT}" ]] || die "--cuda is required (cu128 or cu130)"

case "${CUDA_VARIANT}" in
  cu128|12.8|128)
    CUDA_VARIANT="cu128"
    CUDA_BASE_IMAGE="nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04"
    TORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"
    TORCH_CUDA_PREFIX="12.8"
    CUPY_PACKAGE="cupy-cuda12x"
    ;;
  cu130|13.0|130)
    CUDA_VARIANT="cu130"
    CUDA_BASE_IMAGE="nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04"
    TORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"
    TORCH_CUDA_PREFIX="13.0"
    CUPY_PACKAGE="cupy-cuda13x"
    ;;
  *) die "Unsupported CUDA profile '${CUDA_VARIANT}'; use cu128 or cu130" ;;
esac

if ! $TAG_EXPLICIT; then
  TAG="${CUDA_VARIANT}-dev"
fi
[[ -n "${IMAGE_VERSION}" ]] || IMAGE_VERSION="${TAG}"

have_cmd docker || die "docker not found"
have_cmd git || die "git not found"
have_cmd curl || die "curl not found"
docker info >/dev/null 2>&1 || die "Docker is not accessible as the current user"
docker buildx version >/dev/null 2>&1 || die "docker buildx not available"
docker buildx inspect "${BUILDER}" >/dev/null 2>&1 || die "Buildx builder '${BUILDER}' not found or unavailable"
[[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found: ${DOCKERFILE}"
[[ -f "constraints/${CUDA_VARIANT}.txt" ]] || die "Missing constraints/${CUDA_VARIANT}.txt"

if $LOAD && [[ "${PLATFORM}" == *,* ]]; then
  die "--load supports a single platform only"
fi

# During migration, do not let a casual --tag latest/dev overwrite either the
# existing Krea image namespace or the eventual canonical namespace.
normalized_image="${IMAGE#docker.io/}"
if $PUSH && ! $ALLOW_PROTECTED_PUSH; then
  case "${normalized_image}:${TAG}" in
    markwelshboy/comfy-inference:latest|markwelshboy/comfy-inference:dev|\
    markwelshboy/comfyui-inference:latest|markwelshboy/comfyui-inference:dev)
      die "Refusing protected push to ${IMAGE}:${TAG}. Use --allow-protected-push only when promotion is intentional."
      ;;
  esac
fi

resolve_comfyui_ref() {
  local ref="$1"
  local remote="https://github.com/Comfy-Org/ComfyUI.git"
  local sha=""

  if [[ "${ref}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '%s\n' "${ref,,}"
    return 0
  fi

  sha="$(git ls-remote "${remote}" "refs/tags/${ref}^{}" | awk 'NR==1 {print $1}')"
  if [[ ! "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    sha="$(git ls-remote "${remote}" "refs/tags/${ref}" | awk 'NR==1 {print $1}')"
  fi
  if [[ ! "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    sha="$(git ls-remote "${remote}" "refs/heads/${ref}" | awk 'NR==1 {print $1}')"
  fi

  [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]] \
    || die "Unable to resolve ComfyUI ref '${ref}' to an upstream commit"
  printf '%s\n' "${sha,,}"
}

resolve_comfyui_version() {
  local sha="$1"
  local pyproject=""
  pyproject="$(curl -fsSL --connect-timeout 10 --max-time 20 \
    "https://raw.githubusercontent.com/Comfy-Org/ComfyUI/${sha}/pyproject.toml" 2>/dev/null || true)"
  awk -F'"' '/^[[:space:]]*version[[:space:]]*=[[:space:]]*"/ {print $2; exit}' <<< "${pyproject}"
}

COMFYUI_REF="$(resolve_comfyui_ref "${COMFYUI_REF_REQUESTED}")"
COMFYUI_VERSION="$(resolve_comfyui_version "${COMFYUI_REF}")"
if [[ -z "${COMFYUI_VERSION}" ]]; then
  COMFYUI_VERSION="unknown"
  echo "WARN: Unable to determine ComfyUI version metadata for ${COMFYUI_REF}" >&2
fi

# Deterministic metadata: use the source commit timestamp rather than the wall
# clock so identical source builds keep their expensive Docker cache layers.
if [[ -z "${VCS_REF}" ]]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  else
    VCS_REF="unknown"
  fi
fi
if [[ -z "${BUILD_DATE}" ]]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_DATE="$(git show -s --format=%cI HEAD 2>/dev/null || true)"
  fi
  [[ -n "${BUILD_DATE}" ]] || BUILD_DATE="unknown"
fi

if $PRUNE_HARD; then
  echo "== Aggressive BuildKit cache prune: ${BUILDER} =="
  docker buildx prune --builder "${BUILDER}" --all --force || true
elif $PRUNE; then
  echo "== Safe Docker Engine prune =="
  docker container prune -f || true
  docker image prune -f || true
fi

cat <<SUMMARY
== ComfyUI inference image build ==
Image             : ${IMAGE}:${TAG}
CUDA profile      : ${CUDA_VARIANT}
CUDA base         : ${CUDA_BASE_IMAGE}
Torch index       : ${TORCH_INDEX_URL}
ComfyUI requested : ${COMFYUI_REF_REQUESTED}
ComfyUI commit    : ${COMFYUI_REF}
ComfyUI version   : ${COMFYUI_VERSION}
Builder           : ${BUILDER}
Platform          : ${PLATFORM}
Target            : ${TARGET}
Push              : ${PUSH}
Load              : ${LOAD}
No-cache          : ${NO_CACHE}
Build date        : ${BUILD_DATE}
VCS ref           : ${VCS_REF}
Image version     : ${IMAGE_VERSION}
SUMMARY

show_usage() {
  echo
  echo "== Docker Engine usage =="
  docker system df || true
  echo
  echo "== BuildKit cache: ${BUILDER} =="
  docker buildx du --builder "${BUILDER}" || true
  echo
  echo "== Filesystems =="
  df -h / /var /srv/buildkit 2>/dev/null || df -h
}

show_usage

args=(
  --builder "${BUILDER}"
  --target "${TARGET}"
  --platform "${PLATFORM}"
  --tag "${IMAGE}:${TAG}"
  -f "${DOCKERFILE}"
  --build-arg "CUDA_BASE_IMAGE=${CUDA_BASE_IMAGE}"
  --build-arg "CUDA_VARIANT=${CUDA_VARIANT}"
  --build-arg "TORCH_INDEX_URL=${TORCH_INDEX_URL}"
  --build-arg "TORCH_CUDA_PREFIX=${TORCH_CUDA_PREFIX}"
  --build-arg "CUPY_PACKAGE=${CUPY_PACKAGE}"
  --build-arg "COMFYUI_REF=${COMFYUI_REF}"
  --build-arg "COMFYUI_REQUESTED_REF=${COMFYUI_REF_REQUESTED}"
  --build-arg "COMFYUI_VERSION=${COMFYUI_VERSION}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
)

$NO_CACHE && args+=(--no-cache)
if $PUSH; then
  args+=(--push)
elif $LOAD; then
  args+=(--load)
fi
args+=("${EXTRA_BUILD_ARGS[@]}" .)

echo
echo "================================================================================"
echo "== Building ${IMAGE}:${TAG} (${CUDA_VARIANT})"
echo "================================================================================"
echo

docker buildx build "${args[@]}"

echo
if $PUSH; then
  echo "Pushed: ${IMAGE}:${TAG}"
elif $LOAD; then
  echo "Built and loaded locally: ${IMAGE}:${TAG}"
else
  echo "Built successfully; result remains only in BuildKit cache."
fi

show_usage
