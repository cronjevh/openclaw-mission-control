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
  - `workspace_config` — workspace prompt, guideline, or config file updates (AGENTS.md, SOUL.md, etc.)
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

---

## Task Classes and Verification Patterns

### `code_deterministic`

**Definition:** Tasks that produce deterministic code or configuration with testable outputs.

**Verification Pattern:**
- Run deliverable with predetermined test inputs
- Validate exit code (0 = success, non-zero = failure)
- Capture stdout/stderr as evidence
- Process isolation required (`& pwsh -File`, `python script.py`, etc.)

**Required artifacts:** `verify-<TASK_ID>.ps1` with runtime execution

### `ops_integration`

**Definition:** Tasks that integrate with external systems (APIs, services, infrastructure).

**Verification Pattern:**
- Invoke against real or mock API
- Use dry-run flags if available
- Validate response codes, payloads, or side-effects
- Process isolation mandatory

**Required artifacts:** `verify-<TASK_ID>.ps1` with runtime against real/dry-run APIs

### `docs_content`

**Definition:** Pure documentation, design, or planning tasks with no executable component.

**Verification Pattern:**
- `evaluate-<TASK_ID>.json` — LLM judge spec with criteria and scoring rubric
- `verify-<TASK_ID>.ps1` — wrapper that invokes LLM validation
- No runtime execution of deliverable itself

**Anti-cheat:** Do NOT create executable deliverables (`.ps1`, `.py`, `.sh`, `.js`) unless acceptance criteria explicitly require them. Prototypes should be markdown code blocks.

**Required artifacts:** `evaluate-<TASK_ID>.json` + `verify-<TASK_ID>.ps1`

### `design_exploratory`

**Definition:** Design, architecture, or exploratory work. Semantically distinct from `docs_content` — involves trade-off analysis and spike findings.

**Verification Pattern:** Same as `docs_content` — evaluate.json + wrapper with LLM judgment.

**Required artifacts:** `evaluate-<TASK_ID>.json` + `verify-<TASK_ID>.ps1`

### `component_test`

**Definition:** Detect-only scripts (monitors, diagnostics) that observe but do not mutate state.

**Verification Pattern:**
- `-SelfTest` flag with process isolation
- Internal validation (syntax check, mock data, self-diagnostic)
- Exit code 0 on successful self-test

**Required artifacts:** `verify-<TASK_ID>.ps1` with `-SelfTest` and `& pwsh -File`

### `workspace_config`

**Definition:** Modifications to workspace files (AGENTS.md, SOUL.md, etc.).

**Verification Pattern:**
- Content checks against modified file (`Get-Content`, `-match`, `Test-Path`)
- The modified workspace file IS the deliverable
- No LLM judging needed; string matching sufficient

**Required artifacts:** `verify-<TASK_ID>.ps1` with content checks

---

## Preflight Rules

1. **Runtime signals required** for `code_deterministic`, `ops_integration`, `component_test`
2. **Static-only patterns trigger rejection** unless task_class is `docs_content`, `design_exploratory`, or `workspace_config`
3. **Both exit 0 and exit 1 required** — verification must demonstrably pass AND fail
4. **Deliverable reference required** — verification script must reference actual deliverable, not just filenames
5. **Hybrid detection** — `docs_content`/`design_exploratory` tasks with executable files are rejected unless explicitly exempted

## Common Failure Modes

- Integration-like task has no runtime checks → FAIL
- Verification relies on file presence only → FAIL  
- Task is docs_content but includes executables → FAIL (hybrid confusion)
- Start-Process loses arguments on Linux → Use `& pwsh -File`
- Missing `-Append` on Start-Process → Check stderr redirection
- Unbound variables abort bash scripts → Use `set -u` or check variables
- Wrong target path for workspace config → Verify exact file path in task description
