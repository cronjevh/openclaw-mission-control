"use client";

export const dynamic = "force-dynamic";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";

import { SignedIn, SignedOut, useAuth } from "@/auth/clerk";
import {
  LayoutGrid,
  MessageSquare,
  NotebookText,
  Plus,
  Settings,
  X,
} from "lucide-react";

import { ApiError, customFetch } from "@/api/mutator";
import {
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
  BoardGroupMemoryRead,
  OrganizationMemberRead,
} from "@/api/generated/model";

import {
  type GroupTask,
  listGroupTasks,
  createGroupTask,
  updateGroupTask,
} from "@/lib/groupTasks";
import { TaskBoard, type TaskStatus } from "@/components/organisms/TaskBoard";
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

const canWriteGroupBoards = (
  member: OrganizationMemberRead | null,
  boardIds: Set<string>,
) => {
  if (!member) return false;
  if (member.all_boards_write) return true;
  if (!member.board_access || boardIds.size === 0) return false;
  return member.board_access.some(
    (access) => access.can_write && access.board_id && boardIds.has(access.board_id),
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

type GroupAgentInfo = {
  id: string;
  status: string;
  name: string;
  last_seen_at: string | null;
};

type Task = {
  id: string;
  title: string;
  status: TaskStatus;
  priority: string;
  description?: string | null;
};

const toTaskBoardTask = (t: GroupTask): Task => ({
  id: t.id,
  title: t.title,
  status: t.status as TaskStatus,
  priority: t.priority,
  description: t.description ?? undefined,
});

const STATUS_OPTIONS: Array<{ value: TaskStatus; label: string }> = [
  { value: "inbox", label: "Inbox" },
  { value: "in_progress", label: "In Progress" },
  { value: "review", label: "Review" },
  { value: "done", label: "Done" },
];

export default function BoardGroupDetailPage() {
  const { isSignedIn } = useAuth();
  const params = useParams();
  const groupIdParam = params?.groupId;
  const groupId = Array.isArray(groupIdParam) ? groupIdParam[0] : groupIdParam;
  const isPageActive = usePageActive();

  const [includeDone] = useState(true);
  const [perBoardLimit] = useState(5);

  // View toggle
  const [showInnerBoards, setShowInnerBoards] = useState(false);

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
  const [notesMessages, setNotesMessages] = useState<BoardGroupMemoryRead[]>([]);
  const notesMessagesRef = useRef<BoardGroupMemoryRead[]>([]);
  const notesEndRef = useRef<HTMLDivElement | null>(null);
  const [notesBroadcast, setNotesBroadcast] = useState(true);
  const [isNoteSending, setIsNoteSending] = useState(false);
  const [noteSendError, setNoteSendError] = useState<string | null>(null);

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
      prev.forEach((item) => { byId.set(item.id, item); });
      next.forEach((item) => { if (item.is_chat) { byId.set(item.id, item); } });
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
      prev.forEach((item) => { byId.set(item.id, item); });
      next.forEach((item) => { if (!item.is_chat) { byId.set(item.id, item); } });
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

  const latestMemoryTimestamp = useCallback((items: BoardGroupMemoryRead[]) => {
    if (!items.length) return undefined;
    const latest = items.reduce((max, item) => {
      const ts = apiDatetimeToMs(item.created_at);
      return ts === null ? max : Math.max(max, ts);
    }, 0);
    if (!latest) return undefined;
    return new Date(latest).toISOString();
  }, []);

  useEffect(() => { chatMessagesRef.current = chatMessages; }, [chatMessages]);

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
            { headers: { Accept: "text/event-stream" }, signal: abortController.signal },
          );
        if (streamResult.status !== 200) throw new Error("Unable to connect group chat stream.");
        const response = streamResult.data as Response;
        if (!(response instanceof Response) || !response.body) throw new Error("Unable to connect group chat stream.");
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (!isCancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value && value.length) backoff.reset();
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
              if (line.startsWith("event:")) eventType = line.slice(6).trim();
              else if (line.startsWith("data:")) data += line.slice(5).trim();
            }
            if (eventType === "memory" && data) {
              try {
                const payload = JSON.parse(data) as { memory?: BoardGroupMemoryRead };
                if (payload.memory?.is_chat) {
                  setChatMessages((prev) => mergeChatMessages(prev, [payload.memory as BoardGroupMemoryRead]));
                }
              } catch { /* Ignore malformed events. */ }
            }
            boundary = buffer.indexOf("\n\n");
          }
        }
      } catch {
        if (isCancelled) return;
        if (abortController.signal.aborted) return;
        const delay = backoff.nextDelayMs();
        reconnectTimeout = window.setTimeout(() => { if (!isCancelled) void connect(); }, delay);
      }
    };

    void connect();

    return () => {
      isCancelled = true;
      abortController.abort();
      if (reconnectTimeout) window.clearTimeout(reconnectTimeout);
    };
  }, [groupId, isChatOpen, isPageActive, isSignedIn, latestMemoryTimestamp, mergeChatMessages]);

  useEffect(() => { notesMessagesRef.current = notesMessages; }, [notesMessages]);

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
            { headers: { Accept: "text/event-stream" }, signal: abortController.signal },
          );
        if (streamResult.status !== 200) throw new Error("Unable to connect group notes stream.");
        const response = streamResult.data as Response;
        if (!(response instanceof Response) || !response.body) throw new Error("Unable to connect group notes stream.");
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (!isCancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value && value.length) backoff.reset();
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
              if (line.startsWith("event:")) eventType = line.slice(6).trim();
              else if (line.startsWith("data:")) data += line.slice(5).trim();
            }
            if (eventType === "memory" && data) {
              try {
                const payload = JSON.parse(data) as { memory?: BoardGroupMemoryRead };
                if (payload.memory && !payload.memory.is_chat) {
                  setNotesMessages((prev) => mergeNotesMessages(prev, [payload.memory as BoardGroupMemoryRead]));
                }
              } catch { /* Ignore malformed events. */ }
            }
            boundary = buffer.indexOf("\n\n");
          }
        }
      } catch {
        if (isCancelled) return;
        if (abortController.signal.aborted) return;
        const delay = backoff.nextDelayMs();
        reconnectTimeout = window.setTimeout(() => { if (!isCancelled) void connect(); }, delay);
      }
    };

    void connect();

    return () => {
      isCancelled = true;
      abortController.abort();
      if (reconnectTimeout) window.clearTimeout(reconnectTimeout);
    };
  }, [groupId, isNotesOpen, isPageActive, isSignedIn, latestMemoryTimestamp, mergeNotesMessages]);

  const sendGroupChat = useCallback(
    async (content: string): Promise<boolean> => {
      if (!isSignedIn || !groupId) { setChatError("Sign in to send messages."); return false; }
      if (!canWriteGroup) { setChatError("Read-only access. You cannot post group messages."); return false; }
      const trimmed = content.trim();
      if (!trimmed) return false;
      setIsChatSending(true);
      setChatError(null);
      try {
        const shouldBroadcast = chatBroadcast || HAS_ALL_MENTION_RE.test(trimmed);
        const tags = ["chat", ...(shouldBroadcast ? ["broadcast"] : [])];
        const result = await createBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryPost(groupId, { content: trimmed, tags });
        if (result.status !== 200) throw new Error("Unable to send message.");
        const created = result.data;
        if (created.is_chat) setChatMessages((prev) => mergeChatMessages(prev, [created]));
        return true;
      } catch (err) {
        setChatError(err instanceof Error ? err.message : "Unable to send message.");
        return false;
      } finally {
        setIsChatSending(false);
      }
    },
    [canWriteGroup, chatBroadcast, groupId, isSignedIn, mergeChatMessages],
  );

  const sendGroupNote = useCallback(
    async (content: string): Promise<boolean> => {
      if (!isSignedIn || !groupId) { setNoteSendError("Sign in to post."); return false; }
      if (!canWriteGroup) { setNoteSendError("Read-only access. You cannot post notes."); return false; }
      const trimmed = content.trim();
      if (!trimmed) return false;
      setIsNoteSending(true);
      setNoteSendError(null);
      try {
        const shouldBroadcast = notesBroadcast || HAS_ALL_MENTION_RE.test(trimmed);
        const tags = ["note", ...(shouldBroadcast ? ["broadcast"] : [])];
        const result = await createBoardGroupMemoryApiV1BoardGroupsGroupIdMemoryPost(groupId, { content: trimmed, tags });
        if (result.status !== 200) throw new Error("Unable to post.");
        const created = result.data;
        if (!created.is_chat) setNotesMessages((prev) => mergeNotesMessages(prev, [created]));
        return true;
      } catch (err) {
        setNoteSendError(err instanceof Error ? err.message : "Unable to post.");
        return false;
      } finally {
        setIsNoteSending(false);
      }
    },
    [canWriteGroup, groupId, isSignedIn, mergeNotesMessages, notesBroadcast],
  );

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
      if (result.status === 200) setGroupAgent(result.data);
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

  useEffect(() => { void fetchGroupAgent(); }, [fetchGroupAgent]);

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

  // Group Tasks state
  const [groupTasks, setGroupTasks] = useState<GroupTask[]>([]);
  const [isGroupTasksLoading, setIsGroupTasksLoading] = useState(false);
  const [groupTasksError, setGroupTasksError] = useState<string | null>(null);
  const [isCreatingGroupTask, setIsCreatingGroupTask] = useState(false);
  const [newTaskTitle, setNewTaskTitle] = useState("");
  const [newTaskDescription, setNewTaskDescription] = useState("");
  const [newTaskStatus, setNewTaskStatus] = useState<TaskStatus>("inbox");
  const [showNewTaskForm, setShowNewTaskForm] = useState(false);

  const fetchGroupTasks = useCallback(async () => {
    if (!groupId || !isSignedIn) return;
    setIsGroupTasksLoading(true);
    setGroupTasksError(null);
    try {
      const tasks = await listGroupTasks(groupId);
      setGroupTasks(tasks);
    } catch (err) {
      setGroupTasksError(err instanceof Error ? err.message : "Failed to load group tasks.");
    } finally {
      setIsGroupTasksLoading(false);
    }
  }, [groupId, isSignedIn]);

  useEffect(() => { void fetchGroupTasks(); }, [fetchGroupTasks]);

  const handleCreateGroupTask = useCallback(async () => {
    if (!groupId || !isSignedIn || !newTaskTitle.trim()) return;
    setIsCreatingGroupTask(true);
    setGroupTasksError(null);
    try {
      await createGroupTask(groupId, {
        title: newTaskTitle.trim(),
        description: newTaskDescription.trim() || null,
        status: newTaskStatus,
      });
      setNewTaskTitle("");
      setNewTaskDescription("");
      setNewTaskStatus("inbox");
      setShowNewTaskForm(false);
      await fetchGroupTasks();
    } catch (err) {
      setGroupTasksError(err instanceof Error ? err.message : "Failed to create task.");
    } finally {
      setIsCreatingGroupTask(false);
    }
  }, [groupId, isSignedIn, newTaskTitle, newTaskDescription, newTaskStatus, fetchGroupTasks]);

  const handleGroupTaskMove = useCallback(
    async (taskId: string, status: TaskStatus) => {
      if (!groupId || !isSignedIn) return;
      try {
        await updateGroupTask(groupId, taskId, { status });
        await fetchGroupTasks();
      } catch (err) {
        setGroupTasksError(err instanceof Error ? err.message : "Failed to move task.");
      }
    },
    [groupId, isSignedIn, fetchGroupTasks],
  );

  const taskBoardTasks = useMemo(
    () => groupTasks.map(toTaskBoardTask),
    [groupTasks],
  );

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
        <main className="h-full flex flex-col overflow-hidden bg-[color:var(--bg)]">
          {/* Page header */}
          <div className="shrink-0 border-b border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm">
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
                    <p className="mt-2 text-sm text-quiet">No description</p>
                  )}
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  {group?.id ? (
                    <Link
                      href={`/board-groups/${group.id}/edit`}
                      className={buttonVariants({ variant: "outline", size: "sm" })}
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
                  <Button
                    variant={showInnerBoards ? "primary" : "outline"}
                    size="sm"
                    onClick={() => setShowInnerBoards((v) => !v)}
                    title="Toggle inner boards view"
                  >
                    <LayoutGrid className="mr-2 h-4 w-4" />
                    Inner Boards
                  </Button>
                </div>
              </div>
            </div>
          </div>

          {/* Content area */}
          <div className="flex flex-col flex-1 min-h-0 overflow-hidden p-6 gap-4">
            {/* Group Agent card — always visible */}
            <div className="shrink-0 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-5 shadow-sm">
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

            {/* Main toggleable content */}
            {!showInnerBoards ? (
              /* ── Kanban view (default) ── */
              <div className="flex flex-col flex-1 min-h-0 overflow-hidden">
                {/* Top bar: error + new task button */}
                <div className="shrink-0 flex items-center justify-between mb-3">
                  <div className="min-w-0">
                    {groupTasksError && (
                      <p className="text-xs text-danger">{groupTasksError}</p>
                    )}
                  </div>
                  {canManageHeartbeat && (
                    <button
                      type="button"
                      onClick={() => setShowNewTaskForm(true)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-1.5 text-xs font-semibold text-strong shadow-sm transition hover:border-[color:var(--border-strong)] hover:bg-[color:var(--surface-muted)]"
                    >
                      <Plus className="h-3.5 w-3.5" />
                      New Task
                    </button>
                  )}
                </div>

                {/* Kanban board — always render columns, even when empty */}
                {isGroupTasksLoading ? (
                  <div className="flex-1 flex items-center justify-center text-sm text-muted">
                    Loading group tasks…
                  </div>
                ) : (
                  <div className="flex-1 min-h-0 overflow-hidden">
                    <TaskBoard
                      tasks={taskBoardTasks}
                      onTaskMove={canManageHeartbeat ? handleGroupTaskMove : undefined}
                      onTaskSelect={() => {}}
                      readOnly={!canManageHeartbeat}
                    />
                  </div>
                )}
              </div>
            ) : (
              /* ── Inner Boards view ── */
              <div className="flex-1 overflow-y-auto">
                {snapshotQuery.isLoading ? (
                  <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 text-sm text-muted shadow-sm">
                    Loading group snapshot…
                  </div>
                ) : snapshotQuery.error ? (
                  <div className="rounded-xl border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] p-6 text-sm text-danger shadow-sm">
                    {(snapshotQuery.error as ApiError).message}
                  </div>
                ) : boards.length === 0 ? (
                  <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 text-sm text-muted shadow-sm">
                    No boards in this group yet. Assign boards from the board settings page.
                  </div>
                ) : (
                  <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                    {boards.map((item) => {
                      const boardTasks = item.tasks ?? [];
                      return (
                        <div
                          key={item.board.id}
                          className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm flex flex-col"
                        >
                          <div className="border-b border-[color:var(--border)] px-5 py-4">
                            <div className="flex items-center justify-between gap-3">
                              <div className="min-w-0">
                                <p className="font-semibold text-strong truncate">
                                  {item.board.name}
                                </p>
                                <p className="mt-0.5 text-xs text-quiet">
                                  {boardTasks.length} task{boardTasks.length !== 1 ? "s" : ""}
                                </p>
                              </div>
                              <Link
                                href={`/boards/${item.board.id}`}
                                className={buttonVariants({ variant: "outline", size: "sm" })}
                              >
                                Open
                              </Link>
                            </div>
                          </div>
                          <div className="flex-1 divide-y divide-[color:var(--border)]">
                            {boardTasks.length === 0 ? (
                              <p className="px-5 py-4 text-xs text-quiet">No tasks</p>
                            ) : (
                              boardTasks.slice(0, 5).map((task) => (
                                <div key={task.id} className="flex items-center gap-3 px-5 py-2.5">
                                  <span
                                    className={cn(
                                      "shrink-0 h-2 w-2 rounded-full",
                                      task.status === "in_progress"
                                        ? "bg-emerald-500"
                                        : task.status === "review"
                                          ? "bg-yellow-500"
                                          : task.status === "done"
                                            ? "bg-[color:var(--border-strong)]"
                                            : "bg-info",
                                    )}
                                  />
                                  <span className="min-w-0 flex-1 truncate text-xs text-strong">
                                    {task.title}
                                  </span>
                                  {task.assignee && (
                                    <span className="shrink-0 text-[10px] text-quiet truncate max-w-[80px]">
                                      {task.assignee}
                                    </span>
                                  )}
                                </div>
                              ))
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            )}
          </div>

          {/* New Task Modal */}
          {showNewTaskForm && (
            <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
              <div className="w-full max-w-md rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-2xl">
                <div className="flex items-center justify-between border-b border-[color:var(--border)] px-6 py-4">
                  <p className="text-sm font-semibold text-strong">New Group Task</p>
                  <button
                    type="button"
                    onClick={() => {
                      setShowNewTaskForm(false);
                      setNewTaskTitle("");
                      setNewTaskDescription("");
                      setNewTaskStatus("inbox");
                    }}
                    className="rounded-lg border border-[color:var(--border)] p-1.5 text-quiet transition hover:bg-[color:var(--surface-muted)]"
                    aria-label="Close"
                  >
                    <X className="h-4 w-4" />
                  </button>
                </div>
                <div className="space-y-4 px-6 py-5">
                  <div>
                    <label className="mb-1.5 block text-xs font-semibold text-strong">
                      Title <span className="text-danger">*</span>
                    </label>
                    <input
                      type="text"
                      value={newTaskTitle}
                      onChange={(e) => setNewTaskTitle(e.target.value)}
                      placeholder="Task title"
                      className="h-9 w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-3 text-sm text-strong placeholder:text-quiet focus:border-[color:var(--border-strong)] focus:outline-none"
                      // eslint-disable-next-line jsx-a11y/no-autofocus
                      autoFocus
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.shiftKey) {
                          e.preventDefault();
                          void handleCreateGroupTask();
                        }
                        if (e.key === "Escape") {
                          setShowNewTaskForm(false);
                          setNewTaskTitle("");
                          setNewTaskDescription("");
                          setNewTaskStatus("inbox");
                        }
                      }}
                    />
                  </div>
                  <div>
                    <label className="mb-1.5 block text-xs font-semibold text-strong">
                      Description <span className="text-quiet font-normal">(optional)</span>
                    </label>
                    <textarea
                      value={newTaskDescription}
                      onChange={(e) => setNewTaskDescription(e.target.value)}
                      placeholder="Describe the task…"
                      rows={3}
                      className="w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-3 py-2 text-sm text-strong placeholder:text-quiet focus:border-[color:var(--border-strong)] focus:outline-none resize-none"
                    />
                  </div>
                  <div>
                    <label className="mb-1.5 block text-xs font-semibold text-strong">
                      Status
                    </label>
                    <select
                      value={newTaskStatus}
                      onChange={(e) => setNewTaskStatus(e.target.value as TaskStatus)}
                      className="h-9 w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface-muted)] px-3 text-sm text-strong focus:border-[color:var(--border-strong)] focus:outline-none"
                    >
                      {STATUS_OPTIONS.map((opt) => (
                        <option key={opt.value} value={opt.value}>
                          {opt.label}
                        </option>
                      ))}
                    </select>
                  </div>
                  {groupTasksError && (
                    <p className="text-xs text-danger">{groupTasksError}</p>
                  )}
                </div>
                <div className="flex items-center justify-end gap-2 border-t border-[color:var(--border)] px-6 py-4">
                  <button
                    type="button"
                    onClick={() => {
                      setShowNewTaskForm(false);
                      setNewTaskTitle("");
                      setNewTaskDescription("");
                      setNewTaskStatus("inbox");
                    }}
                    className="rounded-lg border border-[color:var(--border)] px-3 py-1.5 text-xs font-semibold text-muted transition hover:bg-[color:var(--surface-muted)]"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    onClick={() => void handleCreateGroupTask()}
                    disabled={isCreatingGroupTask || !newTaskTitle.trim()}
                    className="rounded-lg bg-[color:var(--accent)] px-3 py-1.5 text-xs font-semibold text-white transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {isCreatingGroupTask ? "Saving…" : "Save"}
                  </button>
                </div>
              </div>
            </div>
          )}
        </main>
      </SignedIn>

      {/* Panel backdrops */}
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

      {/* Chat panel */}
      <aside
        className={cn(
          "fixed right-0 top-0 z-50 h-full w-[560px] max-w-[96vw] transform border-l border-[color:var(--border)] bg-[color:var(--surface)] shadow-2xl transition-transform",
          isChatOpen ? "transform-none" : "translate-x-full",
        )}
      >
        <div className="flex h-full flex-col">
          <div className="flex items-center justify-between border-b border-[color:var(--border)] px-6 py-4">
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Group chat</p>
              <p className="mt-1 truncate text-sm font-medium text-strong">
                Shared across linked boards. Tag @lead, @name, or @all.
              </p>
            </div>
            <button
              type="button"
              onClick={() => { setIsChatOpen(false); setChatError(null); }}
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
                  onChange={(e) => setChatBroadcast(e.target.checked)}
                  disabled={!canWriteGroup}
                />
                Broadcast
              </label>
              <p className="text-xs text-quiet">
                {chatBroadcast ? "Notifies every agent in the group." : "Notifies leads + mentions."}
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
                <p className="text-sm text-quiet">No messages yet. Start the conversation with a broadcast or a mention.</p>
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

      {/* Notes panel */}
      <aside
        className={cn(
          "fixed right-0 top-0 z-50 h-full w-[560px] max-w-[96vw] transform border-l border-[color:var(--border)] bg-[color:var(--surface)] shadow-2xl transition-transform",
          isNotesOpen ? "transform-none" : "translate-x-full",
        )}
      >
        <div className="flex h-full flex-col">
          <div className="flex items-center justify-between border-b border-[color:var(--border)] px-6 py-4">
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Group notes</p>
              <p className="mt-1 truncate text-sm font-medium text-strong">
                Shared across linked boards. Tag @lead, @name, or @all.
              </p>
            </div>
            <button
              type="button"
              onClick={() => { setIsNotesOpen(false); setNoteSendError(null); }}
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
                  onChange={(e) => setNotesBroadcast(e.target.checked)}
                  disabled={!canWriteGroup}
                />
                Broadcast
              </label>
              <p className="text-xs text-quiet">
                {notesBroadcast ? "Notifies every agent in the group." : "Notifies leads + mentions."}
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
                <p className="text-sm text-quiet">No notes yet. Post a note or a broadcast to share context across boards.</p>
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
