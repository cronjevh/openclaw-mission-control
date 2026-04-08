"""Task evidence packet API routes."""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.deps import (
    ACTOR_DEP,
    SESSION_DEP,
    ActorContext,
    get_task_or_404,
)
from app.core.time import utcnow
from app.models.boards import Board
from app.models.task_evidence import (
    TaskEvidenceArtifact,
    TaskEvidenceCheck,
    TaskEvidencePacket,
)
from app.models.tasks import Task
from app.schemas.task_evidence import TaskEvidencePacketCreate, TaskEvidencePacketRead
from app.services.organizations import require_board_access
from app.services.task_evidence import list_task_evidence_packets

router = APIRouter(
    prefix="/boards/{board_id}/tasks/{task_id}/evidence-packets",
    tags=["tasks"],
)
TASK_DEP = Depends(get_task_or_404)

SUBMITTED_PACKET_STATUSES = {"submitted", "accepted"}


async def _require_task_write_access(
    session: AsyncSession,
    *,
    task: Task,
    actor: ActorContext,
) -> None:
    if task.board_id is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Task board_id is required.",
        )
    if actor.actor_type == "user" and actor.user is not None:
        board = await Board.objects.by_id(task.board_id).first(session)
        if board is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        await require_board_access(session, user=actor.user, board=board, write=True)
        return
    if actor.actor_type == "agent" and actor.agent is not None:
        if actor.agent.board_id != task.board_id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN)
        return
    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)


def _resolve_primary_artifact_index(payload: TaskEvidencePacketCreate) -> int | None:
    if not payload.artifacts:
        return None
    primary_indexes = [idx for idx, artifact in enumerate(payload.artifacts) if artifact.is_primary]
    if len(primary_indexes) > 1:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Evidence packets may declare only one primary artifact.",
        )
    if primary_indexes:
        return primary_indexes[0]
    return 0


@router.get("", response_model=list[TaskEvidencePacketRead])
async def list_task_evidence(
    task: Task = TASK_DEP,
    session: AsyncSession = SESSION_DEP,
    _actor: ActorContext = ACTOR_DEP,
) -> list[TaskEvidencePacketRead]:
    """List evidence packets for a task, canonical packet first."""

    return await list_task_evidence_packets(session, task_id=task.id)


@router.post("", response_model=TaskEvidencePacketRead)
async def create_task_evidence(
    payload: TaskEvidencePacketCreate,
    task: Task = TASK_DEP,
    session: AsyncSession = SESSION_DEP,
    actor: ActorContext = ACTOR_DEP,
) -> TaskEvidencePacketRead:
    """Create a new evidence packet for the task."""

    await _require_task_write_access(session, task=task, actor=actor)
    if task.board_id is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Task board_id is required.",
        )

    now = utcnow()
    task_class = payload.task_class or task.task_class
    packet = TaskEvidencePacket(
        board_id=task.board_id,
        task_id=task.id,
        created_by_agent_id=(
            actor.agent.id if actor.actor_type == "agent" and actor.agent is not None else None
        ),
        created_by_user_id=(
            actor.user.id if actor.actor_type == "user" and actor.user is not None else None
        ),
        task_class=task_class,
        status=payload.status,
        summary=payload.summary,
        implementation_delta=payload.implementation_delta,
        review_notes=payload.review_notes,
        submitted_at=(now if payload.status in SUBMITTED_PACKET_STATUSES else None),
    )
    session.add(packet)
    await session.flush()

    primary_artifact_index = _resolve_primary_artifact_index(payload)
    created_artifact_ids: list[UUID] = []
    for idx, artifact_payload in enumerate(payload.artifacts):
        relative_path = (
            artifact_payload.relative_path.strip() if artifact_payload.relative_path else None
        )
        artifact = TaskEvidenceArtifact(
            packet_id=packet.id,
            task_id=task.id,
            kind=artifact_payload.kind,
            label=artifact_payload.label,
            workspace_agent_id=artifact_payload.workspace_agent_id,
            workspace_agent_name=artifact_payload.workspace_agent_name,
            workspace_root_key=artifact_payload.workspace_root_key,
            relative_path=relative_path,
            display_path=(
                artifact_payload.display_path
                or (
                    f"{artifact_payload.workspace_agent_name}/{relative_path}"
                    if artifact_payload.workspace_agent_name and relative_path
                    else relative_path
                )
            ),
            origin_kind=artifact_payload.origin_kind,
            is_primary=(primary_artifact_index == idx),
        )
        session.add(artifact)
        await session.flush()
        created_artifact_ids.append(artifact.id)

    for check_payload in payload.checks:
        check = TaskEvidenceCheck(
            packet_id=packet.id,
            task_id=task.id,
            kind=check_payload.kind,
            label=check_payload.label,
            status=check_payload.status,
            command=check_payload.command,
            result_summary=check_payload.result_summary,
        )
        session.add(check)

    if primary_artifact_index is not None:
        packet.primary_artifact_id = created_artifact_ids[primary_artifact_index]
    packet.updated_at = now
    session.add(packet)

    # Keep task metadata lightweight and explicit when the packet provides it.
    if task_class is not None and task.task_class is None:
        task.task_class = task_class
    task.updated_at = now
    session.add(task)

    await session.commit()

    packets = await list_task_evidence_packets(session, task_id=task.id)
    created_packet = next((item for item in packets if item.id == packet.id), None)
    if created_packet is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Evidence packet was created but could not be loaded.",
        )
    return created_packet
