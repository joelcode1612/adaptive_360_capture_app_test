"""Pure panorama-bridge contract checks, requiring no live Supabase project."""
import pytest
from fastapi import HTTPException

from sitesense.api.v1.panorama_sync import _parse_path, _bearer


def test_path_has_canonical_property_and_session():
    assert _parse_path('properties/17/sessions/sphere-123/panorama.jpg') == (17, 'sphere-123')


@pytest.mark.parametrize('path', [
    '../secret.jpg',
    'properties/1/sessions/../../secret.jpg',
    'properties/abc/sessions/sphere-1/panorama.jpg',
    'properties/1/sessions/sphere-1/frames.jpg',
])
def test_path_traversal_and_noncanonical_paths_rejected(path):
    with pytest.raises(HTTPException) as error:
        _parse_path(path)
    assert error.value.status_code == 422


def test_token_required():
    with pytest.raises(HTTPException) as error:
        _bearer(None)
    assert error.value.status_code == 401
    assert _bearer('Bearer sample') == 'sample'
