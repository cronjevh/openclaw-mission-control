from __future__ import annotations

from uuid import UUID

from app.models.boards import Board
from app.services.board_cadence_crontab import _build_crontab_content


def test_build_board_crontab_uses_cron_gate() -> None:
    board = Board(
        id=UUID("00000000-0000-0000-0000-000000000001"),
        organization_id=UUID("00000000-0000-0000-0000-000000000002"),
        gateway_id=UUID("00000000-0000-0000-0000-000000000003"),
        name="Ops",
        slug="ops",
        cadence_minutes=30,
    )

    content = _build_crontab_content(board, 30)

    assert "*/30 * * * * cronjev" in content
    assert (
        "/home/cronjev/mission-control-tfsmrt/scripts/cron/mission-control-cron-runner.sh"
        in content
    )
    assert "-- bash -lc" in content
    assert "workflow dispatchboard --board 00000000-0000-0000-0000-000000000001" in content
    assert "dispatchboard-00000000.$(date +\\%Y\\%m\\%d).log" in content
