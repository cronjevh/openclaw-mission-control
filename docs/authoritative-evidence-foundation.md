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

## Common Failure Modes and Fixes

### 1. Integration-like task has no runtime checks

**Symptom:** Preflight fails: "Integration-like task has no runtime or behavior-exercising checks; verification is static-only."

**Cause:** Verification script only checks that files exist (`Test-Path`) but doesn't execute anything.

**Fix:**
- For `code_deterministic`: Add `& pwsh -File deliverables/script.ps1 -Test` or equivalent
- For `ops_integration`: Add actual API call or dry-run execution
- For `component_test`: Add `-SelfTest` with process isolation

### 2. Verification relies on file presence only

**Symptom:** Same as above — script uses `Test-Path` or `Get-ChildItem` without execution.

**Fix:** Add runtime execution of the deliverable. File existence is necessary but not sufficient.

### 3. Task appears documentation but includes executables

**Symptom:** Preflight fails: "Task appears to be documentation but includes executable files."

**Cause:** Task title says "document" or "report" but verification script runs `pytest`, `node`, etc.

**Fix:**
- If the task IS documentation, switch to `docs_content` pattern: create `evaluate-*.json` + `verify.ps1` wrapper
- If the task IS code, retitle to remove "document" wording and use appropriate task class

### 4. Start-Process loses arguments on Linux

**Symptom:** `Start-Process` with `-ArgumentList` works on Windows but fails on Linux (WSL) because arguments are not passed correctly.

**Cause:** `Start-Process` in PowerShell on Linux drops quoted arguments when the file is a `.sh` script.

**Fix:**
```powershell
# WRONG (loses arguments on Linux)
Start-Process -FilePath "$script.sh" -ArgumentList @('arg with spaces')

# CORRECT (use call operator for native commands)
& bash "$script" 'arg with spaces'
```

### 5. Missing `-Append` on `Start-Process` output capture

**Symptom:** `Start-Process` throws "A parameter cannot be found that matches parameter name 'Append'."

**Cause:** `-RedirectStandardOutput` has no `-Append` parameter.

**Fix:**
```powershell
# WRONG
Start-Process -RedirectStandardOutput $log -Append

# CORRECT (use separate log or redirect)
& bash "$script" args > $log 2>&1
```

### 6. Unbound variables abort bash scripts

**Symptom:** Bash verification script exits immediately with "unbound variable" error.

**Cause:** `set -euo pipefail` is enabled and a sourced wrapper references `${RADARR_API_KEY}` which is unset.

**Fix:**
```powershell
# In PowerShell verification script, export dummies before calling bash:
$env:RADARR_API_KEY = "dry-run-test-key"
& bash "$script" args
```

### 7. Wrong target path for workspace config

**Symptom:** Verification checks the wrong file path (e.g., worker's workspace instead of main workspace).

**Cause:** Confusion between worker workspace and main workspace paths.

**Fix:**
- Workspace config tasks modify files in the **main OpenClaw workspace** (`/home/cronjev/.openclaw/workspace/AGENTS.md`)
- Verification must check that exact path, not the worker's copy
- If the task says "Add to AGENTS.md" without specifying a workspace, use the main workspace

**Example correct path:**
```powershell
# CHECK the actual modified file in the main workspace
$path = "/home/cronjev/.openclaw/workspace/AGENTS.md"
$content = Get-Content $path -Raw
```

---

## Verification Pattern Decision Tree

```
Is there an executable component?
├─ YES → code_deterministic
│   └─ Pattern: Run deliverable with test inputs, validate exit code
│
├─ NO → Does it integrate with external systems (API, infra)?
│   ├─ YES → ops_integration
│   │   └─ Pattern: Runtime against test/dry-run APIs, process isolation
│   └─ NO → Is it pure documentation/design?
│       ├─ YES → docs_content
│       │   └─ Pattern: evaluate-*.json (judge spec) + verify wrapper
│       └─ NO → Is it a detect-only monitor/health-check?
│           ├─ YES → component_test
│           │   └─ Pattern: -SelfTest with & pwsh -File process isolation
│           └─ NO → workspace_config (modifies workspace files)
│               └─ Pattern: Content checks (Get-Content, -match) against modified file
```

---

## Quick Reference Table

| Task Class | Deliverable | Verification | Runtime Required | Preflight Exemptions |
|------------|-------------|--------------|------------------|---------------------|
| `code_deterministic` | Executable code/script | Execute with test inputs, check exit code | Yes (process isolation) | None |
| `ops_integration` | Integration code/config | Execute against test/dry-run API | Yes (process isolation) | None |
| `docs_content` | Markdown/design doc | LLM judge via evaluate-*.json + wrapper | Yes (LLM invocation) | None |
| `design_exploratory` | Design/architecture doc | LLM judge via evaluate-*.json + wrapper | Yes (LLM invocation) | None |
| `component_test` | Monitor/diagnostic script | Self-test mode (`-SelfTest`) | Yes (process isolation) | None |
| `workspace_config` | Modified workspace file | Content checks (Get-Content, -match) | No | Static-only allowed |
