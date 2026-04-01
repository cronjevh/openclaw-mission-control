"""Token generation and verification helpers for agent authentication."""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
from uuid import UUID

from app.core.config import settings

ITERATIONS = 200_000
SALT_BYTES = 16


def generate_agent_token() -> str:
    """Generate a new URL-safe random token for an agent."""
    return secrets.token_urlsafe(32)


def _agent_token_signing_secret() -> str:
    # Keep this simple for single-node/home deployments: derive stable agent tokens
    # from an existing local server secret rather than introducing another key.
    secret = settings.local_auth_token.strip() or settings.clerk_secret_key.strip()
    if secret:
        return secret
    raise RuntimeError("Agent token signing secret is not configured")


def _b64encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("utf-8").rstrip("=")


def _b64decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def generate_stable_agent_token(agent_id: UUID | str) -> str:
    """Derive a stable per-agent token from local server config.

    This removes drift caused by random re-minting across reprovision/update flows.
    The token remains opaque to callers but is reproducible by Mission Control.
    """

    message = f"mission-control-agent-token:v1:{agent_id}".encode("utf-8")
    digest = hmac.new(
        _agent_token_signing_secret().encode("utf-8"),
        message,
        hashlib.sha256,
    ).digest()
    return f"mca_{_b64encode(digest)}"


def hash_agent_token(token: str) -> str:
    """Hash an agent token using PBKDF2-HMAC-SHA256 with a random salt."""
    salt = secrets.token_bytes(SALT_BYTES)
    digest = hashlib.pbkdf2_hmac("sha256", token.encode("utf-8"), salt, ITERATIONS)
    return f"pbkdf2_sha256${ITERATIONS}${_b64encode(salt)}${_b64encode(digest)}"


def verify_agent_token(token: str, stored_hash: str) -> bool:
    """Verify a plaintext token against a stored PBKDF2 hash representation."""
    try:
        algorithm, iterations, salt_b64, digest_b64 = stored_hash.split("$")
    except ValueError:
        return False
    if algorithm != "pbkdf2_sha256":
        return False
    try:
        iterations_int = int(iterations)
    except ValueError:
        return False
    salt = _b64decode(salt_b64)
    expected_digest = _b64decode(digest_b64)
    candidate = hashlib.pbkdf2_hmac(
        "sha256",
        token.encode("utf-8"),
        salt,
        iterations_int,
    )
    return hmac.compare_digest(candidate, expected_digest)
