"""Runtime configuration for Cyber Eyes."""

from __future__ import annotations

import json
import logging
import os
from typing import List, Optional

from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

PROJECT_ROOT = os.path.dirname(os.path.dirname(__file__))
_CONFIG_PATH = os.path.join(PROJECT_ROOT, "config.json")
_EXAMPLE_PATH = os.path.join(PROJECT_ROOT, "config.example.json")


class ModelConfig(BaseModel):
    model_path: str = Field(description="Path or repo id for the base model.")
    pt_path: Optional[str] = Field(default=None, description="Optional extra checkpoint path.")
    attn_implementation: str = Field(default="auto", pattern="^(auto|flash_attention_2|sdpa|eager)$")


class AudioConfig(BaseModel):
    ref_audio_path: Optional[str] = Field(default="assets/ref_audio/ref_minicpm_signature.wav")
    playback_delay_ms: int = Field(default=200, ge=0, le=2000)
    chat_vocoder: str = Field(default="token2wav", pattern="^(token2wav|cosyvoice2)$")


class ServiceSectionConfig(BaseModel):
    gateway_port: int = Field(default=8006)
    worker_base_port: int = Field(default=22400)
    max_queue_size: int = Field(default=1000)
    eta_chat_s: float = Field(default=15.0)
    eta_half_duplex_s: float = Field(default=180.0)
    eta_audio_duplex_s: float = Field(default=120.0)
    eta_omni_duplex_s: float = Field(default=90.0)
    eta_ema_alpha: float = Field(default=0.3)
    eta_ema_min_samples: int = Field(default=3)
    request_timeout: float = Field(default=300.0)
    compile: bool = Field(default=False)
    data_dir: str = Field(default="data")


class RecordingConfig(BaseModel):
    enabled: bool = Field(default=True)
    session_retention_days: int = Field(default=-1)
    max_storage_gb: float = Field(default=-1)


class DuplexSectionConfig(BaseModel):
    pause_timeout: float = Field(default=60.0)


class ServiceConfig(BaseModel):
    model: ModelConfig
    audio: AudioConfig = Field(default_factory=AudioConfig)
    service: ServiceSectionConfig = Field(default_factory=ServiceSectionConfig)
    duplex: DuplexSectionConfig = Field(default_factory=DuplexSectionConfig)
    recording: RecordingConfig = Field(default_factory=RecordingConfig)

    @property
    def gateway_port(self) -> int:
        return self.service.gateway_port

    @property
    def worker_base_port(self) -> int:
        return self.service.worker_base_port

    @property
    def max_queue_size(self) -> int:
        return self.service.max_queue_size

    @property
    def request_timeout(self) -> float:
        return self.service.request_timeout

    @property
    def eta_chat_s(self) -> float:
        return self.service.eta_chat_s

    @property
    def eta_half_duplex_s(self) -> float:
        return self.service.eta_half_duplex_s

    @property
    def eta_audio_duplex_s(self) -> float:
        return self.service.eta_audio_duplex_s

    @property
    def eta_omni_duplex_s(self) -> float:
        return self.service.eta_omni_duplex_s

    @property
    def eta_ema_alpha(self) -> float:
        return self.service.eta_ema_alpha

    @property
    def eta_ema_min_samples(self) -> int:
        return self.service.eta_ema_min_samples

    @property
    def compile(self) -> bool:
        return self.service.compile

    @property
    def data_dir(self) -> str:
        return self.service.data_dir

    @property
    def ref_audio_path(self) -> Optional[str]:
        return self.audio.ref_audio_path

    @property
    def chat_vocoder(self) -> str:
        return self.audio.chat_vocoder

    @property
    def attn_implementation(self) -> str:
        return self.model.attn_implementation

    @property
    def duplex_pause_timeout(self) -> float:
        return self.duplex.pause_timeout

    @property
    def playback_delay_ms(self) -> int:
        return self.audio.playback_delay_ms

    def worker_port(self, worker_index: int) -> int:
        return self.worker_base_port + worker_index

    def worker_addresses(self, num_workers: int) -> List[str]:
        return [f"localhost:{self.worker_port(i)}" for i in range(num_workers)]

    def frontend_defaults(self) -> dict:
        return {"playback_delay_ms": self.playback_delay_ms}


def load_config(path: str = _CONFIG_PATH) -> ServiceConfig:
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"Config file not found: {path}\n"
            f"Create it from the example template: cp {_EXAMPLE_PATH} {path}"
        )

    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    model_section = data.get("model") or {}
    if not model_section.get("model_path"):
        raise ValueError('config.json is missing required field model.model_path')

    config = ServiceConfig(**data)
    logger.info(
        "Config loaded: model=%s attn=%s gateway_port=%s playback_delay_ms=%s",
        config.model.model_path,
        config.attn_implementation,
        config.gateway_port,
        config.playback_delay_ms,
    )
    return config


_config: Optional[ServiceConfig] = None


def get_config() -> ServiceConfig:
    global _config
    if _config is None:
        _config = load_config()
    return _config
