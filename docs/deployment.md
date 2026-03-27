# Cyber Eyes Deployment

This repository now supports two independent deployment planes:

- backend deployment: MiniCPM worker + gateway, optimized for bare-metal Linux with an NVIDIA GPU
- frontend deployment: a standalone Cyber Eyes web client that can be served locally with `npm`, uploaded as static files, or published through GitHub Pages

The backend path is still optimized for non-Docker deployment. The supported backend baseline is a Linux host with an NVIDIA GPU, local MiniCPM-o weights, a Python 3.10 virtualenv, and one public HTTPS port exposed by the gateway.

## 1. Target Baseline

- OS: Linux
- Python: 3.10
- GPU: NVIDIA GPU with more than 28 GB VRAM recommended by the upstream MiniCPM-o demo
- Driver / CUDA baseline: NVIDIA driver 570.26 or newer, CUDA toolkit 12.8
- PyTorch baseline: `torch==2.8.0` and `torchaudio==2.8.0` from the official `cu128` wheel index
- Browser requirement: HTTPS for camera and microphone permissions

Reference sources:

- [OpenBMB MiniCPM-o-Demo](https://github.com/OpenBMB/MiniCPM-o-Demo)
- [OpenBMB MiniCPM-o 4.5 model card](https://huggingface.co/openbmb/MiniCPM-o-4_5)
- [NVIDIA CUDA Installation Guide for Linux](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)
- [CUDA 12.8 release notes](https://docs.nvidia.com/cuda/archive/12.8.0/cuda-toolkit-release-notes/index.html)
- [PyTorch previous versions](https://pytorch.org/get-started/previous-versions/)

## 2. Install Base Host Packages

Ubuntu helper:

```bash
bash ops/install_system_deps_ubuntu.sh --print-only
```

If the host is a supported Ubuntu release and you want the helper to run the commands directly:

```bash
bash ops/install_system_deps_ubuntu.sh --apply
```

What this installs:

- `build-essential`
- `curl`
- `ffmpeg`
- `git`
- `libsndfile1`
- `pkg-config`
- `wget`
- `python3-venv`
- `python3-pip`

Note: the project still expects Python 3.10. If your distribution default is newer, provision Python 3.10 separately and pass it into bootstrap:

```bash
PYTHON=/path/to/python3.10 bash ops/bootstrap.sh
```

## 3. Install NVIDIA Driver and CUDA 12.8

Ubuntu helper:

```bash
bash ops/install_cuda_ubuntu.sh --print-only
```

If you want the helper to run the install commands directly:

```bash
bash ops/install_cuda_ubuntu.sh --apply
```

The helper does three things:

1. Installs Ubuntu's recommended NVIDIA GPGPU driver via `ubuntu-drivers`.
2. Adds the official NVIDIA CUDA apt repository with the CUDA keyring package.
3. Installs `cuda-toolkit-12-8`.

After the driver step, reboot the host and verify:

```bash
nvidia-smi
nvcc --version
```

What to check:

- `nvidia-smi` reports driver `570.26` or newer.
- `nvcc --version` reports CUDA `12.8.x`.
- At least one visible GPU has enough VRAM for the chosen MiniCPM-o deployment.

Important nuance: the PyTorch `cu128` wheels are sufficient for normal inference and do not require `nvcc`. The full CUDA toolkit is still recommended here because it makes host validation, extension builds, and future troubleshooting much simpler.

## 4. Interactive Bootstrap

Once the host has Python 3.10, ffmpeg, the NVIDIA driver, and the CUDA runtime/toolkit ready, run:

```bash
bash ops/bootstrap.sh
```

The interactive bootstrap will:

- create `.venv/base`
- install PyTorch 2.8.0 / torchaudio 2.8.0 from the `cu128` index
- install `requirements.txt`
- run a host preflight check
- download the model with ModelScope first and Hugging Face fallback
- generate `config.json`
- generate a self-signed certificate unless `--http` is requested
- start local workers and the public gateway

Useful flags:

```bash
bash ops/bootstrap.sh --yes --source auto
bash ops/bootstrap.sh --yes --source local --local-source /data/models/MiniCPM-o-4_5
bash ops/bootstrap.sh --skip-start
bash ops/bootstrap.sh --model-dir /data/models/MiniCPM-o-4_5
bash ops/bootstrap.sh --gpu-list 0
bash ops/bootstrap.sh --port 8443 --worker-base-port 22400 --tls-cn your-domain-or-ip
```

## 5. Manual Install Sequence

If you prefer an explicit step-by-step deployment instead of the wizard:

```bash
PYTHON=/path/to/python3.10 bash ops/install.sh
.venv/base/bin/python ops/scripts/preflight.py
.venv/base/bin/python ops/scripts/fetch_model.py --dest /data/models/MiniCPM-o-4_5 --source auto
.venv/base/bin/python ops/scripts/prepare_runtime.py --config config.json --template config.example.json --model-dir /data/models/MiniCPM-o-4_5 --gateway-port 8006 --worker-base-port 22400
.venv/base/bin/python ops/scripts/ensure_certs.py --cert certs/cert.pem --key certs/key.pem --common-name your-domain-or-ip
bash ops/start_all.sh
```

The PyTorch installation used by `ops/install.sh` is equivalent to:

```bash
.venv/base/bin/pip install --index-url https://download.pytorch.org/whl/cu128 torch==2.8.0 torchaudio==2.8.0
```

## 6. Runtime Model Download Strategy

`ops/scripts/fetch_model.py` supports four modes:

- `auto`: ModelScope first, Hugging Face fallback
- `modelscope`: ModelScope only
- `huggingface`: Hugging Face only
- `skip`: require an already prepared local model directory

Examples:

```bash
.venv/base/bin/python ops/scripts/fetch_model.py --dest /data/models/MiniCPM-o-4_5 --source auto
.venv/base/bin/python ops/scripts/fetch_model.py --dest /data/models/MiniCPM-o-4_5 --local-source /mnt/preloaded/MiniCPM-o-4_5
```

## 7. Start, Stop, and Restart

Start:

```bash
bash ops/start_all.sh
```

Stop:

```bash
bash ops/stop_all.sh
```

`ops/start_all.sh` is restart-safe: it stops prior PIDs from this workspace before spawning fresh workers and the gateway.

Recording defaults are bounded to 7 days and 20 GB unless you override them during bootstrap.

## 8. Split Frontend Deployment

The frontend can now be deployed separately from the MiniCPM backend.

### 8.1 Local proxy mode

This is the default local workflow:

```bash
npm install
cp frontend/config/backend-targets.example.json frontend/config/backend-targets.local.json
npm run dev
```

Then edit `frontend/config/backend-targets.local.json` so the default target points at your local gateway:

- `mode: "proxy"` means the browser only talks to the frontend server
- `httpBaseUrl` / `wsBaseUrl` are the upstream MiniCPM gateway addresses that the frontend server proxies to

The request path becomes:

1. user browser -> frontend server
2. frontend server -> MiniCPM gateway
3. MiniCPM gateway -> local workers

### 8.2 Remote direct mode

To allow the browser to talk to an approved remote backend directly:

1. add a `direct` target in `frontend/config/backend-targets.local.json`
2. set `httpBaseUrl` and `wsBaseUrl` to the remote backend origin
3. add the frontend origin to `config.json -> frontend -> cors_allowed_origins` on the backend

In direct mode the access path becomes:

1. user browser -> frontend host
2. user browser -> remote MiniCPM gateway

The frontend and backend are visited independently, and the frontend proxy is bypassed.

### 8.3 Static build

Build a deployable frontend bundle:

```bash
npm install
npm run build
```

Output directory:

- `dist/`

Useful commands:

```bash
npm run dev
npm run preview
npm run start
```

### 8.4 GitHub Pages / Actions deployment

A workflow is included at `.github/workflows/frontend-deploy.yml`.

For a useful Pages deployment, configure repository variables before enabling the workflow:

- `CYBER_EYES_REMOTE_HTTP_BASE_URL`
- `CYBER_EYES_REMOTE_WS_BASE_URL`
- `CYBER_EYES_ACTIVE_TARGET_ID`
- optionally `CYBER_EYES_REMOTE_TARGET_ID`
- optionally `CYBER_EYES_REMOTE_TARGET_LABEL`
- optionally `CYBER_EYES_REMOTE_TARGET_DESCRIPTION`
- optionally `CYBER_EYES_REMOTE_TARGET_MODE`

The workflow builds `dist/` and publishes it to GitHub Pages. If the remote backend variables are absent, the deployed frontend will still build, but the default target will remain local proxy mode and will not work on Pages.

## 9. Remote Validation Checklist

Once the service is up, verify in this order:

1. `curl -k https://127.0.0.1:8006/health`
2. `curl -k https://127.0.0.1:8006/status`
3. Open `https://<public-host>:8006/cyber-eyes`
4. Confirm the browser grants camera and microphone permissions
5. Start a live session and verify the status badge shows idle workers before entering the queue
6. Confirm the first spoken output is short and interruptible
7. Hold the hold-to-talk button and verify the model yields to the user immediately
8. Check `tmp/gateway.log` and `tmp/worker_0.log` if startup or streaming stalls

For split frontend deployment, also verify:

9. Open the standalone frontend host and confirm the backend target selector points at the expected backend
10. In proxy mode, verify `/status` succeeds through the frontend server
11. In direct mode, verify the backend replies with the expected `Access-Control-Allow-Origin`

## 10. Network Surface

Only the gateway port needs to be exposed externally. Worker processes bind to `127.0.0.1` and are not intended for direct remote access.

When the frontend is deployed separately:

- local proxy mode exposes only the frontend port to users; the frontend server then reaches the backend
- remote direct mode exposes the frontend host and the backend host independently
