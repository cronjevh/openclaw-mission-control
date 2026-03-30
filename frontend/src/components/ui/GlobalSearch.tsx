"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter, usePathname } from "next/navigation";
import { Search, FileText, MessageSquare, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { getLocalAuthToken, isLocalAuthMode } from "@/auth/localAuth";

const API = (process.env.NEXT_PUBLIC_API_URL ?? "").replace(/\/+$/, "");

type ClerkGlobal = { session?: { getToken: () => Promise<string> } | null };
async function getAuthHeader(): Promise<HeadersInit> {
  if (isLocalAuthMode()) {
    const t = getLocalAuthToken();
    return t ? { Authorization: `Bearer ${t}` } : {};
  }
  try {
    const clerk = (window as unknown as { Clerk?: ClerkGlobal }).Clerk;
    const token = await clerk?.session?.getToken();
    return token ? { Authorization: `Bearer ${token}` } : {};
  } catch {
    return {};
  }
}

interface TaskResult {
  id: string;
  title: string;
  status: string;
  description: string | null;
  board_id: string | null;
  board_name: string | null;
}

interface CommentResult {
  id: string;
  message: string;
  author_name: string | null;
  created_at: string;
  task_id: string;
  task_title: string;
  task_status: string;
  board_id: string | null;
  board_name: string | null;
}

interface SearchResults {
  tasks: TaskResult[];
  comments: CommentResult[];
}

const STATUS_COLORS: Record<string, string> = {
  inbox: "bg-[color:var(--surface-strong)] text-muted",
  in_progress: "bg-[color:var(--info-soft)] text-info",
  review: "bg-[color:var(--warning-soft)] text-warning",
  done: "bg-[color:var(--success-soft)] text-success",
  archived: "bg-[color:var(--surface-strong)] text-quiet",
};

function StatusBadge({ status }: { status: string }) {
  return (
    <span
      className={cn(
        "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
        STATUS_COLORS[status] ?? STATUS_COLORS.inbox,
      )}
    >
      {status.replace("_", " ")}
    </span>
  );
}

export function GlobalSearch() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const router = useRouter();
  const pathname = usePathname();

  // Only register Cmd+K when NOT on a board page (board pages have their own)
  const isOnBoardPage = pathname.startsWith("/boards/");

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        if (isOnBoardPage) return; // let board-level search handle it
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [isOnBoardPage]);

  useEffect(() => {
    if (open) setTimeout(() => inputRef.current?.focus(), 50);
    else {
      setQuery("");
      setResults(null);
    }
  }, [open]);

  const doSearch = useCallback(async (q: string) => {
    if (!q.trim()) {
      setResults(null);
      return;
    }
    setLoading(true);
    try {
      const h = await getAuthHeader();
      const res = await fetch(
        `${API}/api/v1/search?q=${encodeURIComponent(q)}`,
        { headers: h },
      );
      if (!res.ok) return;
      const data: SearchResults = await res.json();
      setResults(data);
    } finally {
      setLoading(false);
    }
  }, []);

  const handleInput = (v: string) => {
    setQuery(v);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => doSearch(v), 300);
  };

  const navigateToTask = (boardId: string | null, taskId: string) => {
    setOpen(false);
    if (boardId) {
      router.push(`/boards/${boardId}?taskId=${taskId}`);
    }
  };

  const hasResults =
    results && (results.tasks.length > 0 || results.comments.length > 0);
  const noResults =
    results && results.tasks.length === 0 && results.comments.length === 0;

  return (
    <>
      {/* Trigger button in sidebar */}
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={cn(
          "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm transition",
          "text-quiet hover:bg-[color:var(--surface-strong)] hover:text-muted",
        )}
      >
        <Search className="h-4 w-4" />
        <span className="flex-1 text-left">Search</span>
        <kbd className="rounded border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-1.5 py-0.5 text-[10px] text-quiet">
          ⌘K
        </kbd>
      </button>

      {/* Modal */}
      {open && (
        <div className="fixed inset-0 z-50 flex items-start justify-center pt-24">
          <div
            className="absolute inset-0 bg-black/40 dark:bg-black/60"
            onClick={() => setOpen(false)}
          />

          <div
            className={cn(
              "relative z-10 w-full max-w-xl overflow-hidden rounded-xl border shadow-2xl",
              "border-[color:var(--border)] bg-[color:var(--surface)]",
              "dark:border-slate-700",
            )}
          >
            {/* Input row */}
            <div className="flex items-center gap-3 border-b border-[color:var(--border)] bg-[color:var(--surface)] px-4 py-3">
              <Search className="h-4 w-4 flex-shrink-0 text-quiet" />
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => handleInput(e.target.value)}
                placeholder="Search across all boards…"
                className={cn(
                  "flex-1 bg-transparent text-sm outline-none",
                  "text-strong placeholder:text-quiet",
                  "dark:text-[color:var(--text-inverse)] dark:placeholder:text-quiet",
                )}
              />
              {loading && (
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-[color:var(--border-strong)] border-t-slate-600" />
              )}
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="text-quiet hover:text-muted"
              >
                <X className="h-4 w-4" />
              </button>
            </div>

            {/* Results */}
            <div className="max-h-[28rem] overflow-y-auto">
              {!query && (
                <p className="py-8 text-center text-sm text-quiet">
                  Search tasks and comments across all your boards
                </p>
              )}
              {noResults && (
                <p className="py-8 text-center text-sm text-quiet">
                  No results for &ldquo;{query}&rdquo;
                </p>
              )}

              {hasResults && (
                <>
                  {results.tasks.length > 0 && (
                    <div>
                      <div className="border-b border-[color:var(--border)] px-4 py-2">
                        <span className="text-[10px] font-semibold uppercase tracking-wider text-quiet">
                          Tasks ({results.tasks.length})
                        </span>
                      </div>
                      {results.tasks.map((t) => (
                        <button
                          key={t.id}
                          type="button"
                          onClick={() => navigateToTask(t.board_id, t.id)}
                          className={cn(
                            "flex w-full items-center gap-3 border-b px-4 py-3 text-left transition last:border-b-0",
                            "border-[color:var(--border)] hover:bg-[color:var(--surface-muted)]",
                          )}
                        >
                          <FileText className="h-4 w-4 flex-shrink-0 text-quiet" />
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm font-medium text-strong">
                              {t.title}
                            </p>
                            <div className="mt-0.5 flex items-center gap-2">
                              {t.board_name && (
                                <span className="truncate text-[11px] text-quiet">
                                  {t.board_name}
                                </span>
                              )}
                              {t.description && (
                                <span className="truncate text-[11px] text-quiet">
                                  · {t.description}
                                </span>
                              )}
                            </div>
                          </div>
                          <StatusBadge status={t.status} />
                        </button>
                      ))}
                    </div>
                  )}

                  {results.comments.length > 0 && (
                    <div>
                      <div className="border-b border-[color:var(--border)] px-4 py-2">
                        <span className="text-[10px] font-semibold uppercase tracking-wider text-quiet">
                          Comments ({results.comments.length})
                        </span>
                      </div>
                      {results.comments.map((c) => (
                        <button
                          key={c.id}
                          type="button"
                          onClick={() => navigateToTask(c.board_id, c.task_id)}
                          className={cn(
                            "flex w-full items-start gap-3 border-b px-4 py-3 text-left transition last:border-b-0",
                            "border-[color:var(--border)] hover:bg-[color:var(--surface-muted)]",
                          )}
                        >
                          <MessageSquare className="mt-0.5 h-4 w-4 flex-shrink-0 text-quiet" />
                          <div className="min-w-0 flex-1">
                            <p className="mb-0.5 flex items-center gap-1.5 text-xs text-quiet">
                              <span className="font-medium text-muted">
                                {c.task_title}
                              </span>
                              {c.board_name && (
                                <span className="text-[11px]">
                                  · {c.board_name}
                                </span>
                              )}
                              {c.author_name && (
                                <span>· {c.author_name}</span>
                              )}
                            </p>
                            <p className="line-clamp-2 text-sm text-muted">
                              {c.message}
                            </p>
                          </div>
                          <StatusBadge status={c.task_status} />
                        </button>
                      ))}
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
