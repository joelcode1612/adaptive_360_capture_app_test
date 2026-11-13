import enum
import uuid
from datetime import datetime

from sqlalchemy import DateTime, Enum, ForeignKey, Integer, JSON, String, UniqueConstraint, Uuid, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sitesense.db.base import Base


class CaptureStatus(str, enum.Enum):
    uploading = "uploading"
    stitch_pending = "stitch_pending"
    stitching = "stitching"
    stitched = "stitched"
    failed = "failed"


class VirtualTour(Base):
    __tablename__ = "virtual_tours"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    property_id: Mapped[uuid.UUID] = mapped_column(Uuid, index=True)
    owner_id: Mapped[uuid.UUID] = mapped_column(Uuid, index=True)
    expected_capture_count: Mapped[int] = mapped_column(Integer, default=30)
    status: Mapped[CaptureStatus] = mapped_column(
        Enum(CaptureStatus, name="capture_status"), default=CaptureStatus.uploading
    )
    stitch_manifest_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    captures: Mapped[list["VirtualTourCapture"]] = relationship(
        back_populates="tour", cascade="all, delete-orphan", order_by="VirtualTourCapture.target_index"
    )


class VirtualTourCapture(Base):
    __tablename__ = "virtual_tour_captures"
    __table_args__ = (UniqueConstraint("tour_id", "target_index", name="uq_tour_capture_target"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    tour_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("virtual_tours.id", ondelete="CASCADE"), index=True
    )
    target_index: Mapped[int] = mapped_column(Integer)
    storage_key: Mapped[str] = mapped_column(String(512), unique=True)
    sha256: Mapped[str] = mapped_column(String(64))
    content_type: Mapped[str] = mapped_column(String(64))
    byte_size: Mapped[int] = mapped_column(Integer)
    width: Mapped[int] = mapped_column(Integer)
    height: Mapped[int] = mapped_column(Integer)
    pose: Mapped[dict] = mapped_column(JSON().with_variant(JSON(), "sqlite"))
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    tour: Mapped[VirtualTour] = relationship(back_populates="captures")
