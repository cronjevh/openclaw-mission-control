"""Add cadence_minutes to boards for per-board cron scheduling.

Revision ID: 44e08f3513b9
Revises: 349673082ef8
Create Date: 2026-04-20 09:20:00.000000

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "44e08f3513b9"
down_revision = "349673082ef8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """Add cadence_minutes column to boards (nullable integer, positive)."""
    op.add_column(
        "boards",
        sa.Column("cadence_minutes", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    """Remove cadence_minutes column."""
    op.drop_column("boards", "cadence_minutes")
