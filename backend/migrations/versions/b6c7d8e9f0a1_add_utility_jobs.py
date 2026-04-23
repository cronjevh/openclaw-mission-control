"""Add utility jobs table.

Revision ID: b6c7d8e9f0a1
Revises: 44e08f3513b9
Create Date: 2026-04-23 12:00:00.000000

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision = "b6c7d8e9f0a1"
down_revision = "44e08f3513b9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """Create utility_jobs table."""
    op.create_table(
        "utility_jobs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("organization_id", sa.Uuid(), nullable=False),
        sa.Column("board_id", sa.Uuid(), nullable=True),
        sa.Column("agent_id", sa.Uuid(), nullable=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("cron_expression", sa.String(), nullable=False),
        sa.Column("script_key", sa.String(), nullable=False),
        sa.Column("args", postgresql.JSON(astext_type=sa.Text()), nullable=True),
        sa.Column("crontab_path", sa.String(), nullable=True),
        sa.Column("last_generated_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"]),
        sa.ForeignKeyConstraint(["board_id"], ["boards.id"]),
        sa.ForeignKeyConstraint(["organization_id"], ["organizations.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_utility_jobs_agent_id"), "utility_jobs", ["agent_id"], unique=False)
    op.create_index(op.f("ix_utility_jobs_board_id"), "utility_jobs", ["board_id"], unique=False)
    op.create_index(op.f("ix_utility_jobs_enabled"), "utility_jobs", ["enabled"], unique=False)
    op.create_index(op.f("ix_utility_jobs_name"), "utility_jobs", ["name"], unique=False)
    op.create_index(
        op.f("ix_utility_jobs_organization_id"),
        "utility_jobs",
        ["organization_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_utility_jobs_script_key"),
        "utility_jobs",
        ["script_key"],
        unique=False,
    )


def downgrade() -> None:
    """Drop utility_jobs table."""
    op.drop_index(op.f("ix_utility_jobs_script_key"), table_name="utility_jobs")
    op.drop_index(op.f("ix_utility_jobs_organization_id"), table_name="utility_jobs")
    op.drop_index(op.f("ix_utility_jobs_name"), table_name="utility_jobs")
    op.drop_index(op.f("ix_utility_jobs_enabled"), table_name="utility_jobs")
    op.drop_index(op.f("ix_utility_jobs_board_id"), table_name="utility_jobs")
    op.drop_index(op.f("ix_utility_jobs_agent_id"), table_name="utility_jobs")
    op.drop_table("utility_jobs")
