"""Authenticated SiteWise 38-target panorama upload bridge.

Unlike the legacy /virtual-tours capture-ingestion route, this receives the
*already stitched* panorama. The canonical record lives in Supabase PostgreSQL;
bytes live in the private Supabase Storage bucket. Client JWTs are verified by
Supabase Auth, and association is independently checked against a pre-authorized
fyp.capture_sessions row. The client cannot grant itself property access.

Configure SITESENSE_SUPABASE_URL, SITESENSE_SUPABASE_ANON_KEY and
SITESENSE_SUPABASE_SERVICE_ROLE_KEY on the server (never in the Flutter app).
Apply backend/sql/20261121_panorama_bridge.sql before using these endpoints.
"""

import io
import json
import re
from datetime import datetime, timezone
from uuid import UUID

import httpx
from fastapi import APIRouter, File, Form, Header, HTTPException, Query, UploadFile
from pydantic import BaseModel, Field
from PIL import Image, UnidentifiedImageError

from sitesense.core.config import get_settings

router = APIRouter(prefix="/panoramas", tags=["panoramas"])
_PATH = re.compile(r"^properties/(?P<property>\d+)/sessions/(?P<session>[A-Za-z0-9][A-Za-z0-9._-]*)/panorama\.jpg$")
_MAX_JPEG_BYTES = 35 * 1024 * 1024


class JobInput(BaseModel):
    id: str = Field(min_length=6, max_length=200)
    session_id: str = Field(min_length=1, max_length=150)
    user_id: UUID
    property_id: int = Field(gt=0)
    status: str = Field(pattern=r"^(queued|processing|done|error)$")
    frames: dict
    panorama_path: str | None = None
    error: str | None = None


def _settings():
    settings = get_settings()
    if not all((settings.supabase_url, settings.supabase_anon_key,
                settings.supabase_service_role_key)):
        raise HTTPException(503, "Backend Supabase integration is not configured")
    return settings


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Supabase access token required")
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(401, "Supabase access token required")
    return token


async def _identity(client: httpx.AsyncClient, token: str, settings) -> str:
    response = await client.get(
        f"{settings.supabase_url.rstrip('/')}/auth/v1/user",
        headers={"apikey": settings.supabase_anon_key,
                 "Authorization": f"Bearer {token}"},
    )
    if response.status_code != 200:
        raise HTTPException(401, "Invalid or expired Supabase access token")
    try:
        return str(UUID(response.json()["id"]))
    except (KeyError, ValueError, TypeError):
        raise HTTPException(401, "Invalid Supabase identity") from None


async def _authorize_session(client: httpx.AsyncClient, *, token: str,
                             user_id: str, session_id: str,
                             property_id: int, settings) -> None:
    """Use user's RLS-scoped read, then check owner and property explicitly."""
    response = await client.get(
        f"{settings.supabase_url.rstrip('/')}/rest/v1/capture_sessions",
        params={"select": "session_id,owner_id,property_id,revoked_at",
                "session_id": f"eq.{session_id}",
                "property_id": f"eq.{property_id}", "limit": "1"},
        headers={"apikey": settings.supabase_anon_key,
                 "Authorization": f"Bearer {token}",
                 "Accept-Profile": "fyp"},
    )
    if response.status_code != 200:
        raise HTTPException(503, "Capture session authorization is unavailable")
    rows = response.json()
    if not isinstance(rows, list) or len(rows) != 1:
        raise HTTPException(403, "This capture session is not authorized for the property")
    if str(rows[0].get("owner_id")) != user_id:
        raise HTTPException(403, "Capture session owner mismatch")
    if rows[0].get("revoked_at") is not None:
        raise HTTPException(403, "Capture session authorization was revoked")


def _service_headers(settings, *, write: bool = False) -> dict[str, str]:
    h = {"apikey": settings.supabase_service_role_key,
         "Authorization": f"Bearer {settings.supabase_service_role_key}",
         "Content-Profile" if write else "Accept-Profile": "fyp"}
    if write:
        h["Prefer"] = "resolution=merge-duplicates,return=representation"
    return h


def _parse_path(path: str):
    match = _PATH.fullmatch(path)
    if not match:
        raise HTTPException(422, "Invalid panorama Storage path")
    return int(match.group("property")), match.group("session")


async def _job(client, *, job_id: str, settings):
    response = await client.get(
        f"{settings.supabase_url.rstrip('/')}/rest/v1/panorama_jobs",
        params={"select": "id,session_id,property_id,owner,status", "id": f"eq.{job_id}"},
        headers=_service_headers(settings),
    )
    if response.status_code != 200:
        raise HTTPException(502, "Cannot read panorama job metadata")
    rows = response.json()
    return rows[0] if rows else None


@router.post("/jobs")
async def upsert_panorama_job(body: JobInput, authorization: str | None = Header(default=None)):
    settings = _settings()
    token = _bearer(authorization)
    expected_id = f"pano_{re.sub(r'[^A-Za-z0-9._-]', '_', body.session_id)}"
    if body.id != expected_id:
        raise HTTPException(422, "Invalid job ID")
    expected_path = f"properties/{body.property_id}/sessions/{re.sub(r'[^A-Za-z0-9._-]', '_', body.session_id)}/panorama.jpg"
    if body.panorama_path is not None and body.panorama_path != expected_path:
        raise HTTPException(422, "Panorama path does not match session")
    targets = body.frames.get("targets")
    if not isinstance(targets, list) or len(targets) > 38:
        raise HTTPException(422, "Invalid target manifest")
    async with httpx.AsyncClient(timeout=30) as client:
        user_id = await _identity(client, token, settings)
        if str(body.user_id) != user_id:
            raise HTTPException(403, "Cannot write another user's job")
        await _authorize_session(client, token=token, user_id=user_id,
                                 session_id=body.session_id,
                                 property_id=body.property_id, settings=settings)
        existing = await _job(client, job_id=body.id, settings=settings)
        if existing and (existing["session_id"] != body.session_id or
                         existing["property_id"] != body.property_id or
                         existing["owner"] != user_id):
            raise HTTPException(409, "Job already belongs to another capture")
        if existing and existing["status"] == "done" and body.status != "done":
            raise HTTPException(409, "Cannot reopen a completed panorama job")
        if body.status == "done":
            if body.panorama_path != expected_path:
                raise HTTPException(422, "Completed job must specify panorama path")
            check = await client.head(
                f"{settings.supabase_url.rstrip('/')}/storage/v1/object/{settings.panorama_bucket}/{expected_path}",
                headers=_service_headers(settings),
            )
            if check.status_code != 200:
                raise HTTPException(409, "Cannot mark done before Storage confirms panorama")
        payload = {"id": body.id, "session_id": body.session_id,
                   "owner": user_id, "property_id": body.property_id,
                   "status": body.status, "frames": body.frames,
                   "panorama_path": body.panorama_path, "error": body.error,
                   "updated_at": datetime.now(timezone.utc).isoformat()}
        write = await client.post(
            f"{settings.supabase_url.rstrip('/')}/rest/v1/panorama_jobs",
            params={"on_conflict": "id"}, json=payload,
            headers=_service_headers(settings, write=True),
        )
        if write.status_code not in (200, 201):
            raise HTTPException(502, "Cannot update panorama job")
    return {"id": body.id, "status": body.status}


@router.post("/upload")
async def upload_panorama(object_path: str = Form(...), image: UploadFile = File(...),
                          authorization: str | None = Header(default=None)):
    settings = _settings()
    token = _bearer(authorization)
    property_id, session_id = _parse_path(object_path)
    data = await image.read(_MAX_JPEG_BYTES + 1)
    if len(data) == 0 or len(data) > _MAX_JPEG_BYTES:
        raise HTTPException(413, "Image is empty or too large")
    if image.content_type != "image/jpeg":
        raise HTTPException(415, "Expected JPEG image")
    try:
        with Image.open(io.BytesIO(data)) as img:
            img.verify()
    except (UnidentifiedImageError, OSError) as exc:
        raise HTTPException(422, "Invalid JPEG image") from exc
    async with httpx.AsyncClient(timeout=120) as client:
        user_id = await _identity(client, token, settings)
        await _authorize_session(client, token=token, user_id=user_id,
                                 session_id=session_id,
                                 property_id=property_id, settings=settings)
        existing = await _job(client, job_id=f"pano_{session_id}", settings=settings)
        if not existing or existing["owner"] != user_id or existing["status"] not in ("queued", "processing", "error", "done"):
            raise HTTPException(409, "Create an authorized panorama job before upload")
        result = await client.post(
            f"{settings.supabase_url.rstrip('/')}/storage/v1/object/{settings.panorama_bucket}/{object_path}",
            content=data, headers={**_service_headers(settings),
                                   "Content-Type": "image/jpeg", "x-upsert": "true"},
        )
        if result.status_code not in (200, 201):
            raise HTTPException(502, "Supabase Storage rejected panorama")
    return {"object_path": object_path, "stored": True}


@router.get("/signed-url")
async def signed_panorama_url(object_path: str,
                              ttl_seconds: int = Query(default=600, ge=30, le=3600),
                              authorization: str | None = Header(default=None)):
    settings = _settings()
    token = _bearer(authorization)
    property_id, session_id = _parse_path(object_path)
    async with httpx.AsyncClient(timeout=30) as client:
        user_id = await _identity(client, token, settings)
        await _authorize_session(client, token=token, user_id=user_id,
                                 session_id=session_id,
                                 property_id=property_id, settings=settings)
        job = await _job(client, job_id=f"pano_{session_id}", settings=settings)
        if not job or job["status"] != "done":
            raise HTTPException(404, "Panorama is not yet available")
        result = await client.post(
            f"{settings.supabase_url.rstrip('/')}/storage/v1/object/sign/{settings.panorama_bucket}/{object_path}",
            json={"expiresIn": ttl_seconds}, headers=_service_headers(settings),
        )
        if result.status_code != 200:
            raise HTTPException(502, "Cannot create panorama signed URL")
        signed_path = result.json().get("signedURL") or result.json().get("signedUrl")
        if not isinstance(signed_path, str):
            raise HTTPException(502, "Storage returned no signed URL")
        if signed_path.startswith("http"):
            url = signed_path
        elif signed_path.startswith("/storage/v1"):
            url = f"{settings.supabase_url.rstrip('/')}{signed_path}"
        else:
            url = f"{settings.supabase_url.rstrip('/')}/storage/v1{signed_path if signed_path.startswith('/') else '/' + signed_path}"
    return {"signed_url": url}
