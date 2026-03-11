"""add board group access support to organization member/invite access

Revision ID: b1c2d3e4f5a6
Revises: e4f5a6b7c8d9
Create Date: 2026-03-11 06:30:00.000000

Schema changes manually applied on 2026-03-11 06:33 UTC.
This migration is a no-op (schema already applied).
"""

from __future__ import annotations

# revision identifiers, used by Alembic.
revision = "b1c2d3e4f5a6"
down_revision = "e4f5a6b7c8d9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """Board group access schema already applied manually."""
    pass


def downgrade() -> None:
    """Downgrade not supported for manually applied schema."""
    pass
