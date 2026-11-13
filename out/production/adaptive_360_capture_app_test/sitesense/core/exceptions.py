from dataclasses import dataclass


@dataclass(slots=True)
class DomainError(Exception):
    code: str
    message: str
    status_code: int = 400


class NotFoundError(DomainError):
    def __init__(self, message: str) -> None:
        super().__init__("not_found", message, 404)


class ConflictError(DomainError):
    def __init__(self, message: str) -> None:
        super().__init__("conflict", message, 409)


class ForbiddenError(DomainError):
    def __init__(self, message: str) -> None:
        super().__init__("forbidden", message, 403)
