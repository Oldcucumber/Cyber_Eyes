#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

READY_MARKERS = [
    'config.json',
    'configuration_minicpmo.py',
    'modeling_minicpmo_unified.py',
    'processing_minicpmo.py',
    'tokenizer.json',
]


def is_ready(model_dir: Path) -> bool:
    return model_dir.is_dir() and all((model_dir / marker).exists() for marker in READY_MARKERS)


def ensure_clean_dir(path: Path) -> None:
    if path.exists() and not is_ready(path):
        shutil.rmtree(path, ignore_errors=True)
    path.mkdir(parents=True, exist_ok=True)


def copy_tree(src: Path, dst: Path) -> None:
    if dst.exists() and not is_ready(dst):
        shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, dirs_exist_ok=True)


def try_modelscope(model_id: str, dest: Path) -> bool:
    try:
        try:
            from modelscope.hub.snapshot_download import snapshot_download  # type: ignore
        except ImportError:
            from modelscope import snapshot_download  # type: ignore
    except Exception as exc:
        print(f'[model] modelscope unavailable: {exc}')
        return False

    cache_dir = dest.parent / '.modelscope-cache'
    try:
        try:
            downloaded = snapshot_download(model_id=model_id, local_dir=str(dest))
        except TypeError:
            downloaded = snapshot_download(model_id=model_id, cache_dir=str(cache_dir))
            copy_tree(Path(downloaded), dest)
        print(f'[model] downloaded from ModelScope: {model_id}')
        return is_ready(dest)
    except Exception as exc:
        print(f'[model] ModelScope download failed: {exc}')
        return False


def try_huggingface(repo_id: str, dest: Path) -> bool:
    try:
        from huggingface_hub import snapshot_download  # type: ignore
    except Exception as exc:
        print(f'[model] huggingface_hub unavailable: {exc}')
        return False

    try:
        snapshot_download(
            repo_id=repo_id,
            local_dir=str(dest),
            local_dir_use_symlinks=False,
            resume_download=True,
        )
        print(f'[model] downloaded from Hugging Face: {repo_id}')
        return is_ready(dest)
    except Exception as exc:
        print(f'[model] Hugging Face download failed: {exc}')
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description='Download MiniCPM-o weights with ModelScope first.')
    parser.add_argument('--dest', required=True, help='Target local model directory')
    parser.add_argument('--modelscope-id', default='OpenBMB/MiniCPM-o-4_5')
    parser.add_argument('--hf-id', default='openbmb/MiniCPM-o-4_5')
    args = parser.parse_args()

    dest = Path(args.dest).resolve()
    if is_ready(dest):
        print(f'[model] existing model detected: {dest}')
        return

    ensure_clean_dir(dest)

    if try_modelscope(args.modelscope_id, dest):
        return

    ensure_clean_dir(dest)
    if try_huggingface(args.hf_id, dest):
        return

    raise SystemExit(
        '[model] failed to download MiniCPM-o-4_5 from both ModelScope and Hugging Face. '
        'Please check network connectivity or provide a pre-downloaded local model directory.'
    )


if __name__ == '__main__':
    main()

