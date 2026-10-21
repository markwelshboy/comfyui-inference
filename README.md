# ComfyUI Inference

Canonical headless ComfyUI image build for Vast.ai / RunPod.

This repo is being converged from the older Krea-specific and MiniMax-specific image builds into two sibling CUDA profiles that share the same ComfyUI/application baseline:

- `cu130` — primary, forward-looking image.
- `cu128` — compatibility fallback for wider GPU host availability.

Both profiles currently build PyTorch 2.11 and ComfyUI v0.42.0, with native Krea2 and MiniMax H3 source checks. The binary-sensitive stack is constrained per CUDA profile, while the Hugging Face / Transformers application layer is intentionally allowed to move far enough forward for newer custom nodes such as current ComfyUI-RMBG / `nobg`.

## Migration safety

The default Docker repository is deliberately temporary during convergence:

```text
markwelshboy/comfyui-inference-next
```

Default tags are:

```text
cu128-dev
cu130-dev
```

The builder refuses to push `:latest` or `:dev` to either of these protected production image names unless `--allow-protected-push` is explicitly supplied:

```text
markwelshboy/comfy-inference
markwelshboy/comfyui-inference
```

This is intentional so the currently deployed Krea image is not overwritten during testing.

## Build

CUDA selection is required explicitly:

```bash
./build_comfy-inference.sh --cuda cu130
./build_comfy-inference.sh --cuda cu128
```

Build locally without pushing:

```bash
./build_comfy-inference.sh --cuda cu130 --no-push
```

Load a single-platform build into local Docker:

```bash
./build_comfy-inference.sh --cuda cu128 --load
```

Test a newer ComfyUI branch/ref while still resolving it to an immutable SHA before Docker sees it:

```bash
./build_comfy-inference.sh --cuda cu130 --comfyui-ref master --tag cu130-master-test
```

The old `build_comfy_infer.sh` name remains as a thin compatibility wrapper.

## Image/runtime ownership

The image owns the stable foundation:

- Ubuntu / CUDA
- Python 3.12
- PyTorch
- ComfyUI
- ABI-sensitive constraints
- minimal common runtime dependencies
- build-time capability / dependency checks

`pod-runtime` owns volatile session behavior:

- workload/profile selection
- custom nodes
- model provisioning
- Sage/Kitchen/runtime choices
- workflow and persistent-state setup
- ComfyUI launch policy

The image entrypoint fetches `pod-runtime` and defaults to `start.sh`. It can be overridden with:

```text
POD_RUNTIME_REF=<branch-or-ref>
POD_RUNTIME_ENTRYPOINT=start.minimax.sh
```

Longer term, Krea2 / MiniMax / image-edit should be runtime workload profiles rather than separate Docker image families.

## Constraints policy

`constraints/cu128.txt` and `constraints/cu130.txt` pin the CUDA/PyTorch and other binary-sensitive pieces. They intentionally do not pin `huggingface-hub`, `transformers`, `tokenizers`, `diffusers`, or `accelerate` to old generations.

The Dockerfile currently establishes these minimum application-layer floors:

```text
huggingface-hub >= 1.22.0
transformers    >= 5.5
```

This is specifically intended to avoid the old Krea image's `huggingface-hub==0.36.0` / Transformers 4.x dead-end while still letting custom-node requirements participate in dependency resolution.

## Branches

The pre-convergence repository state is preserved at:

```text
legacy/pre-convergence-20261020
```

Initial convergence work is on:

```text
agent/cu128-cu130-convergence
```
