# Authoritative Evidence Foundation

## What changed

This slice adds a minimal persisted evidence layer for board tasks and fixes
workspace artifact identity so review surfaces stop depending on ambiguous
comment parsing plus first-match file reads.

## Schema and API changes

- Added task closure metadata directly on `tasks`:
  - `task_class`
  - `closure_mode`
  - `required_artifact_kinds`
  - `required_check_kinds`
  - `lead_spot_check_required`
- `task_class` values:
  - `code_deterministic` — deterministic code changes with unit/integration checks
  - `design_exploratory` — design, architecture, or exploratory work
  - `ops_integration` — infrastructure, automation, or service integration
  - `docs_content` — documentation, planning, or content tasks
  - `component_test` — component-level testing with self-test mode, no live API required
- Added persisted evidence tables:
  - `task_evidence_packets`
  - `task_evidence_artifacts`
  - `task_evidence_checks`
- Added task evidence endpoints:
  - `GET /api/v1/boards/{board_id}/tasks/{task_id}/evidence-packets`
  - `POST /api/v1/boards/{board_id}/tasks/{task_id}/evidence-packets`
- Updated workspace file listing to return stable origin identity:
  - `workspace_agent_id`
  - `workspace_agent_name`
  - `workspace_root_key`
  - `relative_path`
- Updated workspace read and download endpoints to resolve exact listed
  artifacts by `workspace_root_key` plus `relative_path` while keeping the old
  `path` query compatible.

## UI behavior

- The board task detail view now shows an `Evidence` section above the existing
  deliverables surface.
- The canonical packet is the first packet returned by the backend, with
  submitted and accepted packets preferred over drafts.
- The UI surfaces:
  - packet summary
  - implementation delta
  - primary artifact
  - supporting artifacts
  - verification checks
  - origin labels such as `Original worker output`, `Lead copy`, and `Backfill`
- Comments, linked reports, and deliverables remain available as supporting
  context.

## Closure behavior

- Legacy tasks still behave the same unless `closure_mode` is set to an
  evidence-based value.
- For `closure_mode=evidence_packet`, moving a task to `done` now requires:
  - a submitted or accepted evidence packet
  - all required artifact kinds
- For `closure_mode=passing_checks`, moving a task to `done` additionally
  requires:
  - all required check kinds
  - at least one passing check for each required kind

## Verification

- Backend tests verify duplicate workspace files no longer collapse during
  read/download:
  - `backend/tests/test_workspace_files_identity.py`
- Backend tests verify evidence packets can be created and read:
  - `backend/tests/test_task_evidence_foundation.py`
- Backend tests verify evidence-gated tasks cannot move to `done` without the
  required evidence:
  - `backend/tests/test_task_evidence_foundation.py`
