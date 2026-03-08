"""Assembles merged system-prompt context for a group-level agent."""

from __future__ import annotations

from uuid import UUID

from sqlmodel.ext.asyncio.session import AsyncSession

from app.models.board_secrets import BoardSecret
from app.models.boards import Board
from app.core.encryption import decrypt_secret

MAX_DESCRIPTION_CHARS = 2000


async def build_group_context_block(session: AsyncSession, *, group_id: UUID) -> str:
    """Return a markdown string injected into the group agent's system prompt.

    Format::

        ## Sister Board: <board name>
        **Description:** <trimmed description>
        **Credentials:**
        - KEY: value
        ...

    One section per board in the group.
    """
    boards = await Board.objects.filter_by(board_group_id=group_id).all(session)
    if not boards:
        return ""

    sections: list[str] = []
    for board in boards:
        desc = (board.objective or board.description or "No description.").strip()
        if len(desc) > MAX_DESCRIPTION_CHARS:
            desc = desc[:MAX_DESCRIPTION_CHARS] + "... (trimmed)"

        secrets = await BoardSecret.objects.filter_by(board_id=board.id).all(session)
        creds_lines: list[str] = []
        for s in secrets:
            try:
                val = decrypt_secret(s.encrypted_value)
            except Exception:
                val = "(decryption error)"
            creds_lines.append(f"- {s.key}: {val}")
        creds_block = "\n".join(creds_lines) if creds_lines else "  (none)"

        sections.append(
            f"## Sister Board: {board.name}\n"
            f"**Board ID:** {board.id}\n"
            f"**Description:** {desc}\n"
            f"**Credentials:**\n{creds_block}"
        )

    return "\n\n---\n\n".join(sections)
