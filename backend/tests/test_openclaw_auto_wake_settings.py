"""Settings tests for the temporary automatic wake/reprovision kill switch."""

from app.core.auth_mode import AuthMode
from app.core.config import Settings


def test_auto_wake_reprovision_kill_switch_defaults_off() -> None:
    settings = Settings(
        auth_mode=AuthMode.LOCAL,
        local_auth_token="x" * 50,
        base_url="http://localhost:8002",
    )

    assert settings.openclaw_automatic_wake_reprovision_enabled is False
