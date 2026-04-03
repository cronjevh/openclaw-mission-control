"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams, useSearchParams } from "next/navigation";
import JsonView from "@uiw/react-json-view";
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getFilteredRowModel,
  getSortedRowModel,
  useReactTable,
  type ColumnDef,
  type FilterFn,
  type SortingState,
  type VisibilityState,
} from "@tanstack/react-table";

import { ApiError, customFetch } from "@/api/mutator";

type HistoryRow = Record<string, unknown>;

type GatewaySessionHistoryResponse = {
  data?: {
    history?: HistoryRow[];
  };
};

const MAX_CELL_LEN = 120;

/** Preferred columns shown first regardless of insertion order. */
const PRIORITY_KEYS = ["role", "timestamp", "created_at", "content", "tool_name", "tool_call_id"];

const BROWSER_DATE_TIME_FORMATTER = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "short",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  timeZoneName: "short",
});

function cellStr(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value);
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "…" : s;
}

function isTimestampKey(key: string): boolean {
  return key === "timestamp" || key.endsWith("_at") || key.endsWith("_timestamp");
}

function toTimestampMs(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    // Heuristic: values below 1e12 are likely epoch seconds.
    return value < 1_000_000_000_000 ? value * 1000 : value;
  }
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;

  // Numeric strings can also be epoch seconds/milliseconds.
  if (/^\d+(\.\d+)?$/.test(trimmed)) {
    const numeric = Number(trimmed);
    if (Number.isFinite(numeric)) {
      return numeric < 1_000_000_000_000 ? numeric * 1000 : numeric;
    }
  }

  const parsed = Date.parse(trimmed);
  return Number.isNaN(parsed) ? null : parsed;
}

function formatBrowserLocalTimestamp(value: unknown): string | null {
  const ts = toTimestampMs(value);
  if (ts === null) return null;
  return BROWSER_DATE_TIME_FORMATTER.format(new Date(ts));
}

/** Global filter that stringifies the whole row so nested JSON is searchable. */
const rowMatchesFilter: FilterFn<HistoryRow> = (row, _columnId, filterValue: string) => {
  if (!filterValue) return true;
  return JSON.stringify(row.original).toLowerCase().includes(filterValue.toLowerCase());
};

export default function BoardAgentSessionLogPage() {
  const params = useParams();
  const searchParams = useSearchParams();

  const boardIdParam = params?.boardId;
  const boardId = Array.isArray(boardIdParam) ? boardIdParam[0] : boardIdParam;
  const sessionKey = searchParams.get("sessionKey")?.trim() ?? "";
  const agentName = searchParams.get("agentName")?.trim() || "Agent";
  const columnVisibilityStorageKey = `mc_session_log_column_visibility_v1:${boardId || "global"}`;

  const [isLoading, setIsLoading] = useState(true);
  const [fetchError, setFetchError] = useState<string | null>(null);
  const [data, setData] = useState<HistoryRow[]>([]);
  const [sorting, setSorting] = useState<SortingState>([]);
  const [columnVisibility, setColumnVisibility] = useState<VisibilityState>({});
  const [columnVisibilityLoaded, setColumnVisibilityLoaded] = useState(false);
  const [globalFilter, setGlobalFilter] = useState("");
  const [selectedRow, setSelectedRow] = useState<HistoryRow | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    setColumnVisibilityLoaded(false);
    if (typeof window === "undefined") {
      setColumnVisibilityLoaded(true);
      return;
    }

    try {
      const stored = window.localStorage.getItem(columnVisibilityStorageKey);
      if (!stored) {
        setColumnVisibility({});
      } else {
        const parsed: unknown = JSON.parse(stored);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          setColumnVisibility(parsed as VisibilityState);
        } else {
          setColumnVisibility({});
        }
      }
    } catch {
      setColumnVisibility({});
    } finally {
      setColumnVisibilityLoaded(true);
    }
  }, [columnVisibilityStorageKey]);

  useEffect(() => {
    if (!columnVisibilityLoaded || typeof window === "undefined") {
      return;
    }
    try {
      window.localStorage.setItem(
        columnVisibilityStorageKey,
        JSON.stringify(columnVisibility),
      );
    } catch {
      // Ignore storage failures (private mode / policy).
    }
  }, [columnVisibility, columnVisibilityLoaded, columnVisibilityStorageKey]);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      if (!boardId || !sessionKey) {
        setFetchError("Missing board or session key.");
        setIsLoading(false);
        return;
      }

      setIsLoading(true);
      setFetchError(null);
      try {
        const result = await customFetch<GatewaySessionHistoryResponse>(
          `/api/v1/gateways/sessions/${encodeURIComponent(sessionKey)}/history?board_id=${encodeURIComponent(boardId)}`,
          { method: "GET" },
        );
        if (!cancelled) {
          setData(result.data?.history ?? []);
        }
      } catch (err) {
        let message = "Unable to load session history.";
        if (err instanceof ApiError) {
          message = err.message || message;
        }
        if (!cancelled) {
          setFetchError(message);
        }
      } finally {
        if (!cancelled) {
          setIsLoading(false);
        }
      }
    };

    void load();

    return () => {
      cancelled = true;
    };
  }, [boardId, sessionKey]);

  /** Auto-detect all unique top-level keys across all rows, priority keys first. */
  const columns = useMemo<ColumnDef<HistoryRow>[]>(() => {
    const keySet = new Set<string>();
    for (const row of data) {
      for (const key of Object.keys(row)) keySet.add(key);
    }

    const ordered = [
      ...PRIORITY_KEYS.filter((k) => keySet.has(k)),
      ...[...keySet].filter((k) => !PRIORITY_KEYS.includes(k)),
    ];

    const helper = createColumnHelper<HistoryRow>();
    return ordered.map((key) =>
      helper.accessor((row) => row[key], {
        id: key,
        header: key,
        cell: (info) => {
          const value = info.getValue();
          const raw = cellStr(value);
          const formattedTimestamp = isTimestampKey(key)
            ? formatBrowserLocalTimestamp(value)
            : null;
          const display = formattedTimestamp ?? raw;
          return (
            <span title={raw.length > MAX_CELL_LEN ? raw : undefined} className="block max-w-xs truncate">
              {truncate(display, MAX_CELL_LEN)}
            </span>
          );
        },
        sortingFn: (a, b) => {
          if (isTimestampKey(key)) {
            const avTs = toTimestampMs(a.original[key]);
            const bvTs = toTimestampMs(b.original[key]);
            if (avTs !== null && bvTs !== null) return avTs - bvTs;
            if (avTs !== null) return 1;
            if (bvTs !== null) return -1;
          }
          const av = cellStr(a.original[key]);
          const bv = cellStr(b.original[key]);
          return av < bv ? -1 : av > bv ? 1 : 0;
        },
        filterFn: "auto",
      }),
    );
  }, [data]);

  const table = useReactTable({
    data,
    columns,
    state: { sorting, globalFilter, columnVisibility },
    onSortingChange: setSorting,
    onGlobalFilterChange: setGlobalFilter,
    onColumnVisibilityChange: setColumnVisibility,
    globalFilterFn: rowMatchesFilter,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
  });

  const handleCopy = useCallback(() => {
    const jsonl = data.map((row) => JSON.stringify(row)).join("\n");
    void navigator.clipboard.writeText(jsonl).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [data]);

  const title = agentName ? `${agentName} — session history` : "Session history";
  const filteredCount = table.getFilteredRowModel().rows.length;

  return (
    <main className="min-h-screen bg-[color:var(--bg)] px-6 py-5 text-[color:var(--text)]">
      <div className="mx-auto max-w-full">
        {isLoading ? (
          <>
            <div>
              <h1 className="text-lg font-semibold text-strong">{title}</h1>
              <p className="mt-0.5 text-xs text-quiet">
                Session: <span className="font-mono">{sessionKey || "—"}</span>
                {" · "}Board: <span className="font-mono">{boardId || "—"}</span>
              </p>
            </div>
            <div className="mt-8 text-sm text-quiet">Loading session history…</div>
          </>
        ) : fetchError ? (
          <>
            <div>
              <h1 className="text-lg font-semibold text-strong">{title}</h1>
              <p className="mt-0.5 text-xs text-quiet">
                Session: <span className="font-mono">{sessionKey || "—"}</span>
                {" · "}Board: <span className="font-mono">{boardId || "—"}</span>
              </p>
            </div>
            <div className="mt-4 rounded-lg border border-[color:var(--danger-border,_theme(colors.red.200))] bg-[color:var(--danger-soft,_theme(colors.red.50))] p-3 text-sm text-danger">
              {fetchError}
            </div>
          </>
        ) : data.length === 0 ? (
          <>
            <div>
              <h1 className="text-lg font-semibold text-strong">{title}</h1>
              <p className="mt-0.5 text-xs text-quiet">
                Session: <span className="font-mono">{sessionKey || "—"}</span>
                {" · "}Board: <span className="font-mono">{boardId || "—"}</span>
              </p>
            </div>
            <div className="mt-4 text-sm text-quiet">No session history available.</div>
          </>
        ) : (
          <>
            {/* Top split: controls/header (1/3) + row detail (2/3) */}
            <div className="grid gap-4 md:grid-cols-3">
              <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-4 md:col-span-1">
                <div>
                  <h1 className="text-lg font-semibold text-strong">{title}</h1>
                  <p className="mt-0.5 text-xs text-quiet">
                    Session: <span className="font-mono">{sessionKey || "—"}</span>
                    {" · "}Board: <span className="font-mono">{boardId || "—"}</span>
                  </p>
                </div>

                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    onClick={handleCopy}
                    className="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-1.5 text-xs font-medium text-muted transition hover:border-[color:var(--border-strong)] hover:text-strong"
                  >
                    {copied ? "Copied!" : "Copy raw JSONL"}
                  </button>
                  <span className="text-xs text-quiet">
                    {filteredCount === data.length
                      ? `${data.length} rows`
                      : `${filteredCount} of ${data.length} rows`}
                  </span>
                </div>

                <div className="mt-3 flex flex-wrap items-center gap-3">
                  <input
                    type="search"
                    value={globalFilter}
                    onChange={(e) => setGlobalFilter(e.target.value)}
                    placeholder="Filter rows…"
                    className="h-8 w-full rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong placeholder:text-quiet focus:border-[color:var(--brand)] focus:outline-none"
                  />
                  {globalFilter ? (
                    <button
                      type="button"
                      onClick={() => setGlobalFilter("")}
                      className="text-xs text-quiet hover:text-strong"
                    >
                      ✕ Clear
                    </button>
                  ) : null}
                  <details className="relative">
                    <summary className="h-8 list-none cursor-pointer rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-1.5 text-xs font-medium text-muted transition hover:border-[color:var(--border-strong)] hover:text-strong">
                      Columns
                    </summary>
                    <div className="absolute left-0 z-20 mt-2 max-h-72 w-64 overflow-y-auto rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-2 shadow-xl">
                      <div className="mb-2 flex items-center justify-between px-1">
                        <button
                          type="button"
                          onClick={() => table.resetColumnVisibility()}
                          className="text-[11px] text-quiet hover:text-strong"
                        >
                          Show all
                        </button>
                      </div>
                      <div className="space-y-1">
                        {table
                          .getAllLeafColumns()
                          .filter((column) => column.getCanHide())
                          .map((column) => {
                            const isVisible = column.getIsVisible();
                            return (
                              <label
                                key={column.id}
                                className="flex items-center gap-2 rounded-md px-2 py-1 text-xs text-muted hover:bg-[color:var(--surface-muted)]"
                              >
                                <input
                                  type="checkbox"
                                  checked={isVisible}
                                  onChange={column.getToggleVisibilityHandler()}
                                />
                                <span className="truncate">{column.id}</span>
                              </label>
                            );
                          })}
                      </div>
                    </div>
                  </details>
                </div>
              </div>

              <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-4 md:col-span-2">
                <div className="mb-2 flex items-center justify-between">
                  <p className="text-[10px] font-semibold uppercase tracking-wider text-quiet">
                    Row detail
                  </p>
                  {selectedRow ? (
                    <button
                      type="button"
                      onClick={() => setSelectedRow(null)}
                      className="text-xs text-quiet hover:text-strong"
                    >
                      ✕ Close
                    </button>
                  ) : null}
                </div>
                <div
                  className="min-h-[220px] overflow-x-auto rounded-lg border border-slate-200 bg-white p-3"
                  style={{
                    ["--w-rjv-background-color" as string]: "#ffffff",
                    ["--w-rjv-color" as string]: "#111827",
                  }}
                >
                  {selectedRow ? (
                    <JsonView
                      value={selectedRow}
                      collapsed={1}
                      displayDataTypes={false}
                      displayObjectSize={false}
                      enableClipboard={false}
                      style={{
                        backgroundColor: "#ffffff",
                        color: "#111827",
                        fontSize: "12px",
                        lineHeight: "1.5",
                        fontFamily:
                          'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
                      }}
                    />
                  ) : (
                    <p className="text-sm text-slate-600">
                      Select a row in the table to inspect its full JSON payload.
                    </p>
                  )}
                </div>
              </div>
            </div>

            {/* Table */}
            <div className="mt-4 overflow-x-auto rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)]">
              <table className="w-full text-xs">
                <thead>
                  {table.getHeaderGroups().map((headerGroup) => (
                    <tr
                      key={headerGroup.id}
                      className="border-b border-[color:var(--border)] bg-[color:var(--surface-muted)]"
                    >
                      {headerGroup.headers.map((header) => {
                        const sorted = header.column.getIsSorted();
                        return (
                          <th
                            key={header.id}
                            onClick={header.column.getToggleSortingHandler()}
                            className="cursor-pointer select-none whitespace-nowrap px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wider text-quiet hover:text-strong"
                          >
                            {flexRender(header.column.columnDef.header, header.getContext())}
                            <span className="ml-1 opacity-50">
                              {sorted === "asc" ? "↑" : sorted === "desc" ? "↓" : "⇅"}
                            </span>
                          </th>
                        );
                      })}
                    </tr>
                  ))}
                </thead>
                <tbody>
                  {table.getRowModel().rows.length === 0 ? (
                    <tr>
                      <td
                        colSpan={columns.length}
                        className="px-3 py-6 text-center text-sm text-quiet"
                      >
                        No rows match the current filter.
                      </td>
                    </tr>
                  ) : (
                    table.getRowModel().rows.map((row, i) => {
                      const isSelected = selectedRow === row.original;
                      return (
                        <tr
                          key={row.id}
                          onClick={() =>
                            setSelectedRow(isSelected ? null : row.original)
                          }
                          className={[
                            "cursor-pointer border-b border-[color:var(--border)] transition",
                            isSelected
                              ? "bg-[color:var(--accent-soft)]"
                              : i % 2 !== 0
                                ? "bg-[color:var(--surface-strong)]/20 hover:bg-[color:var(--surface-muted)]"
                                : "hover:bg-[color:var(--surface-muted)]",
                          ].join(" ")}
                        >
                          {row.getVisibleCells().map((cell) => (
                            <td
                              key={cell.id}
                              className="max-w-xs px-3 py-1.5 align-top text-muted"
                            >
                              {flexRender(cell.column.columnDef.cell, cell.getContext())}
                            </td>
                          ))}
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
          </>
        )}
      </div>
    </main>
  );
}
