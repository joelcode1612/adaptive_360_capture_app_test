from fastapi import APIRouter

from sitesense.api.v1.virtual_tours import router as virtual_tours_router

router = APIRouter(prefix="/api/v1")
router.include_router(virtual_tours_router)
