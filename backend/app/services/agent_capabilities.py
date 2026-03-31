"""Helpers for normalizing and enforcing managed agent capability policies."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any


def _normalize_string_list(raw: object, *, uppercase: bool = False) -> list[str]:
    values: list[str] = []
    if raw is None:
        return values
    items: Iterable[object]
    if isinstance(raw, str):
        items = raw.splitlines()
    elif isinstance(raw, Iterable):
        items = raw
    else:
        items = [raw]

    seen: set[str] = set()
    for item in items:
        text = str(item).strip()
        if not text:
            continue
        if "," in text and "\n" not in text:
            parts = [part.strip() for part in text.split(",")]
        else:
            parts = [text]
        for part in parts:
            if not part:
                continue
            normalized = part.upper() if uppercase else part
            if normalized in seen:
                continue
            seen.add(normalized)
            values.append(normalized)
    return values


def resolve_agent_capabilities(identity_profile: object | None) -> dict[str, Any]:
    """Return a normalized capability policy from an identity profile."""
    if not isinstance(identity_profile, Mapping):
        return {}
    raw = identity_profile.get("capabilities")
    if not isinstance(raw, Mapping):
        return {}

    policy_name = str(raw.get("policy_name") or "").strip()
    notes = str(raw.get("notes") or "").strip()
    capabilities: dict[str, Any] = {
        "policy_name": policy_name,
        "secret_keys": _normalize_string_list(raw.get("secret_keys"), uppercase=True),
        "required_secret_keys": _normalize_string_list(
            raw.get("required_secret_keys"),
            uppercase=True,
        ),
        "skills": _normalize_string_list(raw.get("skills")),
        "file_access": _normalize_string_list(raw.get("file_access")),
        "notes": notes,
    }
    if not any(value for value in capabilities.values()):
        return {}
    return capabilities


def apply_capabilities_to_identity_profile(
    identity_profile: Mapping[str, Any] | None,
    capabilities: Mapping[str, Any],
) -> dict[str, Any] | None:
    """Merge normalized capabilities into an identity profile."""
    resolved = dict(identity_profile or {})
    normalized = resolve_agent_capabilities({"capabilities": dict(capabilities)})
    if normalized:
        resolved["capabilities"] = normalized
    else:
        resolved.pop("capabilities", None)
    return resolved or None


def filter_secret_keys_for_capabilities(
    secrets: list[dict[str, str]],
    capabilities: Mapping[str, Any] | None,
) -> list[dict[str, str]]:
    """Filter board secret metadata/payloads to the agent's allowed subset."""
    allowed = capabilities.get("secret_keys") if isinstance(capabilities, Mapping) else None
    if not isinstance(allowed, list) or not allowed:
        return secrets
    allowed_set = {str(item).upper() for item in allowed if str(item).strip()}
    return [secret for secret in secrets if secret.get("key", "").upper() in allowed_set]
