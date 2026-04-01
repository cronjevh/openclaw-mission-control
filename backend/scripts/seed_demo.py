"""Seed a minimal local demo dataset for manual development flows."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from uuid import uuid4

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))


async def run() -> None:
    """Populate the local database with a demo gateway, board, user, and agent."""
    from app.db.session import async_session_maker, init_db
    from app.models.agents import Agent
    from app.models.boards import Board
    from app.models.gateways import Gateway
    from app.models.organizations import Organization
    from app.models.users import User

    await init_db()
    async with async_session_maker() as session:
        # Get or create org
        from app.models.organizations import Organization
        org = Organization(
            name="Demo Organization",
            slug="demo-org",
            created_by_user_id=None,
        )
        session.add(org)
        await session.commit()
        await session.refresh(org)

        demo_workspace_root = BACKEND_ROOT / ".tmp" / "openclaw-demo"
        gateway = Gateway(
            organization_id=org.id,
            name="Demo Gateway",
            url="ws://host.docker.internal:18789",
            token="demo-token",
            workspace_root=str(demo_workspace_root),
        )
        session.add(gateway)
        await session.commit()
        await session.refresh(gateway)

        board = Board(
            organization_id=org.id,
            name="Demo Board",
            slug="demo-board",
            gateway_id=gateway.id,
            board_type="goal",
            objective="Demo objective",
            success_metrics={"demo": True},
        )
        session.add(board)
        await session.commit()
        await session.refresh(board)

        user = User(
            clerk_user_id=f"demo-{uuid4()}",
            email="demo@example.com",
            name="Demo Admin",
            is_super_admin=True,
        )
        session.add(user)
        await session.commit()
        await session.refresh(user)

        lead = Agent(
            gateway_id=gateway.id,
            board_id=board.id,
            name="Demo Lead Agent",
            status="offline",
        )
        session.add(lead)
        await session.commit()
        print(f"✓ Seeded: Gateway {gateway.id}, Board {board.id}, User {user.id}, Agent {lead.id}")


if __name__ == "__main__":
    asyncio.run(run())
