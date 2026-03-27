"""add task_id to board_memory

Revision ID: d2e3f4a5b6c7
Revises: c1d2e3f4a5b6
Create Date: 2026-03-27 04:30:00.000000

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "d2e3f4a5b6c7"
down_revision = "c1d2e3f4a5b6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "board_memory",
        sa.Column("task_id", sa.UUID(), nullable=True),
    )
    op.create_foreign_key(
        "fk_board_memory_task_id_tasks",
        "board_memory",
        "tasks",
        ["task_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index("ix_board_memory_task_id", "board_memory", ["task_id"])


def downgrade() -> None:
    op.drop_index("ix_board_memory_task_id", table_name="board_memory")
    op.drop_constraint(
        "fk_board_memory_task_id_tasks", "board_memory", type_="foreignkey"
    )
    op.drop_column("board_memory", "task_id")
