import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from sitesense.api.v1.router import router as v1_router
from sitesense.core.config import get_settings
from sitesense.core.exceptions import DomainError
from sitesense.core.logging import configure_logging

configure_logging()
settings = get_settings()
app = FastAPI(title="SiteSense API", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[str(origin) for origin in settings.cors_origins],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(v1_router)


@app.exception_handler(DomainError)
async def domain_error_handler(_: Request, error: DomainError) -> JSONResponse:
    return JSONResponse(
        status_code=error.status_code,
        content={"error": {"code": error.code, "message": error.message}},
    )


@app.exception_handler(Exception)
async def unexpected_error_handler(_: Request, error: Exception) -> JSONResponse:
    logging.getLogger(__name__).exception("unhandled API error", exc_info=error)
    return JSONResponse(
        status_code=500,
        content={"error": {"code": "internal_error", "message": "Unexpected server error."}},
    )


@app.get("/healthz", tags=["health"])
async def healthz() -> dict[str, str]:
    return {"status": "ok"}
