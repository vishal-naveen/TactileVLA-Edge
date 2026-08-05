# PC setup runbook (agent-executable)

This is a self-contained runbook for setting up the **training machine** of the
TactileVLA-Edge project. It is written to be executed step by step by a coding agent
on that machine. A human reading it will also be fine.

## Context you need

- **This machine's job:** training robot-learning policies on an **NVIDIA RTX 3060 Ti
  (8 GB VRAM)**. It does *not* touch the robot arms — those stay on a separate Mac.
- **Environment:** Windows with **WSL2**. Every command below runs *inside* WSL, not
  in PowerShell, unless a step explicitly says otherwise.
- **What is being installed:** [LeRobot](https://github.com/huggingface/lerobot), a
  PyTorch robotics library, pinned to a specific commit.
- **Why a pinned commit:** datasets recorded on the Mac carry a `codebase_version`
  (currently `v3.0`) in `meta/info.json`. A different LeRobot version may refuse to
  read them. Do not substitute `pip install lerobot`.

## Rules for whoever executes this

1. **Steps marked GATE are hard stops.** If a gate's check does not produce the stated
   output, stop and report the failure. Do not continue past a failing gate, and do not
   try to work around it by installing something different.
2. Run commands one step at a time and confirm each result before moving on.
3. Do **not** install an NVIDIA driver inside WSL. See GATE 0.
4. Do **not** `pip install torch` without the CUDA index URL. See GATE 2.
5. If a command needs a value you don't have (e.g. a Hugging Face username), ask
   rather than guessing.

---

## GATE 0 — CUDA must be visible inside WSL

```bash
nvidia-smi
```

**Expected:** a table listing `NVIDIA GeForce RTX 3060 Ti`.

**If it fails:** the fix is on the **Windows** side, not in WSL. A current NVIDIA Game
Ready or Studio driver installed on Windows provides WSL2 CUDA passthrough
automatically. Installing a *Linux* NVIDIA driver inside WSL **breaks** this and must
be avoided. Report this and stop — nothing downstream can work without it.

## Step 1 — Miniforge (conda)

Skip if `conda --version` already works.

```bash
cd ~
wget https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
bash Miniforge3-Linux-x86_64.sh -b -p "$HOME/miniforge3"
"$HOME/miniforge3/bin/conda" init bash
exec $SHELL
conda --version
```

## Step 2 — Environment and ffmpeg

```bash
conda create -y -n lerobot python=3.10
conda activate lerobot
conda install -y ffmpeg -c conda-forge
ffmpeg -hide_banner -encoders | grep svtav1
```

**Expected:** a line containing `libsvtav1`. That encoder is what dataset videos use.

> Every later step assumes `conda activate lerobot` is in effect. If you open a new
> shell, activate it again.

## GATE 2 — PyTorch with CUDA support

This is the single most common failure in this setup. A plain `pip install torch`
silently installs a **CPU-only** build, and the problem only surfaces much later when
training fails with a device error.

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
```

**Expected:** a version followed by `True`.

**If it prints `False`:** the CPU build got installed. Fix with:

```bash
pip uninstall -y torch torchvision
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
```

Then re-check. Do not continue until it prints `True`.

## Step 3 — LeRobot at the pinned commit

```bash
git clone https://github.com/vishal-naveen/lerobot.git ~/lerobot
cd ~/lerobot
git checkout d7ea6f3bd84fa7754cbcdc13a0b023fc2eaa063c
pip install -e ".[feetech,smolvla,training]"
```

All three extras are needed:

- `feetech` — motor driver package (harmless here; keeps parity with the Mac)
- `smolvla` — the vision-language-action policy this project targets
- `training` — provides `accelerate`, which `lerobot-train` hard-requires and checks
  for before doing any work

If pip reports that it would change the installed `torch`, stop and report it — that
would undo GATE 2.

## GATE 4 — torchcodec matching torch's ABI

`torchcodec` ships a compiled extension linked against a specific torch ABI. A
mismatched version **installs cleanly and then fails at import**, which makes this easy
to miss.

```bash
pip install "torchcodec>=0.3.0,<0.12.0"
python -c "from torchcodec.decoders import VideoDecoder; print('torchcodec OK')"
```

**Expected:** `torchcodec OK`.

**If it fails** with `Could not load this library: libtorchcodec_core*`: the version
does not match the installed torch. Known pairings:

| torchcodec | torch |
|---|---|
| 0.10.x | 2.10 |
| 0.11.x | 2.11 |
| 0.12.x | 2.12 |

Check `python -c "import torch; print(torch.__version__)"` and install the matching
torchcodec, e.g. `pip install "torchcodec==0.10.0"` for torch 2.10. LeRobot 0.5.2
requires `>=0.3.0,<0.12.0`, so stay inside that range.

## Step 5 — Hugging Face login

Datasets transfer between machines through the Hub as private repos.

```bash
hf auth login
```

This is interactive and needs a token from https://huggingface.co/settings/tokens
with **write** access. If running non-interactively, ask the user to run it themselves.

## GATE 6 — Full stack verification

```bash
python - <<'PY'
import accelerate
import lerobot
import torch
import torchcodec
from torchcodec.decoders import VideoDecoder  # noqa: F401

print("lerobot   ", lerobot.__version__)
print("torch     ", torch.__version__, "cuda:", torch.cuda.is_available())
print("torchcodec", torchcodec.__version__)
print("accelerate", accelerate.__version__)
print("gpu       ", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
PY
```

**Expected:** `lerobot 0.5.2`, `cuda: True`, a torchcodec version, an accelerate
version, and the GPU named as an RTX 3060 Ti. Report the full output.

## Step 7 — Confirm a real training run starts

Do a tiny smoke test rather than launching hours of training. This needs a dataset on
the Hub — ask the user for their Hugging Face username and dataset name if you do not
have it (expected to be something like `<username>/noodle10`).

```bash
lerobot-train \
  --dataset.repo_id=<username>/<dataset> \
  --policy.type=act \
  --policy.device=cuda \
  --output_dir=/tmp/smoketest \
  --job_name=smoke \
  --batch_size=2 \
  --steps=5 \
  --save_freq=5 \
  --log_freq=1 \
  --wandb.enable=false \
  --policy.push_to_hub=false
```

**Expected:** five `step:N ... loss:...` lines and `End of training`. Loss values will
be large and erratic at five steps — that is fine. What matters is that it runs on CUDA
and finishes. Then clean up: `rm -rf /tmp/smoketest`.

If the dataset is not on the Hub yet, skip this step and report that GATE 6 passed but
step 7 could not be verified.

---

## Reference: real training commands

Not part of setup — for later use.

**Important:** `lerobot-train` defaults to `--steps=100000`. LeRobot's own guidance is
5-10 epochs over the dataset. For a 4,000-frame dataset at batch 8 that is roughly
5,000 steps. Using the default would train ~130 epochs and waste hours overfitting.

```bash
# ACT - comfortable on 8 GB
lerobot-train \
  --dataset.repo_id=<username>/<dataset> \
  --policy.type=act --policy.device=cuda \
  --output_dir=outputs/train/act_run --job_name=act_run \
  --batch_size=8 --steps=5000 --save_freq=1000 --log_freq=100 \
  --wandb.enable=false --policy.push_to_hub=false
```

```bash
# SmolVLA - 8 GB is BELOW the 10-16 GB LeRobot lists as comfortable.
# Keep the vision encoder frozen (the default) and use a small batch.
lerobot-train \
  --policy.path=lerobot/smolvla_base \
  --dataset.repo_id=<username>/<dataset> \
  --policy.device=cuda \
  --output_dir=outputs/train/smolvla_run --job_name=smolvla_run \
  --batch_size=2 --steps=5000 --save_freq=1000 --log_freq=100 \
  --wandb.enable=false --policy.push_to_hub=false
```

On CUDA out-of-memory: lower `--batch_size` first. Gradient accumulation can recover
the effective batch size; SmolVLA's SigLIP vision tower uses LayerNorm rather than
BatchNorm, so accumulation is close to equivalent to a true larger batch.

## Reference: VRAM by policy

The RTX 3060 **Ti** has **8 GB** — less than the plain RTX 3060's 12 GB, despite being
the faster card. VRAM, not compute, is the binding constraint here.

| Policy | VRAM at batch 8 | 8 GB verdict |
|---|---|---|
| ACT | ~2-6 GB | Comfortable |
| Diffusion | ~8-14 GB | Borderline |
| SmolVLA | ~10-16 GB | Tight - reduce batch |
| pi0 / pi05 | ~24-40 GB | Not feasible |

## Troubleshooting summary

| Symptom | Cause |
|---|---|
| `nvidia-smi` not found in WSL | No NVIDIA driver on the Windows host, or a Linux driver was wrongly installed inside WSL |
| `torch.cuda.is_available()` is False | CPU-only torch build |
| `Could not load this library: libtorchcodec_core*` | torchcodec/torch ABI mismatch |
| `'accelerate' is required but not installed` | Missing the `training` extra |
| Dataset refuses to load | LeRobot version differs from the recording machine's |
| CUDA out of memory | Batch too large for 8 GB |
