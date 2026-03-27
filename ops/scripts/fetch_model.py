#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path
from typing import Callable

READY_MARKERS = [
    'config.json',
    'configuration_minicpmo.py',
    'modeling_minicpmo_unified.py',
    'processing_minicpmo.py',
    'tokenizer.json',
]


def is_ready(model_dir: Path) -> bool:
    return model_dir.is_dir() and all((model_dir / marker).exists() for marker in READY_MARKERS)


def is_safe_dest(path: Path) -> bool:
    resolved = path.resolve()
    return resolved.parent != resolved and len(resolved.parts) >= 2


def clear_directory(path: Path) -> None:
    for child in path.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def ensure_destination(path: Path, force_clean: bool) -> None:
    if not is_safe_dest(path):
        raise SystemExit(f'[model] refusing to operate on unsafe destination: {path}')

    if not path.exists():
        path.mkdir(parents=True, exist_ok=True)
        return

    if not path.is_dir():
        if not force_clean:
            raise SystemExit(
                f'[model] destination exists as a file: {path}\n'
                '[model] re-run with --force-clean only if this path is managed by Cyber Eyes.'
            )
        path.unlink()
        path.mkdir(parents=True, exist_ok=True)
        return

    if is_ready(path):
        return

    contents = list(path.iterdir())
    if not contents:
        return

    if not force_clean:
        raise SystemExit(
            f'[model] destination exists but is not a ready model directory: {path}\n'
            '[model] re-run with --force-clean if this path is managed by Cyber Eyes.'
        )

    clear_directory(path)


def reset_destination(path: Path) -> None:
    if path.exists() and not path.is_dir():
        path.unlink()
    path.mkdir(parents=True, exist_ok=True)
    clear_directory(path)


def copy_tree(src: Path, dst: Path, force_clean: bool) -> None:
    src = src.expanduser().resolve()
    if not is_ready(src):
        raise SystemExit(f'[model] local source is not a complete MiniCPM-o model directory: {src}')

    ensure_destination(dst, force_clean=force_clean)
    if src == dst.resolve():
        return
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

    try:
        reset_destination(dest)
        try:
            snapshot_download(model_id=model_id, local_dir=str(dest))
        except TypeError:
            cache_dir = dest.parent / '.modelscope-cache'
            downloaded = snapshot_download(model_id=model_id, cache_dir=str(cache_dir))
            copy_tree(Path(downloaded), dest, force_clean=True)
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
        reset_destination(dest)
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
    parser = argparse.ArgumentParser(description='Resolve MiniCPM-o weights with ModelScope priority and safe local fallback.')
    parser.add_argument('--dest', required=True, help='Target local model directory')
    parser.add_argument('--source', default='auto', choices=['auto', 'modelscope', 'huggingface', 'local', 'skip'])
    parser.add_argument('--local-source', default=None, help='Pre-downloaded local model directory to copy from')
    parser.add_argument('--modelscope-id', default='OpenBMB/MiniCPM-o-4_5')
    parser.add_argument('--hf-id', default='openbmb/MiniCPM-o-4_5')
    parser.add_argument('--force-clean', action='store_true', help='Allow cleaning an existing non-ready destination')
    args = parser.parse_args()

    dest = Path(args.dest).expanduser().resolve()
    if is_ready(dest):
        print(f'[model] existing model detected: {dest}')
        return

    ensure_destination(dest, force_clean=args.force_clean)

    if args.source == 'skip':
        raise SystemExit(f'[model] source=skip but destination is not ready: {dest}')

    if args.source == 'local':
        if not args.local_source:
            raise SystemExit('[model] --local-source is required when --source local')
        copy_tree(Path(args.local_source), dest, force_clean=args.force_clean)
        print(f'[model] copied local model: {dest}')
        return

    if args.source == 'auto' and args.local_source:
        copy_tree(Path(args.local_source), dest, force_clean=args.force_clean)
        print(f'[model] copied local model: {dest}')
        return

    attempts: list[tuple[str, Callable[[], bool]]] = []
    if args.source == 'auto':
        attempts = [
            ('ModelScope', lambda: try_modelscope(args.modelscope_id, dest)),
            ('Hugging Face', lambda: try_huggingface(args.hf_id, dest)),
        ]
    elif args.source == 'modelscope':
        attempts = [('ModelScope', lambda: try_modelscope(args.modelscope_id, dest))]
    elif args.source == 'huggingface':
        attempts = [('Hugging Face', lambda: try_huggingface(args.hf_id, dest))]

    for _, attempt in attempts:
        if attempt():
            return

    raise SystemExit(
        '[model] failed to resolve MiniCPM-o-4_5.\n'
        '[model] Try --source local --local-source /path/to/model, or verify ModelScope/Hugging Face connectivity.'
    )


if __name__ == '__main__':
    main()
