# ruff: noqa: INP001
"""Integration tests for utility jobs API."""

from __future__ import annotations

from pathlib import Path
from uuid import UUID, uuid4

import pytest
from fastapi import APIRouter, FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlmodel import SQLModel
from sqlmodel.ext.asyncio.session import AsyncSession

from app.api.deps import require_org_member
from app.api.utility_jobs import router as utility_jobs_router
from app.db.session import get_session
from app.models.organization_members import OrganizationMember
from app.models.organizations import Organization
from app.models.utility_jobs import UtilityJob
from app.services.organizations import OrganizationContext


async def _make_engine() -> AsyncEngine:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.connect() as conn, conn.begin():
        await conn.run_sync(SQLModel.metadata.create_all)
    return engine


def _build_test_app(
    session_maker: async_sessionmaker[AsyncSession],
    *,
    organization: Organization,
) -> FastAPI:
    app = FastAPI()
    api_v1 = APIRouter(prefix="/api/v1")
    api_v1.include_router(utility_jobs_router)
    app.include_router(api_v1)

    async def _override_get_session() -> AsyncSession:
        async with session_maker() as session:
            yield session

    async def _override_require_org_member() -> OrganizationContext:
        return OrganizationContext(
            organization=organization,
            member=OrganizationMember(
                organization_id=organization.id,
                user_id=uuid4(),
                role="member",
                all_boards_read=True,
                all_boards_write=False,
            ),
        )

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[require_org_member] = _override_require_org_member
    return app


async def _seed_org_and_job(
    session: AsyncSession,
    *,
    job_id: UUID,
) -> tuple[Organization, UtilityJob]:
    organization = Organization(id=uuid4(), name="Test Org")
    job = UtilityJob(
        id=job_id,
        organization_id=organization.id,
        name="Test Job",
        enabled=True,
        cron_expression="0 8 * * *",
        script_key="test_script",
    )
    session.add(organization)
    session.add(job)
    await session.commit()
    return organization, job


@pytest.mark.asyncio
async def test_get_job_logs_returns_recent_lines(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    engine = await _make_engine()
    session_maker = async_sessionmaker(
        engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )

    job_id = UUID("00000000-0000-0000-0000-000000000001")
    async with session_maker() as session:
        organization, job = await _seed_org_and_job(session, job_id=job_id)

    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    monkeypatch.setenv("MC_UTILITY_JOB_LOG_DIR", str(log_dir))

    prefix = f"job-{str(job_id)[:8]}."
    log_file = log_dir / f"{prefix}20260506.log"
    log_file.write_text("line1\nline2\nline3\n", encoding="utf-8")

    # Re-import to pick up the new LOG_DIR from env
    from app.api import utility_jobs as utility_jobs_module

    monkeypatch.setattr(utility_jobs_module, "LOG_DIR", str(log_dir))

    app = _build_test_app(session_maker, organization=organization)

    try:
        async with AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        ) as client:
            response = await client.get(
                f"/api/v1/jobs/{job_id}/logs?limit=2",
            )
            assert response.status_code == 200
            assert response.json() == ["line2", "line3"]
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_get_job_logs_returns_empty_when_no_logs(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    engine = await _make_engine()
    session_maker = async_sessionmaker(
        engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )

    job_id = UUID("00000000-0000-0000-0000-000000000002")
    async with session_maker() as session:
        organization, _job = await _seed_org_and_job(session, job_id=job_id)

    log_dir = tmp_path / "logs"
    log_dir.mkdir()

    from app.api import utility_jobs as utility_jobs_module

    monkeypatch.setattr(utility_jobs_module, "LOG_DIR", str(log_dir))

    app = _build_test_app(session_maker, organization=organization)

    try:
        async with AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        ) as client:
            response = await client.get(
                f"/api/v1/jobs/{job_id}/logs",
            )
            assert response.status_code == 200
            assert response.json() == []
    finally:
        await engine.dispose()
