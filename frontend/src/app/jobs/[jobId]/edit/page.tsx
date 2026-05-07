"use client";

export const dynamic = "force-dynamic";

import { useMemo } from "react";
import { useParams, useRouter } from "next/navigation";

import { useAuth } from "@/auth/clerk";

import { ApiError } from "@/api/mutator";
import {
  type getUtilityJobApiV1JobsJobIdGetResponse,
  useGetUtilityJobApiV1JobsJobIdGet,
  useListUtilityJobScriptOptionsApiV1JobsScriptOptionsGet,
  useUpdateUtilityJobApiV1JobsJobIdPatch,
} from "@/api/generated/jobs/jobs";
import {
  type listBoardsApiV1BoardsGetResponse,
  useListBoardsApiV1BoardsGet,
} from "@/api/generated/boards/boards";
import {
  type listAgentsApiV1AgentsGetResponse,
  useListAgentsApiV1AgentsGet,
} from "@/api/generated/agents/agents";
import { UtilityJobForm } from "@/components/jobs/UtilityJobForm";
import { DashboardPageLayout } from "@/components/templates/DashboardPageLayout";
import { useOrganizationMembership } from "@/lib/use-organization-membership";

export default function EditJobPage() {
  const params = useParams<{ jobId: string }>();
  const jobId = params.jobId;
  const router = useRouter();
  const { isSignedIn } = useAuth();
  const { isAdmin } = useOrganizationMembership(isSignedIn);

  const jobQuery = useGetUtilityJobApiV1JobsJobIdGet<
    getUtilityJobApiV1JobsJobIdGetResponse,
    ApiError
  >(jobId, {
    query: {
      enabled: Boolean(isSignedIn && jobId),
      refetchOnMount: "always",
    },
  });
  const boardsQuery = useListBoardsApiV1BoardsGet<
    listBoardsApiV1BoardsGetResponse,
    ApiError
  >({ limit: 200 }, { query: { enabled: Boolean(isSignedIn) } });
  const agentsQuery = useListAgentsApiV1AgentsGet<
    listAgentsApiV1AgentsGetResponse,
    ApiError
  >({ limit: 200 }, { query: { enabled: Boolean(isSignedIn) } });
  const scriptsQuery = useListUtilityJobScriptOptionsApiV1JobsScriptOptionsGet({
    query: {
      enabled: Boolean(isSignedIn),
    },
  });
  const updateMutation = useUpdateUtilityJobApiV1JobsJobIdPatch<ApiError>({
    mutation: {
      retry: false,
    },
  });

  const job = jobQuery.data?.status === 200 ? jobQuery.data.data : null;
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

  return (
    <DashboardPageLayout
      signedOut={{
        message: "Sign in to edit jobs.",
        forceRedirectUrl: `/jobs/${jobId}/edit`,
        signUpForceRedirectUrl: `/jobs/${jobId}/edit`,
      }}
      title="Edit job"
      description={job ? `Update ${job.name}.` : "Loading job..."}
      isAdmin={isAdmin}
      adminOnlyMessage="Only organization owners and admins can manage jobs."
    >
      {job ? (
        <UtilityJobForm
          jobId={jobId}
          initialValues={{
            name: job.name,
            description: job.description ?? null,
            enabled: job.enabled ?? true,
            board_id: job.board_id ?? null,
            agent_id: job.agent_id ?? null,
            cron_expression: job.cron_expression,
            script_key: job.script_key,
            args: job.args ?? null,
          }}
          boards={boards}
          agents={agents}
          scriptOptions={scripts}
          isSubmitting={updateMutation.isPending}
          submitLabel="Save job"
          submittingLabel="Saving..."
          onCancel={() => router.push("/jobs")}
          onSubmit={async (values) => {
            const result = await updateMutation.mutateAsync({
              jobId,
              data: values,
            });
            if (result.status !== 200) {
              throw new Error("Unable to update job.");
            }
            router.push("/jobs");
          }}
        />
      ) : jobQuery.error ? (
        <p className="text-sm text-danger">{jobQuery.error.message}</p>
      ) : (
        <div className="rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-6 text-sm text-muted shadow-sm">
          Loading job...
        </div>
      )}
    </DashboardPageLayout>
  );
}
