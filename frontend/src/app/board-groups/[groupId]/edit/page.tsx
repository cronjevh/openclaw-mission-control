"use client";

export const dynamic = "force-dynamic";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter, useSearchParams } from "next/navigation";

import { useAuth } from "@/auth/clerk";

import { ApiError } from "@/api/mutator";
import {
  type listBoardsApiV1BoardsGetResponse,
  updateBoardApiV1BoardsBoardIdPatch,
  useListBoardsApiV1BoardsGet,
} from "@/api/generated/boards/boards";
import {
  applyBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatPost,
  type getBoardGroupApiV1BoardGroupsGroupIdGetResponse,
  type getBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGetResponse,
  useGetBoardGroupApiV1BoardGroupsGroupIdGet,
  useGetBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGet,
  useUpdateBoardGroupApiV1BoardGroupsGroupIdPatch,
} from "@/api/generated/board-groups/board-groups";
import {
  type getMyMembershipApiV1OrganizationsMeMemberGetResponse,
  useGetMyMembershipApiV1OrganizationsMeMemberGet,
} from "@/api/generated/organizations/organizations";
import type {
  BoardGroupHeartbeatApplyResult,
  BoardGroupHeartbeatConfig,
  BoardGroupRead,
  BoardGroupUpdate,
  BoardRead,
} from "@/api/generated/model";
import { cn } from "@/lib/utils";
import { DashboardPageLayout } from "@/components/templates/DashboardPageLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";

type HeartbeatUnit = "s" | "m" | "h" | "d";

function parseEvery(every: string | null | undefined): { amount: string; unit: HeartbeatUnit } | null {
  if (!every) return null;
  const match = every.match(/^(\d+)([smhd])$/);
  if (!match) return null;
  return { amount: match[1], unit: match[2] as HeartbeatUnit };
}

const HEARTBEAT_PRESETS: Array<{ label: string; amount: number; unit: HeartbeatUnit }> = [
  { label: "30s", amount: 30, unit: "s" },
  { label: "1m", amount: 1, unit: "m" },
  { label: "2m", amount: 2, unit: "m" },
  { label: "5m", amount: 5, unit: "m" },
  { label: "10m", amount: 10, unit: "m" },
  { label: "15m", amount: 15, unit: "m" },
  { label: "30m", amount: 30, unit: "m" },
  { label: "1h", amount: 1, unit: "h" },
];

function PaceSelector({
  amount,
  unit,
  every,
  disabled,
  isApplying,
  error,
  result,
  onAmountChange,
  onUnitChange,
  onApply,
}: {
  amount: string;
  unit: HeartbeatUnit;
  every: string;
  disabled: boolean;
  isApplying: boolean;
  error: string | null;
  result: BoardGroupHeartbeatApplyResult | null;
  onAmountChange: (v: string) => void;
  onUnitChange: (v: HeartbeatUnit) => void;
  onApply: () => void;
}) {
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-1">
        {HEARTBEAT_PRESETS.map((preset) => {
          const value = `${preset.amount}${preset.unit}`;
          return (
            <button
              key={value}
              type="button"
              disabled={disabled}
              onClick={() => {
                onAmountChange(String(preset.amount));
                onUnitChange(preset.unit);
              }}
              className={cn(
                "rounded-md px-2.5 py-1 text-xs font-semibold transition-colors border",
                every === value
                  ? "border-[color:var(--accent)] bg-[color:var(--accent)] text-white"
                  : "border-[color:var(--border)] bg-[color:var(--surface)] text-muted hover:border-[color:var(--border-strong)] hover:text-strong",
                disabled && "opacity-50 cursor-not-allowed",
              )}
            >
              {preset.label}
            </button>
          );
        })}
      </div>
      <div className="flex items-center gap-2">
        <input
          value={amount}
          onChange={(e) => onAmountChange(e.target.value)}
          className={cn(
            "h-8 w-20 rounded-md border bg-[color:var(--surface)] px-2 text-xs text-strong shadow-sm",
            every ? "border-[color:var(--border)]" : "border-[color:var(--danger-border)]",
            disabled && "opacity-60 cursor-not-allowed",
          )}
          placeholder="10"
          inputMode="numeric"
          type="number"
          min={1}
          step={1}
          disabled={disabled}
        />
        <select
          value={unit}
          onChange={(e) => onUnitChange(e.target.value as HeartbeatUnit)}
          className={cn(
            "h-8 rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-2 text-xs text-strong shadow-sm",
            disabled && "opacity-60 cursor-not-allowed",
          )}
          disabled={disabled}
        >
          <option value="s">seconds</option>
          <option value="m">minutes</option>
          <option value="h">hours</option>
          <option value="d">days</option>
        </select>
        <Button
          size="sm"
          type="button"
          onClick={onApply}
          disabled={isApplying || !every || disabled}
        >
          {isApplying ? "Applying…" : "Apply"}
        </Button>
      </div>
      {error && <p className="text-xs text-danger">{error}</p>}
      {result && !error && (
        <p className="text-xs text-success">
          ✓ Applied to {result.updated_agent_ids.length} agent
          {result.updated_agent_ids.length !== 1 ? "s" : ""}
          {result.failed_agent_ids.length > 0
            ? `, ${result.failed_agent_ids.length} failed`
            : ""}
        </p>
      )}
    </div>
  );
}

const slugify = (value: string) =>
  value
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "") || "group";

export default function EditBoardGroupPage() {
  const { isSignedIn } = useAuth();
  const router = useRouter();
  const searchParams = useSearchParams();
  const params = useParams();
  const groupIdParam = params?.groupId;
  const groupId = Array.isArray(groupIdParam) ? groupIdParam[0] : groupIdParam;

  const [name, setName] = useState<string | undefined>(undefined);
  const [description, setDescription] = useState<string | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  const [boardSearch, setBoardSearch] = useState("");
  const [selectedBoardIds, setSelectedBoardIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [isAssignmentsSaving, setIsAssignmentsSaving] = useState(false);
  const [assignmentsError, setAssignmentsError] = useState<string | null>(null);
  const [assignmentsResult, setAssignmentsResult] = useState<{
    updated: number;
    failed: number;
  } | null>(null);

  // Worker agents heartbeat
  const [workerAmount, setWorkerAmount] = useState("10");
  const [workerUnit, setWorkerUnit] = useState<HeartbeatUnit>("m");
  const [workerSeeded, setWorkerSeeded] = useState(false);
  const [isWorkerApplying, setIsWorkerApplying] = useState(false);
  const [workerApplyError, setWorkerApplyError] = useState<string | null>(null);
  const [workerApplyResult, setWorkerApplyResult] = useState<BoardGroupHeartbeatApplyResult | null>(null);

  // Lead agents heartbeat
  const [leadAmount, setLeadAmount] = useState("30");
  const [leadUnit, setLeadUnit] = useState<HeartbeatUnit>("m");
  const [leadSeeded, setLeadSeeded] = useState(false);
  const [isLeadApplying, setIsLeadApplying] = useState(false);
  const [leadApplyError, setLeadApplyError] = useState<string | null>(null);
  const [leadApplyResult, setLeadApplyResult] = useState<BoardGroupHeartbeatApplyResult | null>(null);

  const assignFailedParam = searchParams.get("assign_failed");
  const assignFailedCount = assignFailedParam
    ? Number.parseInt(assignFailedParam, 10)
    : null;

  const groupQuery = useGetBoardGroupApiV1BoardGroupsGroupIdGet<
    getBoardGroupApiV1BoardGroupsGroupIdGetResponse,
    ApiError
  >(groupId ?? "", {
    query: {
      enabled: Boolean(isSignedIn && groupId),
      refetchOnMount: "always",
      retry: false,
    },
  });

  const loadedGroup: BoardGroupRead | null =
    groupQuery.data?.status === 200 ? groupQuery.data.data : null;
  const baseGroup = loadedGroup;

  const membershipQuery = useGetMyMembershipApiV1OrganizationsMeMemberGet<
    getMyMembershipApiV1OrganizationsMeMemberGetResponse,
    ApiError
  >({
    query: {
      enabled: Boolean(isSignedIn),
      refetchOnMount: "always",
    },
  });

  const member =
    membershipQuery.data?.status === 200 ? membershipQuery.data.data : null;
  const isOrgAdmin = member?.role === "admin" || member?.role === "owner";

  const heartbeatConfigQuery =
    useGetBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGet<
      getBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGetResponse,
      ApiError
    >(groupId ?? "", {
      query: {
        enabled: Boolean(isSignedIn && groupId && isOrgAdmin),
        refetchOnMount: "always",
        retry: false,
      },
    });

  const heartbeatConfig: BoardGroupHeartbeatConfig | null =
    heartbeatConfigQuery.data?.status === 200 ? heartbeatConfigQuery.data.data : null;

  const workerHeartbeatEvery = useMemo(() => {
    const parsed = Number.parseInt(workerAmount, 10);
    if (!Number.isFinite(parsed) || parsed <= 0) return "";
    return `${parsed}${workerUnit}`;
  }, [workerAmount, workerUnit]);

  const leadHeartbeatEvery = useMemo(() => {
    const parsed = Number.parseInt(leadAmount, 10);
    if (!Number.isFinite(parsed) || parsed <= 0) return "";
    return `${parsed}${leadUnit}`;
  }, [leadAmount, leadUnit]);

  const resolvedName = name ?? baseGroup?.name ?? "";
  const resolvedDescription = description ?? baseGroup?.description ?? "";

  useEffect(() => {
    if (!heartbeatConfig || workerSeeded) return;
    const parsed = parseEvery(heartbeatConfig.worker_every);
    if (parsed) {
      setWorkerAmount(parsed.amount);
      setWorkerUnit(parsed.unit);
    }
    setWorkerSeeded(true);
  }, [heartbeatConfig, workerSeeded]);

  useEffect(() => {
    if (!heartbeatConfig || leadSeeded) return;
    const parsed = parseEvery(heartbeatConfig.lead_every);
    if (parsed) {
      setLeadAmount(parsed.amount);
      setLeadUnit(parsed.unit);
    }
    setLeadSeeded(true);
  }, [heartbeatConfig, leadSeeded]);

  const applyWorkerHeartbeat = useCallback(async () => {
    if (!isSignedIn || !groupId) { setWorkerApplyError("Sign in to apply."); return; }
    if (!isOrgAdmin) { setWorkerApplyError("Admin access required."); return; }
    const trimmed = workerHeartbeatEvery.trim();
    if (!trimmed) { setWorkerApplyError("Cadence is required."); return; }
    setIsWorkerApplying(true);
    setWorkerApplyError(null);
    try {
      const result = await applyBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatPost(
        groupId,
        { every: trimmed, include_board_leads: false },
      );
      if (result.status !== 200) throw new Error("Unable to apply.");
      setWorkerApplyResult(result.data);
    } catch (err) {
      setWorkerApplyError(err instanceof Error ? err.message : "Unable to apply.");
    } finally {
      setIsWorkerApplying(false);
    }
  }, [groupId, isOrgAdmin, isSignedIn, workerHeartbeatEvery]);

  const applyLeadHeartbeat = useCallback(async () => {
    if (!isSignedIn || !groupId) { setLeadApplyError("Sign in to apply."); return; }
    if (!isOrgAdmin) { setLeadApplyError("Admin access required."); return; }
    const trimmed = leadHeartbeatEvery.trim();
    if (!trimmed) { setLeadApplyError("Cadence is required."); return; }
    setIsLeadApplying(true);
    setLeadApplyError(null);
    try {
      const result = await applyBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatPost(
        groupId,
        { every: trimmed, include_board_leads: true },
      );
      if (result.status !== 200) throw new Error("Unable to apply.");
      setLeadApplyResult(result.data);
    } catch (err) {
      setLeadApplyError(err instanceof Error ? err.message : "Unable to apply.");
    } finally {
      setIsLeadApplying(false);
    }
  }, [groupId, isOrgAdmin, isSignedIn, leadHeartbeatEvery]);

  const allBoardsQuery = useListBoardsApiV1BoardsGet<
    listBoardsApiV1BoardsGetResponse,
    ApiError
  >(
    { limit: 200 },
    {
      query: {
        enabled: Boolean(isSignedIn),
        refetchOnMount: "always",
        retry: false,
      },
    },
  );

  const groupBoardsQuery = useListBoardsApiV1BoardsGet<
    listBoardsApiV1BoardsGetResponse,
    ApiError
  >(
    { limit: 200, board_group_id: groupId ?? null },
    {
      query: {
        enabled: Boolean(isSignedIn && groupId),
        refetchOnMount: "always",
        retry: false,
      },
    },
  );

  const allBoards = useMemo<BoardRead[]>(() => {
    if (allBoardsQuery.data?.status !== 200) return [];
    return allBoardsQuery.data.data.items ?? [];
  }, [allBoardsQuery.data]);

  const groupBoards = useMemo<BoardRead[]>(() => {
    if (groupBoardsQuery.data?.status !== 200) return [];
    return groupBoardsQuery.data.data.items ?? [];
  }, [groupBoardsQuery.data]);

  const boards = useMemo<BoardRead[]>(() => {
    const byId = new Map<string, BoardRead>();
    for (const board of allBoards) {
      byId.set(board.id, board);
    }
    for (const board of groupBoards) {
      byId.set(board.id, board);
    }
    const merged = Array.from(byId.values());
    merged.sort((a, b) => a.name.localeCompare(b.name));
    return merged;
  }, [allBoards, groupBoards]);

  const initializedSelectionRef = useRef(false);

  useEffect(() => {
    if (!groupId) return;
    if (initializedSelectionRef.current) return;
    if (groupBoardsQuery.data?.status !== 200) return;
    initializedSelectionRef.current = true;
    setSelectedBoardIds(new Set(groupBoards.map((board) => board.id)));
  }, [groupBoards, groupBoardsQuery.data, groupId]);

  const updateMutation =
    useUpdateBoardGroupApiV1BoardGroupsGroupIdPatch<ApiError>({
      mutation: {
        retry: false,
      },
    });

  const isGroupSaving = groupQuery.isLoading || updateMutation.isPending;
  const boardsLoading = allBoardsQuery.isLoading || groupBoardsQuery.isLoading;
  const boardsError = groupBoardsQuery.error ?? allBoardsQuery.error ?? null;
  const isBoardsBusy = boardsLoading || isAssignmentsSaving;
  const isLoading = isGroupSaving || isBoardsBusy;
  const errorMessage = error ?? groupQuery.error?.message ?? null;
  const isFormReady = Boolean(resolvedName.trim());

  const handleSaveAssignments = async (): Promise<{
    updated: number;
    failed: number;
  } | null> => {
    if (!isSignedIn || !groupId) return null;
    if (groupBoardsQuery.data?.status !== 200) {
      setAssignmentsError("Group boards are not loaded yet.");
      return null;
    }

    setAssignmentsError(null);
    setAssignmentsResult(null);

    const desired = selectedBoardIds;
    const current = new Set(groupBoards.map((board) => board.id));
    const toAdd = Array.from(desired).filter((id) => !current.has(id));
    const toRemove = Array.from(current).filter((id) => !desired.has(id));

    const failures: string[] = [];
    let updated = 0;

    for (const boardId of toAdd) {
      try {
        const result = await updateBoardApiV1BoardsBoardIdPatch(boardId, {
          board_group_id: groupId,
        });
        if (result.status === 200) {
          updated += 1;
        } else {
          failures.push(boardId);
        }
      } catch {
        failures.push(boardId);
      }
    }

    for (const boardId of toRemove) {
      try {
        const result = await updateBoardApiV1BoardsBoardIdPatch(boardId, {
          board_group_id: null,
        });
        if (result.status === 200) {
          updated += 1;
        } else {
          failures.push(boardId);
        }
      } catch {
        failures.push(boardId);
      }
    }

    setAssignmentsResult({ updated, failed: failures.length });
    if (failures.length > 0) {
      setAssignmentsError(
        `Failed to update ${failures.length} board assignment${
          failures.length === 1 ? "" : "s"
        }.`,
      );
    }

    void groupBoardsQuery.refetch();
    void allBoardsQuery.refetch();

    return { updated, failed: failures.length };
  };

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!isSignedIn || !groupId) return;
    const trimmedName = resolvedName.trim();
    if (!trimmedName) {
      setError("Group name is required.");
      return;
    }

    setError(null);
    setAssignmentsError(null);
    setAssignmentsResult(null);

    const payload: BoardGroupUpdate = {
      name: trimmedName,
      slug: slugify(trimmedName),
      description: resolvedDescription.trim() || null,
    };

    setIsAssignmentsSaving(true);
    try {
      const result = await updateMutation.mutateAsync({
        groupId,
        data: payload,
      });
      if (result.status !== 200) {
        setError("Something went wrong.");
        return;
      }

      const assignments = await handleSaveAssignments();
      if (!assignments || assignments.failed > 0) {
        return;
      }

      router.push(`/board-groups/${result.data.id}`);
    } catch (err) {
      const message =
        err instanceof ApiError
          ? err.message
          : err instanceof Error
            ? err.message
            : null;
      setError(message || "Something went wrong.");
    } finally {
      setIsAssignmentsSaving(false);
    }
  };

  const title = useMemo(
    () => baseGroup?.name ?? "Edit group",
    [baseGroup?.name],
  );

  return (
    <DashboardPageLayout
      signedOut={{
        message: "Sign in to edit board groups.",
        forceRedirectUrl: `/board-groups/${groupId ?? ""}/edit`,
      }}
      title={title}
      description="Update the shared context that connects boards in this group."
    >
      <form
        onSubmit={handleSubmit}
        className="space-y-6 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 shadow-sm"
      >
        {assignFailedCount && Number.isFinite(assignFailedCount) ? (
          <div className="rounded-xl border border-[color:var(--warning-border)] bg-[color:var(--warning-soft)] p-4 text-sm text-warning shadow-sm">
            Group was created, but {assignFailedCount} board assignment
            {assignFailedCount === 1 ? "" : "s"} failed. You can retry below.
          </div>
        ) : null}
        <div className="grid gap-6 md:grid-cols-2">
          <div className="space-y-2">
            <label className="text-sm font-medium text-strong">
              Group name <span className="text-danger">*</span>
            </label>
            <Input
              value={resolvedName}
              onChange={(event) => setName(event.target.value)}
              placeholder="Group name"
              disabled={isLoading || !baseGroup}
            />
          </div>
        </div>

        <div className="space-y-2">
          <label className="text-sm font-medium text-strong">
            Description
          </label>
          <Textarea
            value={resolvedDescription}
            onChange={(event) => setDescription(event.target.value)}
            placeholder="What ties these boards together?"
            className="min-h-[120px]"
            disabled={isLoading || !baseGroup}
          />
        </div>

        <div className="space-y-2 border-t border-[color:var(--border)] pt-6">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div>
              <p className="text-sm font-medium text-strong">Boards</p>
              <p className="mt-1 text-xs text-quiet">
                Assign boards to this group to share context across related
                work.
              </p>
            </div>
            <span className="text-xs text-quiet">
              {selectedBoardIds.size} selected
            </span>
          </div>

          <Input
            value={boardSearch}
            onChange={(event) => setBoardSearch(event.target.value)}
            placeholder="Search boards..."
            disabled={isLoading || !baseGroup}
          />

          <div className="max-h-64 overflow-auto rounded-xl border border-[color:var(--border)] bg-[color:var(--surface-muted)]">
            {boardsLoading && boards.length === 0 ? (
              <div className="px-4 py-6 text-sm text-quiet">
                Loading boards…
              </div>
            ) : boardsError ? (
              <div className="px-4 py-6 text-sm text-danger">
                {boardsError.message}
              </div>
            ) : boards.length === 0 ? (
              <div className="px-4 py-6 text-sm text-quiet">
                No boards found.
              </div>
            ) : (
              <ul className="divide-y divide-slate-200">
                {boards
                  .filter((board) => {
                    const q = boardSearch.trim().toLowerCase();
                    if (!q) return true;
                    return (
                      board.name.toLowerCase().includes(q) ||
                      board.slug.toLowerCase().includes(q)
                    );
                  })
                  .map((board) => {
                    const checked = selectedBoardIds.has(board.id);
                    const isInThisGroup = board.board_group_id === groupId;
                    const isAlreadyGrouped =
                      Boolean(board.board_group_id) && !isInThisGroup;
                    return (
                      <li key={board.id} className="px-4 py-3">
                        <label className="flex cursor-pointer items-start gap-3">
                          <input
                            type="checkbox"
                            className="mt-1 h-4 w-4 rounded border-[color:var(--border-strong)] text-info"
                            checked={checked}
                            onChange={() => {
                              setSelectedBoardIds((prev) => {
                                const next = new Set(prev);
                                if (next.has(board.id)) {
                                  next.delete(board.id);
                                } else {
                                  next.add(board.id);
                                }
                                return next;
                              });
                            }}
                            disabled={isLoading || !baseGroup}
                          />
                          <div className="min-w-0">
                            <p className="truncate text-sm font-medium text-strong">
                              {board.name}
                            </p>
                            <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-quiet">
                              <span className="font-mono text-[11px] text-quiet">
                                {board.id}
                              </span>
                              {isAlreadyGrouped ? (
                                <span className="rounded-full border border-[color:var(--warning-border)] bg-[color:var(--warning-soft)] px-2 py-0.5 text-warning">
                                  in another group
                                </span>
                              ) : null}
                            </div>
                          </div>
                        </label>
                      </li>
                    );
                  })}
              </ul>
            )}
          </div>

          {assignmentsError ? (
            <p className="text-sm text-danger">{assignmentsError}</p>
          ) : null}
          {assignmentsResult ? (
            <p className="text-sm text-muted">
              Updated {assignmentsResult.updated} board
              {assignmentsResult.updated === 1 ? "" : "s"}, failed{" "}
              {assignmentsResult.failed}.
            </p>
          ) : null}
        </div>

        {isOrgAdmin && (
          <div className="space-y-4 border-t border-[color:var(--border)] pt-6">
            <div>
              <p className="text-sm font-medium text-strong">Agent Check-in Rates</p>
              <p className="mt-1 text-xs text-quiet">
                Configure how often agents in this group wake up and report back.
              </p>
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              {/* Worker rate */}
              <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-4">
                <div className="mb-3">
                  <p className="text-sm font-semibold text-strong">⚙️ Worker check-in rate</p>
                  <p className="mt-0.5 text-xs text-muted">
                    How often worker agents wake up, pick up tasks, and report back.
                  </p>
                </div>
                <PaceSelector
                  amount={workerAmount}
                  unit={workerUnit}
                  every={workerHeartbeatEvery}
                  disabled={isLoading || !baseGroup}
                  isApplying={isWorkerApplying}
                  error={workerApplyError}
                  result={workerApplyResult}
                  onAmountChange={setWorkerAmount}
                  onUnitChange={setWorkerUnit}
                  onApply={() => void applyWorkerHeartbeat()}
                />
              </div>

              {/* Lead rate */}
              <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-4">
                <div className="mb-3">
                  <p className="text-sm font-semibold text-strong">👑 Lead check-in rate</p>
                  <p className="mt-0.5 text-xs text-muted">
                    How often board leads review progress and coordinate across boards.
                  </p>
                </div>
                <PaceSelector
                  amount={leadAmount}
                  unit={leadUnit}
                  every={leadHeartbeatEvery}
                  disabled={isLoading || !baseGroup}
                  isApplying={isLeadApplying}
                  error={leadApplyError}
                  result={leadApplyResult}
                  onAmountChange={setLeadAmount}
                  onUnitChange={setLeadUnit}
                  onApply={() => void applyLeadHeartbeat()}
                />
              </div>
            </div>
          </div>
        )}

        {errorMessage ? (
          <p className="text-sm text-danger">{errorMessage}</p>
        ) : null}

        <div className="flex justify-end gap-3">
          <Button
            type="button"
            variant="ghost"
            onClick={() => router.push(`/board-groups/${groupId ?? ""}`)}
            disabled={isLoading}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            disabled={isLoading || !baseGroup || !isFormReady}
          >
            {isLoading ? "Saving…" : "Save changes"}
          </Button>
        </div>
      </form>
    </DashboardPageLayout>
  );
}
