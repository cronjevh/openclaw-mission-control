"""Add task evidence foundation tables and closure metadata.

Revision ID: f7c1d2e3a4b5
Revises: d2e3f4a5b6c7
Create Date: 2026-04-02 08:30:00.000000

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "f7c1d2e3a4b5"
down_revision = "d2e3f4a5b6c7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("tasks", sa.Column("task_class", sa.String(), nullable=True))
    op.add_column("tasks", sa.Column("closure_mode", sa.String(), nullable=True))
    op.add_column(
        "tasks",
        sa.Column(
            "required_artifact_kinds",
            sa.JSON(),
            nullable=False,
            server_default=sa.text("'[]'"),
        ),
    )
    op.add_column(
        "tasks",
        sa.Column(
            "required_check_kinds",
            sa.JSON(),
            nullable=False,
            server_default=sa.text("'[]'"),
        ),
    )
    op.add_column(
        "tasks",
        sa.Column(
            "lead_spot_check_required",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )
    op.create_index("ix_tasks_task_class", "tasks", ["task_class"])
    op.create_index("ix_tasks_closure_mode", "tasks", ["closure_mode"])

    op.create_table(
        "task_evidence_packets",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("board_id", sa.Uuid(), nullable=False),
        sa.Column("task_id", sa.Uuid(), nullable=False),
        sa.Column("created_by_agent_id", sa.Uuid(), nullable=True),
        sa.Column("created_by_user_id", sa.Uuid(), nullable=True),
        sa.Column("task_class", sa.String(), nullable=True),
        sa.Column(
            "status",
            sa.String(),
            nullable=False,
            server_default=sa.text("'submitted'"),
        ),
        sa.Column("summary", sa.String(), nullable=True),
        sa.Column("implementation_delta", sa.String(), nullable=True),
        sa.Column("review_notes", sa.String(), nullable=True),
        sa.Column("primary_artifact_id", sa.Uuid(), nullable=True),
        sa.Column("submitted_at", sa.DateTime(), nullable=True),
        sa.Column("reviewed_at", sa.DateTime(), nullable=True),
        sa.Column("reviewed_by_agent_id", sa.Uuid(), nullable=True),
        sa.Column("reviewed_by_user_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["board_id"], ["boards.id"]),
        sa.ForeignKeyConstraint(["task_id"], ["tasks.id"]),
        sa.ForeignKeyConstraint(["created_by_agent_id"], ["agents.id"]),
        sa.ForeignKeyConstraint(["created_by_user_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["reviewed_by_agent_id"], ["agents.id"]),
        sa.ForeignKeyConstraint(["reviewed_by_user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_task_evidence_packets_board_id", "task_evidence_packets", ["board_id"])
    op.create_index("ix_task_evidence_packets_task_id", "task_evidence_packets", ["task_id"])
    op.create_index(
        "ix_task_evidence_packets_created_by_agent_id",
        "task_evidence_packets",
        ["created_by_agent_id"],
    )
    op.create_index(
        "ix_task_evidence_packets_created_by_user_id",
        "task_evidence_packets",
        ["created_by_user_id"],
    )
    op.create_index("ix_task_evidence_packets_task_class", "task_evidence_packets", ["task_class"])
    op.create_index("ix_task_evidence_packets_status", "task_evidence_packets", ["status"])
    op.create_index(
        "ix_task_evidence_packets_primary_artifact_id",
        "task_evidence_packets",
        ["primary_artifact_id"],
    )
    op.create_index(
        "ix_task_evidence_packets_reviewed_by_agent_id",
        "task_evidence_packets",
        ["reviewed_by_agent_id"],
    )
    op.create_index(
        "ix_task_evidence_packets_reviewed_by_user_id",
        "task_evidence_packets",
        ["reviewed_by_user_id"],
    )

    op.create_table(
        "task_evidence_artifacts",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("packet_id", sa.Uuid(), nullable=False),
        sa.Column("task_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("label", sa.String(), nullable=False),
        sa.Column("workspace_agent_id", sa.Uuid(), nullable=True),
        sa.Column("workspace_agent_name", sa.String(), nullable=True),
        sa.Column("workspace_root_key", sa.String(), nullable=True),
        sa.Column("relative_path", sa.String(), nullable=True),
        sa.Column("display_path", sa.String(), nullable=True),
        sa.Column("origin_kind", sa.String(), nullable=True),
        sa.Column(
            "is_primary",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["packet_id"], ["task_evidence_packets.id"]),
        sa.ForeignKeyConstraint(["task_id"], ["tasks.id"]),
        sa.ForeignKeyConstraint(["workspace_agent_id"], ["agents.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_task_evidence_artifacts_packet_id", "task_evidence_artifacts", ["packet_id"]
    )
    op.create_index("ix_task_evidence_artifacts_task_id", "task_evidence_artifacts", ["task_id"])
    op.create_index("ix_task_evidence_artifacts_kind", "task_evidence_artifacts", ["kind"])
    op.create_index(
        "ix_task_evidence_artifacts_workspace_agent_id",
        "task_evidence_artifacts",
        ["workspace_agent_id"],
    )
    op.create_index(
        "ix_task_evidence_artifacts_workspace_root_key",
        "task_evidence_artifacts",
        ["workspace_root_key"],
    )
    op.create_index(
        "ix_task_evidence_artifacts_origin_kind",
        "task_evidence_artifacts",
        ["origin_kind"],
    )
    op.create_index(
        "ix_task_evidence_artifacts_is_primary",
        "task_evidence_artifacts",
        ["is_primary"],
    )

    op.create_table(
        "task_evidence_checks",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("packet_id", sa.Uuid(), nullable=False),
        sa.Column("task_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("label", sa.String(), nullable=False),
        sa.Column(
            "status",
            sa.String(),
            nullable=False,
            server_default=sa.text("'not_run'"),
        ),
        sa.Column("command", sa.String(), nullable=True),
        sa.Column("result_summary", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["packet_id"], ["task_evidence_packets.id"]),
        sa.ForeignKeyConstraint(["task_id"], ["tasks.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_task_evidence_checks_packet_id", "task_evidence_checks", ["packet_id"])
    op.create_index("ix_task_evidence_checks_task_id", "task_evidence_checks", ["task_id"])
    op.create_index("ix_task_evidence_checks_kind", "task_evidence_checks", ["kind"])
    op.create_index("ix_task_evidence_checks_status", "task_evidence_checks", ["status"])


def downgrade() -> None:
    op.drop_table("task_evidence_checks")
    op.drop_table("task_evidence_artifacts")
    op.drop_table("task_evidence_packets")

    op.drop_index("ix_tasks_closure_mode", table_name="tasks")
    op.drop_index("ix_tasks_task_class", table_name="tasks")
    op.drop_column("tasks", "lead_spot_check_required")
    op.drop_column("tasks", "required_check_kinds")
    op.drop_column("tasks", "required_artifact_kinds")
    op.drop_column("tasks", "closure_mode")
    op.drop_column("tasks", "task_class")
