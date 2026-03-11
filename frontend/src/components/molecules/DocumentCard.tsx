import { Edit2, Trash2, GripVertical } from "lucide-react";
import { cn } from "@/lib/utils";
import { BoardDocumentRead } from "@/api/generated/model/boardDocumentRead";

interface DocumentCardProps {
  document: BoardDocumentRead;
  index: number;
  onEdit: (doc: BoardDocumentRead) => void;
  onDelete: (docId: string) => void;
  isDragging?: boolean;
}

export function DocumentCard({
  document,
  onEdit,
  onDelete,
  isDragging,
}: DocumentCardProps) {
  return (
    <div
      className={cn(
        "rounded-lg border border-[color:var(--border)] bg-[color:var(--surface)] p-4 transition",
        isDragging && "opacity-50"
      )}
    >
      <div className="flex items-start gap-4">
        <div className="mt-0.5 shrink-0 cursor-grab text-quiet hover:text-muted">
          <GripVertical className="h-4 w-4" />
        </div>

        <div className="flex-1 min-w-0">
          <h3 className="font-semibold text-strong break-words">{document.title}</h3>
          {document.description && (
            <p className="text-sm text-muted mt-1 break-words">
              {document.description}
            </p>
          )}
          <p className="text-xs text-quiet mt-2 line-clamp-2 whitespace-pre-wrap">
            {document.content.substring(0, 200)}
            {document.content.length > 200 ? "..." : ""}
          </p>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <button
            type="button"
            onClick={() => onEdit(document)}
            className="p-2 hover:bg-[color:var(--surface-strong)] rounded transition text-quiet hover:text-muted"
            title="Edit document"
          >
            <Edit2 className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => onDelete(document.id)}
            className="p-2 hover:bg-[color:var(--surface-strong)] rounded transition text-quiet hover:text-muted"
            title="Delete document"
          >
            <Trash2 className="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
  );
}
