import { useState } from "react";
import { Loader2 } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { BoardDocumentRead } from "@/api/generated/model/boardDocumentRead";

interface DocumentModalProps {
  open: boolean;
  document?: BoardDocumentRead | null;
  onSave: (data: {
    title: string;
    content: string;
    description?: string;
  }) => Promise<void>;
  onOpenChange: (open: boolean) => void;
  isSaving?: boolean;
}

export function DocumentModal({
  open,
  document,
  onSave,
  onOpenChange,
  isSaving = false,
}: DocumentModalProps) {
  const [title, setTitle] = useState(document?.title || "");
  const [description, setDescription] = useState(document?.description || "");
  const [content, setContent] = useState(document?.content || "");
  const [error, setError] = useState<string | null>(null);

  const handleSave = async () => {
    if (!title.trim()) {
      setError("Title is required");
      return;
    }
    if (!content.trim()) {
      setError("Content is required");
      return;
    }

    setError(null);
    try {
      await onSave({
        title: title.trim(),
        description: description.trim() || undefined,
        content,
      });
      onOpenChange(false);
      resetForm();
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Failed to save document"
      );
    }
  };

  const resetForm = () => {
    setTitle(document?.title || "");
    setDescription(document?.description || "");
    setContent(document?.content || "");
    setError(null);
  };

  const handleOpenChange = (newOpen: boolean) => {
    if (!newOpen) {
      resetForm();
    }
    onOpenChange(newOpen);
  };

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-2xl max-h-[80vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {document ? "Edit Document" : "Add Document"}
          </DialogTitle>
          <DialogDescription>
            {document
              ? "Update the document content"
              : "Add a new document or guide to provide context for agents"}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div>
            <label className="text-xs font-medium text-muted">Title*</label>
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="e.g., Architecture Overview, Setup Guide"
              className="w-full mt-1 rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-2 text-sm text-strong focus:outline-none focus:border-[color:var(--accent)]"
            />
          </div>

          <div>
            <label className="text-xs font-medium text-muted">
              Description (optional)
            </label>
            <input
              type="text"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Brief summary of the document"
              className="w-full mt-1 rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-2 text-sm text-strong focus:outline-none focus:border-[color:var(--accent)]"
            />
          </div>

          <div>
            <label className="text-xs font-medium text-muted">
              Content (Markdown)* 
            </label>
            <textarea
              value={content}
              onChange={(e) => setContent(e.target.value)}
              placeholder="Write content in Markdown format..."
              className="w-full mt-1 h-64 rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-2 text-sm text-strong font-mono focus:outline-none focus:border-[color:var(--accent)] resize-none"
            />
            <p className="text-xs text-quiet mt-1">
              Supports Markdown formatting (headers, code blocks, links, etc.)
            </p>
          </div>

          {error && (
            <div className="rounded-lg bg-red-500/10 border border-red-500/20 px-3 py-2 text-xs text-red-700">
              {error}
            </div>
          )}
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={isSaving}
          >
            Cancel
          </Button>
          <Button
            type="button"
            onClick={handleSave}
            disabled={isSaving}
            className="gap-2"
          >
            {isSaving && <Loader2 className="h-4 w-4 animate-spin" />}
            {isSaving ? "Saving..." : document ? "Update" : "Create"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
