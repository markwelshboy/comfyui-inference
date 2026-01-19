FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_PREFER_BINARY=1 \
    VENV=/opt/venv

# ---- OS + Python 3.12 + tooling ----
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      git git-lfs curl ca-certificates jq \
      build-essential gcc g++ cmake ninja-build pkg-config \
      ffmpeg aria2 rsync tmux unzip wget vim less nano \
      libgl1 libglib2.0-0 \
      gcc-12 g++-12 \
      openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && git lfs install --system \
    && python3.12 -m venv "${VENV}"

ENV PATH="${VENV}/bin:${PATH}"

# ---- pip tooling (keep it sane) ----
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -U "pip<25.2" setuptools wheel

# ---- Constraints: copy early so ALL subsequent pip installs are constrained ----
COPY pip.conf /etc/pip.conf
COPY constraints.txt /opt/constraints.txt
ENV PIP_CONSTRAINT=/opt/constraints.txt
# Optional extra enforcement for builds that spawn isolated envs:
ENV PIP_BUILD_CONSTRAINT=/opt/constraints.txt

# ---- Torch stack FIRST (pinned, cu128 nightly) ----
ARG TORCH_INDEX="https://download.pytorch.org/whl/nightly/cu128"
ARG TORCH_VER="2.10.0.dev20251202+cu128"
ARG TORCHVISION_VER="0.25.0.dev20251202+cu128"
ARG TORCHAUDIO_VER="2.10.0.dev20251202+cu128"

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
      --index-url "${TORCH_INDEX}" \
      "torch==${TORCH_VER}" \
      "torchvision==${TORCHVISION_VER}" \
      "torchaudio==${TORCHAUDIO_VER}"

# ---- Base runtime libs you commonly need (keep broad) ----
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
      huggingface_hub==0.36.0 \
      pyyaml tqdm pillow \
      opencv-python-headless==4.12.0.88

# ---- ComfyUI clone ----
ARG COMFYUI_REF="v0.9.2"
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI \
    && cd /workspace/ComfyUI \
    && git checkout "${COMFYUI_REF}"

WORKDIR /workspace/ComfyUI

# Strip torch/torchvision/torchaudio from ComfyUI requirements (we install torch separately/pinned)
RUN python - <<'PY'
import re, pathlib

src = pathlib.Path("requirements.txt")
dst = pathlib.Path("/tmp/requirements.notorch.txt")

out = []
for line in src.read_text().splitlines():
    s = line.strip()
    if not s or s.startswith("#"):
        out.append(line); continue
    if re.match(r"^(torch|torchvision|torchaudio)(\b|==|>=|<=|~=|!=|<|>)", s):
        continue
    out.append(line)

dst.write_text("\n".join(out) + "\n")
print(f"Wrote {dst} (removed torch/vision/audio)")
PY

# Install remaining requirements under constraints
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -c /opt/constraints.txt -r /tmp/requirements.notorch.txt

# Expose ports

EXPOSE 22 8188 8288 8388 8888

# Prepare for ssh 
RUN mkdir -p /var/run/sshd

# Make sure /workspace exists (Vast will usually mount over it)
RUN mkdir -p /workspace

# Copy the upscaler
COPY 4xLSDIR.pth /

# Thin startup wrapper – this is where you’ll hook your big shell later
COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

ENTRYPOINT ["/start_script.sh"]
