import { CalendarClock, UserCircle } from "lucide-react";

import { cn } from "@/lib/utils";

type TaskStatus = "inbox" | "in_progress" | "review" | "done" | "blocked";

interface TaskCardProps {
  title: string;
  status?: TaskStatus;
  priority?: string;
  assignee?: string;
  createdBy?: string;
  due?: string;
  isOverdue?: boolean;
  approvalsPendingCount?: number;
  tags?: Array<{ id: string; name: string; color: string }>;
  isBlocked?: boolean;
  blockedByCount?: number;
  onClick?: () => void;
  draggable?: boolean;
  isDragging?: boolean;
  onDragStart?: (event: React.DragEvent<HTMLDivElement>) => void;
  onDragEnd?: (event: React.DragEvent<HTMLDivElement>) => void;
}

export function TaskCard({
  title,
  status,
  priority,
  assignee,
  createdBy,
  due,
  isOverdue = false,
  approvalsPendingCount = 0,
  tags = [],
  isBlocked = false,
  blockedByCount = 0,
  onClick,
  draggable = false,
  isDragging = false,
  onDragStart,
  onDragEnd,
}: TaskCardProps) {
  const hasPendingApproval = approvalsPendingCount > 0;
  const needsLeadReview =
    status === "review" && !isBlocked && !hasPendingApproval;
  const leftBarClassName = isBlocked
    ? "bg-[color:var(--danger)]"
    : hasPendingApproval
      ? "bg-[color:var(--warning)]"
      : needsLeadReview
        ? "bg-[color:var(--status-review-dot)]"
        : null;
  const priorityBadge = (value?: string) => {
    if (!value) return null;
    const normalized = value.toLowerCase();
    if (normalized === "urgent") return "priority-urgent";
    if (normalized === "high")   return "priority-high";
    if (normalized === "medium") return "priority-medium";
    if (normalized === "low")    return "priority-low";
    return "priority-low";
  };

  const priorityLabel = priority ? priority.toUpperCase() : "MEDIUM";
  const visibleTags = tags.slice(0, 3);

  return (
    <div
      className={cn(
        "group relative cursor-pointer rounded-lg border border-[color:var(--border)] bg-surface p-4 shadow-sm transition-all hover:border-[color:var(--border-strong)] hover:shadow-md",
        isDragging && "opacity-60 shadow-none",
        hasPendingApproval && "border-[color:var(--warning-border)] bg-[color:var(--warning-soft)]",
        isBlocked && "border-[color:var(--danger-border)] bg-[color:var(--danger-soft)]",
        needsLeadReview && "border-[color:var(--status-review-border)] bg-[color:var(--status-review-bg)]",
      )}
      draggable={draggable}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
      onClick={onClick}
      role="button"
      tabIndex={0}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onClick?.();
        }
      }}
    >
      {leftBarClassName ? (
        <span
          className={cn(
            "absolute left-0 top-0 h-full w-1 rounded-l-lg",
            leftBarClassName,
          )}
        />
      ) : null}
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 space-y-2">
          <p className="text-sm font-medium text-strong line-clamp-2 break-words">
            {title}
          </p>
          {isBlocked ? (
            <div className="flex items-center gap-2 text-[10px] font-semibold uppercase tracking-wide text-danger">
              <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--danger)]" />
              Blocked{blockedByCount > 0 ? ` · ${blockedByCount}` : ""}
            </div>
          ) : null}
          {hasPendingApproval ? (
            <div className="flex items-center gap-2 text-[10px] font-semibold uppercase tracking-wide text-warning">
              <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--warning)]" />
              Approval needed · {approvalsPendingCount}
            </div>
          ) : null}
          {needsLeadReview ? (
            <div className="flex items-center gap-2 text-[10px] font-semibold uppercase tracking-wide text-[color:var(--status-review-text)]">
              <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--status-review-dot)]" />
              Waiting for lead review
            </div>
          ) : null}
          {visibleTags.length ? (
            <div className="flex flex-wrap items-center gap-1.5">
              {visibleTags.map((tag) => (
                <span
                  key={tag.id}
                  className="tag-chip inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-semibold"
                >
                  <span
                    className="h-1.5 w-1.5 rounded-full"
                    style={{ backgroundColor: `#${tag.color}` }}
                  />
                  {tag.name}
                </span>
              ))}
              {tags.length > visibleTags.length ? (
                <span className="text-[10px] font-semibold text-muted">
                  +{tags.length - visibleTags.length}
                </span>
              ) : null}
            </div>
          ) : null}
        </div>
        <div className="flex flex-shrink-0 flex-col items-end gap-2">
          <span
            className={cn(
              "inline-flex items-center rounded-full px-2 py-1 text-[10px] font-semibold uppercase tracking-wide",
              priorityBadge(priority) ?? "priority-low",
            )}
          >
            {priorityLabel}
          </span>
        </div>
      </div>
      <div className="mt-3 flex items-center justify-between text-xs text-muted">
        <div className="flex items-center gap-2">
          <UserCircle className="h-4 w-4 text-quiet" />
          <span>{assignee ?? "Unassigned"}</span>
        </div>
        {due ? (
          <div
            className={cn(
              "flex items-center gap-2",
              isOverdue && "font-semibold text-danger",
            )}
          >
            <CalendarClock
              className={cn(
                "h-4 w-4",
                isOverdue ? "text-[color:var(--danger)]" : "text-quiet",
              )}
            />
            <span>{due}</span>
          </div>
        ) : null}
      </div>
      {createdBy ? (
        <p className="mt-1.5 text-[10px] text-quiet">by {createdBy}</p>
      ) : null}
    </div>
  );
}
