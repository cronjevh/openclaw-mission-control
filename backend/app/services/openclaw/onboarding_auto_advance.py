"""Self-contained onboarding auto-advancer.

When a user posts an answer the backend calls ``auto_advance`` which
immediately posts the next question (or the completion payload) using
the gateway-agent token — no live gateway-agent session required.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

from sqlmodel.ext.asyncio.session import AsyncSession

from app.models.board_onboarding import BoardOnboardingSession
from app.models.boards import Board

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Question definitions — order matters
# ---------------------------------------------------------------------------

_QUESTIONS: list[dict[str, Any]] = [
    {
        "key": "autonomy",
        "question": "How autonomous should the lead agent be?",
        "options": [
            {"id": "1", "label": "Ask first — confirm with me before taking action"},
            {"id": "2", "label": "Balanced — act independently, flag blockers"},
            {"id": "3", "label": "Autonomous — run fully on its own, update me on results"},
        ],
    },
    {
        "key": "report_format",
        "question": "How should the lead agent deliver findings and reports?",
        "options": [
            {"id": "1", "label": "Bullet-point summaries — quick, scannable"},
            {"id": "2", "label": "Narrative paragraphs — context and interpretation included"},
            {"id": "3", "label": "Mixed — bullets for data, prose for insights"},
        ],
    },
    {
        "key": "cadence",
        "question": "How often should the lead agent send you updates?",
        "options": [
            {"id": "1", "label": "As soon as something notable happens"},
            {"id": "2", "label": "Hourly digest"},
            {"id": "3", "label": "Daily summary"},
            {"id": "4", "label": "Weekly report"},
        ],
    },
    {
        "key": "agent_name",
        "question": "Choose a first-name for the lead agent (type your own or pick one).",
        "options": [
            {"id": "1", "label": "Rex"},
            {"id": "2", "label": "Nova"},
            {"id": "3", "label": "Iris"},
            {"id": "4", "label": "Atlas"},
            {"id": "5", "label": "Other (I'll type it)"},
        ],
    },
    {
        "key": "extra",
        "question": "Anything else the lead agent should know? (constraints, tools, priorities)",
        "options": [
            {"id": "1", "label": "No, that's everything"},
            {"id": "2", "label": "Yes (I'll type it)"},
        ],
    },
]

# ---------------------------------------------------------------------------
# Value mappers
# ---------------------------------------------------------------------------

_AUTONOMY_MAP = {
    "ask first": "ask_first",
    "balanced": "balanced",
    "autonomous": "autonomous",
}
_CADENCE_MAP = {
    "as soon as": "asap",
    "hourly": "hourly",
    "daily": "daily",
    "weekly": "weekly",
}
_FORMAT_MAP = {
    "bullet": "bullets",
    "narrative": "narrative",
    "mixed": "mixed",
    "raw": "bullets",
}


def _map(text: str, mapping: dict[str, str], default: str) -> str:
    tl = text.lower()
    for k, v in mapping.items():
        if k in tl:
            return v
    return default


def _extract_agent_name(answer: str) -> str:
    """Return the agent name from the answer text."""
    built_in = {"Rex", "Nova", "Iris", "Atlas"}
    for name in built_in:
        if name.lower() in answer.lower():
            return name
    # strip "Other (I'll type it):" prefix if present
    clean = answer.split(":", 1)[-1].strip()
    if clean:
        return clean.split()[0].capitalize()
    return "Rex"


def _build_completion(answers: list[str], board_name: str) -> dict[str, Any]:
    """Construct the BoardOnboardingAgentComplete payload from collected answers."""
    autonomy_ans = answers[0] if len(answers) > 0 else ""
    format_ans = answers[1] if len(answers) > 1 else ""
    cadence_ans = answers[2] if len(answers) > 2 else ""
    name_ans = answers[3] if len(answers) > 3 else "Rex"
    extra_ans = answers[4] if len(answers) > 4 else ""

    agent_name = _extract_agent_name(name_ans)
    autonomy = _map(autonomy_ans, _AUTONOMY_MAP, "balanced")
    cadence = _map(cadence_ans, _CADENCE_MAP, "daily")
    output_fmt = _map(format_ans, _FORMAT_MAP, "mixed")
    verbosity = "balanced"

    objective = f"{board_name}: Managed by lead agent per board description."
    metric = "Board tasks completed on time with quality"
    target = "Consistent execution and clear reporting"

    custom_instructions = extra_ans if extra_ans and "no" not in extra_ans.lower() else ""

    return {
        "status": "complete",
        "board_type": "general",
        "objective": objective,
        "success_metrics": {"metric": metric, "target": target},
        "user_profile": {
            "pronouns": None,
            "timezone": "Asia/Dhaka",
            "notes": None,
            "context": None,
        },
        "lead_agent": {
            "name": agent_name,
            "identity_profile": {
                "role": "Board Lead",
                "communication_style": f"{output_fmt.replace('bullets','direct, bullet-driven').replace('mixed','direct, mixed').replace('narrative','detailed narrative')}, practical",
                "emoji": ":crown:",
            },
            "autonomy_level": autonomy,
            "verbosity": verbosity,
            "output_format": output_fmt,
            "update_cadence": cadence,
            "custom_instructions": custom_instructions or None,
        },
    }


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

async def auto_advance(
    *,
    board_id: str,
    board_name: str,
    gateway_id: str,
) -> None:
    """Post the next onboarding question (or completion) using the gateway-agent token.

    Opens its own DB session — safe to call as an asyncio background task
    after the request session has been committed and closed.
    """
    import asyncio
    import httpx
    from app.core.config import settings
    from app.db.session import async_session_maker
    from app.models.agents import Agent
    from app.models.board_onboarding import BoardOnboardingSession
    from app.models.boards import Board
    from app.services.openclaw.db_agent_state import mint_agent_token
    from app.core.time import utcnow
    from datetime import timedelta
    from sqlmodel import select, col
    from uuid import UUID

    # Small delay to let the request session fully commit
    await asyncio.sleep(0.3)

    async with async_session_maker() as session:
        board_uuid = UUID(str(board_id))
        gw_uuid = UUID(str(gateway_id))

        # Fetch latest onboarding session
        onboarding = (
            await session.exec(
                select(BoardOnboardingSession)
                .where(col(BoardOnboardingSession.board_id) == board_uuid)
                .order_by(col(BoardOnboardingSession.updated_at).desc())
            )
        ).first()

        if onboarding is None or onboarding.status not in ("active",):
            logger.info("onboarding.auto_advance.skip board_id=%s status=%s", board_id, onboarding.status if onboarding else "none")
            return

        # Collect user answers (skip the initial long prompt)
        messages = list(onboarding.messages or [])
        user_answers = [
            m["content"]
            for m in messages
            if m.get("role") == "user"
            and "BOARD ONBOARDING REQUEST" not in m.get("content", "")
            and len(m.get("content", "")) < 2000
        ]
        answer_count = len(user_answers)

        logger.info("onboarding.auto_advance board_id=%s answer_count=%d", board_id, answer_count)

        # Fetch gateway agent and mint a fresh token
        gw_agent = (
            await session.exec(
                select(Agent).where(
                    col(Agent.gateway_id) == gw_uuid,
                    col(Agent.openclaw_session_id).contains("mc-gateway-"),
                )
            )
        ).first()

        if gw_agent is None:
            logger.warning("onboarding.auto_advance.no_gateway_agent board_id=%s", board_id)
            return

        raw_token = mint_agent_token(gw_agent)
        gw_agent.checkin_deadline_at = utcnow() + timedelta(hours=2)
        session.add(gw_agent)
        await session.commit()

    # Build payload outside the session
    base_url = str(settings.base_url).rstrip("/") if hasattr(settings, "base_url") else "https://api.somrat.tech"
    endpoint = f"{base_url}/api/v1/boards/{board_id}/onboarding/agent"

    if answer_count < len(_QUESTIONS):
        q = _QUESTIONS[answer_count]
        payload: dict = {"question": q["question"], "options": q["options"]}
    else:
        payload = _build_completion(user_answers, board_name)

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(
                endpoint,
                json=payload,
                headers={"X-Agent-Token": raw_token, "Content-Type": "application/json"},
            )
            if resp.status_code == 200:
                logger.info("onboarding.auto_advance.posted board_id=%s answer_count=%d", board_id, answer_count)
            else:
                logger.warning("onboarding.auto_advance.post_failed board_id=%s status=%d body=%s", board_id, resp.status_code, resp.text[:300])
    except Exception as exc:
        logger.error("onboarding.auto_advance.error board_id=%s error=%s", board_id, exc)
