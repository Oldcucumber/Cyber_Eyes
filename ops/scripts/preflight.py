#!/usr/bin/env python3
from __future__ import annotations

import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, List, Sequence

MIN_DRIVER = (570, 26)
EXPECTED_CUDA = (12, 8)
MIN_VRAM_GB = 28.0
EXPECTED_PYTHON = (3, 10)


@dataclass
class GpuInfo:
    index: int
    name: str
    memory_mb: int
    driver_version: str


def parse_version(text: str) -> Sequence[int]:
    return tuple(int(part) for part in re.findall(r'\d+', text))


def version_at_least(current: Sequence[int], minimum: Sequence[int]) -> bool:
    size = max(len(current), len(minimum))
    padded_current = list(current) + [0] * (size - len(current))
    padded_minimum = list(minimum) + [0] * (size - len(minimum))
    return tuple(padded_current) >= tuple(padded_minimum)


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=False)


def probe_gpus() -> List[GpuInfo]:
    if not shutil.which('nvidia-smi'):
        return []
    result = run_command([
        'nvidia-smi',
        '--query-gpu=index,name,memory.total,driver_version',
        '--format=csv,noheader,nounits',
    ])
    if result.returncode != 0:
        return []

    gpus: List[GpuInfo] = []
    for line in result.stdout.splitlines():
        parts = [part.strip() for part in line.split(',')]
        if len(parts) != 4:
            continue
        try:
            gpus.append(GpuInfo(
                index=int(parts[0]),
                name=parts[1],
                memory_mb=int(float(parts[2])),
                driver_version=parts[3],
            ))
        except ValueError:
            continue
    return gpus


def probe_nvcc_version() -> str | None:
    if not shutil.which('nvcc'):
        return None
    result = run_command(['nvcc', '--version'])
    if result.returncode != 0:
        return None
    match = re.search(r'release\s+(\d+\.\d+)', result.stdout)
    return match.group(1) if match else None


def has_ffmpeg() -> bool:
    return shutil.which('ffmpeg') is not None


def echo_lines(prefix: str, lines: Iterable[str]) -> None:
    for line in lines:
        print(f'{prefix}{line}')


def main() -> int:
    blockers: List[str] = []
    warnings: List[str] = []

    print('[preflight] Cyber Eyes host check')
    print(f'[preflight] OS: {platform.platform()}')
    print(f'[preflight] Python: {sys.version.split()[0]}')

    if platform.system() != 'Linux':
        blockers.append('Linux is required for the supported bare-metal deployment path.')
    if sys.version_info[:2] != EXPECTED_PYTHON:
        blockers.append('Python 3.10 is required by the upstream MiniCPM-o deployment path.')

    if has_ffmpeg():
        print('[preflight] ffmpeg: found')
    else:
        blockers.append('ffmpeg is missing. Install it before deployment.')

    gpus = probe_gpus()
    if not gpus:
        blockers.append('nvidia-smi did not report any NVIDIA GPU. Install the driver first.')
    else:
        for gpu in gpus:
            print(f'[preflight] GPU {gpu.index}: {gpu.name} | {gpu.memory_mb / 1024:.1f} GiB | driver {gpu.driver_version}')
        best_gpu = max(gpus, key=lambda item: item.memory_mb)
        if best_gpu.memory_mb / 1024 < MIN_VRAM_GB:
            blockers.append(
                f'Largest visible GPU has only {best_gpu.memory_mb / 1024:.1f} GiB VRAM; '
                f'the upstream demo recommends more than {MIN_VRAM_GB:.0f} GiB.'
            )
        if not version_at_least(parse_version(best_gpu.driver_version), MIN_DRIVER):
            blockers.append(
                f'NVIDIA driver {best_gpu.driver_version} is below the required baseline '
                f'{MIN_DRIVER[0]}.{MIN_DRIVER[1]} for CUDA 12.8.'
            )

    nvcc_version = probe_nvcc_version()
    if nvcc_version is None:
        warnings.append('nvcc not found. PyTorch CUDA wheels can still run, but toolkit 12.8 is recommended for troubleshooting and extensions.')
    else:
        print(f'[preflight] nvcc: {nvcc_version}')
        if parse_version(nvcc_version)[:2] != EXPECTED_CUDA:
            warnings.append(f'nvcc reports CUDA {nvcc_version}; toolkit 12.8 is the deployment baseline in this repo.')

    if blockers:
        echo_lines('[preflight] BLOCKER: ', blockers)
    if warnings:
        echo_lines('[preflight] WARNING: ', warnings)

    if blockers:
        print('[preflight] Result: not ready')
        return 1

    print('[preflight] Result: ready')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
