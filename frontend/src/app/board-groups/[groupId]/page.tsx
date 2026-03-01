"use client";

export const dynamic = "force-dynamic";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";

import { SignedIn, SignedOut, useAuth } from "@/auth/clerk";
import {
  ArrowUpRight,
  MessageSquare,
  NotebookText,
  Settings,
  X,
} from "lucide-react";

import { ApiError } from "@/api/mutator";
import {
  applyBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatPost,
  type getBoardGroupSnapshotApiV1BoardGroupsGroupIdSnapshotGetResponse,
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
  BoardGroupMemoryRead,
  OrganizationMemberRead,
} from "@/api/generated/model";
import type { BoardGroupBoardSnapshot } from "@/api/generated/model";
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

const safeCount = (snapshot: BoardGroupBoardSnapshot, key: string) =>
  snapshot.task_counts?.[key] ?? 0;

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

export default function BoardGroupDetailPage() {
  const { isSignedIn } = useAuth();
  const params = useParams();
  const groupIdParam = params?.groupId;
  const groupId = Array.isArray(groupIdParam) ? groupIdParam[0] : groupIdParam;
  const isPageActive = usePageActive();

  const [includeDone, setIncludeDone] = useState(false);
  const [perBoardLimit, setPerBoardLimit] = useState(5);

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

  const [heartbeatAmount, setHeartbeatAmount] = useState("10");
  const [heartbeatUnit, setHeartbeatUnit] = useState<HeartbeatUnit>("m");
  const [includeBoardLeads, setIncludeBoardLeads] = useState(false);
  const [isHeartbeatApplying, setIsHeartbeatApplying] = useState(false);
  const [heartbeatApplyError, setHeartbeatApplyError] = useState<string | null>(
    null,
  );
  const [heartbeatApplyResult, setHeartbeatApplyResult] =
    useState<BoardGroupHeartbeatApplyResult | null>(null);

  const heartbeatEvery = useMemo(() => {
    const parsed = Number.parseInt(heartbeatAmount, 10);
    if (!Number.isFinite(parsed) || parsed <= 0) return "";
    return `${parsed}${heartbeatUnit}`;
  }, [heartbeatAmount, heartbeatUnit]);

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

  const applyHeartbeat = useCallback(async () => {
    if (!isSignedIn || !groupId) {
      setHeartbeatApplyError("Sign in to apply.");
      return;
    }
    if (!canManageHeartbeat) {
      setHeartbeatApplyError("Read-only access. You cannot change agent pace.");
      return;
    }
    const trimmed = heartbeatEvery.trim();
    if (!trimmed) {
      setHeartbeatApplyError("Heartbeat cadence is required.");
      return;
    }
    setIsHeartbeatApplying(true);
    setHeartbeatApplyError(null);
    try {
      const result =
        await applyBoardGroupHeartbeatApiV1BoardGroupsGroupIdHeartbeatPost(
          groupId,
          { every: trimmed, include_board_leads: includeBoardLeads },
        );
      if (result.status !== 200) {
        throw new Error("Unable to apply heartbeat.");
      }
      setHeartbeatApplyResult(result.data);
    } catch (err) {
      setHeartbeatApplyError(
        err instanceof Error ? err.message : "Unable to apply heartbeat.",
      );
    } finally {
      setIsHeartbeatApplying(false);
    }
  }, [
    canManageHeartbeat,
    groupId,
    heartbeatEvery,
    includeBoardLeads,
    isSignedIn,
  ]);

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
                  <Link
                    href="/boards"
                    className={buttonVariants({ variant: "ghost", size: "sm" })}
                  >
                    View boards
                  </Link>
                </div>
              </div>

              <div className="mt-5 flex flex-wrap items-center gap-3">
                <label className="inline-flex items-center gap-2 text-sm text-muted">
                  <input
                    type="checkbox"
                    className="h-4 w-4 rounded border-[color:var(--border-strong)] text-info"
                    checked={includeDone}
                    onChange={(event) => setIncludeDone(event.target.checked)}
                  />
                  Include done
                </label>
                <div className="flex items-center gap-2 text-sm text-muted">
                  <span className="text-quiet">Top tasks per board</span>
                  <div className="flex items-center gap-1 rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] p-1">
                    {[0, 3, 5, 10].map((value) => (
                      <button
                        key={value}
                        type="button"
                        className={cn(
                          "rounded-md px-2.5 py-1 text-xs font-semibold transition-colors",
                          perBoardLimit === value
                            ? "bg-[color:var(--text)] text-[color:var(--surface)]"
                            : "text-muted hover:bg-[color:var(--surface-strong)] hover:text-strong",
                        )}
                        onClick={() => setPerBoardLimit(value)}
                      >
                        {value === 0 ? "0" : value}
                      </button>
                    ))}
                  </div>
                </div>

                <div className="flex flex-wrap items-center gap-2 text-sm text-muted">
                  <span className="text-quiet">Agent pace</span>
                  <div className="flex flex-wrap items-center gap-1 rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] p-1">
                    {HEARTBEAT_PRESETS.map((preset) => {
                      const value = `${preset.amount}${preset.unit}`;
                      return (
                        <button
                          key={value}
                          type="button"
                          className={cn(
                            "rounded-md px-2.5 py-1 text-xs font-semibold transition-colors",
                            heartbeatEvery === value
                              ? "bg-[color:var(--text)] text-[color:var(--surface)]"
                              : "text-muted hover:bg-[color:var(--surface-strong)] hover:text-strong",
                            !canManageHeartbeat &&
                              "opacity-50 cursor-not-allowed",
                          )}
                          disabled={!canManageHeartbeat}
                          onClick={() => {
                            setHeartbeatAmount(String(preset.amount));
                            setHeartbeatUnit(preset.unit);
                          }}
                        >
                          {preset.label}
                        </button>
                      );
                    })}
                  </div>
                  <input
                    value={heartbeatAmount}
                    onChange={(event) => setHeartbeatAmount(event.target.value)}
                    className={cn(
                      "h-8 w-20 rounded-md border bg-[color:var(--surface)] px-2 text-xs text-strong shadow-sm",
                      heartbeatEvery
                        ? "border-[color:var(--border)]"
                        : "border-[color:var(--danger-border)] focus:border-[color:var(--danger-border)] focus:ring-2 focus:ring-rose-100",
                      !canManageHeartbeat && "opacity-60 cursor-not-allowed",
                    )}
                    placeholder="10"
                    inputMode="numeric"
                    type="number"
                    min={1}
                    step={1}
                    disabled={!canManageHeartbeat}
                  />
                  <select
                    value={heartbeatUnit}
                    onChange={(event) =>
                      setHeartbeatUnit(event.target.value as HeartbeatUnit)
                    }
                    className={cn(
                      "h-8 rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-2 text-xs text-strong shadow-sm",
                      !canManageHeartbeat && "opacity-60 cursor-not-allowed",
                    )}
                    disabled={!canManageHeartbeat}
                  >
                    <option value="s">sec</option>
                    <option value="m">min</option>
                    <option value="h">hr</option>
                    <option value="d">day</option>
                  </select>
                  <label className="inline-flex items-center gap-2 text-xs text-muted">
                    <input
                      type="checkbox"
                      className="h-4 w-4 rounded border-[color:var(--border-strong)] text-info"
                      checked={includeBoardLeads}
                      onChange={(event) =>
                        setIncludeBoardLeads(event.target.checked)
                      }
                      disabled={!canManageHeartbeat}
                    />
                    Include leads
                  </label>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => void applyHeartbeat()}
                    disabled={
                      isHeartbeatApplying ||
                      !heartbeatEvery ||
                      !canManageHeartbeat
                    }
                    title={
                      canManageHeartbeat
                        ? "Apply heartbeat"
                        : "Read-only access"
                    }
                  >
                    {isHeartbeatApplying ? "Applying…" : "Apply"}
                  </Button>
                </div>
                {!canManageHeartbeat ? (
                  <p className="text-xs text-quiet">
                    Read-only access. You cannot change agent pace for this
                    group.
                  </p>
                ) : null}
              </div>
            </div>
          </div>

          <div className="p-8">
            <div className="space-y-6">
              {heartbeatApplyError ? (
                <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] p-4 text-sm text-danger shadow-sm">
                  {heartbeatApplyError}
                </div>
              ) : null}
              {heartbeatApplyResult ? (
                <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-4 text-sm text-muted shadow-sm">
                  <p className="font-semibold text-strong">
                    Heartbeat applied
                  </p>
                  <p className="mt-1 text-muted">
                    Updated {heartbeatApplyResult.updated_agent_ids.length}{" "}
                    agents, failed{" "}
                    {heartbeatApplyResult.failed_agent_ids.length}.
                  </p>
                </div>
              ) : null}

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
                <div className="grid gap-6 lg:grid-cols-2">
                  {boards.map((item) => (
                    <div
                      key={item.board.id}
                      className="overflow-hidden rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm"
                    >
                      <div className="border-b border-[color:var(--border)] px-6 py-4">
                        <div className="flex items-start justify-between gap-4">
                          <div className="min-w-0">
                            <Link
                              href={`/boards/${item.board.id}`}
                              className="group inline-flex items-center gap-2"
                              title="Open board"
                            >
                              <p className="truncate text-sm font-semibold text-strong group-hover:text-info">
                                {item.board.name}
                              </p>
                              <ArrowUpRight className="h-4 w-4 text-quiet group-hover:text-info" />
                            </Link>
                            <p className="mt-1 text-xs text-quiet">
                              Updated {formatTimestamp(item.board.updated_at)}
                            </p>
                          </div>
                          <div className="flex flex-wrap items-center justify-end gap-2 text-xs">
                            <span className="rounded-full border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-2 py-0.5 text-muted">
                              Inbox {safeCount(item, "inbox")}
                            </span>
                            <span className="rounded-full border border-emerald-200 bg-[color:var(--success-soft)] px-2 py-0.5 text-success">
                              In progress {safeCount(item, "in_progress")}
                            </span>
                            <span className="rounded-full border border-[color:var(--warning-border)] bg-[color:var(--warning-soft)] px-2 py-0.5 text-warning">
                              Review {safeCount(item, "review")}
                            </span>
                          </div>
                        </div>
                      </div>

                      <div className="px-6 py-4">
                        {item.tasks && item.tasks.length > 0 ? (
                          <ul className="space-y-3">
                            {item.tasks.map((task) => (
                              <li key={task.id}>
                                <Link
                                  href={{
                                    pathname: `/boards/${item.board.id}`,
                                    query: { taskId: task.id },
                                  }}
                                  className="block rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-3 transition hover:border-[color:var(--info-border)] hover:bg-[color:var(--info-soft)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 focus-visible:ring-offset-2"
                                  title="Open task on board"
                                >
                                  <div className="flex flex-wrap items-center justify-between gap-2">
                                    <div className="flex min-w-0 items-center gap-2">
                                      <span
                                        className={cn(
                                          "inline-flex flex-shrink-0 items-center rounded-full border px-2 py-0.5 text-[11px] font-semibold",
                                          statusTone(task.status),
                                        )}
                                      >
                                        {statusLabel(task.status)}
                                      </span>
                                      <span
                                        className={cn(
                                          "inline-flex flex-shrink-0 items-center rounded-full border px-2 py-0.5 text-[11px] font-semibold",
                                          priorityTone(task.priority),
                                        )}
                                      >
                                        {task.priority}
                                      </span>
                                      <p className="truncate text-sm font-medium text-strong">
                                        {task.title}
                                      </p>
                                    </div>
                                    <p className="text-xs text-quiet">
                                      {formatTimestamp(task.updated_at)}
                                    </p>
                                  </div>
                                  <div className="mt-2 flex flex-wrap items-center justify-between gap-2 text-xs text-muted">
                                    <p className="truncate">
                                      Assignee:{" "}
                                      <span className="font-medium text-strong">
                                        {task.assignee ?? "Unassigned"}
                                      </span>
                                    </p>
                                    <p className="font-mono text-[11px] text-quiet">
                                      {task.id}
                                    </p>
                                  </div>
                                </Link>
                              </li>
                            ))}
                          </ul>
                        ) : (
                          <p className="text-sm text-quiet">
                            No tasks in this snapshot.
                          </p>
                        )}
                      </div>
                    </div>
                  ))}
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
