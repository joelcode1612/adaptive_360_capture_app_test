from dataclasses import dataclass
from datetime import datetime
from uuid import UUID


@dataclass(frozen=True, slots=True)
class CaptureMetadata:
    target_index: int
    captured_at: datetime
    pose: dict[str, float | int | str | bool | None]


@dataclass(frozen=True, slots=True)
class StitchedInput:
    target_index: int
    storage_key: str
    sha256: str
    pose: dict[str, float | int | str | bool | None]


@dataclass(frozen=True, slots=True)
class StitchManifest:
    tour_id: UUID
    property_id: UUID
    captures: tuple[StitchedInput, ...]
