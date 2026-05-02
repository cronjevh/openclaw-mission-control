# Assignment Template

Use this template when creating new tasks to ensure workers have clear verification expectations.

## Required Fields

### task_class (mandatory)
One of the following values:
- `code_deterministic` — Pure code/script generation with deterministic output
- `ops_integration` — Integration with external systems, APIs, or infrastructure
- `docs_content` — Documentation, planning, analysis, design documents
- `component_test` — Test scripts that validate existing components
- `workspace_config` — Modifications to workspace files (AGENTS.md, SOUL.md, etc.)

### verification_artifact_shape (mandatory)
Specifies the expected verification artifact structure for the worker:

| task_class | Expected verification artifacts | Execution pattern |
|------------|-------------------------------|-------------------|
| `code_deterministic` | `verify-<TASK_ID>.ps1` only | Runtime execution with `& bash`, `& pwsh -File`, `pytest`, etc. |
| `ops_integration` | `verify-<TASK_ID>.ps1` only | Runtime against real/dry-run APIs or services |
| `docs_content` | `evaluate-<TASK_ID>.json` + `verify-<TASK_ID>.ps1` | Content checks only (Test-Path, Get-Content, -match); no runtime execution |
| `component_test` | `verify-<TASK_ID>.ps1` only | `-SelfTest` flag with `& pwsh -File` process isolation |
| `workspace_config` | `verify-<TASK_ID>.ps1` only | Content checks (Get-Content, -match, Test-Path) against modified file |

**Example values:**
- `"verify-<TASK_ID>.ps1 with runtime execution"`
- `"evaluate-<TASK_ID>.json + verify wrapper (content checks only)"`
- `"verify-<TASK_ID>.ps1 with -SelfTest and & pwsh -File isolation"`

### `target_workspace_path` (for workspace_config tasks only)
The exact absolute path of the workspace file to modify (e.g., `/home/cronjev/.openclaw/workspace/AGENTS.md`).

## Anti-Cheat Reminders

### For documentation tasks (`docs_content`)
- **Do NOT create executable deliverables** (`.ps1`, `.py`, `.sh`, `.js`, etc.) unless acceptance criteria explicitly require them.
- If a prototype or proof-of-concept is needed, embed it as markdown code blocks within the main document.
- Verification scripts must use content checks only — no execution of any kind.
- Deliverables must be document files: `.md`, `.json`, `.txt`, diagram code (PlantUML, Mermaid).

### For code tasks (`code_deterministic`, `ops_integration`)
- Executable deliverables are expected and required.
- Verification must include runtime execution to prove correctness.
- Use process isolation (`& pwsh -File`, `& bash`, `pytest`) — avoid dot-sourcing.

### For component tests (`component_test`)
- Scripts must include `-SelfTest` parameter.
- Invoke with `& pwsh -File` (not dot-sourced).
- Verification should run the test in isolation and check exit code.

### For workspace config tasks (`workspace_config`)
- The modified workspace file **is** the deliverable — do not write a report about it.
- Verification uses deterministic content checks (`Get-Content`, `-match`) against the actual file.
- No LLM judging needed; string matching is sufficient.

## Hybrid Deliverables

If a task naturally requires both documentation and executable components:
- **Option A**: Split into two separate tasks with appropriate `task_class` values.
- **Option B**: Explicitly set `task_class` to `code_deterministic` or `ops_integration` and adjust acceptance criteria to include both deliverable types.

**Never** allow a `docs_content` task to produce executable files — this causes verifier misclassification.

## Example Task Creation

```json
{
  "title": "Design architecture for event-driven monitoring system",
  "description": "Create a design document with component diagram and implementation plan...",
  "task_class": "docs_content",
  "verification_artifact_shape": "evaluate-<TASK_ID>.json + verify wrapper (content checks only)",
  "acceptance_criteria": [
    "Design document covers all components",
    "Implementation plan includes migration steps"
  ]
}
```

```json
{
  "title": "Implement stuck-task monitor daemon",
  "description": "Create a PowerShell script that monitors OpenClaw tasks...",
  "task_class": "code_deterministic",
  "verification_artifact_shape": "verify-<TASK_ID>.ps1 with runtime execution",
  "acceptance_criteria": [
    "Script runs without errors",
    "Detects stuck tasks within 5 minutes"
  ]
}
```
