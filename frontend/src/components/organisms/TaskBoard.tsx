"use client";

import {
  memo,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Trash2, MoveRight, X, CheckSquare, ShieldCheck } from "lucide-react";

import { TaskCard } from "@/components/molecules/TaskCard";
import { parseApiDatetime } from "@/lib/datetime";
import { cn } from "@/lib/utils";

type TaskStatus = "inbox" | "in_progress" | "review" | "done" | "blocked";
export type { TaskStatus };

type Task = {
  id: string;
  title: string;
  status: TaskStatus;
  priority: string;
  description?: string | null;
  due_at?: string | null;
  assigned_agent_id?: string | null;
  assignee?: string | null;
  approvals_pending_count?: number;
  tags?: Array<{ id: string; name: string; slug: string; color: string }>;
  depends_on_task_ids?: string[];
  blocked_by_task_ids?: string[];
  is_blocked?: boolean;
  creator_name?: string | null;
  updated_at?: string | null;
};

type TaskBoardProps = {
  tasks: Task[];
  onTaskSelect?: (task: Task) => void;
  onTaskMove?: (taskId: string, status: TaskStatus) => void | Promise<void>;
  onBulkStatusChange?: (taskIds: string[], status: TaskStatus) => Promise<void>;
  onBulkDelete?: (taskIds: string[]) => Promise<void>;
  onBulkApprove?: (taskIds: string[]) => Promise<void>;
  readOnly?: boolean;
};

type ReviewBucket = "all" | "approval_needed" | "waiting_lead" | "blocked";

const columns: Array<{
  title: string;
  status: TaskStatus;
  dot: string;
  accent: string;
  text: string;
  badge: string;
}> = [
  {
    title: "Inbox",
    status: "inbox",
    dot: "bg-[color:var(--status-todo-dot)]",
    accent: "hover:border-[color:var(--status-todo-hover-border)] hover:bg-[color:var(--status-todo-hover-bg)]",
    text: "group-hover:text-[color:var(--status-todo-text)] text-muted",
    badge: "status-todo border",
  },
  {
    title: "In Progress",
    status: "in_progress",
    dot: "bg-[color:var(--status-inprogress-dot)]",
    accent: "hover:border-[color:var(--status-inprogress-hover-border)] hover:bg-[color:var(--status-inprogress-hover-bg)]",
    text: "group-hover:text-[color:var(--status-inprogress-text)] text-muted",
    badge: "status-inprogress border",
  },
  {
    title: "Review",
    status: "review",
    dot: "bg-[color:var(--status-review-dot)]",
    accent: "hover:border-[color:var(--status-review-hover-border)] hover:bg-[color:var(--status-review-hover-bg)]",
    text: "group-hover:text-[color:var(--status-review-text)] text-muted",
    badge: "status-review border",
  },
  {
    title: "Done",
    status: "done",
    dot: "bg-[color:var(--status-done-dot)]",
    accent: "hover:border-[color:var(--status-done-hover-border)] hover:bg-[color:var(--status-done-hover-bg)]",
    text: "group-hover:text-[color:var(--status-done-text)] text-muted",
    badge: "status-done border",
  },
  {
    title: "Blocked",
    status: "blocked",
    dot: "bg-[color:var(--status-blocked-dot)]",
    accent: "hover:border-[color:var(--status-blocked-hover-border)] hover:bg-[color:var(--status-blocked-hover-bg)]",
    text: "group-hover:text-[color:var(--status-blocked-text)] text-muted",
    badge: "status-blocked border",
  },
];

/**
 * Build compact due-date UI state for a task card.
 *
 * - Returns `due: undefined` when the task has no due date (or it's invalid), so
 *   callers can omit the due-date UI entirely.
 * - Treats a task as overdue only if it is not `done` (so "Done" tasks don't
 *   keep showing as overdue forever).
 */
const resolveDueState = (
  task: Task,
): { due: string | undefined; isOverdue: boolean } => {
  const date = parseApiDatetime(task.due_at);
  if (!date) return { due: undefined, isOverdue: false };

  const dueLabel = date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });

  const isOverdue = task.status !== "done" && date.getTime() < Date.now();
  return {
    due: isOverdue ? `Overdue · ${dueLabel}` : dueLabel,
    isOverdue,
  };
};

type CardPosition = { left: number; top: number };

const KANBAN_MOVE_ANIMATION_MS = 240;
const KANBAN_MOVE_EASING = "cubic-bezier(0.2, 0.8, 0.2, 1)";

/**
 * Kanban-style task board with 4 columns.
 *
 * Notes:
 * - Uses a lightweight FLIP animation (via `useLayoutEffect`) to animate cards
 *   to their new positions when tasks move between columns.
 * - Drag interactions can temporarily fight browser-managed drag images; the
 *   animation is disabled while a card is being dragged.
 * - Respects `prefers-reduced-motion`.
 */
export const TaskBoard = memo(function TaskBoard({
  tasks,
  onTaskSelect,
  onTaskMove,
  readOnly = false,
  onBulkStatusChange,
  onBulkDelete,
  onBulkApprove,
}: TaskBoardProps) {
  const boardRef = useRef<HTMLDivElement | null>(null);
  const cardRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const prevPositionsRef = useRef<Map<string, CardPosition>>(new Map());
  const animationRafRef = useRef<number | null>(null);
  const cleanupTimeoutRef = useRef<number | null>(null);
  const animatedTaskIdsRef = useRef<Set<string>>(new Set());

  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [activeColumn, setActiveColumn] = useState<TaskStatus | null>(null);
  const [reviewBucket, setReviewBucket] = useState<ReviewBucket>("all");
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [bulkMoveTo, setBulkMoveTo] = useState<TaskStatus | null>(null);
  const [isBulkBusy, setIsBulkBusy] = useState(false);

  const selectedTasksHaveApprovals = useMemo(
    () =>
      tasks.some(
        (t) => selectedIds.has(t.id) && (t.approvals_pending_count ?? 0) > 0,
      ),
    [tasks, selectedIds],
  );

  const toggleSelect = useCallback((id: string, e: React.MouseEvent) => {
    e.stopPropagation();
    setSelectedIds((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }, []);

  const clearSelection = useCallback(() => {
    setSelectedIds(new Set());
    setBulkMoveTo(null);
  }, []);

  const handleBulkMove = useCallback(async () => {
    if (!bulkMoveTo || selectedIds.size === 0 || !onBulkStatusChange) return;
    setIsBulkBusy(true);
    try {
      await onBulkStatusChange(Array.from(selectedIds), bulkMoveTo);
      clearSelection();
    } finally {
      setIsBulkBusy(false);
    }
  }, [bulkMoveTo, selectedIds, onBulkStatusChange, clearSelection]);

  const handleBulkApprove = useCallback(async () => {
    if (selectedIds.size === 0 || !onBulkApprove) return;
    setIsBulkBusy(true);
    try {
      await onBulkApprove(Array.from(selectedIds));
      clearSelection();
    } finally {
      setIsBulkBusy(false);
    }
  }, [selectedIds, onBulkApprove, clearSelection]);

  const handleBulkDelete = useCallback(async () => {
    if (selectedIds.size === 0 || !onBulkDelete) return;
    if (!window.confirm(`Delete ${selectedIds.size} task(s)? This cannot be undone.`)) return;
    setIsBulkBusy(true);
    try {
      await onBulkDelete(Array.from(selectedIds));
      clearSelection();
    } finally {
      setIsBulkBusy(false);
    }
  }, [selectedIds, onBulkDelete, clearSelection]);

  const setCardRef = useCallback(
    (taskId: string) => (node: HTMLDivElement | null) => {
      if (node) {
        cardRefs.current.set(taskId, node);
        return;
      }
      cardRefs.current.delete(taskId);
    },
    [],
  );

  /**
   * Snapshot each card's position relative to the scroll container.
   *
   * We store these measurements so we can compute deltas (prev - next) and
   * apply the FLIP technique on the next render.
   */
  const measurePositions = useCallback((): Map<string, CardPosition> => {
    const positions = new Map<string, CardPosition>();
    const container = boardRef.current;
    const containerRect = container?.getBoundingClientRect();

    for (const [taskId, element] of cardRefs.current.entries()) {
      const rect = element.getBoundingClientRect();
      // Walk up the DOM accumulating scroll offsets so positions are
      // scroll-independent. Without this, column body scrollTop shifts cause
      // FLIP to see "moved" cards and animate them back — the scroll glitch.
      let scrollLeft = 0;
      let scrollTop = 0;
      let ancestor: HTMLElement | null = element.parentElement;
      while (ancestor && ancestor !== container) {
        scrollLeft += ancestor.scrollLeft;
        scrollTop += ancestor.scrollTop;
        ancestor = ancestor.parentElement;
      }
      positions.set(taskId, {
        left:
          containerRect && container
            ? rect.left - containerRect.left + scrollLeft
            : rect.left,
        top:
          containerRect && container
            ? rect.top - containerRect.top + scrollTop
            : rect.top,
      });
    }

    return positions;
  }, []);

  // Stable key that changes only when tasks actually reorder or change status.
  // Using `tasks` directly as a dep would refire FLIP on every React Query
  // refetch (new array reference = same data), which mistakenly treats the
  // column's scrollTop change as card movement and animates cards back up.
  const taskListKey = useMemo(
    () => tasks.map((t) => `${t.id}:${t.status}`).join(","),
    [tasks],
  );

  // Animate card reordering smoothly by applying FLIP whenever layout positions change.
  useLayoutEffect(() => {
    const cardRefsSnapshot = cardRefs.current;
    if (animationRafRef.current !== null) {
      window.cancelAnimationFrame(animationRafRef.current);
      animationRafRef.current = null;
    }
    if (cleanupTimeoutRef.current !== null) {
      window.clearTimeout(cleanupTimeoutRef.current);
      cleanupTimeoutRef.current = null;
    }
    for (const taskId of animatedTaskIdsRef.current) {
      const element = cardRefsSnapshot.get(taskId);
      if (!element) continue;
      element.style.transform = "";
      element.style.transition = "";
      element.style.willChange = "";
      element.style.position = "";
      element.style.zIndex = "";
    }
    animatedTaskIdsRef.current.clear();

    const prevPositions = prevPositionsRef.current;
    const nextPositions = measurePositions();
    prevPositionsRef.current = nextPositions;

    // Avoid fighting the browser while it manages the drag image.
    if (draggingId) return;

    const prefersReducedMotion =
      window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches ?? false;
    if (prefersReducedMotion) return;

    const moved: Array<{
      taskId: string;
      element: HTMLDivElement;
      dx: number;
      dy: number;
    }> = [];
    for (const [taskId, next] of nextPositions.entries()) {
      const prev = prevPositions.get(taskId);
      if (!prev) continue;
      const dx = prev.left - next.left;
      const dy = prev.top - next.top;
      if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
      const element = cardRefsSnapshot.get(taskId);
      if (!element) continue;
      moved.push({ taskId, element, dx, dy });
    }

    if (!moved.length) return;
    animatedTaskIdsRef.current = new Set(moved.map(({ taskId }) => taskId));

    // FLIP: invert to the previous position before paint, then animate back to 0.
    for (const { element, dx, dy } of moved) {
      element.style.transform = `translate(${dx}px, ${dy}px)`;
      element.style.transition = "transform 0s";
      element.style.willChange = "transform";
      element.style.position = "relative";
      element.style.zIndex = "1";
    }

    animationRafRef.current = window.requestAnimationFrame(() => {
      for (const { element } of moved) {
        element.style.transition = `transform ${KANBAN_MOVE_ANIMATION_MS}ms ${KANBAN_MOVE_EASING}`;
        element.style.transform = "";
      }

      cleanupTimeoutRef.current = window.setTimeout(() => {
        for (const { element } of moved) {
          element.style.transition = "";
          element.style.willChange = "";
          element.style.position = "";
          element.style.zIndex = "";
        }
        animatedTaskIdsRef.current.clear();
        cleanupTimeoutRef.current = null;
      }, KANBAN_MOVE_ANIMATION_MS + 60);

      animationRafRef.current = null;
    });

    return () => {
      if (animationRafRef.current !== null) {
        window.cancelAnimationFrame(animationRafRef.current);
        animationRafRef.current = null;
      }
      if (cleanupTimeoutRef.current !== null) {
        window.clearTimeout(cleanupTimeoutRef.current);
        cleanupTimeoutRef.current = null;
      }
      for (const taskId of animatedTaskIdsRef.current) {
        const element = cardRefsSnapshot.get(taskId);
        if (!element) continue;
        element.style.transform = "";
        element.style.transition = "";
        element.style.willChange = "";
        element.style.position = "";
        element.style.zIndex = "";
      }
      animatedTaskIdsRef.current.clear();
    };
  }, [draggingId, measurePositions, taskListKey]);

  const grouped = useMemo(() => {
    const buckets: Record<TaskStatus, Task[]> = {
      inbox: [],
      in_progress: [],
      review: [],
      blocked: [],
      done: [],
    };
    for (const column of columns) {
      buckets[column.status] = [];
    }
    tasks.forEach((task) => {
      const bucket = buckets[task.status] ?? buckets.inbox;
      bucket.push(task);
    });
    // Sort done tasks by updated_at descending (most recently updated first)
    // Tasks without updated_at are treated as oldest (placed at bottom).
    buckets.done.sort((a, b) => {
      const timeA = a.updated_at ? new Date(a.updated_at).getTime() : 0;
      const timeB = b.updated_at ? new Date(b.updated_at).getTime() : 0;
      return timeB - timeA;
    });
    return buckets;
  }, [tasks]);

  // Keep drag/drop state and payload handling centralized for column move interactions.
  const handleDragStart =
    (task: Task) => (event: React.DragEvent<HTMLDivElement>) => {
      if (readOnly) {
        event.preventDefault();
        return;
      }
      if (task.is_blocked) {
        event.preventDefault();
        return;
      }
      setDraggingId(task.id);
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData(
        "text/plain",
        JSON.stringify({ taskId: task.id, status: task.status }),
      );
    };

  const handleDragEnd = () => {
    setDraggingId(null);
    setActiveColumn(null);
  };

  const handleDrop =
    (status: TaskStatus) => (event: React.DragEvent<HTMLDivElement>) => {
      if (readOnly) return;
      event.preventDefault();
      setActiveColumn(null);
      const raw = event.dataTransfer.getData("text/plain");
      if (!raw) return;
      try {
        const payload = JSON.parse(raw) as { taskId?: string; status?: string };
        if (!payload.taskId || !payload.status) return;
        if (payload.status === status) return;
        onTaskMove?.(payload.taskId, status);
      } catch {
        // Ignore malformed payloads.
      }
    };

  const handleDragOver =
    (status: TaskStatus) => (event: React.DragEvent<HTMLDivElement>) => {
      if (readOnly) return;
      event.preventDefault();
      if (activeColumn !== status) {
        setActiveColumn(status);
      }
    };

  const handleDragLeave = (status: TaskStatus) => () => {
    if (readOnly) return;
    if (activeColumn === status) {
      setActiveColumn(null);
    }
  };

  return (
    <div className="relative flex flex-1 min-h-0 flex-col">
    {/* Bulk action bar */}
    {selectedIds.size > 0 && (
      <div className="fixed bottom-6 left-1/2 z-50 -translate-x-1/2 flex items-center gap-2 rounded-xl border border-[color:var(--border-strong)] bg-[color:var(--surface)] px-4 py-2.5 shadow-xl">
        <CheckSquare className="h-4 w-4 text-[color:var(--accent)] shrink-0" />
        <span className="text-sm font-semibold text-strong whitespace-nowrap">{selectedIds.size} selected</span>
        <div className="mx-2 h-5 w-px bg-[color:var(--border)]" />
        {/* Move to */}
        <div className="flex items-center gap-1.5">
          <span className="text-xs text-quiet whitespace-nowrap">Move to:</span>
          <select
            value={bulkMoveTo ?? ""}
            onChange={(e) => setBulkMoveTo(e.target.value as TaskStatus || null)}
            className="rounded border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-2 py-1 text-xs text-strong focus:outline-none"
            disabled={isBulkBusy}
          >
            <option value="">Pick status…</option>
            {columns.map((col) => (
              <option key={col.status} value={col.status}>{col.title}</option>
            ))}
          </select>
          <button
            type="button"
            onClick={handleBulkMove}
            disabled={!bulkMoveTo || isBulkBusy}
            className="flex items-center gap-1 rounded bg-[color:var(--accent)] px-2.5 py-1 text-xs font-semibold text-white disabled:opacity-40 hover:opacity-90"
          >
            <MoveRight className="h-3.5 w-3.5" />
            Move
          </button>
        </div>
        {onBulkApprove && selectedTasksHaveApprovals && (
          <>
            <div className="mx-1 h-5 w-px bg-[color:var(--border)]" />
            <button
              type="button"
              onClick={handleBulkApprove}
              disabled={isBulkBusy}
              className="flex items-center gap-1 rounded bg-emerald-600 px-2.5 py-1 text-xs font-semibold text-white disabled:opacity-40 hover:opacity-90"
            >
              <ShieldCheck className="h-3.5 w-3.5" />
              Approve all
            </button>
          </>
        )}
        <div className="mx-1 h-5 w-px bg-[color:var(--border)]" />
        {/* Delete */}
        <button
          type="button"
          onClick={handleBulkDelete}
          disabled={isBulkBusy}
          className="flex items-center gap-1 rounded bg-[color:var(--danger-soft)] px-2.5 py-1 text-xs font-semibold text-danger hover:bg-[color:var(--danger-soft)] disabled:opacity-40"
        >
          <Trash2 className="h-3.5 w-3.5" />
          Delete
        </button>
        <div className="mx-1 h-5 w-px bg-[color:var(--border)]" />
        <button
          type="button"
          onClick={clearSelection}
          className="rounded p-1 text-quiet hover:text-muted"
          aria-label="Clear selection"
        >
          <X className="h-4 w-4" />
        </button>
      </div>
    )}
    <div
      ref={boardRef}
      data-testid="task-board"
      className={cn(
        // Mobile-first: stack columns vertically.
        "grid grid-cols-1 gap-4 overflow-x-hidden pb-6",
        // Desktop: flex row — align-items:stretch (the CSS default) gives every column
        // the exact height of the flex container WITHOUT any h-full percentage chain.
        // This avoids the CSS Grid circular-reference issue where grid-row:auto means
        // h-full on children resolves to content height instead of container height.
        // overflow-y-hidden: overflow-x:auto implicitly promotes overflow-y:visible→auto; block it.
        "sm:flex sm:flex-row sm:gap-4 sm:flex-1 sm:min-h-0 sm:overflow-x-auto sm:overflow-y-hidden sm:overscroll-none sm:pb-0",
      )}
    >
      {columns.map((column) => {
        const columnTasks = grouped[column.status] ?? [];
        // Derive review tab counts and the active subset from one canonical task list.
        const reviewCounts =
          column.status === "review"
            ? columnTasks.reduce(
                (acc, task) => {
                  if (task.is_blocked) {
                    acc.blocked += 1;
                    return acc;
                  }
                  if ((task.approvals_pending_count ?? 0) > 0) {
                    acc.approval_needed += 1;
                    return acc;
                  }
                  acc.waiting_lead += 1;
                  return acc;
                },
                {
                  all: columnTasks.length,
                  approval_needed: 0,
                  waiting_lead: 0,
                  blocked: 0,
                },
              )
            : null;

        const filteredTasks =
          column.status === "review" && reviewBucket !== "all"
            ? columnTasks.filter((task) => {
                if (reviewBucket === "blocked") return Boolean(task.is_blocked);
                if (reviewBucket === "approval_needed")
                  return (
                    (task.approvals_pending_count ?? 0) > 0 && !task.is_blocked
                  );
                if (reviewBucket === "waiting_lead")
                  return (
                    !task.is_blocked &&
                    (task.approvals_pending_count ?? 0) === 0
                  );
                return true;
              })
            : columnTasks;

        return (
          <div
            key={column.title}
            className={cn(
              // Mobile: stacked, auto height.
              "kanban-column flex flex-col",
              // Desktop: fixed width, no h-full needed — parent flex row stretches to container height.
              "sm:w-[280px] sm:flex-none",
              activeColumn === column.status &&
                !readOnly &&
                "ring-2 ring-slate-200",
            )}
            onDrop={readOnly ? undefined : handleDrop(column.status)}
            onDragOver={readOnly ? undefined : handleDragOver(column.status)}
            onDragLeave={readOnly ? undefined : handleDragLeave(column.status)}
          >
            <div className="column-header shrink-0 z-10 rounded-t-xl border border-b-0 border-[color:var(--border)] bg-[color:var(--surface)] px-4 py-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span className={cn("h-2 w-2 rounded-full", column.dot)} />
                  <h3 className="text-sm font-semibold text-strong">
                    {column.title}
                  </h3>
                </div>
                <span
                  className={cn(
                    "flex h-6 w-6 items-center justify-center rounded-full text-xs font-semibold",
                    column.badge,
                  )}
                >
                  {filteredTasks.length}
                </span>
              </div>
              {column.status === "review" && reviewCounts ? (
                <div className="mt-2 flex flex-wrap items-center gap-2 text-[10px] font-semibold uppercase tracking-wide text-quiet">
                  {(
                    [
                      { key: "all", label: "All", count: reviewCounts.all },
                      {
                        key: "approval_needed",
                        label: "Approval needed",
                        count: reviewCounts.approval_needed,
                      },
                      {
                        key: "waiting_lead",
                        label: "Lead review",
                        count: reviewCounts.waiting_lead,
                      },
                      {
                        key: "blocked",
                        label: "Blocked",
                        count: reviewCounts.blocked,
                      },
                    ] as const
                  ).map((option) => (
                    <button
                      key={option.key}
                      type="button"
                      onClick={() => setReviewBucket(option.key)}
                      className={cn(
                        "rounded-full border px-2.5 py-1 transition",
                        reviewBucket === option.key
                          ? "border-[color:var(--border-strong)] bg-[color:var(--text)] text-white dark:border-[color:var(--border)] dark:bg-[color:var(--surface-strong)]"
                          : "border-[color:var(--border)] bg-[color:var(--surface)] text-muted hover:border-[color:var(--border-strong)] hover:bg-[color:var(--surface-muted)] dark:hover:bg-[color:var(--surface-strong)]",
                      )}
                      aria-pressed={reviewBucket === option.key}
                    >
                      {option.label} · {option.count}
                    </button>
                  ))}
                </div>
              ) : null}
            </div>
            <div className="flex-1 min-h-0 overflow-y-auto overscroll-none [overflow-anchor:none] rounded-b-xl border border-t-0 border-[color:var(--border)] bg-[color:var(--surface)] p-3">
              <div className="space-y-3">
                {filteredTasks.map((task) => {
                  const dueState = resolveDueState(task);
                  return (
                    <div key={task.id} ref={setCardRef(task.id)} className="group/selectable relative">
                      {/* Checkbox overlay */}
                      <div
                        className={cn(
                          "absolute left-2 top-2 z-10 transition-opacity",
                          selectedIds.has(task.id) ? "opacity-100" : "opacity-0 group-hover/selectable:opacity-100",
                        )}
                      >
                        <button
                          type="button"
                          onClick={(e) => toggleSelect(task.id, e)}
                          aria-label={selectedIds.has(task.id) ? "Deselect task" : "Select task"}
                          className={cn(
                            "flex h-5 w-5 items-center justify-center rounded border-2 transition-colors",
                            selectedIds.has(task.id)
                              ? "border-[color:var(--accent)] bg-[color:var(--accent)]"
                              : "border-[color:var(--border-strong)] bg-[color:var(--surface)]",
                          )}
                        >
                          {selectedIds.has(task.id) && (
                            <svg viewBox="0 0 12 12" className="h-3 w-3 text-white" fill="none" stroke="currentColor" strokeWidth="2">
                              <polyline points="2,6 5,9 10,3" />
                            </svg>
                          )}
                        </button>
                      </div>
                      <div className={cn(selectedIds.has(task.id) && "ring-2 ring-[color:var(--accent)] rounded-lg")}>
                        <TaskCard
                          title={task.title}
                          status={task.status}
                          priority={task.priority}
                          assignee={task.assignee ?? undefined}
                          createdBy={task.creator_name ?? undefined}
                          due={dueState.due}
                          isOverdue={dueState.isOverdue}
                          approvalsPendingCount={task.approvals_pending_count}
                          tags={task.tags}
                          isBlocked={task.is_blocked}
                          blockedByCount={task.blocked_by_task_ids?.length ?? 0}
                          onClick={() => onTaskSelect?.(task)}
                          draggable={!readOnly && !task.is_blocked && selectedIds.size === 0}
                          isDragging={draggingId === task.id}
                          onDragStart={readOnly ? undefined : handleDragStart(task)}
                          onDragEnd={readOnly ? undefined : handleDragEnd}
                        />
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        );
      })}
    </div>
    </div>
  );
});

TaskBoard.displayName = "TaskBoard";
