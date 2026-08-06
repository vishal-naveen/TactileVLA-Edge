# Training machine setup (RTX 3060 12GB, Windows + WSL2)

Recording and teleoperation run on the Mac. Training runs here, on the GPU box.

WSL2 is preferred over native Windows: it gets the Linux `x86_64` wheels, which have
the widest `torchcodec` availability, and it keeps the environment close to the Mac's.

> **The version pin matters.** A dataset's `meta/info.json` records a
> `codebase_version` (currently **v3.0**), and a mismatched LeRobot may refuse to read
> it. Install the same commit as the recording machine, not a fresh `pip install
> lerobot`. See [ADR-0002](adr/0002-pin-lerobot-version.md).

## 0. Prerequisites on the Windows host

CUDA under WSL2 needs the driver installed on **Windows**, not inside WSL:

- Install the current NVIDIA driver on Windows (the standard Game Ready or Studio
  driver includes WSL2 CUDA support). Do **not** install a Linux NVIDIA driver
  inside WSL — that breaks the passthrough.
- Confirm from inside WSL:

```bash
nvidia-smi
```

This must list the GPU (an RTX 3060 on this machine) along with its driver version and
total memory. If it does not appear at all, stop here and fix the driver — nothing below
will work without it. Note the reported VRAM: it, rather than the model name, determines
which policies fit.

## 1. Miniforge

```bash
wget https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
bash Miniforge3-Linux-x86_64.sh
exec $SHELL
```

## 2. Environment

```bash
conda create -y -n lerobot python=3.10
conda activate lerobot
conda install -y ffmpeg -c conda-forge
```

Verify ffmpeg has the AV1 encoder used for dataset video:

```bash
ffmpeg -hide_banner -encoders | grep svtav1
```

## 3. PyTorch with CUDA

**This is the step that most often goes wrong.** A plain `pip install torch` installs
the CPU-only build, and you will not discover it until `--policy.device=cuda` fails.
Always use the CUDA index URL:

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
```

The second value **must** print `True`. If it prints `False`, the CPU build was
installed — uninstall and repeat with the index URL.

## 4. LeRobot, pinned to the recording machine's commit

```bash
git clone https://github.com/vishal-naveen/lerobot.git ~/lerobot
cd ~/lerobot
git checkout d7ea6f3bd84fa7754cbcdc13a0b023fc2eaa063c
pip install -e ".[feetech,smolvla,training]"
```

The `training` extra is required, not optional: `lerobot-train` calls
`require_package("accelerate")` and aborts immediately without it. Installing only
`[feetech,smolvla]` gets you all the way to launching a run before it fails.

## 5. torchcodec must match the installed torch

`torchcodec` ships a compiled extension linked against a specific torch ABI. The wrong
pairing installs cleanly and then fails at import with
`Could not load this library: libtorchcodec_core*.dylib/.so`.

Known pairings: torchcodec 0.10 ↔ torch 2.10, 0.11 ↔ torch 2.11, 0.12 ↔ torch 2.12.
LeRobot 0.5.2 constrains it to `>=0.3.0,<0.12.0`.

```bash
pip install "torchcodec>=0.3.0,<0.12.0"
python -c "from torchcodec.decoders import VideoDecoder; print('torchcodec OK')"
```

If the import fails, pick the version matching your torch minor rather than the newest.

## 6. Verify the whole stack

```bash
python - <<'PY'
import torch, torchcodec, lerobot
from torchcodec.decoders import VideoDecoder
print("lerobot   ", lerobot.__version__)
print("torch     ", torch.__version__, "cuda:", torch.cuda.is_available())
print("torchcodec", torchcodec.__version__)
print("gpu       ", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")
PY
```

## 7. Move the dataset over

The Hugging Face Hub is easier and more reliable than copying files between machines,
and it doubles as a backup. Use a **private** repo while the dataset is unpublished.

On the Mac:

```bash
hf auth login
hf upload <user>/noodle10 ~/.cache/huggingface/lerobot/local/<dataset_dir> \
  --repo-type dataset --private
```

On the PC, no download step is needed — training pulls by `repo_id`:

```bash
hf auth login
lerobot-train --dataset.repo_id=<user>/noodle10 ...
```

Alternatively, copy directly over the network (WSL2 can reach the Mac by IP):

```bash
mkdir -p ~/.cache/huggingface/lerobot/local
rsync -av <mac-user>@<mac-ip>:~/.cache/huggingface/lerobot/local/<dataset_dir> \
  ~/.cache/huggingface/lerobot/local/
```

## 8. Train

Do **not** accept the default `--steps=100000`. LeRobot's guidance is 5-10 epochs over
the dataset; on a 4k-frame dataset at batch 8 that is roughly 5,000 steps, not 100,000.

```bash
lerobot-train \
  --dataset.repo_id=<user>/noodle10 \
  --policy.type=act \
  --policy.device=cuda \
  --output_dir=outputs/train/act_noodle \
  --job_name=act_noodle \
  --batch_size=8 \
  --steps=5000 \
  --save_freq=1000 \
  --log_freq=100 \
  --wandb.enable=false \
  --policy.push_to_hub=false
```

For SmolVLA, 12 GB sits at the low end of the 10-16 GB LeRobot lists as comfortable.
Start around `--batch_size=4` and adjust from there. On out-of-memory, lower the batch
first; gradient accumulation recovers the effective batch size, and keeping
`freeze_vision_encoder=true` (the default) saves more.

## Notes on this GPU

Confirmed on this machine: **RTX 3060 with 12 GB**. Worth stating explicitly because
the faster RTX 3060 **Ti** has only **8 GB** — the name suggests an upgrade but the
VRAM is smaller, and VRAM is the binding constraint for these policies, not compute.

| Policy | VRAM at batch 8 | 12 GB verdict |
|---|---|---|
| ACT | ~2-6 GB | Comfortable |
| Diffusion | ~8-14 GB | Workable |
| SmolVLA | ~10-16 GB | Plausible at a modest batch; tune down on OOM |
| pi0 / pi05 | ~24-40 GB | Not feasible |

## Troubleshooting

| Symptom | Cause |
|---|---|
| `torch.cuda.is_available()` is False | CPU torch build, or missing Windows-side NVIDIA driver |
| `nvidia-smi` not found in WSL | Driver not installed on the Windows host, or a Linux driver was wrongly installed inside WSL |
| `Could not load this library: libtorchcodec_core*` | torchcodec/torch version mismatch |
| Dataset refuses to load | LeRobot version differs from the one that recorded it — check `codebase_version` |
| CUDA out of memory | Lower `--batch_size`; for SmolVLA also keep the vision encoder frozen |
