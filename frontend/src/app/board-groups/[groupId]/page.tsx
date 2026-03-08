"use client";

export const dynamic = "force-dynamic";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";

import { SignedIn, SignedOut, useAuth } from "@/auth/clerk";
import {
  MessageSquare,
  NotebookText,
  Settings,
  X,
} from "lucide-react";

import { ApiError, customFetch } from "@/api/mutator";
import {
  applyBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatPost,
  type getBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGetResponse,
  type getBoardGroupSnapshotApiV1BoardGroupsGroupIdSnapshotGetResponse,
  useGetBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGet,
  useGetBoardGroupSnapshotApiV1BoardGroupsGroupIdSnapshotGet,
} from "@/api/generated/board-groups/board-groups";
import {
  createBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryPost,
  type listBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryGetResponse,
  streamBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryStreamGet,
  useListBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryGet,
} from "@/api/generated/board-group-memory/board-group-memory";
import {
  type getMyMembershipApiV1OrganizationsMeMemberGetResponse,
  useGetMyMembershipApiV1OrganizationsMeMemberGet,
} from "@/api/generated/organizations/organizations";
import type {
  BoardGroupHeartbeatApplyResult,
  BoardGroupHeartbeatConfig,
  BoardGroupMemoryRead,
  OrganizationMemberRead,
} from "@/api/generated/model";

import { Markdown } from "@/components/atoms/Markdown";
import { SignedOutPanel } from "@/components/auth/SignedOutPanel";
import { DashboardSidebar } from "@/components/organisms/DashboardSidebar";
import { DashboardShell } from "@/components/templates/DashboardShell";
import { BoardChatComposer } from "@/components/BoardChatComposer";
import { Button, buttonVariants } from "@/components/ui/button";
import { createExponentialBackoff } from "@/lib/backoff";
import { apiDatetimeToMs } from "@/lib/datetime";
import { formatTimestamp } from "@/lib/formatters";
import { cn } from "@/lib/utils";
import { usePageActive } from "@/hooks/usePageActive";

const statusLabel = (value?: string | null) => {
  switch (value) {
    case "inbox":
      return "Inbox";
    case "in_progress":
      return "In progress";
    case "review":
      return "Review";
    case "done":
      return "Done";
    default:
      return value || "—";
  }
};

const statusTone = (value?: string | null) => {
  switch (value) {
    case "in_progress":
      return "bg-[color:var(--success-soft)] text-success border-emerald-200";
    case "review":
      return "bg-[color:var(--warning-soft)] text-warning border-[color:var(--warning-border)]";
    case "done":
      return "bg-[color:var(--surface-muted)] text-muted border-[color:var(--border)]";
    default:
      return "bg-[color:var(--info-soft)] text-info border-[color:var(--info-border)]";
  }
};

const priorityTone = (value?: string | null) => {
  switch (value) {
    case "high":
      return "bg-[color:var(--danger-soft)] text-danger border-[color:var(--danger-border)]";
    case "low":
      return "bg-[color:var(--surface-muted)] text-muted border-[color:var(--border)]";
    default:
      return "bg-[color:var(--info-soft)] text-info border-[color:var(--info-border)]";
  }
};


const canWriteGroupBoards = (
  member: OrganizationMemberRead | null,
  boardIds: Set<string>,
) => {
  if (!member) return false;
  if (member.all_boards_write) return true;
  if (!member.board_access || boardIds.size === 0) return false;
  return member.board_access.some(
    (access) => access.can_write && boardIds.has(access.board_id),
  );
};

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
          onClick={onApply}
          disabled={isApplying || !every || disabled}
        >
          {isApplying ? "Applying…" : "Apply"}
        </Button>
      </div>
      {error && (
        <p className="text-xs text-danger">{error}</p>
      )}
      {result && !error && (
        <p className="text-xs text-success">
          ✓ Applied to {result.updated_agent_ids.length} agent{result.updated_agent_ids.length !== 1 ? "s" : ""}
          {result.failed_agent_ids.length > 0 ? `, ${result.failed_agent_ids.length} failed` : ""}
        </p>
      )}
    </div>
  );
}

function GroupChatMessageCard({ message }: { message: BoardGroupMemoryRead }) {
  return (
    <div className="rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold text-strong">
          {message.source ?? "User"}
        </p>
        <span className="text-xs text-quiet">
          {formatTimestamp(message.created_at)}
        </span>
      </div>
      <div className="mt-2 select-text cursor-text text-sm leading-relaxed text-strong break-words">
        <Markdown content={message.content} variant="basic" />
      </div>
      {message.tags?.length ? (
        <div className="mt-3 flex flex-wrap gap-2 text-[11px] text-muted">
          {message.tags.map((tag) => (
            <span
              key={tag}
              className="rounded-full border border-[color:var(--border)] bg-[color:var(--surface)] px-2 py-0.5"
            >
              {tag}
            </span>
          ))}
        </div>
      ) : null}
    </div>
  );
}

const SSE_RECONNECT_BACKOFF = {
  baseMs: 1_000,
  factor: 2,
  jitter: 0.2,
  maxMs: 5 * 60_000,
} as const;
const HAS_ALL_MENTION_RE = /(^|\s)@all\b/i;

type HeartbeatUnit = "s" | "m" | "h" | "d";

function parseEvery(every: string | null | undefined): { amount: string; unit: HeartbeatUnit } | null {
  if (!every) return null;
  const match = every.match(/^(\d+)([smhd])$/);
  if (!match) return null;
  return { amount: match[1], unit: match[2] as HeartbeatUnit };
}

const HEARTBEAT_PRESETS: Array<{
  label: string;
  amount: number;
  unit: HeartbeatUnit;
}> = [
  { label: "30s", amount: 30, unit: "s" },
  { label: "1m", amount: 1, unit: "m" },
  { label: "2m", amount: 2, unit: "m" },
  { label: "5m", amount: 5, unit: "m" },
  { label: "10m", amount: 10, unit: "m" },
  { label: "15m", amount: 15, unit: "m" },
  { label: "30m", amount: 30, unit: "m" },
  { label: "1h", amount: 1, unit: "h" },
];

type GroupAgentInfo = {
  id: string;
  status: string;
  name: string;
  last_seen_at: string | null;
};

export default function BoardGroupDetailPage() {
  const { isSignedIn } = useAuth();
  const params = useParams();
  const groupIdParam = params?.groupId;
  const groupId = Array.isArray(groupIdParam) ? groupIdParam[0] : groupIdParam;
  const isPageActive = usePageActive();

  const [includeDone] = useState(true);
  const [perBoardLimit] = useState(5);
  const [statusFilter, setStatusFilter] = useState<string | null>(null);

  // Unified task table filters
  const [boardFilter, setBoardFilter] = useState<string | null>(null);
  const [taskSearch, setTaskSearch] = useState("");

  // Group Agent
  const [groupAgent, setGroupAgent] = useState<GroupAgentInfo | null>(null);
  const [isAgentLoading, setIsAgentLoading] = useState(false);
  const [isProvisioningAgent, setIsProvisioningAgent] = useState(false);
  const [isDeprovisioningAgent, setIsDeprovisioningAgent] = useState(false);
  const [agentError, setAgentError] = useState<string | null>(null);

  const [isChatOpen, setIsChatOpen] = useState(false);
  const [chatMessages, setChatMessages] = useState<BoardGroupMemoryRead[]>([]);
  const [isChatSending, setIsChatSending] = useState(false);
  const [chatError, setChatError] = useState<string | null>(null);
  const [chatBroadcast, setChatBroadcast] = useState(true);
  const chatMessagesRef = useRef<BoardGroupMemoryRead[]>([]);
  const chatEndRef = useRef<HTMLDivElement | null>(null);

  const [isNotesOpen, setIsNotesOpen] = useState(false);
  const [notesMessages, setNotesMessages] = useState<BoardGroupMemoryRead[]>(
    [],
  );
  const notesMessagesRef = useRef<BoardGroupMemoryRead[]>([]);
  const notesEndRef = useRef<HTMLDivElement | null>(null);
  const [notesBroadcast, setNotesBroadcast] = useState(true);
  const [isNoteSending, setIsNoteSending] = useState(false);
  const [noteSendError, setNoteSendError] = useState<string | null>(null);

  // Worker agents heartbeat
  const [workerAmount, setWorkerAmount] = useState("10");
  const [workerUnit, setWorkerUnit] = useState<HeartbeatUnit>("m");
  const [workerSeeded, setWorkerSeeded] = useState(false);
  const [isWorkerApplying, setIsWorkerApplying] = useState(false);
  const [workerApplyError, setWorkerApplyError] = useState<string | null>(null);
  const [workerApplyResult, setWorkerApplyResult] =
    useState<BoardGroupHeartbeatApplyResult | null>(null);

  // Lead agents heartbeat
  const [leadAmount, setLeadAmount] = useState("30");
  const [leadUnit, setLeadUnit] = useState<HeartbeatUnit>("m");
  const [leadSeeded, setLeadSeeded] = useState(false);
  const [isLeadApplying, setIsLeadApplying] = useState(false);
  const [leadApplyError, setLeadApplyError] = useState<string | null>(null);
  const [leadApplyResult, setLeadApplyResult] =
    useState<BoardGroupHeartbeatApplyResult | null>(null);

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

  const snapshotQuery =
    useGetBoardGroupSnapshotApiV1BoardGroupsGroupIdSnapshotGet<
      getBoardGroupSnapshotApiV1BoardGroupsGroupIdSnapshotGetResponse,
      ApiError
    >(
      groupId ?? "",
      { include_done: includeDone, per_board_task_limit: perBoardLimit },
      {
        query: {
          enabled: Boolean(isSignedIn && groupId),
          refetchInterval: 30_000,
          refetchOnMount: "always",
          retry: false,
        },
      },
    );

  const heartbeatConfigQuery =
    useGetBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGet<
      getBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatGetResponse,
      ApiError
    >(
      groupId ?? "",
      {
        query: {
          enabled: Boolean(isSignedIn && groupId),
          refetchOnMount: "always",
          retry: false,
        },
      },
    );

  const heartbeatConfig: BoardGroupHeartbeatConfig | null =
    heartbeatConfigQuery.data?.status === 200 ? heartbeatConfigQuery.data.data : null;

  // Seed pace pickers from real agent config once loaded
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

  const snapshot =
    snapshotQuery.data?.status === 200 ? snapshotQuery.data.data : null;
  const group = snapshot?.group ?? null;
  const boards = useMemo(() => snapshot?.boards ?? [], [snapshot?.boards]);
  const boardIdSet = useMemo(() => {
    const ids = new Set<string>();
    boards.forEach((item) => {
      if (item.board?.id) {
        ids.add(item.board.id);
      }
    });
    return ids;
  }, [boards]);
  const groupMentionSuggestions = useMemo(() => {
    const options = new Set<string>(["lead", "all"]);
    boards.forEach((item) => {
      (item.tasks ?? []).forEach((task) => {
        if (task.assignee) {
          options.add(task.assignee);
        }
      });
    });
    return [...options];
  }, [boards]);

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
  const isAdmin = member?.role === "admin" || member?.role === "owner";
  const canWriteGroup = useMemo(
    () => canWriteGroupBoards(member, boardIdSet),
    [boardIdSet, member],
  );
  const canManageHeartbeat = Boolean(isAdmin && canWriteGroup);

  const chatHistoryQuery =
    useListBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryGet<
      listBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryGetResponse,
      ApiError
    >(
      groupId ?? "",
      { limit: 200, is_chat: true },
      {
        query: {
          enabled: Boolean(isSignedIn && groupId && isChatOpen),
          refetchOnMount: "always",
          retry: false,
        },
      },
    );

  const notesHistoryQuery =
    useListBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryGet<
      listBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryGetResponse,
      ApiError
    >(
      groupId ?? "",
      { limit: 200, is_chat: false },
      {
        query: {
          enabled: Boolean(isSignedIn && groupId && isNotesOpen),
          refetchOnMount: "always",
          retry: false,
        },
      },
    );

  const mergeChatMessages = useCallback(
    (prev: BoardGroupMemoryRead[], next: BoardGroupMemoryRead[]) => {
      const byId = new Map<string, BoardGroupMemoryRead>();
      prev.forEach((item) => {
        byId.set(item.id, item);
      });
      next.forEach((item) => {
        if (item.is_chat) {
          byId.set(item.id, item);
        }
      });
      const merged = Array.from(byId.values());
      merged.sort((a, b) => {
        const aTime = apiDatetimeToMs(a.created_at) ?? 0;
        const bTime = apiDatetimeToMs(b.created_at) ?? 0;
        return aTime - bTime;
      });
      return merged;
    },
    [],
  );

  const mergeNotesMessages = useCallback(
    (prev: BoardGroupMemoryRead[], next: BoardGroupMemoryRead[]) => {
      const byId = new Map<string, BoardGroupMemoryRead>();
      prev.forEach((item) => {
        byId.set(item.id, item);
      });
      next.forEach((item) => {
        if (!item.is_chat) {
          byId.set(item.id, item);
        }
      });
      const merged = Array.from(byId.values());
      merged.sort((a, b) => {
        const aTime = apiDatetimeToMs(a.created_at) ?? 0;
        const bTime = apiDatetimeToMs(b.created_at) ?? 0;
        return aTime - bTime;
      });
      return merged;
    },
    [],
  );

  /**
   * Computes the newest `created_at` timestamp in a list of memory items.
   *
   * We pass this as `since` when reconnecting SSE so we don't re-stream the
   * entire chat history after transient disconnects.
   */
  const latestMemoryTimestamp = useCallback((items: BoardGroupMemoryRead[]) => {
    if (!items.length) return undefined;
    const latest = items.reduce((max, item) => {
      const ts = apiDatetimeToMs(item.created_at);
      return ts === null ? max : Math.max(max, ts);
    }, 0);
    if (!latest) return undefined;
    return new Date(latest).toISOString();
  }, []);

  useEffect(() => {
    chatMessagesRef.current = chatMessages;
  }, [chatMessages]);

  useEffect(() => {
    if (!isChatOpen) return;
    if (chatHistoryQuery.data?.status !== 200) return;
    const items = chatHistoryQuery.data.data.items ?? [];
    setChatMessages((prev) => mergeChatMessages(prev, items));
  }, [chatHistoryQuery.data, isChatOpen, mergeChatMessages]);

  useEffect(() => {
    if (!isChatOpen) return;
    const timeout = window.setTimeout(() => {
      chatEndRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
    }, 50);
    return () => window.clearTimeout(timeout);
  }, [chatMessages, isChatOpen]);

  useEffect(() => {
    if (!isPageActive) return;
    if (!isSignedIn || !groupId) return;
    if (!isChatOpen) return;

    let isCancelled = false;
    const abortController = new AbortController();
    const backoff = createExponentialBackoff(SSE_RECONNECT_BACKOFF);
    let reconnectTimeout: number | undefined;

    const connect = async () => {
      try {
        const since = latestMemoryTimestamp(chatMessagesRef.current);
        const params = { is_chat: true, ...(since ? { since } : {}) };
        const streamResult =
          await streamBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryStreamGet(
            groupId,
            params,
            {
              headers: { Accept: "text/event-stream" },
              signal: abortController.signal,
            },
          );
        if (streamResult.status !== 200) {
          throw new Error("Unable to connect group chat stream.");
        }
        const response = streamResult.data as Response;
        if (!(response instanceof Response) || !response.body) {
          throw new Error("Unable to connect group chat stream.");
        }
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (!isCancelled) {
          const { value, done } = await reader.read();
          if (done) break;

          // Consider the stream healthy once we receive any bytes (including pings)
          // and reset the backoff so a later disconnect doesn't wait the full max.
          if (value && value.length) {
            backoff.reset();
          }

          buffer += decoder.decode(value, { stream: true });
          buffer = buffer.replace(/\r\n/g, "\n");
          let boundary = buffer.indexOf("\n\n");
          while (boundary !== -1) {
            const raw = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const lines = raw.split("\n");
            let eventType = "message";
            let data = "";
            for (const line of lines) {
              if (line.startsWith("event:")) {
                eventType = line.slice(6).trim();
              } else if (line.startsWith("data:")) {
                data += line.slice(5).trim();
              }
            }
            if (eventType === "memory" && data) {
              try {
                const payload = JSON.parse(data) as {
                  memory?: BoardGroupMemoryRead;
                };
                if (payload.memory?.is_chat) {
                  setChatMessages((prev) =>
                    mergeChatMessages(prev, [
                      payload.memory as BoardGroupMemoryRead,
                    ]),
                  );
                }
              } catch {
                // Ignore malformed events.
              }
            }
            boundary = buffer.indexOf("\n\n");
          }
        }
      } catch {
        if (isCancelled) return;
        if (abortController.signal.aborted) return;
        const delay = backoff.nextDelayMs();
        reconnectTimeout = window.setTimeout(() => {
          if (!isCancelled) void connect();
        }, delay);
      }
    };

    void connect();

    return () => {
      isCancelled = true;
      abortController.abort();
      if (reconnectTimeout) {
        window.clearTimeout(reconnectTimeout);
      }
    };
  }, [
    groupId,
    isChatOpen,
    isPageActive,
    isSignedIn,
    latestMemoryTimestamp,
    mergeChatMessages,
  ]);

  useEffect(() => {
    notesMessagesRef.current = notesMessages;
  }, [notesMessages]);

  useEffect(() => {
    if (!isNotesOpen) return;
    if (notesHistoryQuery.data?.status !== 200) return;
    const items = notesHistoryQuery.data.data.items ?? [];
    setNotesMessages((prev) => mergeNotesMessages(prev, items));
  }, [isNotesOpen, mergeNotesMessages, notesHistoryQuery.data]);

  useEffect(() => {
    if (!isNotesOpen) return;
    const timeout = window.setTimeout(() => {
      notesEndRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
    }, 50);
    return () => window.clearTimeout(timeout);
  }, [isNotesOpen, notesMessages]);

  useEffect(() => {
    if (!isPageActive) return;
    if (!isSignedIn || !groupId) return;
    if (!isNotesOpen) return;

    let isCancelled = false;
    const abortController = new AbortController();
    const backoff = createExponentialBackoff(SSE_RECONNECT_BACKOFF);
    let reconnectTimeout: number | undefined;

    const connect = async () => {
      try {
        const since = latestMemoryTimestamp(notesMessagesRef.current);
        const params = { is_chat: false, ...(since ? { since } : {}) };
        const streamResult =
          await streamBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryStreamGet(
            groupId,
            params,
            {
              headers: { Accept: "text/event-stream" },
              signal: abortController.signal,
            },
          );
        if (streamResult.status !== 200) {
          throw new Error("Unable to connect group notes stream.");
        }
        const response = streamResult.data as Response;
        if (!(response instanceof Response) || !response.body) {
          throw new Error("Unable to connect group notes stream.");
        }
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (!isCancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value && value.length) {
            backoff.reset();
          }
          buffer += decoder.decode(value, { stream: true });
          buffer = buffer.replace(/\r\n/g, "\n");
          let boundary = buffer.indexOf("\n\n");
          while (boundary !== -1) {
            const raw = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const lines = raw.split("\n");
            let eventType = "message";
            let data = "";
            for (const line of lines) {
              if (line.startsWith("event:")) {
                eventType = line.slice(6).trim();
              } else if (line.startsWith("data:")) {
                data += line.slice(5).trim();
              }
            }
            if (eventType === "memory" && data) {
              try {
                const payload = JSON.parse(data) as {
                  memory?: BoardGroupMemoryRead;
                };
                if (payload.memory && !payload.memory.is_chat) {
                  setNotesMessages((prev) =>
                    mergeNotesMessages(prev, [
                      payload.memory as BoardGroupMemoryRead,
                    ]),
                  );
                }
              } catch {
                // Ignore malformed events.
              }
            }
            boundary = buffer.indexOf("\n\n");
          }
        }
      } catch {
        if (isCancelled) return;
        if (abortController.signal.aborted) return;
        const delay = backoff.nextDelayMs();
        reconnectTimeout = window.setTimeout(() => {
          if (!isCancelled) void connect();
        }, delay);
      }
    };

    void connect();

    return () => {
      isCancelled = true;
      abortController.abort();
      if (reconnectTimeout) {
        window.clearTimeout(reconnectTimeout);
      }
    };
  }, [
    groupId,
    isNotesOpen,
    isPageActive,
    isSignedIn,
    latestMemoryTimestamp,
    mergeNotesMessages,
  ]);

  const sendGroupChat = useCallback(
    async (content: string): Promise<boolean> => {
      if (!isSignedIn || !groupId) {
        setChatError("Sign in to send messages.");
        return false;
      }
      if (!canWriteGroup) {
        setChatError("Read-only access. You cannot post group messages.");
        return false;
      }
      const trimmed = content.trim();
      if (!trimmed) return false;

      setIsChatSending(true);
      setChatError(null);
      try {
        const shouldBroadcast =
          chatBroadcast || HAS_ALL_MENTION_RE.test(trimmed);
        const tags = ["chat", ...(shouldBroadcast ? ["broadcast"] : [])];
        const result =
          await createBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryPost(
            groupId,
            { content: trimmed, tags },
          );
        if (result.status !== 200) {
          throw new Error("Unable to send message.");
        }
        const created = result.data;
        if (created.is_chat) {
          setChatMessages((prev) => mergeChatMessages(prev, [created]));
        }
        return true;
      } catch (err) {
        setChatError(
          err instanceof Error ? err.message : "Unable to send message.",
        );
        return false;
      } finally {
        setIsChatSending(false);
      }
    },
    [canWriteGroup, chatBroadcast, groupId, isSignedIn, mergeChatMessages],
  );

  const sendGroupNote = useCallback(
    async (content: string): Promise<boolean> => {
      if (!isSignedIn || !groupId) {
        setNoteSendError("Sign in to post.");
        return false;
      }
      if (!canWriteGroup) {
        setNoteSendError("Read-only access. You cannot post notes.");
        return false;
      }
      const trimmed = content.trim();
      if (!trimmed) return false;

      setIsNoteSending(true);
      setNoteSendError(null);
      try {
        const shouldBroadcast =
          notesBroadcast || HAS_ALL_MENTION_RE.test(trimmed);
        const tags = ["note", ...(shouldBroadcast ? ["broadcast"] : [])];
        const result =
          await createBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryPost(
            groupId,
            { content: trimmed, tags },
          );
        if (result.status !== 200) {
          throw new Error("Unable to post.");
        }
        const created = result.data;
        if (!created.is_chat) {
          setNotesMessages((prev) => mergeNotesMessages(prev, [created]));
        }
        return true;
      } catch (err) {
        setNoteSendError(
          err instanceof Error ? err.message : "Unable to post.",
        );
        return false;
      } finally {
        setIsNoteSending(false);
      }
    },
    [canWriteGroup, groupId, isSignedIn, mergeNotesMessages, notesBroadcast],
  );

  const applyWorkerHeartbeat = useCallback(async () => {
    if (!isSignedIn || !groupId) { setWorkerApplyError("Sign in to apply."); return; }
    if (!canManageHeartbeat) { setWorkerApplyError("Read-only access."); return; }
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
  }, [canManageHeartbeat, groupId, isSignedIn, workerHeartbeatEvery]);

  const applyLeadHeartbeat = useCallback(async () => {
    if (!isSignedIn || !groupId) { setLeadApplyError("Sign in to apply."); return; }
    if (!canManageHeartbeat) { setLeadApplyError("Read-only access."); return; }
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
  }, [canManageHeartbeat, groupId, isSignedIn, leadHeartbeatEvery]);

  // Group Agent callbacks
  const fetchGroupAgent = useCallback(async () => {
    if (!groupId || !isSignedIn) return;
    setIsAgentLoading(true);
    setAgentError(null);
    try {
      const result = await customFetch<{ data: GroupAgentInfo; status: number }>(
        `/api/v1/board-groups/${groupId}/agent`,
        { method: "GET" },
      );
      if (result.status === 200) {
        setGroupAgent(result.data);
      }
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        setGroupAgent(null);
      } else {
        setAgentError(err instanceof Error ? err.message : "Failed to load agent status.");
      }
    } finally {
      setIsAgentLoading(false);
    }
  }, [groupId, isSignedIn]);

  useEffect(() => {
    void fetchGroupAgent();
  }, [fetchGroupAgent]);

  const provisionGroupAgent = useCallback(async () => {
    if (!groupId || !isSignedIn) return;
    setIsProvisioningAgent(true);
    setAgentError(null);
    try {
      await customFetch(`/api/v1/board-groups/${groupId}/agent`, { method: "POST" });
      await fetchGroupAgent();
    } catch (err) {
      setAgentError(err instanceof Error ? err.message : "Failed to provision agent.");
    } finally {
      setIsProvisioningAgent(false);
    }
  }, [groupId, isSignedIn, fetchGroupAgent]);

  const deprovisionGroupAgent = useCallback(async () => {
    if (!groupId || !isSignedIn) return;
    if (!window.confirm("Remove the Group Agent? This cannot be undone.")) return;
    setIsDeprovisioningAgent(true);
    setAgentError(null);
    try {
      await customFetch(`/api/v1/board-groups/${groupId}/agent`, { method: "DELETE" });
      setGroupAgent(null);
    } catch (err) {
      setAgentError(err instanceof Error ? err.message : "Failed to deprovision agent.");
    } finally {
      setIsDeprovisioningAgent(false);
    }
  }, [groupId, isSignedIn]);

  // Flat tasks for unified table
  const flatTasks = useMemo(() => {
    const all: Array<{ task: NonNullable<(typeof boards)[0]["tasks"]>[0]; boardId: string; boardName: string }> = [];
    boards.forEach((item) => {
      (item.tasks ?? []).forEach((task) => {
        all.push({ task, boardId: item.board.id, boardName: item.board.name });
      });
    });
    return all;
  }, [boards]);

  const filteredTasks = useMemo(() => {
    return flatTasks.filter((item) => {
      if (boardFilter && item.boardId !== boardFilter) return false;
      if (statusFilter && item.task.status !== statusFilter) return false;
      const q = taskSearch.trim().toLowerCase();
      if (q) {
        const matchTitle = item.task.title?.toLowerCase().includes(q);
        if (!matchTitle) return false;
      }
      return true;
    });
  }, [flatTasks, boardFilter, statusFilter, taskSearch]);

  return (
    <DashboardShell>
      <SignedOut>
        <SignedOutPanel
          message="Sign in to view board groups."
          forceRedirectUrl={`/board-groups/${groupId ?? ""}`}
        />
      </SignedOut>
      <SignedIn>
        <DashboardSidebar />
        <main className="flex-1 overflow-y-auto bg-[color:var(--surface-muted)]">
          <div className="sticky top-0 z-30 border-b border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm">
            <div className="px-8 py-6">
              <div className="flex flex-wrap items-start justify-between gap-4">
                <div className="min-w-0">
                  <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
                    Board group
                  </p>
                  <h1 className="mt-2 text-2xl font-semibold tracking-tight text-strong">
                    {group?.name ?? "Group"}
                  </h1>
                  {group?.description ? (
                    <p className="mt-2 max-w-2xl text-sm text-muted">
                      {group.description}
                    </p>
                  ) : (
                    <p className="mt-2 text-sm text-quiet">
                      No description
                    </p>
                  )}
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  {group?.id ? (
                    <Link
                      href={`/board-groups/${group.id}/edit`}
                      className={buttonVariants({
                        variant: "outline",
                        size: "sm",
                      })}
                      title="Edit group"
                    >
                      <Settings className="mr-2 h-4 w-4" />
                      Edit
                    </Link>
                  ) : null}
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setIsNotesOpen(false);
                      setNoteSendError(null);
                      setChatError(null);
                      setIsChatOpen(true);
                    }}
                    disabled={!groupId}
                    title="Group chat"
                  >
                    <MessageSquare className="mr-2 h-4 w-4" />
                    Chat
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setIsChatOpen(false);
                      setChatError(null);
                      setNoteSendError(null);
                      setIsNotesOpen(true);
                    }}
                    disabled={!groupId}
                    title="Group notes"
                  >
                    <NotebookText className="mr-2 h-4 w-4" />
                    Notes
                  </Button>
                </div>
              </div>
            </div>
          </div>

          <div className="p-8">
            <div className="space-y-6">
              {/* Group Agent card */}
              <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5 shadow-sm">
                <div className="flex flex-wrap items-start justify-between gap-4">
                  <div className="min-w-0">
                    <p className="text-sm font-semibold text-strong">🤖 Group Agent</p>
                    <p className="mt-0.5 text-xs text-muted">
                      A shared lead that has context across all boards in this group.
                    </p>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    {isAgentLoading ? (
                      <span className="inline-flex items-center rounded-full border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-2.5 py-1 text-xs text-muted">
                        Loading…
                      </span>
                    ) : groupAgent ? (
                      <span
                        className={cn(
                          "inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-semibold",
                          groupAgent.status === "online"
                            ? "border-emerald-200 bg-[color:var(--success-soft)] text-success"
                            : "border-[color:var(--warning-border)] bg-[color:var(--warning-soft)] text-warning",
                        )}
                      >
                        {groupAgent.status}
                      </span>
                    ) : (
                      <span className="inline-flex items-center rounded-full border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-2.5 py-1 text-xs text-muted">
                        Not provisioned
                      </span>
                    )}
                    {isAdmin && !groupAgent && !isAgentLoading && (
                      <Button
                        size="sm"
                        onClick={() => void provisionGroupAgent()}
                        disabled={isProvisioningAgent}
                      >
                        {isProvisioningAgent ? "Provisioning…" : "Provision"}
                      </Button>
                    )}
                    {isAdmin && groupAgent && (
                      <Button
                        size="sm"
                        variant="destructive"
                        onClick={() => void deprovisionGroupAgent()}
                        disabled={isDeprovisioningAgent}
                      >
                        {isDeprovisioningAgent ? "Removing…" : "Deprovision"}
                      </Button>
                    )}
                  </div>
                </div>
                {groupAgent?.name && (
                  <p className="mt-2 text-xs text-muted">
                    Agent: <span className="font-medium text-strong">{groupAgent.name}</span>
                  </p>
                )}
                {agentError && (
                  <p className="mt-2 text-xs text-danger">{agentError}</p>
                )}
              </div>

              {/* Unified task table */}
              {snapshotQuery.isLoading ? (
                <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 text-sm text-muted shadow-sm">
                  Loading group snapshot…
                </div>
              ) : snapshotQuery.error ? (
                <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] p-6 text-sm text-danger shadow-sm">
                  {snapshotQuery.error.message}
                </div>
              ) : boards.length === 0 ? (
                <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 text-sm text-muted shadow-sm">
                  No boards in this group yet. Assign boards from the board
                  settings page.
                </div>
              ) : (
                <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm">
                  {/* Filters row */}
                  <div className="flex flex-wrap items-center gap-3 border-b border-[color:var(--border)] px-6 py-4">
                    <select
                      value={boardFilter ?? ""}
                      onChange={(e) => setBoardFilter(e.target.value || null)}
                      className="h-8 rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-2 text-xs text-strong shadow-sm"
                    >
                      <option value="">All boards</option>
                      {boards.map((item) => (
                        <option key={item.board.id} value={item.board.id}>
                          {item.board.name}
                        </option>
                      ))}
                    </select>
                    <select
                      value={statusFilter ?? ""}
                      onChange={(e) => setStatusFilter(e.target.value || null)}
                      className="h-8 rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-2 text-xs text-strong shadow-sm"
                    >
                      <option value="">All statuses</option>
                      <option value="inbox">Inbox</option>
                      <option value="in_progress">In progress</option>
                      <option value="review">Review</option>
                      <option value="done">Done</option>
                    </select>
                    <input
                      type="text"
                      value={taskSearch}
                      onChange={(e) => setTaskSearch(e.target.value)}
                      placeholder="Search tasks…"
                      className="h-8 min-w-[160px] flex-1 rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-xs text-strong shadow-sm placeholder:text-quiet"
                    />
                    <span className="whitespace-nowrap text-xs text-quiet">
                      {filteredTasks.length} of {flatTasks.length}
                    </span>
                  </div>

                  {/* Task table */}
                  {filteredTasks.length === 0 ? (
                    <div className="px-6 py-8 text-center text-sm text-muted">
                      No tasks match your filters.
                    </div>
                  ) : (
                    <div className="overflow-x-auto">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="border-b border-[color:var(--border)] bg-[color:var(--surface-muted)]">
                            <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted">
                              Board
                            </th>
                            <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted">
                              Task
                            </th>
                            <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted">
                              Status
                            </th>
                            <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted">
                              Priority
                            </th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-[color:var(--border)]">
                          {filteredTasks.map(({ task, boardId, boardName }) => (
                            <tr
                              key={task.id}
                              className="transition-colors hover:bg-[color:var(--surface-muted)]"
                            >
                              <td className="px-4 py-3">
                                <span className="inline-flex items-center rounded-full border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-2 py-0.5 text-xs text-muted">
                                  {boardName}
                                </span>
                              </td>
                              <td className="px-4 py-3">
                                <Link
                                  href={`/boards/${boardId}`}
                                  className="font-medium text-strong transition-colors hover:text-info"
                                  title="Open board"
                                >
                                  {task.title}
                                </Link>
                                {task.assignee && (
                                  <p className="mt-0.5 text-xs text-quiet">
                                    {task.assignee}
                                  </p>
                                )}
                              </td>
                              <td className="whitespace-nowrap px-4 py-3">
                                <span
                                  className={cn(
                                    "inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-semibold",
                                    statusTone(task.status),
                                  )}
                                >
                                  {statusLabel(task.status)}
                                </span>
                              </td>
                              <td className="whitespace-nowrap px-4 py-3">
                                <span
                                  className={cn(
                                    "inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-semibold capitalize",
                                    priorityTone(task.priority),
                                  )}
                                >
                                  {task.priority ?? "—"}
                                </span>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        </main>
      </SignedIn>
      {isChatOpen || isNotesOpen ? (
        <div
          className="fixed inset-0 z-40 bg-black/30"
          onClick={() => {
            setIsChatOpen(false);
            setChatError(null);
            setIsNotesOpen(false);
            setNoteSendError(null);
          }}
        />
      ) : null}
      <aside
        className={cn(
          "fixed right-0 top-0 z-50 h-full w-[560px] max-w-[96vw] transform border-l border-[color:var(--border)] bg-[color:var(--surface)] shadow-2xl transition-transform",
          isChatOpen ? "transform-none" : "translate-x-full",
        )}
      >
        <div className="flex h-full flex-col">
          <div className="flex items-center justify-between border-b border-[color:var(--border)] px-6 py-4">
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
                Group chat
              </p>
              <p className="mt-1 truncate text-sm font-medium text-strong">
                Shared across linked boards. Tag @lead, @name, or @all.
              </p>
            </div>
            <button
              type="button"
              onClick={() => {
                setIsChatOpen(false);
                setChatError(null);
              }}
              className="rounded-lg border border-[color:var(--border)] p-2 text-quiet transition hover:bg-[color:var(--surface-muted)]"
              aria-label="Close group chat"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
          <div className="flex flex-1 flex-col overflow-hidden px-6 py-4">
            <div className="flex flex-wrap items-center justify-between gap-3 pb-3">
              <label className="inline-flex items-center gap-2 text-sm text-muted">
                <input
                  type="checkbox"
                  className="h-4 w-4 rounded border-[color:var(--border-strong)] text-info"
                  checked={chatBroadcast}
                  onChange={(event) => setChatBroadcast(event.target.checked)}
                  disabled={!canWriteGroup}
                />
                Broadcast
              </label>
              <p className="text-xs text-quiet">
                {chatBroadcast
                  ? "Notifies every agent in the group."
                  : "Notifies leads + mentions."}
              </p>
            </div>

            <div className="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-4">
              {chatHistoryQuery.error ? (
                <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] px-3 py-2 text-sm text-danger">
                  {chatHistoryQuery.error.message}
                </div>
              ) : null}
              {chatError ? (
                <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] px-3 py-2 text-sm text-danger">
                  {chatError}
                </div>
              ) : null}
              {chatHistoryQuery.isLoading && chatMessages.length === 0 ? (
                <p className="text-sm text-quiet">Loading…</p>
              ) : chatMessages.length === 0 ? (
                <p className="text-sm text-quiet">
                  No messages yet. Start the conversation with a broadcast or a
                  mention.
                </p>
              ) : (
                chatMessages.map((message) => (
                  <GroupChatMessageCard key={message.id} message={message} />
                ))
              )}
              <div ref={chatEndRef} />
            </div>

            <BoardChatComposer
              placeholder={
                canWriteGroup
                  ? "Message the whole group. Tag @lead, @name, or @all."
                  : "Read-only access. Group chat is disabled."
              }
              isSending={isChatSending}
              onSend={sendGroupChat}
              disabled={!canWriteGroup}
              mentionSuggestions={groupMentionSuggestions}
            />
          </div>
        </div>
      </aside>
      <aside
        className={cn(
          "fixed right-0 top-0 z-50 h-full w-[560px] max-w-[96vw] transform border-l border-[color:var(--border)] bg-[color:var(--surface)] shadow-2xl transition-transform",
          isNotesOpen ? "transform-none" : "translate-x-full",
        )}
      >
        <div className="flex h-full flex-col">
          <div className="flex items-center justify-between border-b border-[color:var(--border)] px-6 py-4">
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
                Group notes
              </p>
              <p className="mt-1 truncate text-sm font-medium text-strong">
                Shared across linked boards. Tag @lead, @name, or @all.
              </p>
            </div>
            <button
              type="button"
              onClick={() => {
                setIsNotesOpen(false);
                setNoteSendError(null);
              }}
              className="rounded-lg border border-[color:var(--border)] p-2 text-quiet transition hover:bg-[color:var(--surface-muted)]"
              aria-label="Close group notes"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
          <div className="flex flex-1 flex-col overflow-hidden px-6 py-4">
            <div className="flex flex-wrap items-center justify-between gap-3 pb-3">
              <label className="inline-flex items-center gap-2 text-sm text-muted">
                <input
                  type="checkbox"
                  className="h-4 w-4 rounded border-[color:var(--border-strong)] text-info"
                  checked={notesBroadcast}
                  onChange={(event) => setNotesBroadcast(event.target.checked)}
                  disabled={!canWriteGroup}
                />
                Broadcast
              </label>
              <p className="text-xs text-quiet">
                {notesBroadcast
                  ? "Notifies every agent in the group."
                  : "Notifies leads + mentions."}
              </p>
            </div>

            <div className="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] p-4">
              {notesHistoryQuery.error ? (
                <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] px-3 py-2 text-sm text-danger">
                  {notesHistoryQuery.error.message}
                </div>
              ) : null}
              {noteSendError ? (
                <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] px-3 py-2 text-sm text-danger">
                  {noteSendError}
                </div>
              ) : null}
              {notesHistoryQuery.isLoading && notesMessages.length === 0 ? (
                <p className="text-sm text-quiet">Loading…</p>
              ) : notesMessages.length === 0 ? (
                <p className="text-sm text-quiet">
                  No notes yet. Post a note or a broadcast to share context
                  across boards.
                </p>
              ) : (
                notesMessages.map((message) => (
                  <GroupChatMessageCard key={message.id} message={message} />
                ))
              )}
              <div ref={notesEndRef} />
            </div>

            <BoardChatComposer
              placeholder={
                canWriteGroup
                  ? "Post a shared note for all linked boards. Tag @lead, @name, or @all."
                  : "Read-only access. Notes are disabled."
              }
              isSending={isNoteSending}
              onSend={sendGroupNote}
              disabled={!canWriteGroup}
              mentionSuggestions={groupMentionSuggestions}
            />
          </div>
        </div>
      </aside>
    </DashboardShell>
  );
}
