"use client";

import { useMemo, useState } from "react";

import type {
  AgentRead,
  BoardRead,
  UtilityJobScriptOption,
} from "@/api/generated/model";
import { ApiError } from "@/api/mutator";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";

const NONE_VALUE = "__none__";

export type UtilityJobFormValues = {
  name: string;
  description: string | null;
  enabled: boolean;
  board_id: string | null;
  agent_id: string | null;
  cron_expression: string;
  script_key: string;
  args: Record<string, unknown> | null;
};

type UtilityJobFormProps = {
  initialValues?: UtilityJobFormValues;
  boards: BoardRead[];
  agents: AgentRead[];
  scriptOptions: UtilityJobScriptOption[];
  isSubmitting: boolean;
  submitLabel: string;
  submittingLabel: string;
  onCancel: () => void;
  onSubmit: (values: UtilityJobFormValues) => Promise<void>;
};

const DEFAULT_VALUES: UtilityJobFormValues = {
  name: "",
  description: null,
  enabled: true,
  board_id: null,
  agent_id: null,
  cron_expression: "0 8 * * *",
  script_key: "",
  args: null,
};

const extractErrorMessage = (error: unknown, fallback: string) => {
  if (error instanceof ApiError) return error.message || fallback;
  if (error instanceof Error) return error.message || fallback;
  return fallback;
};

const stringifyArgs = (args: Record<string, unknown> | null | undefined) =>
  args ? JSON.stringify(args, null, 2) : "";

export function UtilityJobForm({
  initialValues,
  boards,
  agents,
  scriptOptions,
  isSubmitting,
  submitLabel,
  submittingLabel,
  onCancel,
  onSubmit,
}: UtilityJobFormProps) {
  const resolvedInitial = initialValues ?? DEFAULT_VALUES;
  const defaultScriptKey =
    resolvedInitial.script_key || scriptOptions[0]?.key || "";
  const [name, setName] = useState(resolvedInitial.name);
  const [description, setDescription] = useState(
    resolvedInitial.description ?? "",
  );
  const [enabled, setEnabled] = useState(resolvedInitial.enabled);
  const [boardId, setBoardId] = useState(resolvedInitial.board_id);
  const [agentId, setAgentId] = useState(resolvedInitial.agent_id);
  const [cronExpression, setCronExpression] = useState(
    resolvedInitial.cron_expression,
  );
  const [scriptKey, setScriptKey] = useState(defaultScriptKey);
  const [argsText, setArgsText] = useState(stringifyArgs(resolvedInitial.args));
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const boardAgents = useMemo(
    () =>
      agents.filter((agent) => agent.board_id && agent.board_id === boardId),
    [agents, boardId],
  );

  const handleBoardChange = (value: string) => {
    const nextBoardId = value === NONE_VALUE ? null : value;
    setBoardId(nextBoardId);
    if (!nextBoardId) {
      setAgentId(null);
      return;
    }
    const currentAgent = agents.find((agent) => agent.id === agentId);
    if (currentAgent?.board_id !== nextBoardId) {
      setAgentId(null);
    }
  };

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const normalizedName = name.trim();
    const normalizedCron = cronExpression.trim();
    if (!normalizedName) {
      setErrorMessage("Job name is required.");
      return;
    }
    if (!normalizedCron) {
      setErrorMessage("Cron expression is required.");
      return;
    }
    const resolvedScriptKey = scriptKey || scriptOptions[0]?.key || "";
    if (!resolvedScriptKey) {
      setErrorMessage("Select a script.");
      return;
    }

    let parsedArgs: Record<string, unknown> | null = null;
    if (argsText.trim()) {
      try {
        const parsed = JSON.parse(argsText) as unknown;
        if (
          parsed === null ||
          Array.isArray(parsed) ||
          typeof parsed !== "object"
        ) {
          setErrorMessage("Arguments must be a JSON object.");
          return;
        }
        parsedArgs = parsed as Record<string, unknown>;
      } catch {
        setErrorMessage("Arguments must be valid JSON.");
        return;
      }
    }

    setErrorMessage(null);
    try {
      await onSubmit({
        name: normalizedName,
        description: description.trim() || null,
        enabled,
        board_id: boardId,
        agent_id: agentId,
        cron_expression: normalizedCron,
        script_key: resolvedScriptKey,
        args: parsedArgs,
      });
    } catch (error) {
      setErrorMessage(extractErrorMessage(error, "Unable to save job."));
    }
  };

  return (
    <form
      onSubmit={handleSubmit}
      className="space-y-6 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 shadow-sm"
    >
      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Name
          </label>
          <Input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="Daily conversation review"
            disabled={isSubmitting}
          />
        </div>
        <div className="space-y-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Cron expression
          </label>
          <Input
            value={cronExpression}
            onChange={(event) => setCronExpression(event.target.value)}
            placeholder="0 8 * * *"
            disabled={isSubmitting}
          />
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Script
          </label>
          <Select
            value={scriptKey || scriptOptions[0]?.key || ""}
            onValueChange={setScriptKey}
            disabled={isSubmitting}
          >
            <SelectTrigger>
              <SelectValue placeholder="Select script" />
            </SelectTrigger>
            <SelectContent>
              {scriptOptions.map((option) => (
                <SelectItem key={option.key} value={option.key}>
                  {option.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Status
          </label>
          <Select
            value={enabled ? "enabled" : "disabled"}
            onValueChange={(value) => setEnabled(value === "enabled")}
            disabled={isSubmitting}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="enabled">Enabled</SelectItem>
              <SelectItem value="disabled">Disabled</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Board
          </label>
          <Select
            value={boardId ?? NONE_VALUE}
            onValueChange={handleBoardChange}
            disabled={isSubmitting}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={NONE_VALUE}>No board scope</SelectItem>
              {boards.map((board) => (
                <SelectItem key={board.id} value={board.id}>
                  {board.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
            Agent
          </label>
          <Select
            value={agentId ?? NONE_VALUE}
            onValueChange={(value) =>
              setAgentId(value === NONE_VALUE ? null : value)
            }
            disabled={isSubmitting || !boardId}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={NONE_VALUE}>No agent scope</SelectItem>
              {boardAgents.map((agent) => (
                <SelectItem key={agent.id} value={agent.id}>
                  {agent.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="space-y-2">
        <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
          Description
        </label>
        <Textarea
          value={description}
          onChange={(event) => setDescription(event.target.value)}
          placeholder="Optional notes about what this job does"
          disabled={isSubmitting}
        />
      </div>

      <div className="space-y-2">
        <label className="text-xs font-semibold uppercase tracking-wider text-quiet">
          Arguments JSON
        </label>
        <Textarea
          value={argsText}
          onChange={(event) => setArgsText(event.target.value)}
          placeholder={`{\n  "tag": "daily-review"\n}`}
          className="min-h-[130px] font-mono text-xs"
          disabled={isSubmitting}
        />
      </div>

      {errorMessage ? (
        <div className="rounded-lg border border-[color:var(--danger-border)] bg-[color:var(--danger-soft)] p-3 text-sm text-danger">
          {errorMessage}
        </div>
      ) : null}

      <div className="flex justify-end gap-3">
        <Button
          type="button"
          variant="outline"
          onClick={onCancel}
          disabled={isSubmitting}
        >
          Cancel
        </Button>
        <Button
          type="submit"
          disabled={isSubmitting || scriptOptions.length === 0}
        >
          {isSubmitting ? submittingLabel : submitLabel}
        </Button>
      </div>
    </form>
  );
}
