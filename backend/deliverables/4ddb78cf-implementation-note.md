# MVP Implementation Complete — hide_done_after_days

**Task**: 4ddb78cf-b203-4278-b29e-ba2d4985d9f2
**Date**: 2026-04-12
**Agent**: Vulcan

---

## Scope Completed

All 4 scope items from Athena analysis implemented:

### 1. DB Migration ✅
- Added `hide_done_after_days` INTEGER NULL to `boards` table
- Added composite index `ix_tasks_board_id_status_updated_at` on `tasks(board_id, status, updated_at)`
- Migration file: `migrations/versions/d4e5f6a7b8c9_add_hide_done_after_days_to_boards_and_task_index.py`
- Applied successfully via Alembic (`alembic upgrade head`)

### 2. API Schema ✅
- Updated `BoardUpdate` schema to accept optional `hide_done_after_days: int | None`
- Field also added to `BoardBase` (thus included in BoardRead responses)
- File: `app/schemas/boards.py`

### 3. Handler Logic ✅
- Modified `_task_list_statement` in `app/api/tasks.py` to filter out old done tasks when `hide_done_after_days > 0`
- Modified `build_board_snapshot` in `app/services/board_snapshot.py` to apply same filter
- Filter uses `(Task.status == "done") & (Task.updated_at < cutoff)` exclusion
- Cutoff = `datetime.now(timezone.utc) - timedelta(days=hide_done_after_days)`

### 4. Tests ✅
- Created `tests/test_hide_done_after_days.py` with 4 tests:
  - `test_task_list_statement_excludes_old_done_when_filter_set` — integration test verifies list_tasks filtering
  - `test_task_list_statement_no_filter_when_null_or_zero` — null/0 treated as no filter
  - `test_board_update_schema_accepts_hide_done_after_days` — schema validation
  - `test_snapshot_uses_board_hide_done_after_days` — snapshot filtering verified
- All tests pass (4/4)

---

## Behavior Summary

| hide_done_after_days | Effect |
|----------------------|--------|
| `null` or omitted | No filtering; all tasks returned (default) |
| `0` | No filtering (0 means no threshold) |
| `> 0` (e.g., 30) | Tasks with `status="done"` AND `updated_at < now()-30d` are excluded from list_tasks and snapshot results |

**Note**: `updated_at` is used as proxy for completion time (it updates on status changes).

---

## Files Changed

1. `app/models/boards.py` — added `hide_done_after_days` field
2. `app/schemas/boards.py` — added field to BoardBase/BoardUpdate
3. `app/api/tasks.py` — updated `_task_list_statement` with filter logic
4. `app/services/board_snapshot.py` — added filter to `build_board_snapshot`
5. `migrations/versions/d4e5f6a7b8c9_add_hide_done_after_days_to_boards_and_task_index.py` — new migration
6. `tests/test_hide_done_after_days.py` — test suite

---

## Verification

- Migration applied: `alembic upgrade head` completed without error
- Schema change confirmed: `boards` table now has `hide_done_after_days` column
- Index created: `ix_tasks_board_id_status_updated_at` exists on tasks table
- Tests pass: `pytest tests/test_hide_done_after_days.py -v` → 4 passed
- No deprecation warnings (used `datetime.now(timezone.utc)`)

---

## Usage Example

```python
# Set on board via PATCH /boards/{id}
PATCH /api/v1/boards/{board_id}
{
  "hide_done_after_days": 30
}

# Then list_tasks automatically hides done tasks older than 30 days
GET /api/v1/boards/{board_id}/tasks?status=done  # will only show recent done tasks
GET /api/v1/boards/{board_id}/tasks  # mixed statuses, old done hidden
```

---

**Ready for lead review and closure.**
