// Board documents API hooks - properly using customFetch
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { customFetch, ApiError } from "@/api/mutator";
import type { BoardDocumentRead, BoardDocumentCreate, BoardDocumentUpdate } from "@/api/generated/model";

export interface ListBoardDocumentsResponse {
  data: {
    items: BoardDocumentRead[];
    total: number;
  };
  status: number;
}

// List documents
export const useListBoardDocumentsApiV1BoardsBoardIdDocumentsGet = <
  TData = ListBoardDocumentsResponse,
  TError = ApiError
>(
  boardId: string,
  params?: { limit?: number },
  options?: { query?: any }
) => {
  return useQuery<TData, TError>({
    queryKey: ["boards", boardId, "documents", params],
    queryFn: async () => {
      const queryParams = new URLSearchParams();
      if (params?.limit) queryParams.set("limit", String(params.limit));
      const queryString = queryParams.toString();
      const url = `/api/v1/boards/${boardId}/documents${queryString ? `?${queryString}` : ""}`;
      return customFetch<TData>(url, { method: "GET" });
    },
    enabled: !!boardId,
    ...options?.query,
  });
};

// Create document
export const useCreateBoardDocumentApiV1BoardsBoardIdDocumentsPost = <
  TError = ApiError
>(
  boardId: string,
  options?: { mutation?: any }
) => {
  const queryClient = useQueryClient();
  return useMutation<{ data: BoardDocumentRead; status: number }, TError, BoardDocumentCreate>({
    mutationFn: async (payload) => {
      return customFetch(`/api/v1/boards/${boardId}/documents`, {
        method: "POST",
        body: JSON.stringify(payload),
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["boards", boardId, "documents"] });
    },
    ...options?.mutation,
  });
};

// Update document
export const useUpdateBoardDocumentApiV1BoardsBoardIdDocumentsDocIdPatch = <
  TError = ApiError
>(
  boardId: string,
  docId?: string,
  options?: { mutation?: any }
) => {
  const queryClient = useQueryClient();
  return useMutation<
    { data: BoardDocumentRead; status: number },
    TError,
    { board_id: string; doc_id: string; data: Partial<BoardDocumentUpdate> }
  >({
    mutationFn: async ({ board_id, doc_id, data }) => {
      return customFetch(`/api/v1/boards/${board_id}/documents/${doc_id}`, {
        method: "PATCH",
        body: JSON.stringify(data),
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["boards", boardId, "documents"] });
    },
    ...options?.mutation,
  });
};

// Delete document
export const useDeleteBoardDocumentApiV1BoardsBoardIdDocumentsDocIdDelete = <
  TError = ApiError
>(
  boardId: string,
  options?: { mutation?: any }
) => {
  const queryClient = useQueryClient();
  return useMutation<void, TError, { board_id: string; doc_id: string }>({
    mutationFn: async ({ board_id, doc_id }) => {
      await customFetch(`/api/v1/boards/${board_id}/documents/${doc_id}`, {
        method: "DELETE",
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["boards", boardId, "documents"] });
    },
    ...options?.mutation,
  });
};
