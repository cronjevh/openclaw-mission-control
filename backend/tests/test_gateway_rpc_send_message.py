from __future__ import annotations

from uuid import UUID

import pytest

import app.services.openclaw.gateway_rpc as gateway_rpc
from app.services.openclaw.gateway_rpc import GatewayConfig


@pytest.mark.asyncio
async def test_send_message_dispatches_when_auto_wake_kill_switch_is_off(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, object] = {}

    async def _fake_openclaw_call(
        method: str,
        params: dict[str, object] | None = None,
        *,
        config: GatewayConfig,
    ) -> object:
        captured["method"] = method
        captured["params"] = params
        captured["config"] = config
        return {"ok": True}

    monkeypatch.setattr(gateway_rpc, "openclaw_call", _fake_openclaw_call)

    result = await gateway_rpc.send_message(
        "Escalation payload",
        session_key="agent:gateway-main:test",
        config=GatewayConfig(url="ws://gateway.example/ws"),
        deliver=True,
    )

    assert result == {"ok": True}
    assert captured["method"] == "chat.send"
    assert captured["config"] == GatewayConfig(url="ws://gateway.example/ws")
    params = captured["params"]
    assert isinstance(params, dict)
    assert params["sessionKey"] == "agent:gateway-main:test"
    assert params["message"] == "Escalation payload"
    assert params["deliver"] is True
    assert UUID(str(params["idempotencyKey"]))
