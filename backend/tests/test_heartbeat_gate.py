from __future__ import annotations

from pathlib import Path
from uuid import uuid4

from jinja2 import Environment, StrictUndefined

TEMPLATES = Path(__file__).resolve().parents[1] / "templates"
BOARD_TPL = TEMPLATES / "BOARD_HEARTBEAT.md.j2"
GROUP_LEAD_TPL = TEMPLATES / "GROUP_LEAD_HEARTBEAT.md.j2"

env = Environment(undefined=StrictUndefined)


def _render_board(**overrides: object) -> str:
    defaults = {
        "base_url": "http://localhost:8002",
        "agent_id": str(uuid4()),
        "board_id": str(uuid4()),
        "is_main_agent": False,
        "is_board_lead": False,
    }
    defaults.update(overrides)
    return env.from_string(BOARD_TPL.read_text(encoding="utf-8")).render(**defaults)


def _render_group_lead(**overrides: object) -> str:
    defaults = {
        "base_url": "http://localhost:8002",
        "agent_id": str(uuid4()),
        "group_id": str(uuid4()),
    }
    defaults.update(overrides)
    return env.from_string(GROUP_LEAD_TPL.read_text(encoding="utf-8")).render(
        **defaults
    )


class TestBoardMainAgentNoGate:
    def test_main_agent_has_no_pre_llm_gate(self) -> None:
        t = _render_board(is_main_agent=True)
        assert "Pre-LLM Gate" not in t

    def test_main_agent_has_no_gate_variables(self) -> None:
        t = _render_board(is_main_agent=True)
        assert "GATE_" not in t


class TestBoardLeadGate:
    def test_lead_has_pre_llm_gate(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "Pre-LLM Gate" in t

    def test_lead_uses_limit_20_for_pause(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "limit=20" in t

    def test_lead_queries_in_progress(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "GATE_IP_TOTAL" in t
        assert "status=in_progress&limit=1" in t

    def test_lead_queries_review(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "GATE_RV_TOTAL" in t
        assert "status=review&limit=1" in t

    def test_lead_queries_unassigned_inbox(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "GATE_UA_TOTAL" in t
        assert "unassigned=true" in t

    def test_lead_queries_lead_assigned_inbox(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "GATE_LI_TOTAL" in t
        assert "assigned_agent_id" in t

    def test_lead_does_not_have_worker_ib_variable(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "GATE_IB_TOTAL" not in t

    def test_lead_pause_scan_parses_latest_pause_or_resume(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "/pause" in t and "/resume" in t
        assert "GATE_PAUSE_STATE" in t
        assert "map(select" in t

    def test_lead_fail_closed_on_api_error(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        assert "GATE: API failure reading board memory" in t


class TestBoardWorkerGate:
    def test_worker_has_pre_llm_gate(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "Pre-LLM Gate" in t

    def test_worker_uses_limit_20_for_pause(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "limit=20" in t

    def test_worker_queries_assigned_in_progress_only(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "GATE_IP_TOTAL" in t
        assert "status=in_progress&assigned_agent_id=" in t

    def test_worker_queries_assigned_inbox_only(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "GATE_IB_TOTAL" in t
        assert "status=inbox&assigned_agent_id=" in t

    def test_worker_has_no_review_query(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "GATE_RV_TOTAL" not in t
        assert "status=review" not in t

    def test_worker_has_no_unassigned_query(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "GATE_UA_TOTAL" not in t
        assert "unassigned=true" not in t

    def test_worker_has_no_lead_assigned_inbox(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "GATE_LI_TOTAL" not in t

    def test_worker_states_no_unassigned_or_assist(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "do NOT count as actionable" in t

    def test_worker_pause_scan_parses_latest_pause_or_resume(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "/pause" in t and "/resume" in t
        assert "GATE_PAUSE_STATE" in t
        assert "map(select" in t

    def test_worker_fail_closed_on_api_error(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        assert "GATE: API failure reading board memory" in t


class TestGroupLeadGate:
    def test_group_lead_has_pre_llm_gate(self) -> None:
        t = _render_group_lead()
        assert "Pre-LLM Gate" in t

    def test_group_lead_uses_snapshot_for_board_discovery(self) -> None:
        t = _render_group_lead()
        assert "GATE_SNAPSHOT" in t
        assert "GATE_BOARD_IDS" in t
        assert "/snapshot" in t

    def test_group_lead_checks_each_board_with_limit_20(self) -> None:
        t = _render_group_lead()
        assert "GATE_ANY_PAUSED" in t
        assert "limit=20" in t

    def test_group_lead_uses_group_tasks_endpoint(self) -> None:
        t = _render_group_lead()
        assert "board-groups" in t
        assert "GATE_TASKS" in t

    def test_group_lead_fail_closed_on_snapshot_error(self) -> None:
        t = _render_group_lead()
        assert "GATE: API failure reading group snapshot" in t

    def test_group_lead_no_undefined_board_id(self) -> None:
        t = _render_group_lead()
        assert "$BOARD_ID" not in t


class TestGateOrderingAcrossRoles:
    def test_gate_appears_before_signal_working_in_lead(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=True)
        gate_pos = t.index("Pre-LLM Gate")
        signal_pos = t.index("## Signal Working Status")
        assert gate_pos < signal_pos

    def test_gate_appears_before_signal_working_in_worker(self) -> None:
        t = _render_board(is_main_agent=False, is_board_lead=False)
        gate_pos = t.index("Pre-LLM Gate")
        signal_pos = t.index("## Signal Working Status")
        assert gate_pos < signal_pos

    def test_gate_appears_before_group_lead_loop(self) -> None:
        t = _render_group_lead()
        gate_pos = t.index("Pre-LLM Gate")
        loop_pos = t.index("## Group Lead Loop")
        assert gate_pos < loop_pos


class TestStrictUndefined:
    def test_board_template_raises_on_missing_base_url(self) -> None:
        try:
            env.from_string(BOARD_TPL.read_text(encoding="utf-8")).render(
                agent_id="a", board_id="b", is_main_agent=True, is_board_lead=False
            )
            raise AssertionError("Expected StrictUndefined error")
        except Exception as exc:
            assert "base_url" in str(exc) or "undefined" in str(exc).lower()

    def test_group_lead_template_raises_on_missing_group_id(self) -> None:
        try:
            env.from_string(GROUP_LEAD_TPL.read_text(encoding="utf-8")).render(
                base_url="http://localhost:8002", agent_id="a"
            )
            raise AssertionError("Expected StrictUndefined error")
        except Exception as exc:
            assert "group_id" in str(exc) or "undefined" in str(exc).lower()
