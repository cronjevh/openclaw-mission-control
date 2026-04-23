"use client";

export const dynamic = "force-dynamic";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";

import { useAuth } from "@/auth/clerk";
import { useQueryClient } from "@tanstack/react-query";

import { ApiError } from "@/api/mutator";
import {
  getListUtilityJobsApiV1JobsGetQueryKey,
  type listUtilityJobScriptOptionsApiV1JobsScriptOptionsGetResponse,
  type listUtilityJobsApiV1JobsGetResponse,
  useDeleteUtilityJobApiV1JobsJobIdDelete,
  useListUtilityJobScriptOptionsApiV1JobsScriptOptionsGet,
  useListUtilityJobsApiV1JobsGet,
} from "@/api/generated/jobs/jobs";
import {
  type listBoardsApiV1BoardsGetResponse,
  useListBoardsApiV1BoardsGet,
} from "@/api/generated/boards/boards";
import {
  type listAgentsApiV1AgentsGetResponse,
  useListAgentsApiV1AgentsGet,
} from "@/api/generated/agents/agents";
import type { UtilityJobRead } from "@/api/generated/model";
import { UtilityJobsTable } from "@/components/jobs/UtilityJobsTable";
import { ConfirmActionDialog } from "@/components/ui/confirm-action-dialog";
import { buttonVariants } from "@/components/ui/button";
import { DashboardPageLayout } from "@/components/templates/DashboardPageLayout";
import { useOrganizationMembership } from "@/lib/use-organization-membership";
import { useUrlSorting } from "@/lib/use-url-sorting";

const JOB_SORTABLE_COLUMNS = [
  "name",
  "cron_expression",
  "script_key",
  "updated_at",
];

const extractErrorMessage = (error: unknown, fallback: string) => {
  if (error instanceof ApiError) return error.message || fallback;
  if (error instanceof Error) return error.message || fallback;
  return fallback;
};

export default function JobsPage() {
  const { isSignedIn } = useAuth();
  const { isAdmin } = useOrganizationMembership(isSignedIn);
  const router = useRouter();
  const queryClient = useQueryClient();
  const { sorting, onSortingChange } = useUrlSorting({
    allowedColumnIds: JOB_SORTABLE_COLUMNS,
    defaultSorting: [{ id: "name", desc: false }],
    paramPrefix: "jobs",
  });

  const [deleteTarget, setDeleteTarget] = useState<UtilityJobRead | null>(null);

  const jobsKey = getListUtilityJobsApiV1JobsGetQueryKey();
  const jobsQuery = useListUtilityJobsApiV1JobsGet<
    listUtilityJobsApiV1JobsGetResponse,
    ApiError
  >(undefined, {
    query: {
      enabled: Boolean(isSignedIn),
      refetchOnMount: "always",
      refetchInterval: 30_000,
    },
  });
  const boardsQuery = useListBoardsApiV1BoardsGet<
    listBoardsApiV1BoardsGetResponse,
    ApiError
  >(
    { limit: 200 },
    {
      query: {
        enabled: Boolean(isSignedIn),
        refetchOnMount: "always",
        refetchInterval: 30_000,
      },
    },
  );
  const agentsQuery = useListAgentsApiV1AgentsGet<
    listAgentsApiV1AgentsGetResponse,
    ApiError
  >(
    { limit: 200 },
    {
      query: {
        enabled: Boolean(isSignedIn),
        refetchOnMount: "always",
        refetchInterval: 30_000,
      },
    },
  );
  const scriptsQuery = useListUtilityJobScriptOptionsApiV1JobsScriptOptionsGet<
    listUtilityJobScriptOptionsApiV1JobsScriptOptionsGetResponse,
    ApiError
  >({
    query: {
      enabled: Boolean(isSignedIn),
      refetchOnMount: "always",
    },
  });

  const jobs = useMemo(
    () =>
      jobsQuery.data?.status === 200 ? (jobsQuery.data.data.items ?? []) : [],
    [jobsQuery.data],
  );
  const boards = useMemo(
    () =>
      boardsQuery.data?.status === 200
        ? (boardsQuery.data.data.items ?? [])
        : [],
    [boardsQuery.data],
  );
  const agents = useMemo(
    () =>
      agentsQuery.data?.status === 200
        ? (agentsQuery.data.data.items ?? [])
        : [],
    [agentsQuery.data],
  );
  const scripts = useMemo(
    () => (scriptsQuery.data?.status === 200 ? scriptsQuery.data.data : []),
    [scriptsQuery.data],
  );

  const deleteMutation = useDeleteUtilityJobApiV1JobsJobIdDelete({
    mutation: {
      onSuccess: async () => {
        setDeleteTarget(null);
        await queryClient.invalidateQueries({ queryKey: jobsKey });
      },
    },
  });

  const handleDelete = () => {
    if (!deleteTarget) return;
    deleteMutation.mutate({ jobId: deleteTarget.id });
  };

  return (
    <>
      <DashboardPageLayout
        signedOut={{
          message: "Sign in to manage jobs.",
          forceRedirectUrl: "/jobs",
          signUpForceRedirectUrl: "/jobs",
        }}
        title="Jobs"
        description={`${jobs.length} utility job${jobs.length === 1 ? "" : "s"} configured.`}
        headerActions={
          isAdmin ? (
            <Link
              href="/jobs/new"
              className={buttonVariants({ size: "md", variant: "primary" })}
            >
              New job
            </Link>
          ) : null
        }
        isAdmin={isAdmin}
        adminOnlyMessage="Only organization owners and admins can manage jobs."
        stickyHeader
      >
        <div className="overflow-hidden rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] shadow-sm">
          <UtilityJobsTable
            jobs={jobs}
            boards={boards}
            agents={agents}
            scriptOptions={scripts}
            isLoading={
              jobsQuery.isLoading ||
              boardsQuery.isLoading ||
              agentsQuery.isLoading ||
              scriptsQuery.isLoading
            }
            sorting={sorting}
            onSortingChange={onSortingChange}
            stickyHeader
            onEdit={
              isAdmin
                ? (job) => {
                    router.push(`/jobs/${job.id}/edit`);
                  }
                : undefined
            }
            onDelete={isAdmin ? setDeleteTarget : undefined}
            emptyState={{
              title: "No jobs yet",
              description:
                "Create jobs to schedule deterministic utility scripts from Mission Control.",
              actionHref: isAdmin ? "/jobs/new" : undefined,
              actionLabel: isAdmin ? "Create your first job" : undefined,
            }}
          />
        </div>
        {jobsQuery.error ? (
          <p className="mt-4 text-sm text-danger">{jobsQuery.error.message}</p>
        ) : null}
      </DashboardPageLayout>

      <ConfirmActionDialog
        open={Boolean(deleteTarget)}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null);
        }}
        ariaLabel="Delete job"
        title="Delete job"
        description={
          <>
            This will remove <strong>{deleteTarget?.name}</strong> and delete
            its generated cron file. This action cannot be undone.
          </>
        }
        errorMessage={
          deleteMutation.error
            ? extractErrorMessage(deleteMutation.error, "Unable to delete job.")
            : undefined
        }
        onConfirm={handleDelete}
        isConfirming={deleteMutation.isPending}
      />
    </>
  );
}
