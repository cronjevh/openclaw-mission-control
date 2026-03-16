"use client";

export const dynamic = "force-dynamic";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams, useRouter, usePathname, useSearchParams } from "next/navigation";

import { SignedIn, SignedOut, useAuth } from "@/auth/clerk";
import {
  LayoutGrid,
  MessageSquare,
  NotebookText,
  Pencil,
  Plus,
  Send,
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
  useListOrgMembersApiV1OrganizationsMeMembersGet,
  type listOrgMembersApiV1OrganizationsMeMembersGetResponse,
} from "@/api/generated/organizations/organizations";
import {
  useListAgentsApiV1AgentsGet,
  type listAgentsApiV1AgentsGetResponse,
} from "@/api/generated/agents/agents";
import type {
  BoardGroupMemoryRead,
  OrganizationMemberRead,
} from "@/api/generated/model";

import {
  type GroupTask,
  type TaskComment,
  listGroupTasks,
  createGroupTask,
  updateGroupTask,
  deleteGroupTask,
  listGroupTaskComments,
  createGroupTaskComment,
} from "@/lib/groupTasks";
import { TaskBoard, type TaskStatus } from "@/components/organisms/TaskBoard";
import { StatusDot } from "@/components/atoms/StatusDot";
import { CollapsibleMarkdown, Markdown } from "@/components/atoms/Markdown";
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
  assignee?: string | null;
  assigned_agent_id?: string | null;
  creator_name?: string | null;
};

const toTaskBoardTask = (t: GroupTask): Task => ({
  id: t.id,
  title: t.title,
  status: t.status as TaskStatus,
  priority: t.priority,
  description: t.description ?? undefined,
  assignee: t.assignee ?? undefined,
  assigned_agent_id: t.assigned_agent_id ?? undefined,
  creator_name: t.creator_name ?? undefined,
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
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
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
  const [chatBroadcast, setChatBroadcast] = useState(false);
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
    // Add group agent name if provisioned
    if (groupAgent?.name) {
      options.add(groupAgent.name.toLowerCase());
    }
    boards.forEach((item) => {
      (item.tasks ?? []).forEach((task) => {
        if (task.assignee) {
          options.add(task.assignee);
        }
      });
    });
    return [...options];
  }, [boards, groupAgent]);

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

  // Board agents query (for team sidebar)
  const boardAgentsQuery = useListAgentsApiV1AgentsGet<listAgentsApiV1AgentsGetResponse, ApiError>(
    undefined,
    { query: { enabled: Boolean(isSignedIn) } },
  );
  const allAgents = useMemo(
    () => (boardAgentsQuery.data?.status === 200 ? (boardAgentsQuery.data.data.items ?? []) : []),
    [boardAgentsQuery.data],
  );
  // Agents belonging to boards in this group (deduped, excluding groupAgent itself)
  const boardLeadAgents = useMemo(() => {
    const seen = new Set<string>();
    if (groupAgent?.id) seen.add(groupAgent.id);
    const result: typeof allAgents = [];
    for (const agent of allAgents) {
      // Only show board lead agents (not workers)
      if (agent.board_id && boardIdSet.has(agent.board_id) && agent.is_board_lead && !seen.has(agent.id)) {
        seen.add(agent.id);
        result.push(agent);
      }
    }
    return result;
  }, [allAgents, boardIdSet, groupAgent]);

    // Group members query — only members with access to THIS group (not all org members)
  const [groupMembers, setGroupMembers] = useState<any[]>([]);
  useEffect(() => {
    if (!groupId || !isSignedIn) return;
    customFetch<{ data: { items: any[] }; status: number }>(
      `/api/v1/board-groups/${groupId}/members`,
      { method: "GET" },
    ).then((res) => {
      setGroupMembers(res.data?.items ?? []);
    }).catch(() => setGroupMembers([]));
  }, [groupId, isSignedIn]);
  const orgMembers = groupMembers;

  const agentAvatarLabel = (name: string) => {
    const parts = name.trim().split(/\s+/);
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return name.slice(0, 2).toUpperCase();
  };

  const agentRoleLabel = (agent: (typeof allAgents)[0]) => {
    if (agent.is_board_lead && agent.group_id) return "Group Lead";
    if (agent.is_board_lead) return "Board Lead";
    return (agent.identity_profile as { role?: string } | null)?.role ?? "Worker";
  };

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
  const [newTaskPriority, setNewTaskPriority] = useState("medium");
  const [newTaskDueAt, setNewTaskDueAt] = useState("");
  const [newTaskAssigneeId, setNewTaskAssigneeId] = useState<string>("");
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
        priority: newTaskPriority,
        due_at: newTaskDueAt || null,
        assigned_agent_id: newTaskAssigneeId || null,
      });
      setNewTaskTitle("");
      setNewTaskDescription("");
      setNewTaskStatus("inbox");
      setNewTaskPriority("medium");
      setNewTaskDueAt("");
      setNewTaskAssigneeId("");
      setShowNewTaskForm(false);
      await fetchGroupTasks();
    } catch (err) {
      setGroupTasksError(err instanceof Error ? err.message : "Failed to create task.");
    } finally {
      setIsCreatingGroupTask(false);
    }
  }, [groupId, isSignedIn, newTaskTitle, newTaskDescription, newTaskStatus, newTaskPriority, newTaskDueAt, newTaskAssigneeId, fetchGroupTasks]);

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

  // Task detail drawer state
  const [selectedGroupTask, setSelectedGroupTask] = useState<GroupTask | null>(null);
  const [isTaskDetailOpen, setIsTaskDetailOpen] = useState(false);
  const [editTaskTitle, setEditTaskTitle] = useState("");
  const [editTaskDescription, setEditTaskDescription] = useState("");
  const [editTaskStatus, setEditTaskStatus] = useState<TaskStatus>("inbox");
  const [editTaskPriority, setEditTaskPriority] = useState("medium");
  const [isSavingTask, setIsSavingTask] = useState(false);
  const [isDeletingTask, setIsDeletingTask] = useState(false);
  const [taskDetailError, setTaskDetailError] = useState<string | null>(null);
  const [isEditingTaskTitle, setIsEditingTaskTitle] = useState(false);

  // Task comments state
  const [taskComments, setTaskComments] = useState<TaskComment[]>([]);
  const [isCommentsLoading, setIsCommentsLoading] = useState(false);
  const [newComment, setNewComment] = useState("");
  const [isPostingComment, setIsPostingComment] = useState(false);
  const [commentError, setCommentError] = useState<string | null>(null);
  const commentsEndRef = useRef<HTMLDivElement | null>(null);

  const fetchTaskComments = useCallback(async (taskId: string) => {
    if (!groupId) return;
    setIsCommentsLoading(true);
    setCommentError(null);
    try {
      const comments = await listGroupTaskComments(groupId, taskId);
      setTaskComments(comments);
    } catch {
      // Silently fail; comments are supplementary
    } finally {
      setIsCommentsLoading(false);
    }
  }, [groupId]);

  const openTaskDetail = useCallback((task: Task) => {
    const full = groupTasks.find((t) => t.id === task.id);
    if (!full) return;
    setSelectedGroupTask(full);
    setEditTaskTitle(full.title);
    setEditTaskDescription(full.description ?? "");
    setEditTaskStatus(full.status as TaskStatus);
    setEditTaskPriority(full.priority ?? "medium");
    setTaskDetailError(null);
    setIsEditingTaskTitle(false);
    setTaskComments([]);
    setNewComment("");
    setCommentError(null);
    setIsTaskDetailOpen(true);
    void fetchTaskComments(full.id);
    // Update URL so the task can be shared
    const p = new URLSearchParams(searchParams.toString());
    p.set("taskId", full.id);
    router.replace(`${pathname}?${p.toString()}`);
  }, [groupTasks, fetchTaskComments, pathname, router, searchParams]);

  const closeTaskDetail = useCallback(() => {
    setIsTaskDetailOpen(false);
    setSelectedGroupTask(null);
    setTaskDetailError(null);
    setIsEditingTaskTitle(false);
    setTaskComments([]);
    setNewComment("");
    setCommentError(null);
    // Remove taskId from URL
    const p = new URLSearchParams(searchParams.toString());
    p.delete("taskId");
    const qs = p.toString();
    router.replace(qs ? `${pathname}?${qs}` : pathname);
  }, [pathname, router, searchParams]);

  // Open task panel from URL ?taskId= on load
  const openedTaskIdFromUrlRef = useRef<string | null>(null);
  useEffect(() => {
    const taskIdFromUrl = searchParams.get("taskId");
    if (!taskIdFromUrl || groupTasks.length === 0) return;
    if (openedTaskIdFromUrlRef.current === taskIdFromUrl) return;
    const found = groupTasks.find((t) => t.id === taskIdFromUrl);
    if (!found) return;
    openedTaskIdFromUrlRef.current = taskIdFromUrl;
    openTaskDetail({ id: found.id, title: found.title, status: found.status as TaskStatus, priority: found.priority });
  }, [searchParams, groupTasks, openTaskDetail]);

  const handleSaveTask = useCallback(async () => {
    if (!groupId || !isSignedIn || !selectedGroupTask) return;
    setIsSavingTask(true);
    setTaskDetailError(null);
    try {
      const updated = await updateGroupTask(groupId, selectedGroupTask.id, {
        title: editTaskTitle,
        description: editTaskDescription || null,
        status: editTaskStatus,
        priority: editTaskPriority,
      });
      setSelectedGroupTask(updated);
      setIsEditingTaskTitle(false);
      await fetchGroupTasks();
    } catch (err) {
      setTaskDetailError(err instanceof Error ? err.message : "Failed to save task.");
    } finally {
      setIsSavingTask(false);
    }
  }, [groupId, isSignedIn, selectedGroupTask, editTaskTitle, editTaskDescription, editTaskStatus, editTaskPriority, fetchGroupTasks]);

  const handlePostComment = useCallback(async () => {
    if (!groupId || !isSignedIn || !selectedGroupTask || !newComment.trim()) return;
    setIsPostingComment(true);
    setCommentError(null);
    try {
      await createGroupTaskComment(groupId, selectedGroupTask.id, newComment.trim());
      setNewComment("");
      await fetchTaskComments(selectedGroupTask.id);
      setTimeout(() => {
        commentsEndRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
      }, 50);
    } catch (err) {
      setCommentError(err instanceof Error ? err.message : "Failed to post comment.");
    } finally {
      setIsPostingComment(false);
    }
  }, [groupId, isSignedIn, selectedGroupTask, newComment, fetchTaskComments]);

  const handleDeleteTask = useCallback(async () => {
    if (!groupId || !isSignedIn || !selectedGroupTask) return;
    if (!confirm("Delete this task?")) return;
    setIsDeletingTask(true);
    setTaskDetailError(null);
    try {
      await deleteGroupTask(groupId, selectedGroupTask.id);
      await fetchGroupTasks();
      closeTaskDetail();
    } catch (err) {
      setTaskDetailError(err instanceof Error ? err.message : "Failed to delete task.");
    } finally {
      setIsDeletingTask(false);
    }
  }, [groupId, isSignedIn, selectedGroupTask, fetchGroupTasks, closeTaskDetail]);

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
                  <h1 className="text-2xl font-semibold tracking-tight text-strong">
                    {group?.name ?? "Group"}
                  </h1>

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
                  {canManageHeartbeat && !showInnerBoards && (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => {
                        setNewTaskAssigneeId(groupAgent?.id ?? "");
                        setShowNewTaskForm(true);
                      }}
                      title="New group task"
                    >
                      <Plus className="mr-2 h-4 w-4" />
                      New Task
                    </Button>
                  )}
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
              {/* Agent row — compact strip below the buttons */}
              <div className="mt-3 flex items-center gap-3">
                {isAgentLoading ? (
                  <span className="text-xs text-muted">Loading agent…</span>
                ) : groupAgent ? (
                  <>
                    <span className="text-xs text-quiet">Agent:</span>
                    <span className="text-xs font-semibold text-strong">{groupAgent.name}</span>
                    {(() => {
                      // Derive display status: if last_seen_at < 30min ago, treat as online
                      const seenMs = groupAgent.last_seen_at ? new Date(groupAgent.last_seen_at).getTime() : 0;
                      const agoMs = Date.now() - seenMs;
                      const displayStatus = groupAgent.status === "working"
                        ? "working"
                        : agoMs < 30 * 60 * 1000
                          ? "online"
                          : groupAgent.status;
                      return (
                        <span
                          className={cn(
                            "inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px] font-semibold",
                            displayStatus === "online"
                              ? "border-emerald-200 bg-[color:var(--success-soft)] text-success"
                              : displayStatus === "working"
                                ? "border-blue-300 bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:border-blue-700"
                                : "border-[color:var(--warning-border)] bg-[color:var(--warning-soft)] text-warning",
                          )}
                        >
                          {displayStatus === "working" && (
                            <span className="relative flex h-1.5 w-1.5">
                              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-blue-400 opacity-75" />
                              <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-blue-500" />
                            </span>
                          )}
                          {displayStatus}
                        </span>
                      );
                    })()}
                    {isAdmin && (
                      <button
                        type="button"
                        onClick={() => void deprovisionGroupAgent()}
                        disabled={isDeprovisioningAgent}
                        className="text-[11px] text-danger hover:underline disabled:opacity-50"
                      >
                        {isDeprovisioningAgent ? "Removing…" : "Deprovision"}
                      </button>
                    )}
                  </>
                ) : (
                  <>
                    <span className="text-xs text-quiet">No group agent</span>
                    {isAdmin && (
                      <button
                        type="button"
                        onClick={() => void provisionGroupAgent()}
                        disabled={isProvisioningAgent}
                        className="text-[11px] text-[color:var(--accent)] hover:underline disabled:opacity-50"
                      >
                        {isProvisioningAgent ? "Provisioning…" : "Provision agent"}
                      </button>
                    )}
                  </>
                )}
                {agentError && <span className="text-[11px] text-danger">{agentError}</span>}
              </div>
            </div>
          </div>

          {/* Content area */}
          <div className="relative flex flex-1 min-h-0 gap-4 p-6 overflow-hidden">
            {/* Team sidebar — always visible, same level as content */}
            {!showInnerBoards && (
              <aside className="flex h-full w-60 flex-col rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm shrink-0">
                  {/* Header */}
                  <div className="flex items-center justify-between border-b border-[color:var(--border)] px-4 py-3">
                    <div>
                      <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Team</p>
                      <p className="text-xs text-quiet">
                        {(groupAgent ? 1 : 0) + boardLeadAgents.length} agents · {orgMembers.length} humans
                      </p>
                    </div>
                    <Link
                      href="/organization"
                      className="rounded-md border border-[color:var(--border)] px-2.5 py-1 text-xs font-semibold text-muted transition hover:border-[color:var(--border-strong)] hover:bg-[color:var(--surface-muted)]"
                    >
                      Add
                    </Link>
                  </div>
                  {/* Body */}
                  <div className="flex-1 overflow-y-auto p-3 space-y-1">
                    {/* Agents */}
                    <p className="px-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-quiet">
                      Agents
                    </p>

                    {/* Group Agent first */}
                    {groupAgent && (() => {
                      const seenMs = groupAgent.last_seen_at ? new Date(groupAgent.last_seen_at).getTime() : 0;
                      const agoMs = Date.now() - seenMs;
                      const displayStatus = groupAgent.status === "working"
                        ? "working"
                        : agoMs < 30 * 60 * 1000
                          ? "online"
                          : groupAgent.status;
                      return (
                        <div className="flex w-full items-center gap-3 rounded-lg border border-transparent px-2 py-2">
                          <div className="relative flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[color:var(--surface)] text-xs font-semibold text-strong border border-[color:var(--border-strong)]">
                            {agentAvatarLabel(groupAgent.name)}
                            <StatusDot
                              status={displayStatus}
                              variant="agent"
                              className="absolute -right-1 -bottom-1 h-3.5 w-3.5 rounded-full border-2 border-[color:var(--surface-muted)]"
                            />
                          </div>
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm font-medium text-strong">{groupAgent.name}</p>
                            <p className="text-[11px] text-quiet">Group Lead</p>
                          </div>
                        </div>
                      );
                    })()}

                    {/* Board lead agents */}
                    {boardLeadAgents.map((agent) => (
                      <div key={agent.id} className="flex w-full items-center gap-3 rounded-lg border border-transparent px-2 py-2">
                        <div className="relative flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[color:var(--surface)] text-xs font-semibold text-strong border border-[color:var(--border-strong)]">
                          {agentAvatarLabel(agent.name)}
                          <StatusDot
                            status={agent.status}
                            variant="agent"
                            className="absolute -right-1 -bottom-1 h-3.5 w-3.5 rounded-full border-2 border-[color:var(--surface-muted)]"
                          />
                        </div>
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm font-medium text-strong">{agent.name}</p>
                          <p className="text-[11px] text-quiet">{agentRoleLabel(agent)}</p>
                        </div>
                      </div>
                    ))}

                    {!groupAgent && boardLeadAgents.length === 0 && (
                      <div className="rounded-lg border border-dashed border-[color:var(--border)] p-3 text-xs text-quiet">
                        No agents in this group yet.
                      </div>
                    )}

                    {/* Humans */}
                    {orgMembers.length > 0 && (
                      <>
                        <div className="my-3 border-t border-[color:var(--border)]" />
                        <p className="px-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-quiet">
                          Humans
                        </p>
                        {orgMembers.map((m: any) => {
                          const name = m.name ?? m.user?.name ?? m.user?.email ?? m.email ?? "Unknown";
                          const initials = name.split(" ").map((w: string) => w[0]).join("").toUpperCase().slice(0, 2);
                          const hasWrite = m.can_write ?? m.all_boards_write;
                          const accessLabel = hasWrite ? "read-write" : "read-only";
                          return (
                            <div key={m.user_id} className="flex w-full items-center gap-3 rounded-lg border border-transparent px-2 py-2">
                              <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-[color:var(--accent)] to-[color:var(--accent-strong)] text-xs font-semibold text-white">
                                {initials}
                              </div>
                              <div className="min-w-0 flex-1">
                                <p className="truncate text-sm font-medium text-strong">{name}</p>
                                <p className="text-[11px] text-quiet">{accessLabel}</p>
                              </div>
                            </div>
                          );
                        })}
                      </>
                    )}
                  </div>
                </aside>
            )}

            {/* Main content — kanban or inner boards */}
            {!showInnerBoards ? (
              /* ── Kanban view ── */
              <div className="min-w-0 flex-1 min-h-0 h-full flex flex-col overflow-hidden">
                {groupTasksError && (
                  <p className="shrink-0 mb-3 text-xs text-danger">{groupTasksError}</p>
                )}
                {isGroupTasksLoading ? (
                  <div className="flex-1 flex items-center justify-center text-sm text-muted">
                    Loading group tasks…
                  </div>
                ) : (
                  <TaskBoard
                    tasks={taskBoardTasks}
                    onTaskMove={canManageHeartbeat ? handleGroupTaskMove : undefined}
                    onTaskSelect={openTaskDetail}
                    readOnly={!canManageHeartbeat}
                  />
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
            <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40" onClick={() => setShowNewTaskForm(false)}>
              <div className="w-full max-w-lg rounded-2xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-2xl" onClick={(e) => e.stopPropagation()}>
                <div className="border-b border-[color:var(--border)] px-6 py-5">
                  <h2 className="text-lg font-semibold text-strong">New task</h2>
                  <p className="mt-0.5 text-xs text-quiet">Add a task to the inbox and triage it when you are ready.</p>
                </div>
                <div className="space-y-5 px-6 py-5 max-h-[70vh] overflow-y-auto">
                  {/* Title */}
                  <div>
                    <label className="mb-1.5 block text-sm font-semibold text-strong">Title</label>
                    <input
                      type="text"
                      value={newTaskTitle}
                      onChange={(e) => setNewTaskTitle(e.target.value)}
                      placeholder="e.g. Prepare launch notes"
                      className="h-11 w-full rounded-xl border border-[color:var(--border-strong)] bg-[color:var(--surface)] px-3 text-sm text-strong placeholder:text-quiet focus:border-[color:var(--accent)] focus:ring-2 focus:ring-blue-200 focus:outline-none"
                      autoFocus
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void handleCreateGroupTask(); }
                        if (e.key === "Escape") setShowNewTaskForm(false);
                      }}
                    />
                  </div>
                  {/* Description */}
                  <div>
                    <label className="mb-1.5 block text-sm font-semibold text-strong">Description</label>
                    <textarea
                      value={newTaskDescription}
                      onChange={(e) => setNewTaskDescription(e.target.value)}
                      placeholder="Optional details"
                      rows={4}
                      className="w-full rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-2.5 text-sm text-strong placeholder:text-quiet focus:border-[color:var(--accent)] focus:outline-none resize-y"
                    />
                  </div>
                  {/* Priority */}
                  <div>
                    <label className="mb-1.5 block text-sm font-semibold text-strong">Priority</label>
                    <select
                      value={newTaskPriority}
                      onChange={(e) => setNewTaskPriority(e.target.value)}
                      className="h-11 w-full rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong focus:outline-none"
                    >
                      <option value="low">Low</option>
                      <option value="medium">Medium</option>
                      <option value="high">High</option>
                      <option value="critical">Critical</option>
                    </select>
                  </div>
                  {/* Due date */}
                  <div>
                    <label className="mb-1.5 block text-sm font-semibold text-strong">Due date</label>
                    <input
                      type="date"
                      value={newTaskDueAt}
                      onChange={(e) => setNewTaskDueAt(e.target.value)}
                      className="h-11 w-full rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong focus:outline-none"
                    />
                  </div>
                  {/* Assign to */}
                  <div>
                    <label className="mb-1.5 block text-sm font-semibold text-strong">Assign to</label>
                    <select
                      value={newTaskAssigneeId}
                      onChange={(e) => setNewTaskAssigneeId(e.target.value)}
                      className="h-11 w-full rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong focus:outline-none"
                    >
                      <option value="">Unassigned</option>
                      {groupAgent && <option value={groupAgent.id}>{groupAgent.name} (group lead)</option>}
                    </select>
                  </div>
                  {groupTasksError && (
                    <p className="text-xs text-danger">{groupTasksError}</p>
                  )}
                </div>
                <div className="flex items-center justify-end gap-3 border-t border-[color:var(--border)] px-6 py-4">
                  <button
                    type="button"
                    onClick={() => setShowNewTaskForm(false)}
                    className="rounded-xl border border-[color:var(--border)] px-4 py-2 text-sm font-semibold text-muted transition hover:bg-[color:var(--surface-muted)]"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    onClick={() => void handleCreateGroupTask()}
                    disabled={isCreatingGroupTask || !newTaskTitle.trim()}
                    className="rounded-xl bg-[color:var(--accent)] px-5 py-2 text-sm font-semibold text-white transition hover:opacity-90 disabled:opacity-50"
                  >
                    {isCreatingGroupTask ? "Creating…" : "Create task"}
                  </button>
                </div>
              </div>
            </div>
          )}


        </main>
      </SignedIn>

      {/* Task detail side panel backdrop */}
      {isTaskDetailOpen ? (
        <div
          className="fixed inset-0 z-40 bg-black/30"
          onClick={closeTaskDetail}
        />
      ) : null}

      {/* Task detail side panel — matches board page design */}
      <aside
        className={cn(
          "fixed right-0 top-0 z-50 h-full w-[max(760px,45vw)] max-w-[99vw] transform bg-[color:var(--surface)] shadow-2xl transition-transform",
          isTaskDetailOpen ? "transform-none" : "translate-x-full",
        )}
      >
        <div className="flex h-full flex-col">
          {/* Header */}
          <div className="flex items-center justify-between border-b border-[color:var(--border)] px-6 py-4">
            <div>
              <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Task detail</p>
              <p className="mt-1 text-sm font-medium text-strong">
                {selectedGroupTask?.title ?? "Task"}
              </p>
            </div>
            <div className="flex items-center gap-2">
              {canManageHeartbeat && (
                <button
                  type="button"
                  onClick={() => setIsEditingTaskTitle((v) => !v)}
                  className="rounded-lg border border-[color:var(--border)] p-2 text-quiet transition hover:bg-[color:var(--surface-muted)]"
                  title="Edit task"
                >
                  <Pencil className="h-4 w-4" />
                </button>
              )}
              <button
                type="button"
                onClick={closeTaskDetail}
                className="rounded-lg border border-[color:var(--border)] p-2 text-quiet transition hover:bg-[color:var(--surface-muted)]"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>

          {/* Body */}
          <div className="flex-1 space-y-6 overflow-y-auto px-6 py-5">
            {/* Task ID */}
            {selectedGroupTask && (
              <div className="flex items-center gap-2">
                <span className="text-xs font-semibold uppercase tracking-wider text-quiet">Task ID</span>
                <span
                  className="cursor-pointer select-all rounded bg-[color:var(--surface-strong)] px-2 py-0.5 font-mono text-xs text-quiet hover:bg-[color:var(--surface-strong)]"
                  title="Click to select"
                >
                  {selectedGroupTask.id}
                </span>
              </div>
            )}

            {/* Edit form (title, status, priority, description) — shown when editing */}
            {isEditingTaskTitle && canManageHeartbeat ? (
              <div className="space-y-4 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-4">
                <div>
                  <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-quiet">Title</label>
                  <input
                    type="text"
                    value={editTaskTitle}
                    onChange={(e) => setEditTaskTitle(e.target.value)}
                    className="h-9 w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong focus:outline-none"
                    // eslint-disable-next-line jsx-a11y/no-autofocus
                    autoFocus
                  />
                </div>
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-quiet">Status</label>
                    <select value={editTaskStatus} onChange={(e) => setEditTaskStatus(e.target.value as TaskStatus)} className="h-9 w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong focus:outline-none">
                      {STATUS_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                    </select>
                  </div>
                  <div>
                    <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-quiet">Priority</label>
                    <select value={editTaskPriority} onChange={(e) => setEditTaskPriority(e.target.value)} className="h-9 w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-3 text-sm text-strong focus:outline-none">
                      <option value="low">Low</option>
                      <option value="medium">Medium</option>
                      <option value="high">High</option>
                      <option value="critical">Critical</option>
                    </select>
                  </div>
                </div>
                <div>
                  <label className="mb-1.5 block text-xs font-semibold uppercase tracking-wider text-quiet">Description</label>
                  <textarea value={editTaskDescription} onChange={(e) => setEditTaskDescription(e.target.value)} rows={4} className="w-full rounded-md border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-2 text-sm text-strong focus:outline-none resize-none" />
                </div>
                {taskDetailError && <p className="text-xs text-danger">{taskDetailError}</p>}
                <div className="flex items-center justify-between pt-1">
                  <button type="button" onClick={() => void handleDeleteTask()} disabled={isDeletingTask} className="rounded-lg border border-[color:var(--danger-border)] px-3 py-1.5 text-xs font-semibold text-danger transition hover:bg-[color:var(--danger-soft)] disabled:opacity-50">
                    {isDeletingTask ? "Deleting…" : "Delete Task"}
                  </button>
                  <div className="flex gap-2">
                    <button type="button" onClick={() => setIsEditingTaskTitle(false)} className="rounded-lg border border-[color:var(--border)] px-3 py-1.5 text-xs font-semibold text-muted transition hover:bg-[color:var(--surface-muted)]">Cancel</button>
                    <button type="button" onClick={() => void handleSaveTask()} disabled={isSavingTask || !editTaskTitle.trim()} className="rounded-lg bg-[color:var(--accent)] px-4 py-1.5 text-xs font-semibold text-white transition hover:opacity-90 disabled:opacity-50">
                      {isSavingTask ? "Saving…" : "Save Changes"}
                    </button>
                  </div>
                </div>
              </div>
            ) : (
              <>
                {/* Description (read mode) */}
                <div className="space-y-2">
                  <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Description</p>
                  {selectedGroupTask?.description ? (
                    <div className="prose prose-sm max-w-none dark:prose-invert text-[color:var(--text)]">
                      <CollapsibleMarkdown content={selectedGroupTask.description} variant="description" />
                    </div>
                  ) : (
                    <p className="text-sm text-quiet">No description provided.</p>
                  )}
                </div>

                {/* Created by */}
                {selectedGroupTask?.creator_name && (
                  <div className="space-y-1">
                    <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Created by</p>
                    <p className="text-sm text-muted">{selectedGroupTask.creator_name}</p>
                  </div>
                )}
              </>
            )}

            {/* Comments section */}
            <div className="space-y-3">
              <p className="text-xs font-semibold uppercase tracking-wider text-quiet">Comments</p>
              {/* Composer first (above comments, like board page) */}
              <div className="space-y-2 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-3">
                <BoardChatComposer
                  placeholder="Write a message for the assigned agent. Tag @lead or @name."
                  isSending={isPostingComment}
                  disabled={!isSignedIn || !selectedGroupTask}
                  mentionSuggestions={groupMentionSuggestions}
                  onSend={async (content) => {
                    if (!groupId || !selectedGroupTask) return false;
                    setIsPostingComment(true);
                    setCommentError(null);
                    try {
                      await createGroupTaskComment(groupId, selectedGroupTask.id, content);
                      await fetchTaskComments(selectedGroupTask.id);
                      return true;
                    } catch (err) {
                      setCommentError(err instanceof Error ? err.message : "Failed to post comment.");
                      return false;
                    } finally {
                      setIsPostingComment(false);
                    }
                  }}
                />
                {commentError && <p className="text-xs text-danger">{commentError}</p>}
              </div>
              {/* Comment list below */}
              {isCommentsLoading ? (
                <p className="text-sm text-quiet">Loading comments…</p>
              ) : taskComments.length === 0 ? (
                <p className="text-sm text-quiet">No comments yet.</p>
              ) : (
                <div className="space-y-3">
                  {taskComments.map((comment) => (
                    <div key={comment.id} className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-3">
                      <div className="flex items-center justify-between text-xs text-quiet">
                        <span>{comment.author_name ?? comment.agent_name ?? (comment.agent_id ? "Agent" : "User")}</span>
                        <span>{new Date(comment.created_at).toLocaleString()}</span>
                      </div>
                      <div className="mt-2 select-text cursor-text text-sm leading-relaxed text-strong break-words">
                        <Markdown content={comment.message ?? ""} variant="comment" />
                      </div>
                    </div>
                  ))}
                  <div ref={commentsEndRef} />
                </div>
              )}
            </div>
          </div>
        </div>
      </aside>

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
