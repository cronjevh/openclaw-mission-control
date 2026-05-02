# Task Creation Guide

## Required Fields for Every Task

### task_class (mandatory)
One of the following values:
- `code_deterministic` — Pure code/script generation with deterministic output
- `ops_integration` — Integration with external systems, APIs, or infrastructure
- `docs_content` — Documentation, planning, analysis, design documents
- `design_exploratory` — Design, architecture, or exploratory work (evaluate.json + wrapper)
- `component_test` — Test scripts that validate existing components
- `workspace_config` — Modifications to workspace files (AGENTS.md, SOUL.md, etc.)

### verification_artifact_shape (mandatory)
Specifies the expected verification artifact structure:

| task_class | Expected artifacts | Execution pattern |
|------------|-------------------|-------------------|
| `code_deterministic` | `verify-<TASK_ID>.ps1` | Runtime execution (`& bash`, `& pwsh -File`, `pytest`) |
| `ops_integration` | `verify-<TASK_ID>.ps1` | Runtime against real/dry-run APIs |
| `docs_content` | `evaluate-<TASK_ID>.json` + `verify-<TASK_ID>.ps1` | Content checks only; wrapper loads judge spec |
| `design_exploratory` | `evaluate-<TASK_ID>.json` + `verify-<TASK_ID>.ps1` | Content checks; same pattern as docs_content |
| `component_test` | `verify-<TASK_ID>.ps1` | `-SelfTest` flag with `& pwsh -File` isolation |
| `workspace_config` | `verify-<TASK_ID>.ps1` | Content checks (`Get-Content`, `-match`, `Test-Path`) |

### target_workspace_path (for workspace_config only)
The exact absolute path of the workspace file to modify (e.g., `/home/user/.openclaw/workspace/AGENTS.md`).

## Anti-Cheat Reminders per Task Class

### docs_content / design_exploratory
- **Do NOT create executable deliverables** unless explicitly required
- Prototypes should be markdown code blocks
- Verification must use content checks, not runtime execution

### code_deterministic / ops_integration
- Executable deliverables expected and required
- Runtime execution mandatory
- Process isolation required

### component_test
- Must include `-SelfTest` parameter
- Invoke with `& pwsh -File` (not dot-sourced)

### workspace_config
- Modified file IS the deliverable
- Content checks only; no LLM judging needed

## Hybrid Deliverables

If a task requires both documentation and executables:
- **Option A:** Split into two separate tasks
- **Option B:** Use `code_deterministic` or `ops_integration` with explicit acceptance criteria

**Never** allow `docs_content` to produce executable files — causes verifier misclassification.
