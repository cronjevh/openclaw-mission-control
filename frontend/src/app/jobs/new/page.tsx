"use client";

export const dynamic = "force-dynamic";

import { useMemo } from "react";
import { useRouter } from "next/navigation";

import { useAuth } from "@/auth/clerk";

import { ApiError } from "@/api/mutator";
import {
  useCreateUtilityJobApiV1JobsPost,
  useListUtilityJobScriptOptionsApiV1JobsScriptOptionsGet,
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

export default function NewJobPage() {
  const router = useRouter();
  const { isSignedIn } = useAuth();
  const { isAdmin } = useOrganizationMembership(isSignedIn);

  const createMutation = useCreateUtilityJobApiV1JobsPost<ApiError>({
    mutation: {
      retry: false,
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
        message: "Sign in to create jobs.",
        forceRedirectUrl: "/jobs/new",
        signUpForceRedirectUrl: "/jobs/new",
      }}
      title="Create job"
      description="Schedule an allowlisted utility script."
      isAdmin={isAdmin}
      adminOnlyMessage="Only organization owners and admins can manage jobs."
    >
      <UtilityJobForm
        boards={boards}
        agents={agents}
        scriptOptions={scripts}
        isSubmitting={createMutation.isPending}
        submitLabel="Create job"
        submittingLabel="Creating..."
        onCancel={() => router.push("/jobs")}
        onSubmit={async (values) => {
          const result = await createMutation.mutateAsync({
            data: values,
          });
          if (result.status !== 200) {
            throw new Error("Unable to create job.");
          }
          router.push("/jobs");
        }}
      />
    </DashboardPageLayout>
  );
}
