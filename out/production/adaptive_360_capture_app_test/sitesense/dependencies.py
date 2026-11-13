import uuid
from dataclasses import dataclass

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from sitesense.core.config import Settings, get_settings
from sitesense.db.session import get_db_session
from sitesense.repositories.virtual_tour_repository import VirtualTourRepository
from sitesense.services.capture_storage import LocalCaptureStorage
from sitesense.services.virtual_tour_service import VirtualTourService


@dataclass(frozen=True, slots=True)
class CurrentUser:
    id: uuid.UUID


def get_capture_service(
    session: AsyncSession = Depends(get_db_session),
    settings: Settings = Depends(get_settings),
) -> VirtualTourService:
    return VirtualTourService(
        VirtualTourRepository(session),
        LocalCaptureStorage(settings.capture_storage_root),
        max_capture_bytes=settings.max_capture_bytes,
        max_capture_count=settings.max_capture_count,
    )


async def get_current_user(
    x_user_id: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> CurrentUser:
    """Development boundary; production must replace this with verified JWT auth."""
    if not settings.allow_development_identity:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="No production authentication provider is configured.",
        )
    try:
        return CurrentUser(id=uuid.UUID(x_user_id or ""))
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="X-User-Id must be a UUID in development mode.",
        ) from error
