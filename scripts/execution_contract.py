"""Shared validation primitives for RPM execution-marker contracts."""

from __future__ import annotations

import hashlib
import re
from datetime import datetime


IDEMPOTENCY_KEY = re.compile(r"sha256:[0-9a-f]{64}\Z")
SHA256_KEY = IDEMPOTENCY_KEY
RUN_FIELDS = ("run_id", "event_id", "idempotency_key", "status")
RFC3339_TIMESTAMP = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)


def parse_rfc3339(value: object, field: str = "lease.expires_at") -> datetime:
    if not isinstance(value, str) or not RFC3339_TIMESTAMP.fullmatch(value):
        raise ValueError(f"{field} must be an RFC3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00", 1))
    except ValueError as error:
        raise ValueError(f"{field} must be an RFC3339 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must be an RFC3339 timestamp")
    return parsed


def validate_run_record(value: object, context: str = "run") -> dict[str, object]:
    if not isinstance(value, dict) or any(
        not isinstance(value.get(field), str) or not value[field].strip()
        for field in RUN_FIELDS
    ):
        raise ValueError(f"{context} has invalid fields")
    if not IDEMPOTENCY_KEY.fullmatch(value["idempotency_key"]):
        raise ValueError(f"{context} has an invalid idempotency key")
    return value


def compute_idempotency_key(
    repository: str,
    issue_number: int,
    plan_revision: str,
    scope_hash: str,
    event_id: str,
) -> str:
    values = (repository, str(issue_number), plan_revision, scope_hash, event_id)
    canonical = "\0".join(values).encode("utf-8")
    return f"sha256:{hashlib.sha256(canonical).hexdigest()}"
