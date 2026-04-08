from __future__ import annotations

from typing import Any, cast
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlmodel import SQLModel, col, select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api import board_memory
from app.models.board_memory import BoardMemory
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.organizations import Organization


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


async def _make_session(engine: AsyncEngine) -> AsyncSession:
    return AsyncSession(engine, expire_on_commit=False)


@pytest.mark.asyncio
async def test_board_chat_fallback_skips_no_reply_and_mirrors_actual_reply() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            org_id = uuid4()
            gateway_id = uuid4()
            board_id = uuid4()

            session.add(Organization(id=org_id, name="org"))
            session.add(
                Gateway(
                    id=gateway_id,
                    organization_id=org_id,
                    name="gateway",
                    url="https://gateway.local",
                    workspace_root="/tmp/workspace",
                ),
            )
            session.add(
                Board(
                    id=board_id,
                    organization_id=org_id,
                    name="Mission Control Management",
                    slug="mission-control-management",
                    gateway_id=gateway_id,
                ),
            )
            # Existing NO_REPLY in recent board chat should not block real reply mirroring.
            session.add(
                BoardMemory(
                    board_id=board_id,
                    content="NO_REPLY",
                    tags=["chat"],
                    is_chat=True,
                    source="Atlas",
                )
            )
            await session.commit()

            local_session_maker = async_sessionmaker(
                engine,
                expire_on_commit=False,
                class_=AsyncSession,
            )

            expected_message = (
                "BOARD CHAT\n"
                "Board: Mission Control Management\n"
                "From: Cronje van Heerden\n\n"
                "Why is inbox task unassigned?\n\n"
                "Reply in plain natural language as a concise board-chat message.\n"
                "Do not output shell commands, curl snippets, JSON payloads, or code blocks.\n"
                "If asked a simple question, answer it directly in one short sentence.\n"
                "Do not promise future actions or outcomes unless they are already completed and verified.\n"
                "If something is blocked, state the concrete blocker instead of making a promise."
            )

            async def fake_openclaw_call(
                method: str,
                params: dict[str, Any],
                *,
                config: object,
            ) -> dict[str, Any]:
                assert method == "chat.history"
                assert params["sessionKey"] == "agent:lead:main"
                return {
                    "messages": [
                        {
                            "role": "user",
                            "content": [{"type": "text", "text": expected_message}],
                            "__openclaw": {"seq": 11},
                        },
                        {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "text",
                                    "text": (
                                        "[[reply_to_current]] "
                                        "It is unassigned because no owner has been set yet."
                                    ),
                                }
                            ],
                            "__openclaw": {"seq": 12},
                        },
                        {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "NO_REPLY"}],
                            "__openclaw": {"seq": 13},
                        },
                    ]
                }

            monkeypatch = pytest.MonkeyPatch()
            monkeypatch.setattr(board_memory, "async_session_maker", local_session_maker)
            monkeypatch.setattr(board_memory, "openclaw_call", fake_openclaw_call)
            try:
                await board_memory._mirror_session_reply_to_board_chat(
                    board_id=board_id,
                    agent_name="Atlas",
                    session_key="agent:lead:main",
                    config=cast(Any, object()),
                    after_seq=10,
                    expected_message=expected_message,
                )
            finally:
                monkeypatch.undo()

            rows = list(
                await session.exec(
                    select(BoardMemory)
                    .where(col(BoardMemory.board_id) == board_id)
                    .where(col(BoardMemory.is_chat).is_(True))
                    .where(col(BoardMemory.source) == "Atlas")
                    .order_by(col(BoardMemory.created_at))
                )
            )
            assert [row.content for row in rows] == [
                "NO_REPLY",
                "It is unassigned because no owner has been set yet.",
            ]
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_board_chat_fallback_skips_unverified_promise_reply() -> None:
    engine = await _make_engine()
    try:
        async with await _make_session(engine) as session:
            org_id = uuid4()
            gateway_id = uuid4()
            board_id = uuid4()

            session.add(Organization(id=org_id, name="org"))
            session.add(
                Gateway(
                    id=gateway_id,
                    organization_id=org_id,
                    name="gateway",
                    url="https://gateway.local",
                    workspace_root="/tmp/workspace",
                ),
            )
            session.add(
                Board(
                    id=board_id,
                    organization_id=org_id,
                    name="Mission Control Management",
                    slug="mission-control-management",
                    gateway_id=gateway_id,
                ),
            )
            await session.commit()

            local_session_maker = async_sessionmaker(
                engine,
                expire_on_commit=False,
                class_=AsyncSession,
            )

            expected_message = (
                "BOARD CHAT\n"
                "Board: Mission Control Management\n"
                "From: Cronje van Heerden\n\n"
                "Why is inbox task unassigned?\n\n"
                "Reply in plain natural language as a concise board-chat message.\n"
                "Do not output shell commands, curl snippets, JSON payloads, or code blocks.\n"
                "If asked a simple question, answer it directly in one short sentence.\n"
                "Do not promise future actions or outcomes unless they are already completed and verified.\n"
                "If something is blocked, state the concrete blocker instead of making a promise."
            )

            async def fake_openclaw_call(
                method: str,
                params: dict[str, Any],
                *,
                config: object,
            ) -> dict[str, Any]:
                assert method == "chat.history"
                assert params["sessionKey"] == "agent:lead:main"
                return {
                    "messages": [
                        {
                            "role": "user",
                            "content": [{"type": "text", "text": expected_message}],
                            "__openclaw": {"seq": 21},
                        },
                        {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "[[reply_to_current]] I'll assign it now."}],
                            "__openclaw": {"seq": 22},
                        },
                        {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "text",
                                    "text": "[[reply_to_current]] It's unassigned because nobody has set an owner yet.",
                                }
                            ],
                            "__openclaw": {"seq": 23},
                        },
                    ]
                }

            monkeypatch = pytest.MonkeyPatch()
            monkeypatch.setattr(board_memory, "async_session_maker", local_session_maker)
            monkeypatch.setattr(board_memory, "openclaw_call", fake_openclaw_call)
            try:
                await board_memory._mirror_session_reply_to_board_chat(
                    board_id=board_id,
                    agent_name="Atlas",
                    session_key="agent:lead:main",
                    config=cast(Any, object()),
                    after_seq=20,
                    expected_message=expected_message,
                )
            finally:
                monkeypatch.undo()

            rows = list(
                await session.exec(
                    select(BoardMemory)
                    .where(col(BoardMemory.board_id) == board_id)
                    .where(col(BoardMemory.is_chat).is_(True))
                    .where(col(BoardMemory.source) == "Atlas")
                    .order_by(col(BoardMemory.created_at))
                )
            )
            assert [row.content for row in rows] == [
                "It's unassigned because nobody has set an owner yet.",
            ]
    finally:
        await engine.dispose()
