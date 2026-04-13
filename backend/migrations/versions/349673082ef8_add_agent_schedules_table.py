"""add_agent_schedules_table

Revision ID: 349673082ef8
Revises: d4e5f6a7b8c9
Create Date: 2026-04-13 15:45:21.662191

"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = '349673082ef8'
down_revision = 'd4e5f6a7b8c9'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "agent_schedules",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("agent_id", sa.Uuid(), nullable=False),
        sa.Column("board_id", sa.Uuid(), nullable=False),
        sa.Column("interval_minutes", sa.Integer(), nullable=False),
        sa.Column("cron_expression", sa.Text(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("last_updated_by", sa.Uuid(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"]),
        sa.ForeignKeyConstraint(["board_id"], ["boards.id"]),
        sa.ForeignKeyConstraint(["last_updated_by"], ["agents.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_agent_schedules_agent_id", "agent_schedules", ["agent_id"])
    op.create_index("ix_agent_schedules_board_id", "agent_schedules", ["board_id"])
    op.create_index("ix_agent_schedules_enabled", "agent_schedules", ["enabled"])
    op.create_index("ix_agent_schedules_interval_minutes", "agent_schedules", ["interval_minutes"])
    # Unique constraint: one schedule per agent
    op.create_unique_constraint("uq_agent_schedules_agent_id", "agent_schedules", ["agent_id"])


def downgrade() -> None:
    op.drop_constraint("uq_agent_schedules_agent_id", "agent_schedules", type_="unique")
    op.drop_index("ix_agent_schedules_interval_minutes", table_name="agent_schedules")
    op.drop_index("ix_agent_schedules_enabled", table_name="agent_schedules")
    op.drop_index("ix_agent_schedules_board_id", table_name="agent_schedules")
    op.drop_index("ix_agent_schedules_agent_id", table_name="agent_schedules")
    op.drop_table("agent_schedules")
