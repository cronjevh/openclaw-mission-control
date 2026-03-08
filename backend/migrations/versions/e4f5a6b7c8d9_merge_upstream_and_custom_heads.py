"""merge upstream a9b1c2d3e4f7 and custom d5e6f7a8b9c0 heads

Revision ID: e4f5a6b7c8d9
Revises: a9b1c2d3e4f7, d5e6f7a8b9c0
Create Date: 2026-03-08 12:00:00.000000

"""

from __future__ import annotations

from alembic import op

# revision identifiers, used by Alembic.
revision = "e4f5a6b7c8d9"
down_revision = ("a9b1c2d3e4f7", "d5e6f7a8b9c0", "e3a1b2c4d5f6")
branch_labels = None
depends_on = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
