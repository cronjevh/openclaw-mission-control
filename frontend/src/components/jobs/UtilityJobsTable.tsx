import { useMemo, useState } from "react";

import {
  type ColumnDef,
  type OnChangeFn,
  type SortingState,
  type Updater,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
} from "@tanstack/react-table";

import type {
  AgentRead,
  BoardRead,
  UtilityJobRead,
  UtilityJobScriptOption,
} from "@/api/generated/model";
import { Badge } from "@/components/ui/badge";
import {
  DataTable,
  type DataTableEmptyState,
} from "@/components/tables/DataTable";
import { dateCell } from "@/components/tables/cell-formatters";

type UtilityJobsTableProps = {
  jobs: UtilityJobRead[];
  boards: BoardRead[];
  agents: AgentRead[];
  scriptOptions: UtilityJobScriptOption[];
  isLoading?: boolean;
  sorting?: SortingState;
  onSortingChange?: OnChangeFn<SortingState>;
  stickyHeader?: boolean;
  onEdit?: (job: UtilityJobRead) => void;
  onDelete?: (job: UtilityJobRead) => void;
  emptyState?: Omit<DataTableEmptyState, "icon"> & {
    icon?: DataTableEmptyState["icon"];
  };
};

const DEFAULT_EMPTY_ICON = (
  <svg
    className="h-16 w-16 text-quiet"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="1.5"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d="M8 2v4" />
    <path d="M16 2v4" />
    <path d="M3 10h18" />
    <path d="M4 6h16v15H4z" />
    <path d="M8 14h.01" />
    <path d="M12 14h.01" />
    <path d="M16 14h.01" />
  </svg>
);

export function UtilityJobsTable({
  jobs,
  boards,
  agents,
  scriptOptions,
  isLoading = false,
  sorting,
  onSortingChange,
  stickyHeader = false,
  onEdit,
  onDelete,
  emptyState,
}: UtilityJobsTableProps) {
  const [internalSorting, setInternalSorting] = useState<SortingState>([
    { id: "name", desc: false },
  ]);
  const resolvedSorting = sorting ?? internalSorting;
  const handleSortingChange: OnChangeFn<SortingState> =
    onSortingChange ??
    ((updater: Updater<SortingState>) => {
      setInternalSorting(updater);
    });

  const boardById = useMemo(
    () => new Map(boards.map((board) => [board.id, board.name])),
    [boards],
  );
  const agentById = useMemo(
    () => new Map(agents.map((agent) => [agent.id, agent.name])),
    [agents],
  );
  const scriptByKey = useMemo(
    () => new Map(scriptOptions.map((option) => [option.key, option.label])),
    [scriptOptions],
  );

  const columns = useMemo<ColumnDef<UtilityJobRead>[]>(
    () => [
      {
        accessorKey: "name",
        header: "Job",
        cell: ({ row }) => (
          <div className="space-y-1">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-sm font-semibold text-strong">
                {row.original.name}
              </span>
              <Badge variant={row.original.enabled ? "success" : "outline"}>
                {row.original.enabled ? "Enabled" : "Disabled"}
              </Badge>
            </div>
            <p className="text-xs text-quiet">
              {row.original.description || "No description"}
            </p>
          </div>
        ),
      },
      {
        accessorKey: "cron_expression",
        header: "Schedule",
        cell: ({ row }) => (
          <code className="rounded border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-2 py-1 text-xs text-muted">
            {row.original.cron_expression}
          </code>
        ),
      },
      {
        accessorKey: "script_key",
        header: "Script",
        cell: ({ row }) => (
          <div className="space-y-1 text-sm">
            <p className="font-medium text-muted">
              {scriptByKey.get(row.original.script_key) ??
                row.original.script_key}
            </p>
            <p className="text-xs text-quiet">{row.original.script_key}</p>
          </div>
        ),
      },
      {
        id: "scope",
        header: "Scope",
        cell: ({ row }) => {
          const boardName = row.original.board_id
            ? (boardById.get(row.original.board_id) ??
              row.original.board_id.slice(0, 8))
            : "Global";
          const agentName = row.original.agent_id
            ? (agentById.get(row.original.agent_id) ??
              row.original.agent_id.slice(0, 8))
            : null;
          return (
            <div className="space-y-1 text-sm text-muted">
              <p>{boardName}</p>
              {agentName ? (
                <p className="text-xs text-quiet">{agentName}</p>
              ) : null}
            </div>
          );
        },
      },
      {
        accessorKey: "updated_at",
        header: "Updated",
        cell: ({ row }) => dateCell(row.original.updated_at),
      },
    ],
    [agentById, boardById, scriptByKey],
  );

  // eslint-disable-next-line react-hooks/incompatible-library
  const table = useReactTable({
    data: jobs,
    columns,
    state: {
      sorting: resolvedSorting,
    },
    onSortingChange: handleSortingChange,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  return (
    <DataTable
      table={table}
      isLoading={isLoading}
      stickyHeader={stickyHeader}
      rowClassName="transition hover:bg-[color:var(--surface-muted)]"
      cellClassName="px-6 py-4 align-top"
      rowActions={
        onEdit || onDelete
          ? {
              actions: [
                ...(onEdit
                  ? [{ key: "edit", label: "Edit", onClick: onEdit }]
                  : []),
                ...(onDelete
                  ? [{ key: "delete", label: "Delete", onClick: onDelete }]
                  : []),
              ],
            }
          : undefined
      }
      emptyState={
        emptyState
          ? {
              icon: emptyState.icon ?? DEFAULT_EMPTY_ICON,
              title: emptyState.title,
              description: emptyState.description,
              actionHref: emptyState.actionHref,
              actionLabel: emptyState.actionLabel,
            }
          : undefined
      }
    />
  );
}
