import hashlib
import os
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4


@dataclass(frozen=True, slots=True)
class StoredObject:
    key: str
    sha256: str
    byte_size: int


class LocalCaptureStorage:
    """Development storage with atomic writes and deterministic object keys."""

    def __init__(self, root: Path) -> None:
        self._root = root.resolve()

    async def put_capture(
        self, *, tour_id: UUID, target_index: int, content: bytes, extension: str
    ) -> StoredObject:
        digest = hashlib.sha256(content).hexdigest()
        key = f"tours/{tour_id}/captures/{target_index:03d}-{digest[:16]}.{extension}"
        destination = (self._root / key).resolve()
        if self._root not in destination.parents:
            raise ValueError("capture storage key escaped configured root")
        self._atomic_write(destination, content)
        return StoredObject(key=key, sha256=digest, byte_size=len(content))

    async def put_manifest(self, *, tour_id: UUID, content: bytes) -> str:
        digest = hashlib.sha256(content).hexdigest()
        key = f"tours/{tour_id}/stitch-manifest-{digest[:16]}.json"
        destination = (self._root / key).resolve()
        if self._root not in destination.parents:
            raise ValueError("manifest storage key escaped configured root")
        self._atomic_write(destination, content)
        return key

    @staticmethod
    def _atomic_write(destination: Path, content: bytes) -> None:
        """Make an upload visible only after its complete contents reach disk."""
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(f"{destination.suffix}.{uuid4().hex}.uploading")
        try:
            with temporary.open("xb") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(destination)
        finally:
            # A failed write must not leave a partial image for a later stitcher.
            if temporary.exists():
                temporary.unlink()
