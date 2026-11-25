from __future__ import annotations

import os
from dataclasses import dataclass

DEV_ENCRYPTION_KEY = "P4FA2Ab7sJ5jVJq7i6x0j1y3HfWwBPAJf0nl9M8B7V0="
DEV_FINGERPRINT_KEY = "secretbox-dev-fingerprint-key-not-for-production"


def _is_set(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in {"1", "true", "yes", "on"}


@dataclass(slots=True)
class Settings:
    database_url: str = os.getenv("DATABASE_URL", "sqlite:///./secretbox.db")
    ai_timeout_seconds: float = float(os.getenv("AI_TIMEOUT_SECONDS", "20"))
    server_host: str = os.getenv("SERVER_HOST", "0.0.0.0")
    server_port: int = int(os.getenv("SERVER_PORT", "8000"))
    encryption_key: str = os.getenv("ENCRYPTION_KEY", DEV_ENCRYPTION_KEY)
    fingerprint_key: str = os.getenv("FINGERPRINT_KEY", DEV_FINGERPRINT_KEY)
    # `SECRETBOX_DEV=1` opts into the built-in development keys and the
    # unauthenticated development surface. Without it the server refuses to
    # start on the development keys.
    allow_dev_defaults: bool = _is_set("SECRETBOX_DEV")
    # `SECRETBOX_RATE_LIMIT=0` disables the per-client request limits
    # (benchmarks and scenario suites fire bursts on purpose).
    rate_limit_enabled: bool = os.getenv("SECRETBOX_RATE_LIMIT", "1").strip().lower() not in {"0", "false", "no", "off"}
    # Comma-separated list of origins allowed to make cross-origin browser
    # requests. Empty (the default) means same-origin only: the dashboard is
    # served by this server and native clients do not use CORS.
    cors_origins: tuple[str, ...] = tuple(
        origin.strip()
        for origin in os.getenv("SECRETBOX_CORS_ORIGINS", "").split(",")
        if origin.strip()
    )


settings = Settings()
