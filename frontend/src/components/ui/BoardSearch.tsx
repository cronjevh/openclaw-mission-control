"use client";

import { useCallback, useEffect, useRef, useState } from "react";
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
}

interface SearchResults {
  tasks: TaskResult[];
  comments: CommentResult[];
}

const STATUS_COLORS: Record<string, string> = {
  inbox: "bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300",
  in_progress: "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300",
  review: "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300",
  done: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300",
};

function StatusBadge({ status }: { status: string }) {
  return (
    <span
      className={cn(
        "rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
        STATUS_COLORS[status] ?? STATUS_COLORS.inbox,
      )}
    >
      {status.replace("_", " ")}
    </span>
  );
}

interface BoardSearchProps {
  boardId: string;
  onTaskSelect: (taskId: string) => void;
}

export function BoardSearch({ boardId, onTaskSelect }: BoardSearchProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Cmd+K / Ctrl+K shortcut
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  useEffect(() => {
    if (open) setTimeout(() => inputRef.current?.focus(), 50);
    else {
      setQuery("");
      setResults(null);
    }
  }, [open]);

  const doSearch = useCallback(
    async (q: string) => {
      if (!q.trim()) {
        setResults(null);
        return;
      }
      setLoading(true);
      try {
        const h = await getAuthHeader();
        const res = await fetch(
          `${API}/api/v1/boards/${boardId}/search?q=${encodeURIComponent(q)}`,
          { headers: h },
        );
        if (!res.ok) return;
        const data: SearchResults = await res.json();
        setResults(data);
      } finally {
        setLoading(false);
      }
    },
    [boardId],
  );

  const handleInput = (v: string) => {
    setQuery(v);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => doSearch(v), 300);
  };

  const handleTaskClick = (taskId: string) => {
    onTaskSelect(taskId);
    setOpen(false);
  };

  const hasResults =
    results && (results.tasks.length > 0 || results.comments.length > 0);
  const noResults =
    results && results.tasks.length === 0 && results.comments.length === 0;

  return (
    <>
      {/* Trigger button */}
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={cn(
          "flex items-center gap-2 rounded-lg border px-3 py-1.5 text-sm transition",
          "border-slate-200 bg-white text-slate-500 hover:border-slate-300 hover:text-slate-700",
          "dark:border-slate-700 dark:bg-slate-800 dark:text-slate-400 dark:hover:border-slate-600 dark:hover:text-slate-200",
        )}
      >
        <Search className="h-3.5 w-3.5" />
        <span className="hidden sm:inline">Search</span>
        <kbd className="hidden rounded border border-slate-200 bg-slate-50 px-1 py-0.5 text-[10px] text-slate-400 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-500 sm:inline">
          ⌘K
        </kbd>
      </button>

      {/* Modal */}
      {open && (
        <div className="fixed inset-0 z-50 flex items-start justify-center pt-24">
          {/* Backdrop */}
          <div
            className="absolute inset-0 bg-black/40 dark:bg-black/60"
            onClick={() => setOpen(false)}
          />

          {/* Panel */}
          <div
            className={cn(
              "relative z-10 w-full max-w-lg overflow-hidden rounded-xl border shadow-2xl",
              "border-slate-200 bg-white",
              "dark:border-slate-700 dark:bg-slate-900",
            )}
          >
            {/* Input row */}
            <div className="flex items-center gap-3 border-b border-slate-100 px-4 py-3 dark:border-slate-800">
              <Search className="h-4 w-4 flex-shrink-0 text-slate-400" />
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => handleInput(e.target.value)}
                placeholder="Search tasks and comments…"
                className={cn(
                  "flex-1 bg-transparent text-sm outline-none",
                  "text-slate-900 placeholder-slate-400",
                  "dark:text-slate-100 dark:placeholder-slate-500",
                )}
              />
              {loading && (
                <span className="h-4 w-4 animate-spin rounded-full border-2 border-slate-300 border-t-slate-600 dark:border-slate-600 dark:border-t-slate-300" />
              )}
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="text-slate-400 hover:text-slate-600 dark:text-slate-500 dark:hover:text-slate-300"
              >
                <X className="h-4 w-4" />
              </button>
            </div>

            {/* Results */}
            <div className="max-h-96 overflow-y-auto">
              {!query && (
                <p className="py-8 text-center text-sm text-slate-400 dark:text-slate-500">
                  Type to search within this board
                </p>
              )}
              {noResults && (
                <p className="py-8 text-center text-sm text-slate-400 dark:text-slate-500">
                  No results for &ldquo;{query}&rdquo;
                </p>
              )}

              {hasResults && (
                <>
                  {results.tasks.length > 0 && (
                    <div>
                      <div className="border-b border-slate-100 px-4 py-2 dark:border-slate-800">
                        <span className="text-[10px] font-semibold uppercase tracking-wider text-slate-400 dark:text-slate-500">
                          Tasks ({results.tasks.length})
                        </span>
                      </div>
                      {results.tasks.map((t) => (
                        <button
                          key={t.id}
                          type="button"
                          onClick={() => handleTaskClick(t.id)}
                          className={cn(
                            "flex w-full items-center gap-3 border-b px-4 py-3 text-left transition last:border-b-0",
                            "border-slate-50 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-800",
                          )}
                        >
                          <FileText className="h-4 w-4 flex-shrink-0 text-slate-400 dark:text-slate-500" />
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm font-medium text-slate-900 dark:text-slate-100">
                              {t.title}
                            </p>
                            {t.description && (
                              <p className="mt-0.5 truncate text-xs text-slate-400 dark:text-slate-500">
                                {t.description}
                              </p>
                            )}
                          </div>
                          <StatusBadge status={t.status} />
                        </button>
                      ))}
                    </div>
                  )}

                  {results.comments.length > 0 && (
                    <div>
                      <div className="border-b border-slate-100 px-4 py-2 dark:border-slate-800">
                        <span className="text-[10px] font-semibold uppercase tracking-wider text-slate-400 dark:text-slate-500">
                          Comments ({results.comments.length})
                        </span>
                      </div>
                      {results.comments.map((c) => (
                        <button
                          key={c.id}
                          type="button"
                          onClick={() => handleTaskClick(c.task_id)}
                          className={cn(
                            "flex w-full items-start gap-3 border-b px-4 py-3 text-left transition last:border-b-0",
                            "border-slate-50 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-800",
                          )}
                        >
                          <MessageSquare className="mt-0.5 h-4 w-4 flex-shrink-0 text-slate-400 dark:text-slate-500" />
                          <div className="min-w-0 flex-1">
                            <p className="mb-0.5 text-xs text-slate-500 dark:text-slate-400">
                              <span className="font-medium text-slate-700 dark:text-slate-300">
                                {c.task_title}
                              </span>
                              {c.author_name && (
                                <span> · {c.author_name}</span>
                              )}
                            </p>
                            <p className="line-clamp-2 text-sm text-slate-600 dark:text-slate-300">
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
