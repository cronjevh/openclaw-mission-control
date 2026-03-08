"""Add group agent support (agents.group_id + board_groups.group_agent_id).

Revision ID: c4d5e6f7a8b9
Revises: b1a2c3d4e5f7
Create Date: 2026-03-08 08:00:00.000000
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "c4d5e6f7a8b9"
down_revision = "b1a2c3d4e5f7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Add group_id to agents table (FK → board_groups, nullable, SET NULL on delete)
    op.add_column("agents", sa.Column("group_id", sa.Uuid(), nullable=True))
    op.create_index("ix_agents_group_id", "agents", ["group_id"])
    op.create_foreign_key(
        "fk_agents_group_id_board_groups",
        "agents",
        "board_groups",
        ["group_id"],
        ["id"],
        ondelete="SET NULL",
    )

    # Add group_agent_id to board_groups table (FK → agents, nullable, SET NULL on delete)
    op.add_column("board_groups", sa.Column("group_agent_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_board_groups_group_agent_id_agents",
        "board_groups",
        "agents",
        ["group_agent_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(
        "fk_board_groups_group_agent_id_agents", "board_groups", type_="foreignkey"
    )
    op.drop_column("board_groups", "group_agent_id")

    op.drop_constraint("fk_agents_group_id_board_groups", "agents", type_="foreignkey")
    op.drop_index("ix_agents_group_id", table_name="agents")
    op.drop_column("agents", "group_id")
