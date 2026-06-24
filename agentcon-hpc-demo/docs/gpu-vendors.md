# GPU vendor paths — AMD (primary), NVIDIA, CPU fallback

This repo originally targeted NVIDIA + CUDA. Your subscription's GPU quota is for the `Standard_NV8as_v4` family, which exposes a **partition of an AMD Radeon Instinct MI25 (Vega 10, gfx900) via MxGPU virtualization**. That changes the runtime in three places: the driver, the container toolkit, and the GROMACS build flags. This doc walks all three vendor paths, with the AMD path as the primary.

Before you spend hours on the AMD path, read the next section: there is a real chance ROCm won't see the GPU on this specific VM family, and the realistic fix is to switch hardware.

## The honest assessment of `NV8as_v4`

`NVas_v4` is the AMD half of Azure's "NV" family — it is **marketed for remote desktop / visualization workloads**, not for compute. The Linux ROCm runtime is not officially supported on this SKU by either Microsoft or AMD. Things that may bite you:

- **MxGPU virtualization.** The MI25 is sliced into 8 partitions (2 GB VRAM each on `NV8as_v4`). The host SR-IOV layer can prevent ROCm's HSA runtime from seeing the device — `rocminfo` shows nothing, `hipDeviceCount` returns 0.
- **Vega 10 / gfx900.** Officially dropped from ROCm 6.x. The last release with first-class support was ROCm 5.7 (released late 2023). Newer ROCm can sometimes be coerced into running on gfx900 via `HSA_OVERRIDE_GFX_VERSION=9.0.0`, but reliability is best-effort.
- **Azure drivers.** Microsoft publishes an `amdgpu` Linux driver for the NVas family, but it targets the display path (DisplayManager, OpenGL), not the compute path. You may need to install the open AMDGPU + ROCm stack on top.

If ROCm comes up and `rocminfo` lists `gfx900`, you're in business. If it doesn't, see "what to do if ROCm doesn't see the GPU" below.

## The three vendor paths

| Path | When to pick | Setup script | Container | Estimated wall time for the demo's 50 ps production MD |
|---|---|---|---|---|
| **AMD / ROCm** | `NV*_v4` (MI25) — primary, given your quota | `infra/setup-vm-amd.sh` | `Dockerfile.rocm` | 30–60 s if ROCm sees the GPU |
| **NVIDIA / CUDA** | `NC*_T4`, `NV*_A10` — original target | `infra/setup-vm.sh` | `Dockerfile.cuda` (renamed from `Dockerfile`) | ~15 s on T4, ~8 s on A10 |
| **CPU only** | Anything; safety net | `infra/setup-vm.sh --cpu` *(or just install Docker)* | `Dockerfile.cpu` | 90–180 s on 8 vCPU |

The runtime selector everything respects is the `GPU_VENDOR` environment variable: `amd`, `nvidia`, or `cpu`. Set it once in `agent/.env` and the workflow scripts pick the right `docker run` flags, the right image tag, and the right log messages.

## The AMD path, end to end

### 1. Provision

Your `infra/provision-vm.sh` already picks `Standard_NV8as_v4`. Run it as-is.

### 2. Install ROCm on the VM

```bash
ssh azureuser@<vm-ip>
git clone <this-repo>
cd agentcon-hpc-demo
./infra/setup-vm-amd.sh
# This will reboot once after the AMDGPU driver install.
# Re-run the script after reboot to finish ROCm + Docker setup.
```

After it finishes, smoke test:

```bash
/opt/rocm/bin/rocminfo | grep -E "gfx|Name:"
# Expect a line like: Name: gfx900
```

**If `rocminfo` shows no agents:** skip to "what to do if ROCm doesn't see the GPU".

### 3. Build the GROMACS-ROCm image

```bash
cd ~/agentcon-hpc-demo/container
docker build -f Dockerfile.rocm -t gromacs-demo:rocm .
```

This pins ROCm 5.7 (last release with first-class MI25 support) and builds GROMACS 2024.3 with the **SYCL backend via AdaptiveCpp** (formerly hipSYCL). We don't use the HIP backend because it requires ROCm 5.5+ in practice with mixed reports on gfx900; SYCL via AdaptiveCpp targets gfx900 cleanly.

Expected build time: ~20 minutes on 8 vCPU.

### 4. Configure and run the agent

```bash
cd ~/agentcon-hpc-demo/agent
cp .env.example .env
# Edit .env, set:
#   GPU_VENDOR=amd
#   GMX_IMAGE=gromacs-demo:rocm
pip install -r requirements.txt
python agent.py
```

The agent's `check_environment` tool will probe for ROCm instead of CUDA when `GPU_VENDOR=amd`. The workflow scripts will use `--device=/dev/kfd --device=/dev/dri --group-add video --security-opt seccomp=unconfined` instead of `--gpus all`.

### 5. What to say on stage about the vendor swap

The talk's message gets *stronger* with this swap: the agent didn't change. The tools didn't change. Only the container image and the docker-run flags changed. That's the orchestration-layer point in concrete form — swapping the compute substrate is a config change, not an agent change.

## What to do if ROCm doesn't see the GPU

`rocminfo` shows no agents → `NV8as_v4`'s MxGPU layer is blocking compute access. Three options, in order:

1. **Use the CPU fallback for the demo.** Set `GPU_VENDOR=cpu`, `GMX_IMAGE=gromacs-demo:cpu`. The 50 ps run takes 90–180 s on the 8 vCPU you already have. Slower, but it actually works. *This is the safest demo-day choice.*
2. **Request NVIDIA GPU quota for `Standard_NC4as_T4_v3`.** Submit via Portal → Quotas → Compute. Standard quota requests are usually approved within hours; some take 1–2 business days. With T4 quota in hand, switch back to the CUDA path entirely.
3. **Try ROCm with override.** Set `HSA_OVERRIDE_GFX_VERSION=9.0.0` in the container env. If that doesn't help, try newer ROCm (6.x) with the same override. This is the longest, riskiest path and not recommended before a talk.

I would pick **(1) for the talk** and start **(2) in parallel** so you have the CUDA path available for the next talk or for follow-up experimentation.

## The CPU fallback in detail

The CPU image is a separate, tiny Dockerfile. It's worth keeping around even on a working GPU machine: it's your "the GPU broke five minutes before I go on stage" insurance.

```bash
docker build -f Dockerfile.cpu -t gromacs-demo:cpu container/
# in .env:
GPU_VENDOR=cpu
GMX_IMAGE=gromacs-demo:cpu
```

`run_stage.sh` knows that with `GPU_VENDOR=cpu` it should drop `-nb gpu -update gpu -bonded gpu` from the mdrun command and just let GROMACS use all available cores. On 8 vCPUs lysozyme 50 ps prod completes in roughly 90–180 s; the equilibration is similar. The agent's narration doesn't change at all — the model never knew what hardware it was on.

For a live demo, 90 s of "the agent is working" dead air is workable if you fill it with explanation; 180 s is uncomfortable but survivable. If you go this route, consider shortening production to 25 ps (12,500 steps) — pass `nsteps=12500` to `run_stage` and you halve the wait.

## Summary

| Question | Answer |
|---|---|
| Will the AMD path work on `NV8as_v4`? | Maybe. It is not officially supported. Verify with `rocminfo` before committing the talk to it. |
| What if it doesn't? | CPU fallback. Same agent, slower compute. Demo still demonstrable. |
| Should I request NVIDIA quota anyway? | Yes — this is the lowest-risk path for the actual talk if you have time. |
| Does the agent change between paths? | No. Only the image tag and the `GPU_VENDOR` env var. That's a feature, not a workaround. |
