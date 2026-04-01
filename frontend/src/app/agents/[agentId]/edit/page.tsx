"use client";

export const dynamic = "force-dynamic";

import { useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";

import { useAuth } from "@/auth/clerk";

import { ApiError } from "@/api/mutator";
import {
  type getAgentApiV1AgentsAgentIdGetResponse,
  useGetAgentApiV1AgentsAgentIdGet,
  useUpdateAgentApiV1AgentsAgentIdPatch,
} from "@/api/generated/agents/agents";
import {
  type listBoardsApiV1BoardsGetResponse,
  useListBoardsApiV1BoardsGet,
} from "@/api/generated/boards/boards";
import type { AgentRead, AgentUpdate, BoardRead } from "@/api/generated/model";
import { DashboardPageLayout } from "@/components/templates/DashboardPageLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import SearchableSelect, {
  type SearchableSelectOption,
} from "@/components/ui/searchable-select";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { AGENT_EMOJI_OPTIONS } from "@/lib/agent-emoji";
import { DEFAULT_IDENTITY_PROFILE } from "@/lib/agent-templates";

type IdentityProfile = {
  role: string;
  communication_style: string;
  emoji: string;
};

type AgentCapabilities = {
  policy_name: string;
  secret_keys: string;
  required_secret_keys: string;
  skills: string;
  file_access: string;
  notes: string;
};

const EMPTY_CAPABILITIES: AgentCapabilities = {
  policy_name: "",
  secret_keys: "",
  required_secret_keys: "",
  skills: "",
  file_access: "",
  notes: "",
};

const getBoardOptions = (boards: BoardRead[]): SearchableSelectOption[] =>
  boards.map((board) => ({
    value: board.id,
    label: board.name,
  }));

const mergeIdentityProfile = (
  existing: unknown,
  patch: IdentityProfile,
): Record<string, unknown> | null => {
  const resolved: Record<string, unknown> =
    existing && typeof existing === "object"
      ? { ...(existing as Record<string, unknown>) }
      : {};
  const updates: Record<string, string> = {
    role: patch.role.trim(),
    communication_style: patch.communication_style.trim(),
    emoji: patch.emoji.trim(),
  };
  for (const [key, value] of Object.entries(updates)) {
    if (value) {
      resolved[key] = value;
    } else {
      delete resolved[key];
    }
  }
  return Object.keys(resolved).length > 0 ? resolved : null;
};

const withIdentityDefaults = (
  profile: Partial<IdentityProfile> | null | undefined,
): IdentityProfile => ({
  role: profile?.role ?? DEFAULT_IDENTITY_PROFILE.role,
  communication_style:
    profile?.communication_style ??
    DEFAULT_IDENTITY_PROFILE.communication_style,
  emoji: profile?.emoji ?? DEFAULT_IDENTITY_PROFILE.emoji,
});

const normalizeCapabilitiesText = (value: string): string =>
  value
    .split(/\r?\n|,/)
    .map((entry) => entry.trim())
    .filter(Boolean)
    .join("\n");

const loadCapabilities = (
  identityProfile: unknown,
): AgentCapabilities => {
  if (!identityProfile || typeof identityProfile !== "object") {
    return EMPTY_CAPABILITIES;
  }
  const capabilities = (identityProfile as Record<string, unknown>).capabilities;
  if (!capabilities || typeof capabilities !== "object") {
    return EMPTY_CAPABILITIES;
  }
  const record = capabilities as Record<string, unknown>;
  const readList = (key: string) => {
    const value = record[key];
    if (Array.isArray(value)) {
      return value
        .map((entry) => String(entry).trim())
        .filter(Boolean)
        .join("\n");
    }
    if (typeof value === "string") {
      return normalizeCapabilitiesText(value);
    }
    return "";
  };
  return {
    policy_name:
      typeof record.policy_name === "string" ? record.policy_name : "",
    secret_keys: readList("secret_keys"),
    required_secret_keys: readList("required_secret_keys"),
    skills: readList("skills"),
    file_access: readList("file_access"),
    notes: typeof record.notes === "string" ? record.notes : "",
  };
};

const mergeCapabilities = (
  existing: unknown,
  patch: AgentCapabilities,
): Record<string, unknown> | null => {
  const resolved: Record<string, unknown> =
    existing && typeof existing === "object"
      ? { ...(existing as Record<string, unknown>) }
      : {};
  const asList = (value: string, uppercase = false) =>
    value
      .split(/\r?\n|,/)
      .map((entry) => entry.trim())
      .filter(Boolean)
      .map((entry) => (uppercase ? entry.toUpperCase() : entry));
  const next = {
    policy_name: patch.policy_name.trim(),
    secret_keys: asList(patch.secret_keys, true),
    required_secret_keys: asList(patch.required_secret_keys, true),
    skills: asList(patch.skills),
    file_access: asList(patch.file_access),
    notes: patch.notes.trim(),
  };
  const hasAny = Object.values(next).some((value) =>
    Array.isArray(value) ? value.length > 0 : Boolean(value),
  );
  if (hasAny) {
    resolved.capabilities = next;
  } else {
    delete resolved.capabilities;
  }
  return Object.keys(resolved).length > 0 ? resolved : null;
};

export default function EditAgentPage() {
  const { isSignedIn } = useAuth();
  const router = useRouter();
  const params = useParams();
  const agentIdParam = params?.agentId;
  const agentId = Array.isArray(agentIdParam) ? agentIdParam[0] : agentIdParam;

  const [name, setName] = useState<string | undefined>(undefined);
  const [boardId, setBoardId] = useState<string | undefined>(undefined);
  const [isGatewayMain, setIsGatewayMain] = useState<boolean | undefined>(
    undefined,
  );
  const [heartbeatEvery, setHeartbeatEvery] = useState<string | undefined>(
    undefined,
  );
  const [identityProfile, setIdentityProfile] = useState<
    IdentityProfile | undefined
  >(undefined);
  const [capabilities, setCapabilities] = useState<AgentCapabilities | undefined>(
    undefined,
  );
  const [error, setError] = useState<string | null>(null);

  const boardsQuery = useListBoardsApiV1BoardsGet<
    listBoardsApiV1BoardsGetResponse,
    ApiError
  >(undefined, {
    query: {
      enabled: Boolean(isSignedIn),
      refetchOnMount: "always",
      retry: false,
    },
  });

  const agentQuery = useGetAgentApiV1AgentsAgentIdGet<
    getAgentApiV1AgentsAgentIdGetResponse,
    ApiError
  >(agentId ?? "", {
    query: {
      enabled: Boolean(isSignedIn && agentId),
      refetchOnMount: "always",
      retry: false,
    },
  });

  const updateMutation = useUpdateAgentApiV1AgentsAgentIdPatch<ApiError>({
    mutation: {
      onSuccess: () => {
        if (agentId) {
          router.push(`/agents/${agentId}`);
        }
      },
      onError: (err) => {
        setError(err.message || "Something went wrong.");
      },
    },
  });

  const boards = useMemo<BoardRead[]>(() => {
    if (boardsQuery.data?.status !== 200) return [];
    return boardsQuery.data.data.items ?? [];
  }, [boardsQuery.data]);
  const loadedAgent: AgentRead | null =
    agentQuery.data?.status === 200 ? agentQuery.data.data : null;

  const loadedHeartbeat = useMemo(() => {
    const heartbeat = loadedAgent?.heartbeat_config;
    if (heartbeat && typeof heartbeat === "object") {
      const record = heartbeat as Record<string, unknown>;
      const every = record.every;
      return {
        every: typeof every === "string" && every.trim() ? every : "10m",
      };
    }
    return { every: "10m" };
  }, [loadedAgent?.heartbeat_config]);

  const loadedIdentityProfile = useMemo(() => {
    const identity = loadedAgent?.identity_profile;
    if (identity && typeof identity === "object") {
      const record = identity as Record<string, unknown>;
      return withIdentityDefaults({
        role: typeof record.role === "string" ? record.role : undefined,
        communication_style:
          typeof record.communication_style === "string"
            ? record.communication_style
            : undefined,
        emoji: typeof record.emoji === "string" ? record.emoji : undefined,
      });
    }
    return withIdentityDefaults(null);
  }, [loadedAgent?.identity_profile]);

  const isLoading =
    boardsQuery.isLoading || agentQuery.isLoading || updateMutation.isPending;
  const errorMessage =
    error ?? agentQuery.error?.message ?? boardsQuery.error?.message ?? null;

  const resolvedName = name ?? loadedAgent?.name ?? "";
  const resolvedIsGatewayMain =
    isGatewayMain ?? Boolean(loadedAgent?.is_gateway_main);
  const resolvedHeartbeatEvery = heartbeatEvery ?? loadedHeartbeat.every;
  const resolvedIdentityProfile = identityProfile ?? loadedIdentityProfile;
  const resolvedCapabilities =
    capabilities ?? loadCapabilities(loadedAgent?.identity_profile);

  const resolvedBoardId = useMemo(() => {
    if (resolvedIsGatewayMain) return boardId ?? "";
    return boardId ?? loadedAgent?.board_id ?? boards[0]?.id ?? "";
  }, [boardId, boards, loadedAgent?.board_id, resolvedIsGatewayMain]);

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!isSignedIn || !agentId || !loadedAgent) return;
    const trimmed = resolvedName.trim();
    if (!trimmed) {
      setError("Agent name is required.");
      return;
    }
    if (!resolvedIsGatewayMain && !resolvedBoardId) {
      setError("Select a board or mark this agent as the gateway main.");
      return;
    }
    if (
      resolvedIsGatewayMain &&
      !resolvedBoardId &&
      !loadedAgent.is_gateway_main &&
      !loadedAgent.board_id
    ) {
      setError(
        "Select a board once so we can resolve the gateway main session key.",
      );
      return;
    }
    setError(null);

    const existingHeartbeat =
      loadedAgent.heartbeat_config &&
      typeof loadedAgent.heartbeat_config === "object"
        ? (loadedAgent.heartbeat_config as Record<string, unknown>)
        : {};

    const payload: AgentUpdate = {
      name: trimmed,
      heartbeat_config: {
        ...existingHeartbeat,
        every: resolvedHeartbeatEvery.trim() || "10m",
        target: "last",
        includeReasoning:
          typeof existingHeartbeat.includeReasoning === "boolean"
            ? existingHeartbeat.includeReasoning
            : false,
      } as unknown as Record<string, unknown>,
      identity_profile: mergeIdentityProfile(
        loadedAgent.identity_profile,
        resolvedIdentityProfile,
      ) as unknown as Record<string, unknown> | null,
    };
    payload.identity_profile = mergeCapabilities(
      payload.identity_profile,
      resolvedCapabilities,
    ) as unknown as Record<string, unknown> | null;
    if (!resolvedIsGatewayMain) {
      payload.board_id = resolvedBoardId || null;
    } else if (resolvedBoardId) {
      payload.board_id = resolvedBoardId;
    }
    if (Boolean(loadedAgent.is_gateway_main) !== resolvedIsGatewayMain) {
      payload.is_gateway_main = resolvedIsGatewayMain;
    }

    updateMutation.mutate({ agentId, params: { force: true }, data: payload });
  };

  return (
    <DashboardPageLayout
      signedOut={{
        message: "Sign in to edit agents.",
        forceRedirectUrl: `/agents/${agentId}/edit`,
        signUpForceRedirectUrl: `/agents/${agentId}/edit`,
      }}
      title={
        resolvedName.trim() ? resolvedName : (loadedAgent?.name ?? "Edit agent")
      }
      description="Status is controlled by agent heartbeat."
    >
      <form
        onSubmit={handleSubmit}
        className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 shadow-sm space-y-6"
      >
        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Basic configuration
          </p>
          <div className="mt-4 space-y-6">
            <div className="grid gap-6 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Agent name <span className="text-danger">*</span>
                </label>
                <Input
                  value={resolvedName}
                  onChange={(event) => setName(event.target.value)}
                  placeholder="e.g. Deploy bot"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Role
                </label>
                <Input
                  value={resolvedIdentityProfile.role}
                  onChange={(event) =>
                    setIdentityProfile({
                      ...resolvedIdentityProfile,
                      role: event.target.value,
                    })
                  }
                  placeholder="e.g. Founder, Social Media Manager"
                  disabled={isLoading}
                />
              </div>
            </div>
            <div className="grid gap-6 md:grid-cols-2">
              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <label className="text-sm font-medium text-strong">
                    Board
                    {resolvedIsGatewayMain ? (
                      <span className="ml-2 text-xs font-normal text-quiet">
                        optional
                      </span>
                    ) : (
                      <span className="text-danger"> *</span>
                    )}
                  </label>
                  {resolvedBoardId ? (
                    <button
                      type="button"
                      className="text-xs font-medium text-muted hover:text-strong"
                      onClick={() => {
                        setBoardId("");
                      }}
                      disabled={isLoading}
                    >
                      Clear board
                    </button>
                  ) : null}
                </div>
                <SearchableSelect
                  ariaLabel="Select board"
                  value={resolvedBoardId}
                  onValueChange={(value) => setBoardId(value)}
                  options={getBoardOptions(boards)}
                  placeholder={
                    resolvedIsGatewayMain
                      ? "No board (main agent)"
                      : "Select board"
                  }
                  searchPlaceholder="Search boards..."
                  emptyMessage="No matching boards."
                  triggerClassName="w-full h-11 rounded-xl border border-[color:var(--border-strong)] bg-[color:var(--surface)] px-3 py-2 text-sm font-medium text-strong shadow-sm focus:border-[color:var(--info-border)] focus:ring-2 focus:ring-blue-200"
                  contentClassName="rounded-xl border border-[color:var(--border)] shadow-lg"
                  itemClassName="px-4 py-3 text-sm text-muted data-[selected=true]:bg-[color:var(--surface-muted)] data-[selected=true]:text-strong"
                  disabled={boards.length === 0}
                />
                {resolvedIsGatewayMain ? (
                  <p className="text-xs text-quiet">
                    Main agents are not attached to a board. If a board is
                    selected, it is only used to resolve the gateway main
                    session key and will be cleared on save.
                  </p>
                ) : boards.length === 0 ? (
                  <p className="text-xs text-quiet">
                    Create a board before assigning agents.
                  </p>
                ) : null}
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Emoji
                </label>
                <Select
                  value={resolvedIdentityProfile.emoji}
                  onValueChange={(value) =>
                    setIdentityProfile({
                      ...resolvedIdentityProfile,
                      emoji: value,
                    })
                  }
                  disabled={isLoading}
                >
                  <SelectTrigger>
                    <SelectValue placeholder="Select emoji" />
                  </SelectTrigger>
                  <SelectContent>
                    {AGENT_EMOJI_OPTIONS.map((option) => (
                      <SelectItem key={option.value} value={option.value}>
                        {option.glyph} {option.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          </div>
          <div className="mt-6 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface-muted)] p-4">
            <label className="flex items-start gap-3 text-sm text-muted">
              <input
                type="checkbox"
                className="mt-1 h-4 w-4 rounded border-[color:var(--border-strong)] text-info focus:ring-blue-200"
                checked={resolvedIsGatewayMain}
                onChange={(event) => setIsGatewayMain(event.target.checked)}
                disabled={isLoading}
              />
              <span>
                <span className="block font-medium text-strong">
                  Gateway main agent
                </span>
                <span className="block text-xs text-quiet">
                  Uses the gateway main session key and is not tied to a single
                  board.
                </span>
              </span>
            </label>
          </div>
        </div>

        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Personality & behavior
          </p>
          <div className="mt-4">
            <div className="space-y-2">
              <label className="text-sm font-medium text-strong">
                Communication style
              </label>
              <Input
                value={resolvedIdentityProfile.communication_style}
                onChange={(event) =>
                  setIdentityProfile({
                    ...resolvedIdentityProfile,
                    communication_style: event.target.value,
                  })
                }
                disabled={isLoading}
              />
            </div>
          </div>
        </div>

        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Schedule & notifications
          </p>
          <div className="mt-4">
            <div className="space-y-2">
              <label className="text-sm font-medium text-strong">
                Interval
              </label>
              <Input
                value={resolvedHeartbeatEvery}
                onChange={(event) => setHeartbeatEvery(event.target.value)}
                placeholder="e.g. 10m"
                disabled={isLoading}
              />
              <p className="text-xs text-quiet">
                Set how often this agent runs HEARTBEAT.md.
              </p>
            </div>
          </div>
        </div>

        <div>
          <p className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Managed access policy
          </p>
          <div className="mt-4 grid gap-6">
            <div className="space-y-2">
              <label className="text-sm font-medium text-strong">
                Policy name
              </label>
              <Input
                value={resolvedCapabilities.policy_name}
                onChange={(event) =>
                  setCapabilities({
                    ...resolvedCapabilities,
                    policy_name: event.target.value,
                  })
                }
                placeholder="e.g. board-worker-minimal"
                disabled={isLoading}
              />
            </div>
            <div className="grid gap-6 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Allowed secret keys
                </label>
                <Textarea
                  value={resolvedCapabilities.secret_keys}
                  onChange={(event) =>
                    setCapabilities({
                      ...resolvedCapabilities,
                      secret_keys: event.target.value,
                    })
                  }
                  placeholder={"GITHUB_ACCESS_TOKEN\nSLACK_BOT_TOKEN"}
                  disabled={isLoading}
                  className="min-h-[110px]"
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Required secret keys
                </label>
                <Textarea
                  value={resolvedCapabilities.required_secret_keys}
                  onChange={(event) =>
                    setCapabilities({
                      ...resolvedCapabilities,
                      required_secret_keys: event.target.value,
                    })
                  }
                  placeholder={"GITHUB_ACCESS_TOKEN"}
                  disabled={isLoading}
                  className="min-h-[110px]"
                />
              </div>
            </div>
            <div className="grid gap-6 md:grid-cols-2">
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Allowed skills
                </label>
                <Textarea
                  value={resolvedCapabilities.skills}
                  onChange={(event) =>
                    setCapabilities({
                      ...resolvedCapabilities,
                      skills: event.target.value,
                    })
                  }
                  placeholder={"skill-installer\nrepo-audit"}
                  disabled={isLoading}
                  className="min-h-[110px]"
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium text-strong">
                  Approved file access roots
                </label>
                <Textarea
                  value={resolvedCapabilities.file_access}
                  onChange={(event) =>
                    setCapabilities({
                      ...resolvedCapabilities,
                      file_access: event.target.value,
                    })
                  }
                  placeholder={"/workspace/project-a\n/workspace/shared/docs"}
                  disabled={isLoading}
                  className="min-h-[110px]"
                />
              </div>
            </div>
            <div className="space-y-2">
              <label className="text-sm font-medium text-strong">
                Policy notes
              </label>
              <Textarea
                value={resolvedCapabilities.notes}
                onChange={(event) =>
                  setCapabilities({
                    ...resolvedCapabilities,
                    notes: event.target.value,
                  })
                }
                placeholder="Use this agent for triage only. Escalate for extra access."
                disabled={isLoading}
                className="min-h-[110px]"
              />
            </div>
          </div>
        </div>

        {errorMessage ? (
          <div className="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] p-3 text-sm text-muted shadow-sm">
            {errorMessage}
          </div>
        ) : null}

        <div className="flex flex-wrap items-center gap-3">
          <Button type="submit" disabled={isLoading}>
            {isLoading ? "Saving…" : "Save changes"}
          </Button>
          <Button
            variant="outline"
            type="button"
            onClick={() => router.push(`/agents/${agentId}`)}
          >
            Back to agent
          </Button>
        </div>
      </form>
    </DashboardPageLayout>
  );
}
