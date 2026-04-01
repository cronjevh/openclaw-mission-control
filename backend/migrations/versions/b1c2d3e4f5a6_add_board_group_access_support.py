"""add board group access support to organization member/invite access

Revision ID: b1c2d3e4f5a6
Revises: e4f5a6b7c8d9
Create Date: 2026-03-11 06:30:00.000000
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "b1c2d3e4f5a6"
down_revision = "e4f5a6b7c8d9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """Add board-group access support for fresh installs and older databases."""
    _upgrade_board_access_table(
        table_name="organization_board_access",
        owner_column="organization_member_id",
        legacy_constraint="uq_org_board_access_member_board",
        new_constraint="uq_org_board_access_member_board_group",
    )
    _upgrade_board_access_table(
        table_name="organization_invite_board_access",
        owner_column="organization_invite_id",
        legacy_constraint="uq_org_invite_board_access_invite_board",
        new_constraint="uq_org_invite_board_access_invite_board_group",
    )


def downgrade() -> None:
    """Best-effort reversal for locally created schemas."""
    _downgrade_board_access_table(
        table_name="organization_invite_board_access",
        owner_column="organization_invite_id",
        legacy_constraint="uq_org_invite_board_access_invite_board",
        new_constraint="uq_org_invite_board_access_invite_board_group",
    )
    _downgrade_board_access_table(
        table_name="organization_board_access",
        owner_column="organization_member_id",
        legacy_constraint="uq_org_board_access_member_board",
        new_constraint="uq_org_board_access_member_board_group",
    )


def _upgrade_board_access_table(
    *,
    table_name: str,
    owner_column: str,
    legacy_constraint: str,
    new_constraint: str,
) -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    if not _has_column(inspector, table_name, "board_group_id"):
        op.add_column(table_name, sa.Column("board_group_id", sa.Uuid(), nullable=True))
        inspector = sa.inspect(bind)

    op.alter_column(table_name, "board_id", existing_type=sa.Uuid(), nullable=True)

    index_name = f"ix_{table_name}_board_group_id"
    if not _has_index(inspector, table_name, index_name):
        op.create_index(index_name, table_name, ["board_group_id"], unique=False)
        inspector = sa.inspect(bind)

    fk_name = f"{table_name}_board_group_id_fkey"
    if not _has_foreign_key(inspector, table_name, ["board_group_id"]):
        op.create_foreign_key(
            fk_name,
            table_name,
            "board_groups",
            ["board_group_id"],
            ["id"],
        )
        inspector = sa.inspect(bind)

    if _has_unique_constraint(inspector, table_name, legacy_constraint):
        op.drop_constraint(legacy_constraint, table_name, type_="unique")
        inspector = sa.inspect(bind)

    if not _has_unique_constraint(inspector, table_name, new_constraint):
        op.create_unique_constraint(
            new_constraint,
            table_name,
            [owner_column, "board_id", "board_group_id"],
        )


def _downgrade_board_access_table(
    *,
    table_name: str,
    owner_column: str,
    legacy_constraint: str,
    new_constraint: str,
) -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    if _has_unique_constraint(inspector, table_name, new_constraint):
        op.drop_constraint(new_constraint, table_name, type_="unique")
        inspector = sa.inspect(bind)

    if not _has_unique_constraint(inspector, table_name, legacy_constraint):
        op.create_unique_constraint(
            legacy_constraint,
            table_name,
            [owner_column, "board_id"],
        )
        inspector = sa.inspect(bind)

    fk_name = f"{table_name}_board_group_id_fkey"
    if _has_foreign_key(inspector, table_name, ["board_group_id"]):
        op.drop_constraint(fk_name, table_name, type_="foreignkey")
        inspector = sa.inspect(bind)

    index_name = f"ix_{table_name}_board_group_id"
    if _has_index(inspector, table_name, index_name):
        op.drop_index(index_name, table_name=table_name)
        inspector = sa.inspect(bind)

    if _has_column(inspector, table_name, "board_group_id"):
        op.drop_column(table_name, "board_group_id")
        inspector = sa.inspect(bind)

    op.alter_column(table_name, "board_id", existing_type=sa.Uuid(), nullable=False)


def _has_column(inspector: sa.Inspector, table_name: str, column_name: str) -> bool:
    return any(column["name"] == column_name for column in inspector.get_columns(table_name))


def _has_index(inspector: sa.Inspector, table_name: str, index_name: str) -> bool:
    return any(index["name"] == index_name for index in inspector.get_indexes(table_name))


def _has_unique_constraint(
    inspector: sa.Inspector,
    table_name: str,
    constraint_name: str,
) -> bool:
    return any(
        constraint["name"] == constraint_name
        for constraint in inspector.get_unique_constraints(table_name)
    )


def _has_foreign_key(
    inspector: sa.Inspector,
    table_name: str,
    constrained_columns: list[str],
) -> bool:
    return any(
        foreign_key.get("constrained_columns") == constrained_columns
        for foreign_key in inspector.get_foreign_keys(table_name)
    )
