"""Board group CRUD, snapshot, and heartbeat endpoints."""

from __future__ import annotations

import re
from typing import TYPE_CHECKING, Any
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import asc, func
from sqlmodel import col, select

from app.api.deps import ActorContext, require_user_or_agent, require_org_admin, require_org_member
from app.core.config import settings
from app.core.time import utcnow
from app.db import crud
from app.db.pagination import paginate
from app.db.session import get_session
from app.models.activity_events import ActivityEvent
from app.models.agents import Agent
from app.models.board_group_memory import BoardGroupMemory
from app.models.board_groups import BoardGroup
from app.models.boards import Board
from app.models.gateways import Gateway
from app.models.tasks import Task
from app.schemas.board_group_heartbeat import (
    BoardGroupHeartbeatApply,
    BoardGroupHeartbeatApplyResult,
    BoardGroupHeartbeatConfig,
)
from app.schemas.agents import AgentRead
from app.schemas.board_groups import BoardGroupCreate, BoardGroupRead, BoardGroupUpdate
from app.schemas.common import OkResponse
from app.schemas.pagination import DefaultLimitOffsetPage
from app.schemas.tasks import TaskCommentCreate, TaskCommentRead, TaskCreate, TaskRead, TaskUpdate
from app.schemas.view_models import BoardGroupSnapshot
from app.services.board_group_snapshot import build_group_snapshot
from app.services.openclaw.constants import DEFAULT_HEARTBEAT_CONFIG
from app.services.openclaw.db_agent_state import mint_agent_token
from app.services.openclaw.gateway_rpc import OpenClawGatewayError, GatewayConfig, send_message as _gw_send_message
from app.services.openclaw.gateway_dispatch import GatewayDispatchService
from app.services.openclaw.internal.session_keys import group_lead_session_key
from app.services.openclaw.provisioning import OpenClawGatewayProvisioner
from app.services.openclaw.lifecycle_orchestrator import AgentLifecycleOrchestrator
from app.services.openclaw.provisioning_db import AgentLifecycleService
from app.services.organizations import (
    OrganizationContext,
    board_access_filter,
    get_member,
    is_org_admin,
    list_accessible_board_ids,
    member_all_boards_read,
    member_all_boards_write,
)

if TYPE_CHECKING:
    from fastapi_pagination.limit_offset import LimitOffsetPage
    from sqlmodel.ext.asyncio.session import AsyncSession

    from app.models.organization_members import OrganizationMember

router = APIRouter(prefix="/board-groups", tags=["board-groups"])
SESSION_DEP = Depends(get_session)
ORG_MEMBER_DEP = Depends(require_org_member)
ORG_ADMIN_DEP = Depends(require_org_admin)
ACTOR_DEP = Depends(require_user_or_agent)


def _slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or uuid4().hex


async def _require_group_access_for_actor(
    session: AsyncSession,
    *,
    group_id: UUID,
    actor: "ActorContext",
    write: bool,
) -> "BoardGroup":
    """Accept both user (OrganizationMember) and agent (group agent) callers."""
    if actor.actor_type == "agent" and actor.agent is not None:
        group = await BoardGroup.objects.by_id(group_id).first(session)
        if group is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        agent = actor.agent
        # Group agent for this group ✓
        if agent.group_id == group_id:
            return group
        # Board-scoped agent whose board belongs to this group ✓
        if agent.board_id is not None:
            from app.models.boards import Board
            board = await Board.objects.by_id(agent.board_id).first(session)
            if board and board.board_group_id == group_id:
                return group
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    if actor.user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    from app.services.organizations import get_active_membership
    member = await get_active_membership(session, actor.user)
    if member is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    return await _require_group_access(session, group_id=group_id, member=member, write=write)


async def _require_group_access(
    session: AsyncSession,
    *,
    group_id: UUID,
    member: OrganizationMember,
    write: bool,
) -> BoardGroup:
    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if group.organization_id != member.organization_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    if write and member_all_boards_write(member):
        return group
    if not write and member_all_boards_read(member):
        return group

    board_ids = [
        board.id for board in await Board.objects.filter_by(board_group_id=group_id).all(session)
    ]
    if not board_ids:
        if is_org_admin(member):
            return group
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    allowed_ids = await list_accessible_board_ids(session, member=member, write=write)
    if not set(board_ids).intersection(set(allowed_ids)):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    return group


@router.get("", response_model=DefaultLimitOffsetPage[BoardGroupRead])
async def list_board_groups(
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> LimitOffsetPage[BoardGroupRead]:
    """List board groups in the active organization."""
    if member_all_boards_read(ctx.member):
        statement = select(BoardGroup).where(
            col(BoardGroup.organization_id) == ctx.organization.id,
        )
    else:
        accessible_boards = select(Board.board_group_id).where(
            board_access_filter(ctx.member, write=False),
        )
        statement = select(BoardGroup).where(
            col(BoardGroup.organization_id) == ctx.organization.id,
            col(BoardGroup.id).in_(accessible_boards),
        )
    statement = statement.order_by(func.lower(col(BoardGroup.name)).asc())
    return await paginate(session, statement)


@router.post("", response_model=BoardGroupRead)
async def create_board_group(
    payload: BoardGroupCreate,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> BoardGroup:
    """Create a board group in the active organization."""
    data = payload.model_dump()
    if not (data.get("slug") or "").strip():
        data["slug"] = _slugify(data.get("name") or "")
    data["organization_id"] = ctx.organization.id
    return await crud.create(session, BoardGroup, **data)


@router.get("/{group_id}", response_model=BoardGroupRead)
async def get_board_group(
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> BoardGroup:
    """Get a board group by id."""
    return await _require_group_access(
        session,
        group_id=group_id,
        member=ctx.member,
        write=False,
    )


@router.get("/{group_id}/snapshot", response_model=BoardGroupSnapshot)
async def get_board_group_snapshot(
    group_id: UUID,
    *,
    include_done: bool = False,
    per_board_task_limit: int = 5,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> BoardGroupSnapshot:
    """Get a snapshot across boards in a group."""
    group = await _require_group_access_for_actor(
        session,
        group_id=group_id,
        actor=actor,
        write=False,
    )
    if per_board_task_limit < 0:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT)
    snapshot = await build_group_snapshot(
        session,
        group=group,
        exclude_board_id=None,
        include_done=include_done,
        per_board_task_limit=per_board_task_limit,
    )
    # For user actors, filter snapshot to boards they have access to
    if actor.actor_type == "user" and actor.user is not None and snapshot.boards:
        from app.services.organizations import get_active_membership
        member = await get_active_membership(session, actor.user)
        if member and not member_all_boards_read(member):
            allowed_ids = set(
                await list_accessible_board_ids(session, member=member, write=False),
            )
            snapshot.boards = [item for item in snapshot.boards if item.board.id in allowed_ids]
    return snapshot


async def _authorize_heartbeat_actor(
    session: AsyncSession,
    *,
    group_id: UUID,
    group: BoardGroup,
    actor: ActorContext,
) -> None:
    if actor.actor_type == "user":
        if actor.user is None:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
        member = await get_member(
            session,
            user_id=actor.user.id,
            organization_id=group.organization_id,
        )
        if member is None or not is_org_admin(member):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
        await _require_group_access(
            session,
            group_id=group_id,
            member=member,
            write=True,
        )
        return
    agent = actor.agent
    if agent is None or agent.board_id is None or not agent.is_board_lead:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
    board = await Board.objects.by_id(agent.board_id).first(session)
    if board is None or board.board_group_id != group_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)


async def _agents_for_group_heartbeat(
    session: AsyncSession,
    *,
    group_id: UUID,
    include_board_leads: bool,
) -> tuple[dict[UUID, Board], list[Agent]]:
    boards = await Board.objects.filter_by(board_group_id=group_id).all(session)
    board_by_id = {board.id: board for board in boards}
    board_ids = list(board_by_id.keys())
    if not board_ids:
        return board_by_id, []
    agents = await Agent.objects.by_field_in("board_id", board_ids).all(session)
    if include_board_leads:
        agents = [agent for agent in agents if agent.is_board_lead]
    else:
        agents = [agent for agent in agents if not agent.is_board_lead]
    return board_by_id, agents


def _update_agent_heartbeat(
    *,
    agent: Agent,
    payload: BoardGroupHeartbeatApply,
) -> None:
    raw = agent.heartbeat_config
    heartbeat: dict[str, Any] = DEFAULT_HEARTBEAT_CONFIG.copy()
    if isinstance(raw, dict):
        heartbeat.update(raw)
    heartbeat["every"] = payload.every
    heartbeat["target"] = DEFAULT_HEARTBEAT_CONFIG.get("target", "last")
    agent.heartbeat_config = heartbeat
    agent.updated_at = utcnow()


async def _sync_gateway_heartbeats(
    session: AsyncSession,
    *,
    board_by_id: dict[UUID, Board],
    agents: list[Agent],
) -> list[UUID]:
    agents_by_gateway_id: dict[UUID, list[Agent]] = {}
    for agent in agents:
        board_id = agent.board_id
        if board_id is None:
            continue
        board = board_by_id.get(board_id)
        if board is None or board.gateway_id is None:
            continue
        agents_by_gateway_id.setdefault(board.gateway_id, []).append(agent)

    failed_agent_ids: list[UUID] = []
    gateway_ids = list(agents_by_gateway_id.keys())
    gateways = await Gateway.objects.by_ids(gateway_ids).all(session)
    gateway_by_id = {gateway.id: gateway for gateway in gateways}
    for gateway_id, gateway_agents in agents_by_gateway_id.items():
        gateway = gateway_by_id.get(gateway_id)
        if gateway is None or not gateway.url or not gateway.workspace_root:
            for agent in gateway_agents:
                agent.last_provision_error = "gateway not configured"
                agent.updated_at = utcnow()
                session.add(agent)
            failed_agent_ids.extend([agent.id for agent in gateway_agents])
            continue
        try:
            await OpenClawGatewayProvisioner().sync_gateway_agent_heartbeats(
                gateway,
                gateway_agents,
            )
            # Clear any previous error and reset to online on success
            for agent in gateway_agents:
                if agent.provision_action == "update":
                    agent.provision_action = None
                    agent.last_provision_error = None
                    agent.status = "online"
                    agent.updated_at = utcnow()
                    session.add(agent)
        except OpenClawGatewayError as exc:
            error_msg = str(exc) if str(exc) else "gateway sync failed"
            for agent in gateway_agents:
                agent.last_provision_error = error_msg
                agent.updated_at = utcnow()
                session.add(agent)
            failed_agent_ids.extend([agent.id for agent in gateway_agents])
    if any(True for _ in failed_agent_ids):
        await session.commit()
    return failed_agent_ids


@router.get("/{group_id}/heartbeat", response_model=BoardGroupHeartbeatConfig)
async def get_board_group_heartbeat(
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_MEMBER_DEP,
) -> BoardGroupHeartbeatConfig:
    """Return the current heartbeat cadence for worker and lead agents in a group."""
    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    await _require_group_access(session, group_id=group_id, member=ctx.member, write=False)
    boards = await Board.objects.filter_by(board_group_id=group_id).all(session)
    board_ids = [b.id for b in boards]
    if not board_ids:
        return BoardGroupHeartbeatConfig()
    agents = await Agent.objects.by_field_in("board_id", board_ids).all(session)
    worker_every: str | None = None
    lead_every: str | None = None
    for agent in agents:
        cfg = agent.heartbeat_config or {}
        every = cfg.get("every") if isinstance(cfg, dict) else None
        if not every:
            continue
        if agent.is_board_lead:
            if lead_every is None:
                lead_every = every
        else:
            if worker_every is None:
                worker_every = every
        if worker_every and lead_every:
            break
    return BoardGroupHeartbeatConfig(worker_every=worker_every, lead_every=lead_every)


@router.post("/{group_id}/heartbeat", response_model=BoardGroupHeartbeatApplyResult)
async def apply_board_group_heartbeat(
    group_id: UUID,
    payload: BoardGroupHeartbeatApply,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> BoardGroupHeartbeatApplyResult:
    """Apply heartbeat settings to agents in a board group."""
    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    await _authorize_heartbeat_actor(
        session,
        group_id=group_id,
        group=group,
        actor=actor,
    )
    board_by_id, agents = await _agents_for_group_heartbeat(
        session,
        group_id=group_id,
        include_board_leads=payload.include_board_leads,
    )
    if not agents:
        return BoardGroupHeartbeatApplyResult(
            board_group_id=group_id,
            requested=payload.model_dump(mode="json"),
            updated_agent_ids=[],
            failed_agent_ids=[],
        )

    updated_agent_ids: list[UUID] = []
    for agent in agents:
        _update_agent_heartbeat(agent=agent, payload=payload)
        session.add(agent)
        updated_agent_ids.append(agent.id)

    await session.commit()
    failed_agent_ids = await _sync_gateway_heartbeats(
        session,
        board_by_id=board_by_id,
        agents=agents,
    )

    return BoardGroupHeartbeatApplyResult(
        board_group_id=group_id,
        requested=payload.model_dump(mode="json"),
        updated_agent_ids=updated_agent_ids,
        failed_agent_ids=failed_agent_ids,
    )


@router.patch("/{group_id}", response_model=BoardGroupRead)
async def update_board_group(
    payload: BoardGroupUpdate,
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> BoardGroup:
    """Update a board group."""
    group = await _require_group_access(
        session,
        group_id=group_id,
        member=ctx.member,
        write=True,
    )
    updates = payload.model_dump(exclude_unset=True)
    if "slug" in updates and updates["slug"] is not None and not updates["slug"].strip():
        updates["slug"] = _slugify(updates.get("name") or group.name)
    updates["updated_at"] = utcnow()
    return await crud.patch(session, group, updates)


# ---------------------------------------------------------------------------
# Group Agent Provisioning
# ---------------------------------------------------------------------------

from sqlmodel import SQLModel  # noqa: E402


class GroupAgentProvision(SQLModel):
    """Payload for provisioning a group lead agent."""

    gateway_id: UUID | None = None  # auto-selects org's first gateway if omitted
    name: str | None = None  # defaults to "{group.name} Lead"


@router.post("/{group_id}/agent", response_model=AgentRead)
async def provision_group_agent(
    group_id: UUID,
    payload: GroupAgentProvision = GroupAgentProvision(),
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> AgentRead:
    """Provision a group lead agent for a board group.

    Creates a new Agent record scoped to the group (no board), sets it as the
    group's agent, and mints its auth token. Only org admins may call this.
    If gateway_id is omitted, the first gateway in the organization is used.
    """
    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if group.organization_id != ctx.organization.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    if group.group_agent_id is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A group agent is already provisioned for this board group.",
        )

    if payload.gateway_id:
        gateway = await Gateway.objects.by_id(payload.gateway_id).first(session)
    else:
        gateways = await Gateway.objects.filter_by(
            organization_id=ctx.organization.id,
        ).all(session)
        gateway = gateways[0] if gateways else None

    if gateway is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No gateway found. Please configure a gateway first.",
        )

    agent_name = (payload.name or "").strip() or f"{group.name} Lead"
    session_key = group_lead_session_key(group_id)

    agent = Agent(
        name=agent_name,
        board_id=None,
        group_id=group_id,
        gateway_id=gateway.id,
        is_board_lead=True,
        status="provisioning",
        openclaw_session_id=session_key,
    )
    raw_token = mint_agent_token(agent)
    session.add(agent)
    await session.flush()

    group.group_agent_id = agent.id
    group.updated_at = utcnow()
    session.add(group)
    await session.commit()
    await session.refresh(agent)

    # Actually provision the agent on the gateway (sets up workspace files, wakes it up).
    agent = await AgentLifecycleOrchestrator(session).run_lifecycle(
        gateway=gateway,
        agent_id=agent.id,
        board=None,
        user=None,  # run_lifecycle fetches org owner automatically when board=None
        action="provision",
        auth_token=raw_token,
        force_bootstrap=True,
        wakeup_verb="provisioned",
    )

    # Append sister-board context block to TOOLS.md in the agent workspace.
    # This runs best-effort; provisioning is already done at this point.
    try:
        from app.services.group_agent_context import build_group_context_block
        context_block = await build_group_context_block(session, group_id=group_id)
        if context_block and gateway.workspace_root:
            from app.services.openclaw.provisioning import _workspace_path
            workspace_path = _workspace_path(agent, gateway.workspace_root)
            tools_path = f"{workspace_path}/TOOLS.md"
            import os
            if os.path.exists(tools_path):
                with open(tools_path, "a") as f:
                    f.write("\n\n---\n\n## Sister Boards Context\n\n")
                    f.write("You have full read/write access to all boards in your group.\n\n")
                    f.write(context_block)
    except Exception:
        pass  # non-fatal: agent is already provisioned and running

    return AgentLifecycleService.to_agent_read(AgentLifecycleService.with_computed_status(agent))


@router.delete("/{group_id}/agent", response_model=OkResponse)
async def deprovision_group_agent(
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> OkResponse:
    """Deprovision the group lead agent for a board group.

    Deletes the agent record and clears the group's agent reference.
    Only org admins may call this.
    """
    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if group.organization_id != ctx.organization.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    if group.group_agent_id is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No group agent is provisioned for this board group.",
        )

    agent = await Agent.objects.by_id(group.group_agent_id).first(session)

    group.group_agent_id = None
    group.updated_at = utcnow()
    session.add(group)
    await session.flush()

    if agent is not None:
        # Use the proper service delete path so FK-linked rows (activity_events,
        # approvals, webhooks, etc.) are nullified before the agent is removed.
        await AgentLifecycleService(session)._delete_agent_record(agent=agent)
    else:
        await session.commit()

    return OkResponse()


@router.get("/{group_id}/agent", response_model=AgentRead)
async def get_group_agent(
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> AgentRead:
    """Get the group lead agent for a board group.

    Returns 404 if no group agent has been provisioned. Only org admins may call this.
    """
    group = await BoardGroup.objects.by_id(group_id).first(session)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    if group.organization_id != ctx.organization.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)

    if group.group_agent_id is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No group agent is provisioned for this board group.",
        )

    agent = await Agent.objects.by_id(group.group_agent_id).first(session)
    if agent is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)

    return AgentLifecycleService.to_agent_read(AgentLifecycleService.with_computed_status(agent))


@router.delete("/{group_id}", response_model=OkResponse)
async def delete_board_group(
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    ctx: OrganizationContext = ORG_ADMIN_DEP,
) -> OkResponse:
    """Delete a board group."""
    await _require_group_access(
        session,
        group_id=group_id,
        member=ctx.member,
        write=True,
    )

    # Boards reference groups, so clear the FK first to keep deletes simple.
    await crud.update_where(
        session,
        Board,
        col(Board.board_group_id) == group_id,
        board_group_id=None,
        commit=False,
    )
    await crud.delete_where(
        session,
        BoardGroupMemory,
        col(BoardGroupMemory.board_group_id) == group_id,
        commit=False,
    )
    await crud.delete_where(
        session,
        BoardGroup,
        col(BoardGroup.id) == group_id,
        commit=False,
    )
    await session.commit()
    return OkResponse()


# ---------------------------------------------------------------------------
# Group-level Tasks
# ---------------------------------------------------------------------------


async def _wake_assigned_agent(session: AsyncSession, *, task: Task) -> None:
    """Send a wake message to the agent assigned to a group task."""
    if task.assigned_agent_id is None:
        return
    agent = await Agent.objects.by_id(task.assigned_agent_id).first(session)
    if agent is None or not agent.openclaw_session_id or not agent.gateway_id:
        return
    gateway = await Gateway.objects.by_id(agent.gateway_id).first(session)
    if gateway is None or not gateway.url or not gateway.token:
        return
    base_url = settings.base_url or "http://localhost:8000"
    group_id = task.board_group_id
    msg = (
        f"TASK ASSIGNED — ACT NOW\n"
        f"Task: {task.title}\n"
        f"Task ID: {task.id}\n"
        f"Group ID: {group_id}\n"
        f"Status: {task.status}\n"
        f"Priority: {task.priority or 'medium'}\n\n"
        f"{task.description or ''}\n\n"
        f"This is a GROUP TASK. Follow these steps IN ORDER:\n\n"
        f"STEP 1 — Move to in_progress:\n"
        f"  curl -s -X PATCH \"{base_url}/api/v1/board-groups/{group_id}/tasks/{task.id}\" "
        f"-H \"X-Agent-Token: $AUTH_TOKEN\" -H \"Content-Type: application/json\" "
        f"-d '{{\"status\":\"in_progress\"}}'\n\n"
        f"STEP 2 — Do the work described above.\n\n"
        f"STEP 3 — MANDATORY: Post your findings as a task comment (this is REQUIRED, do NOT skip):\n"
        f"  curl -s -X POST \"{base_url}/api/v1/board-groups/{group_id}/tasks/{task.id}/comments\" "
        f"-H \"X-Agent-Token: $AUTH_TOKEN\" -H \"Content-Type: application/json\" "
        f"-d '{{\"message\":\"## Findings\\n\\n...your evidence and results here...\"}}'\n\n"
        f"STEP 4 — Mark done:\n"
        f"  curl -s -X PATCH \"{base_url}/api/v1/board-groups/{group_id}/tasks/{task.id}\" "
        f"-H \"X-Agent-Token: $AUTH_TOKEN\" -H \"Content-Type: application/json\" "
        f"-d '{{\"status\":\"done\"}}'\n\n"
        f"IMPORTANT RULES:\n"
        f"- Use /api/v1/board-groups/ endpoints, NOT /api/v1/agent/boards/\n"
        f"- You MUST post a task comment with evidence BEFORE marking done\n"
        f"- $AUTH_TOKEN is in your TOOLS.md file\n"
        f"- Do NOT post findings to group chat — post them as a TASK COMMENT"
    ).strip()
    try:
        config = GatewayConfig(url=gateway.url, token=gateway.token)
        await _gw_send_message(msg, session_key=agent.openclaw_session_id, config=config)
    except Exception:  # noqa: BLE001
        pass  # best-effort, don't fail the task operation


async def _build_agent_name_map(session: AsyncSession, tasks: list[Task]) -> dict[UUID, str]:
    """Return {agent_id: agent_name} for all assigned agents in the task list."""
    ids = [t.assigned_agent_id for t in tasks if t.assigned_agent_id]
    if not ids:
        return {}
    result = await session.exec(select(Agent).where(col(Agent.id).in_(ids)))
    return {a.id: a.name for a in result.all()}


async def _build_user_name_map(session: AsyncSession, tasks: list[Task]) -> dict[UUID, str]:
    """Return {user_id: user_name} for all task creators."""
    from app.models.users import User
    ids = [t.created_by_user_id for t in tasks if t.created_by_user_id]
    if not ids:
        return {}
    result = await session.exec(select(User).where(col(User.id).in_(ids)))
    return {u.id: (u.name or u.email or "User") for u in result.all()}


async def _get_group_task_or_404(
    session: AsyncSession,
    *,
    task_id: UUID,
    group_id: UUID,
) -> Task:
    task = await session.get(Task, task_id)
    if task is None or task.board_group_id != group_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    return task


@router.get(
    "/{group_id}/tasks",
    response_model=DefaultLimitOffsetPage[TaskRead],
    tags=["agent-lead"],
    openapi_extra={
        "x-llm-intent": "List all tasks owned by this board group (inbox, in_progress, review, done)",
        "x-when-to-use": ["group lead heartbeat loop", "picking up unassigned inbox tasks"],
    },
)
async def list_group_tasks(
    group_id: UUID,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> Any:
    """List tasks belonging directly to a board group (not scoped to any inner board)."""
    await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=False)
    statement = (
        select(Task)
        .where(col(Task.board_group_id) == group_id)
        .where(col(Task.board_id).is_(None))
        .order_by(col(Task.created_at).desc())
    )
    page = await paginate(session, statement)
    agent_map = await _build_agent_name_map(session, page.items)
    user_map = await _build_user_name_map(session, page.items)
    from app.schemas.tasks import TaskRead
    enriched_items = []
    for task in page.items:
        d = task.model_dump()
        d["assignee"] = agent_map.get(task.assigned_agent_id) if task.assigned_agent_id else None
        d["creator_name"] = user_map.get(task.created_by_user_id) if task.created_by_user_id else None
        enriched_items.append(TaskRead.model_validate(d))
    page.items = enriched_items
    return page


@router.post("/{group_id}/tasks", response_model=TaskRead, tags=["agent-lead"])
async def create_group_task(
    group_id: UUID,
    payload: TaskCreate,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> Task:
    """Create a task directly owned by a board group."""
    await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=True)
    data = payload.model_dump(exclude={"depends_on_task_ids", "tag_ids", "custom_field_values"})
    task = Task.model_validate(data)
    task.board_group_id = group_id
    task.board_id = None
    task.created_by_user_id = actor.user.id if actor.user else None
    session.add(task)
    await session.commit()
    await session.refresh(task)
    # Wake the assigned agent immediately so it picks up the task
    await _wake_assigned_agent(session, task=task)
    return task


@router.get("/{group_id}/tasks/{task_id}", response_model=TaskRead)
async def get_group_task(
    group_id: UUID,
    task_id: UUID,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> Task:
    """Get a single group-level task."""
    await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=False)
    return await _get_group_task_or_404(session, task_id=task_id, group_id=group_id)


@router.patch(
    "/{group_id}/tasks/{task_id}",
    response_model=TaskRead,
    tags=["agent-lead"],
    openapi_extra={
        "x-llm-intent": "Update status, title, description, or priority of a group task",
        "x-when-to-use": ["moving task to in_progress", "marking task done", "updating task details"],
    },
)
async def update_group_task(
    group_id: UUID,
    task_id: UUID,
    payload: TaskUpdate,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> Task:
    """Update a group-level task."""
    await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=True)
    task = await _get_group_task_or_404(session, task_id=task_id, group_id=group_id)
    old_assignee = task.assigned_agent_id
    updates = payload.model_dump(
        exclude={"depends_on_task_ids", "tag_ids", "custom_field_values"},
        exclude_unset=True,
    )
    updates["updated_at"] = utcnow()
    for key, value in updates.items():
        setattr(task, key, value)
    session.add(task)
    await session.commit()
    await session.refresh(task)
    # Wake newly assigned agent
    if task.assigned_agent_id and task.assigned_agent_id != old_assignee:
        await _wake_assigned_agent(session, task=task)
    return task


@router.delete("/{group_id}/tasks/{task_id}", response_model=OkResponse, tags=["agent-lead"])
async def delete_group_task(
    group_id: UUID,
    task_id: UUID,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> OkResponse:
    """Delete a group-level task."""
    await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=True)
    task = await _get_group_task_or_404(session, task_id=task_id, group_id=group_id)
    await session.delete(task)
    await session.commit()
    return OkResponse()


@router.get(
    "/{group_id}/tasks/{task_id}/comments",
    response_model=DefaultLimitOffsetPage[TaskCommentRead],
    tags=["agent-lead"],
)
async def list_group_task_comments(
    group_id: UUID,
    task_id: UUID,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> Any:
    """List comments for a group-level task in chronological order."""
    await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=False)
    await _get_group_task_or_404(session, task_id=task_id, group_id=group_id)
    statement = (
        select(ActivityEvent)
        .where(col(ActivityEvent.task_id) == task_id)
        .where(col(ActivityEvent.event_type) == "task.comment")
        .order_by(asc(col(ActivityEvent.created_at)))
    )
    return await paginate(session, statement)


@router.post(
    "/{group_id}/tasks/{task_id}/comments",
    response_model=TaskCommentRead,
    tags=["agent-lead"],
)
async def create_group_task_comment(
    group_id: UUID,
    task_id: UUID,
    payload: TaskCommentCreate,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> ActivityEvent:
    """Create a comment on a group-level task and notify the group agent when mentioned."""
    group = await _require_group_access_for_actor(session, group_id=group_id, actor=actor, write=True)
    task = await _get_group_task_or_404(session, task_id=task_id, group_id=group_id)
    event = ActivityEvent(
        event_type="task.comment",
        message=payload.message,
        task_id=task.id,
        board_id=task.board_id,
        agent_id=(actor.agent.id if actor.actor_type == "agent" and actor.agent else None),
        created_by_user_id=(actor.user.id if actor.actor_type == "user" and actor.user else None),
        author_name=(
            (actor.agent.name or "Agent")
            if actor.actor_type == "agent" and actor.agent
            else (actor.user.name or "User")
            if actor.actor_type == "user" and actor.user
            else None
        ),
    )
    session.add(event)
    await session.commit()
    await session.refresh(event)

    # Notify the group agent if @lead or its name is mentioned (or it's the task assignee)
    if group.group_agent_id is not None:
        group_agent = await Agent.objects.by_id(group.group_agent_id).first(session)
        if group_agent is not None and group_agent.openclaw_session_id:
            # Skip if actor IS the group agent (no self-notify)
            is_self = actor.actor_type == "agent" and actor.agent and actor.agent.id == group_agent.id
            if not is_self:
                from app.services.mentions import extract_mentions, matches_agent_mention
                mentions = extract_mentions(payload.message)
                should_notify = (
                    "lead" in mentions
                    or matches_agent_mention(group_agent, mentions)
                    or bool(mentions)  # any mention in task comment = notify
                )
                if should_notify:
                    from app.services.openclaw.gateway_dispatch import GatewayDispatchService
                    dispatch = GatewayDispatchService(session)
                    gateway = await Gateway.objects.by_id(group_agent.gateway_id).first(session)
                    if gateway:
                        from app.services.openclaw.gateway_rpc import GatewayConfig, send_message
                        actor_name = (
                            actor.user.name if actor.user else
                            (actor.agent.name if actor.agent else "User")
                        )
                        base_url = settings.base_url or "http://localhost:8000"
                        msg = (
                            f"TASK COMMENT MENTION\n"
                            f"Task: {task.title}\n"
                            f"Task ID: {task.id}\n"
                            f"From: {actor_name}\n\n"
                            f"{payload.message}\n\n"
                            f"Reply via task comment:\n"
                            f"POST {base_url}/api/v1/board-groups/{group_id}/tasks/{task_id}/comments\n"
                            f'Body: {{"message":"..."}}'
                        )
                        config = GatewayConfig(url=gateway.url, token=gateway.token)
                        try:
                            await send_message(
                                msg,
                                session_key=group_agent.openclaw_session_id,
                                config=config,
                            )
                        except Exception:  # noqa: BLE001
                            pass  # best-effort, don't fail the comment

    return event
