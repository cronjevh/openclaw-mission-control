"""Add hide_done_after_days to boards and composite index on tasks for done filtering.

Revision ID: d4e5f6a7b8c9
Revises: f7c1d2e3a4b5
Create Date: 2026-04-12 19:00:00.000000

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "d4e5f6a7b8c9"
down_revision = "f7c1d2e3a4b5"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """Add hide_done_after_days column to boards and create composite index on tasks."""
    # 1. Add hide_done_after_days to boards (nullable integer)
    op.add_column(
        "boards",
        sa.Column("hide_done_after_days", sa.Integer(), nullable=True),
    )

    # 2. Create composite index on tasks(board_id, status, updated_at)
    # This supports efficient filtering of done tasks by board and recency.
    op.create_index(
        "ix_tasks_board_id_status_updated_at",
        "tasks",
        ["board_id", "status", "updated_at"],
    )


def downgrade() -> None:
    """Remove hide_done_after_days column and composite index."""
    op.drop_index("ix_tasks_board_id_status_updated_at", table_name="tasks")
    op.drop_column("boards", "hide_done_after_days")
