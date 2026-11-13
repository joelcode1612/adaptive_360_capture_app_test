from functools import lru_cache
from pathlib import Path

from pydantic import AnyHttpUrl, Field
# Pydantic v2 moved BaseSettings out of `pydantic` into `pydantic-settings`.
# Importing it from `pydantic` raises PydanticImportError at import time, which
# takes the whole app down before a single route is registered.
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """The only configuration source for application code."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="SITESENSE_",
        extra="ignore",
    )

    database_url: str = "sqlite+aiosqlite:///./var/sitesense.db"
    capture_storage_root: Path = Path("./var/captures")
    max_capture_bytes: int = Field(default=25 * 1024 * 1024, gt=0)
    max_capture_count: int = Field(default=30, ge=1, le=500)
    cors_origins: list[AnyHttpUrl] = []
    allow_development_identity: bool = False


@lru_cache
def get_settings() -> Settings:
    return Settings()
