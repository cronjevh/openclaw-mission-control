"""add notifications table for user-scoped task event alerts

Revision ID: e3f0a1b2c4d5
Revises: d7e8f9a0b1c2
Create Date: 2026-02-23 15:00:00.000000

Notifications are created when:
- A task's status changes (notify the task creator)
- A comment is posted on a task (notify the task creator)
- A user is @mentioned in a comment (notify the mentioned user)
"""

from __future__ import annotations

import sqlalchemy as sa
import sqlmodel
from alembic import op

# revision identifiers, used by Alembic.
revision = "e3f0a1b2c4d5"
down_revision = "d7e8f9a0b1c2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "notifications",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("org_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("board_id", sa.Uuid(), nullable=True),
        sa.Column("task_id", sa.Uuid(), nullable=True),
        sa.Column("type", sqlmodel.AutoString(), nullable=False),
        sa.Column("title", sqlmodel.AutoString(), nullable=False),
        sa.Column("body", sqlmodel.AutoString(), nullable=False),
        sa.Column("read", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["board_id"], ["boards.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["org_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["task_id"], ["tasks.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_notifications_user_id"), "notifications", ["user_id"])
    op.create_index(op.f("ix_notifications_org_id"), "notifications", ["org_id"])
    op.create_index(op.f("ix_notifications_board_id"), "notifications", ["board_id"])
    op.create_index(op.f("ix_notifications_read"), "notifications", ["read"])


def downgrade() -> None:
    op.drop_index(op.f("ix_notifications_read"), table_name="notifications")
    op.drop_index(op.f("ix_notifications_board_id"), table_name="notifications")
    op.drop_index(op.f("ix_notifications_org_id"), table_name="notifications")
    op.drop_index(op.f("ix_notifications_user_id"), table_name="notifications")
    op.drop_table("notifications")
