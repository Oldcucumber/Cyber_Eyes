# Cyber Eyes

Cyber Eyes is a productized local deployment of MiniCPM-o full-duplex multimodal interaction for blind-assistance scenarios. The repo is trimmed to one public experience: a real-time, interruptible guidance client that prioritizes hazard alerts, action-first prompts, and operator-friendly deployment.

## Repository Layout

- `backend/`: gateway, worker, model integration, session utilities
- `frontend/`: Cyber Eyes web client and duplex runtime
- `ops/`: bare-metal deployment, host preflight, install helpers
- `vendor/`: vendorized MiniCPM-o runtime code
- `assets/`: default reference audio and bundled runtime assets
- `docs/`: deployment and validation notes
- `tests/`: retained low-level tests and mock worker helpers

## Bare-Metal Quick Start

1. Provision a Linux host with an NVIDIA GPU.
2. Review the deployment guide in [`docs/deployment.md`](/D:/gpd/Cyber_Eyes/docs/deployment.md).
3. Run the interactive bootstrap:

```bash
bash ops/bootstrap.sh
```

The bootstrap path is bare-metal first:

- ModelScope is preferred for model download and falls back to Hugging Face.
- HTTPS is enabled by default using a self-signed certificate.
- Internal workers bind to `127.0.0.1`; only the gateway port needs to be opened externally.
- Docker is intentionally removed from the primary path to avoid GPU/runtime compatibility drift.

## Useful Commands

```bash
bash ops/install_system_deps_ubuntu.sh --print-only
bash ops/install_cuda_ubuntu.sh --print-only
bash ops/bootstrap.sh --yes --source auto
bash ops/start_all.sh
bash ops/stop_all.sh
```

## Operational Notes

- The validated software baseline is Linux + Python 3.10 + PyTorch 2.8.0 CUDA 12.8 wheels.
- Camera and microphone access require HTTPS in normal browser deployments.
- The frontend sends structured `assist_context` to the worker so the backend owns the final guidance policy.
