#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path: Path) -> dict:
    with path.open('r', encoding='utf-8') as fh:
        return json.load(fh)


def dump_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=4, ensure_ascii=False)
        fh.write('\n')


def main() -> None:
    parser = argparse.ArgumentParser(description='Prepare config.json for Cyber Eyes deployment.')
    parser.add_argument('--config', required=True, help='Target config.json path')
    parser.add_argument('--template', default='config.example.json', help='Template config path')
    parser.add_argument('--model-dir', required=True, help='Resolved local model directory')
    parser.add_argument('--gateway-port', type=int, default=8006, help='Public HTTPS port')
    parser.add_argument('--worker-base-port', type=int, default=22400, help='Internal worker base port')
    args = parser.parse_args()

    config_path = Path(args.config).resolve()
    template_path = Path(args.template).resolve()
    data = load_json(config_path) if config_path.exists() else load_json(template_path)

    data.setdefault('model', {})
    data['model']['model_path'] = str(Path(args.model_dir).resolve())

    service = data.setdefault('service', {})
    service['gateway_port'] = args.gateway_port
    service['worker_base_port'] = args.worker_base_port
    service.setdefault('data_dir', 'data')
    service.setdefault('compile', False)

    audio = data.setdefault('audio', {})
    audio.setdefault('ref_audio_path', 'assets/ref_audio/ref_minicpm_signature.wav')
    audio.setdefault('playback_delay_ms', 200)
    audio.setdefault('chat_vocoder', 'token2wav')

    recording = data.setdefault('recording', {})
    recording.setdefault('enabled', True)
    recording.setdefault('session_retention_days', -1)
    recording.setdefault('max_storage_gb', -1)

    dump_json(config_path, data)
    print(f'[config] prepared: {config_path}')


if __name__ == '__main__':
    main()
