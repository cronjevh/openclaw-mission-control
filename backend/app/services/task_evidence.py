"""Helpers for reading task evidence packets and enforcing evidence closure."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING, Iterable
from uuid import UUID

from sqlmodel import col, select

from app.models.task_evidence import (
    TaskEvidenceArtifact,
    TaskEvidenceCheck,
    TaskEvidencePacket,
)
from app.models.tasks import Task
from app.schemas.task_evidence import (
    TaskEvidenceArtifactRead,
    TaskEvidenceCheckRead,
    TaskEvidencePacketRead,
)

if TYPE_CHECKING:
    from sqlmodel.ext.asyncio.session import AsyncSession

ACTIVE_EVIDENCE_PACKET_STATUSES = {"submitted", "accepted"}
EVIDENCE_BASED_CLOSURE_MODES = {"evidence_packet", "passing_checks"}
PASSING_CHECKS_CLOSURE_MODE = "passing_checks"
PASSED_CHECK_STATUS = "passed"


def normalize_kind_list(values: Iterable[str] | None) -> list[str]:
    """Normalize required kinds for stable comparison and display."""

    if values is None:
        return []
    normalized: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized_value = value.strip().lower()
        if not normalized_value or normalized_value in seen:
            continue
        seen.add(normalized_value)
        normalized.append(normalized_value)
    return normalized


def _packet_sort_key(packet: TaskEvidencePacketRead) -> tuple[int, datetime, datetime]:
    active_rank = 1 if packet.status in ACTIVE_EVIDENCE_PACKET_STATUSES else 0
    effective_timestamp = packet.submitted_at or packet.created_at
    return (active_rank, effective_timestamp, packet.created_at)


async def list_task_evidence_packets(
    session: AsyncSession,
    *,
    task_id: UUID,
) -> list[TaskEvidencePacketRead]:
    """Return task evidence packets with nested artifacts/checks, canonical first."""

    packets = list(
        await session.exec(
            select(TaskEvidencePacket)
            .where(col(TaskEvidencePacket.task_id) == task_id)
            .order_by(col(TaskEvidencePacket.created_at).desc()),
        )
    )
    if not packets:
        return []

    packet_ids = [packet.id for packet in packets]
    artifacts = list(
        await session.exec(
            select(TaskEvidenceArtifact)
            .where(col(TaskEvidenceArtifact.packet_id).in_(packet_ids))
            .order_by(
                col(TaskEvidenceArtifact.is_primary).desc(),
                col(TaskEvidenceArtifact.created_at).asc(),
            ),
        )
    )
    checks = list(
        await session.exec(
            select(TaskEvidenceCheck)
            .where(col(TaskEvidenceCheck.packet_id).in_(packet_ids))
            .order_by(col(TaskEvidenceCheck.created_at).asc()),
        )
    )

    artifacts_by_packet: dict[UUID, list[TaskEvidenceArtifactRead]] = {
        packet_id: [] for packet_id in packet_ids
    }
    for artifact in artifacts:
        artifacts_by_packet.setdefault(artifact.packet_id, []).append(
            TaskEvidenceArtifactRead.model_validate(artifact, from_attributes=True),
        )

    checks_by_packet: dict[UUID, list[TaskEvidenceCheckRead]] = {
        packet_id: [] for packet_id in packet_ids
    }
    for check in checks:
        checks_by_packet.setdefault(check.packet_id, []).append(
            TaskEvidenceCheckRead.model_validate(check, from_attributes=True),
        )

    output: list[TaskEvidencePacketRead] = []
    for packet in packets:
        artifact_reads = artifacts_by_packet.get(packet.id, [])
        primary_artifact = next(
            (
                artifact
                for artifact in artifact_reads
                if artifact.id == packet.primary_artifact_id or artifact.is_primary
            ),
            artifact_reads[0] if artifact_reads else None,
        )
        output.append(
            TaskEvidencePacketRead.model_validate(packet, from_attributes=True).model_copy(
                update={
                    "primary_artifact": primary_artifact,
                    "artifacts": artifact_reads,
                    "checks": checks_by_packet.get(packet.id, []),
                },
            ),
        )

    output.sort(key=_packet_sort_key, reverse=True)
    return output


async def get_canonical_task_evidence_packet(
    session: AsyncSession,
    *,
    task_id: UUID,
) -> TaskEvidencePacketRead | None:
    """Return the packet that should be treated as the canonical review surface."""

    packets = await list_task_evidence_packets(session, task_id=task_id)
    return packets[0] if packets else None


@dataclass(frozen=True, slots=True)
class TaskEvidenceClosureAssessment:
    """Closure assessment returned to task status guards."""

    closure_mode: str | None
    packet: TaskEvidencePacketRead | None
    missing_artifact_kinds: tuple[str, ...] = ()
    missing_check_kinds: tuple[str, ...] = ()
    failing_check_kinds: tuple[str, ...] = ()

    @property
    def has_packet(self) -> bool:
        return self.packet is not None


async def assess_task_evidence_for_done(
    session: AsyncSession,
    *,
    task: Task,
) -> TaskEvidenceClosureAssessment:
    """Assess whether a task satisfies evidence requirements for `done`."""

    closure_mode = (task.closure_mode or "").strip().lower() or None
    packet = await get_canonical_task_evidence_packet(session, task_id=task.id)
    if packet is None or packet.status not in ACTIVE_EVIDENCE_PACKET_STATUSES:
        return TaskEvidenceClosureAssessment(closure_mode=closure_mode, packet=None)

    if closure_mode not in EVIDENCE_BASED_CLOSURE_MODES:
        return TaskEvidenceClosureAssessment(closure_mode=closure_mode, packet=packet)

    artifact_kinds = {artifact.kind for artifact in packet.artifacts}
    required_artifact_kinds = normalize_kind_list(task.required_artifact_kinds)
    missing_artifact_kinds = tuple(
        kind for kind in required_artifact_kinds if kind not in artifact_kinds
    )

    missing_check_kinds: tuple[str, ...] = ()
    failing_check_kinds: tuple[str, ...] = ()
    if closure_mode == PASSING_CHECKS_CLOSURE_MODE:
        checks_by_kind: dict[str, list[str]] = {}
        for check in packet.checks:
            checks_by_kind.setdefault(check.kind, []).append(check.status)
        required_check_kinds = normalize_kind_list(task.required_check_kinds)
        missing_check_kinds = tuple(
            kind for kind in required_check_kinds if kind not in checks_by_kind
        )
        failing_check_kinds = tuple(
            kind
            for kind in required_check_kinds
            if kind in checks_by_kind and PASSED_CHECK_STATUS not in checks_by_kind[kind]
        )

    return TaskEvidenceClosureAssessment(
        closure_mode=closure_mode,
        packet=packet,
        missing_artifact_kinds=missing_artifact_kinds,
        missing_check_kinds=missing_check_kinds,
        failing_check_kinds=failing_check_kinds,
    )
