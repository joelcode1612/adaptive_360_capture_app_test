import json
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, UploadFile, status
from pydantic import BaseModel, Field, ValidationError

from sitesense.dependencies import CurrentUser, get_capture_service, get_current_user
from sitesense.domain.entities import CaptureMetadata
from sitesense.services.virtual_tour_service import VirtualTourService

router = APIRouter(prefix="/virtual-tours", tags=["virtual-tours"])


class CreateVirtualTourRequest(BaseModel):
    property_id: uuid.UUID
    expected_capture_count: int = Field(default=30, ge=1, le=500)


class CapturePose(BaseModel):
    position_x: float | None = None
    position_y: float | None = None
    position_z: float | None = None
    quaternion_x: float | None = None
    quaternion_y: float | None = None
    quaternion_z: float | None = None
    quaternion_w: float | None = None
    alignment_error_deg: float | None = Field(default=None, ge=0, le=180)
    station_drift_m: float | None = Field(default=None, ge=0)


class CaptureResponse(BaseModel):
    target_index: int
    storage_key: str
    sha256: str
    width: int
    height: int
    duplicate: bool


class TourResponse(BaseModel):
    id: uuid.UUID
    property_id: uuid.UUID
    status: str
    expected_capture_count: int
    uploaded_capture_count: int
    stitch_manifest_key: str | None


def _tour_response(tour) -> TourResponse:
    return TourResponse(
        id=tour.id,
        property_id=tour.property_id,
        status=tour.status.value,
        expected_capture_count=tour.expected_capture_count,
        uploaded_capture_count=len(tour.captures),
        stitch_manifest_key=tour.stitch_manifest_key,
    )


@router.post("", response_model=TourResponse, status_code=status.HTTP_201_CREATED)
async def create_virtual_tour(
    body: CreateVirtualTourRequest,
    user: CurrentUser = Depends(get_current_user),
    service: VirtualTourService = Depends(get_capture_service),
) -> TourResponse:
    tour = await service.create_upload_session(
        property_id=body.property_id,
        owner_id=user.id,
        expected_capture_count=body.expected_capture_count,
    )
    return _tour_response(tour)


@router.post("/{tour_id}/captures", response_model=CaptureResponse)
async def upload_capture(
    tour_id: uuid.UUID,
    target_index: int = Form(..., ge=1),
    captured_at: datetime = Form(...),
    pose_json: str = Form(...),
    image: UploadFile = File(...),
    idempotency_key: str | None = Header(default=None),
    user: CurrentUser = Depends(get_current_user),
    service: VirtualTourService = Depends(get_capture_service),
) -> CaptureResponse:
    # The target index itself is the durable idempotency key. The optional
    # header is accepted for client tracing and future request-level storage.
    del idempotency_key
    try:
        pose = CapturePose.model_validate(json.loads(pose_json))
    except (json.JSONDecodeError, ValidationError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="pose_json must be a valid CapturePose JSON object.",
        ) from error
    content = await image.read()
    capture, duplicate = await service.upload_capture(
        tour_id=tour_id,
        owner_id=user.id,
        metadata=CaptureMetadata(
            target_index=target_index,
            captured_at=captured_at,
            pose=pose.model_dump(mode="json", exclude_none=True),
        ),
        image=content,
        content_type=image.content_type or "",
    )
    return CaptureResponse(
        target_index=capture.target_index,
        storage_key=capture.storage_key,
        sha256=capture.sha256,
        width=capture.width,
        height=capture.height,
        duplicate=duplicate,
    )


@router.post("/{tour_id}/finalise", response_model=TourResponse)
async def finalise_virtual_tour(
    tour_id: uuid.UUID,
    user: CurrentUser = Depends(get_current_user),
    service: VirtualTourService = Depends(get_capture_service),
) -> TourResponse:
    return _tour_response(
        await service.finalise_for_stitching(tour_id=tour_id, owner_id=user.id)
    )


@router.get("/{tour_id}", response_model=TourResponse)
async def get_virtual_tour(
    tour_id: uuid.UUID,
    user: CurrentUser = Depends(get_current_user),
    service: VirtualTourService = Depends(get_capture_service),
) -> TourResponse:
    return _tour_response(await service.get_tour(tour_id=tour_id, owner_id=user.id))
