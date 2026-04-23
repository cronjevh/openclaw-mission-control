from __future__ import annotations

from uuid import UUID

import pytest

from app.models.utility_jobs import UtilityJob
from app.services.utility_job_crontab import (
    _build_crontab_content,
    script_options,
    validate_cron_expression,
    validate_script_key,
)


def test_script_options_load_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(
        "MC_UTILITY_JOB_SCRIPTS_JSON",
        '{"daily":{"label":"Daily","description":"Runs daily","command":"/tmp/daily.sh"}}',
    )

    assert script_options() == [
        {"key": "daily", "label": "Daily", "description": "Runs daily"},
    ]
    validate_script_key("daily")


def test_validate_cron_expression_rejects_shell_metacharacters() -> None:
    with pytest.raises(ValueError, match="unsupported shell metacharacters"):
        validate_cron_expression("0 8 * * *;")


def test_build_crontab_content_for_board_agent_job(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(
        "MC_UTILITY_JOB_SCRIPTS_JSON",
        (
            '{"daily_conversation_review":'
            '{"label":"Daily conversation review",'
            '"command":"/home/cronjev/jobs/daily-review.ps1"}}'
        ),
    )
    job = UtilityJob(
        id=UUID("00000000-0000-0000-0000-000000000001"),
        organization_id=UUID("00000000-0000-0000-0000-000000000002"),
        board_id=UUID("00000000-0000-0000-0000-000000000003"),
        agent_id=UUID("00000000-0000-0000-0000-000000000004"),
        name="Daily review",
        enabled=True,
        cron_expression="0 8 * * *",
        script_key="daily_conversation_review",
        args={"tag": "daily-review"},
    )

    content = _build_crontab_content(job)

    assert "0 8 * * * cronjev" in content
    assert "pwsh -NoProfile -File /home/cronjev/jobs/daily-review.ps1" in content
    assert "--board-id 00000000-0000-0000-0000-000000000003" in content
    assert "--agent-id 00000000-0000-0000-0000-000000000004" in content
    assert "--tag daily-review" in content
