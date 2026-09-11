from __future__ import annotations

import os
from dataclasses import dataclass


DEV_ENCRYPTION_KEY = "P4FA2Ab7sJ5jVJq7i6x0j1y3HfWwBPAJf0nl9M8B7V0="
DEV_FINGERPRINT_KEY = "secretbox-dev-fingerprint-key-not-for-production"


@dataclass(slots=True)
class Settings:
    database_url: str = os.getenv("DATABASE_URL", "sqlite:///./secretbox.db")
    ai_timeout_seconds: float = float(os.getenv("AI_TIMEOUT_SECONDS", "20"))
    server_host: str = os.getenv("SERVER_HOST", "0.0.0.0")
    server_port: int = int(os.getenv("SERVER_PORT", "8000"))
    encryption_key: str = os.getenv("ENCRYPTION_KEY", DEV_ENCRYPTION_KEY)
    fingerprint_key: str = os.getenv("FINGERPRINT_KEY", DEV_FINGERPRINT_KEY)


settings = Settings()
