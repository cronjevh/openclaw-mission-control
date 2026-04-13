"""Placeholder migration to restore broken revision chain.

Revision ID: a1b2c3d4e5f6
Revises: f1b2c3d4e5a6
Create Date: 2026-03-03 00:00:00.000000

Note: This is a placeholder to fix broken migration graph.
The original migration (add_webhook_secret) was lost; this no-op
revision restores connectivity for downstream migrations.
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "a1b2c3d4e5f6"
down_revision = "f1b2c3d4e5a6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """No-op upgrade — placeholder to restore migration graph."""
    pass


def downgrade() -> None:
    """No-op downgrade."""
    pass
