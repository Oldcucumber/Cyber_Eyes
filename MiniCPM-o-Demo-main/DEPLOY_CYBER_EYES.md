# Cyber Eyes Deployment

## Outcome
- Public app: `https://<host>:8006/cyber-eyes`
- Root URL `/` redirects to Cyber Eyes
- Camera and microphone run over HTTPS by default
- Self-signed TLS certs are generated automatically when missing
- Internal workers bind to `127.0.0.1` only
- Model download order: ModelScope first, Hugging Face fallback

## Bare Metal
```bash
cd MiniCPM-o-Demo-main
bash bootstrap.sh
```

Optional environment variables:
```bash
PORT=8006 WORKER_BASE_PORT=22400 TLS_CN=your-domain-or-ip bash bootstrap.sh
MODEL_DIR=/data/models/MiniCPM-o-4_5 bash bootstrap.sh
```

## Docker
```bash
cd MiniCPM-o-Demo-main
docker compose up -d --build
```

The mounted `./workspace` directory will persist:
- `workspace/models/MiniCPM-o-4_5`
- `workspace/config.json`
- `workspace/certs/`
- `workspace/data/`
- `workspace/torch_compile_cache/`

## Notes
- Browsers will warn on the self-signed certificate the first time. Accept it once, then camera and microphone access will work.
- Only the gateway port is intended for external access. Worker ports stay on loopback.
- If you already have a local model directory, place it at `models/MiniCPM-o-4_5` or set `MODEL_DIR` explicitly.
- `config.example.json` now defaults to the local model directory layout used by `bootstrap.sh`.
