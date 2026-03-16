"use client";

import { useState, useEffect, useCallback } from "react";
import { Eye, EyeOff, Plus, Trash2, KeyRound, Loader2 } from "lucide-react";
import { customFetch } from "@/api/mutator";
import { cn } from "@/lib/utils";

interface Secret {
  id: string;
  key: string;
  description: string;
}

interface BoardSecretsPanelProps {
  boardId: string;
}

const API = (boardId: string) => `/api/v1/boards/${boardId}/secrets`;

export function BoardSecretsPanel({ boardId }: BoardSecretsPanelProps) {
  const [secrets, setSecrets] = useState<Secret[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Add form state
  const [newKey, setNewKey] = useState("");
  const [newValue, setNewValue] = useState("");
  const [newDesc, setNewDesc] = useState("");
  const [showValue, setShowValue] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const [deletingKey, setDeletingKey] = useState<string | null>(null);
  const [showAddForm, setShowAddForm] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await customFetch<{ data: Secret[] }>(API(boardId), { method: "GET" });
      setSecrets(res.data ?? []);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to load secrets");
    } finally {
      setLoading(false);
    }
  }, [boardId]);

  useEffect(() => { load(); }, [load]);

  const handleSave = async () => {
    const key = newKey.trim().toUpperCase();
    const value = newValue.trim();
    if (!key || !value) return;
    setSaving(true);
    setSaveError(null);
    try {
      await customFetch(`${API(boardId)}/${key}`, {
        method: "PUT",
        body: JSON.stringify({ key, value, description: newDesc.trim() }),
      });
      setNewKey("");
      setNewValue("");
      setNewDesc("");
      await load();
    } catch (e: unknown) {
      setSaveError(e instanceof Error ? e.message : "Failed to save secret");
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (key: string) => {
    setDeletingKey(key);
    try {
      await customFetch(`${API(boardId)}/${key}`, { method: "DELETE" });
      setSecrets((prev) => prev.filter((s) => s.key !== key));
    } catch {
      // no-op, could show a toast
    } finally {
      setDeletingKey(null);
    }
  };

  return (
    <div className="space-y-4">
      {/* Existing secrets */}
      {loading ? (
        <p className="flex items-center gap-2 text-sm text-quiet">
          <Loader2 className="h-3.5 w-3.5 animate-spin" /> Loading secrets…
        </p>
      ) : error ? (
        <p className="text-sm text-danger">{error}</p>
      ) : secrets.length === 0 ? (
        <p className="text-sm text-quiet">No secrets yet. Add one below.</p>
      ) : (
        <div className="divide-y divide-[color:var(--border)] rounded-lg border border-[color:var(--border)]">
          {secrets.map((s) => (
            <div key={s.id} className="flex items-center gap-3 px-3 py-2.5">
              <KeyRound className="h-3.5 w-3.5 shrink-0 text-quiet" />
              <div className="min-w-0 flex-1">
                <p className="font-mono text-xs font-semibold text-strong">{s.key}</p>
                {s.description && (
                  <p className="text-xs text-quiet">{s.description}</p>
                )}
              </div>
              <span className="font-mono text-xs text-quiet">••••••••</span>
              <button
                type="button"
                onClick={() => handleDelete(s.key)}
                disabled={deletingKey === s.key}
                className="ml-1 rounded p-1 text-quiet transition hover:text-danger"
                aria-label={`Delete ${s.key}`}
              >
                {deletingKey === s.key ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : (
                  <Trash2 className="h-3.5 w-3.5" />
                )}
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Add new secret */}
      <div className="rounded-lg border border-[color:var(--border)] p-3 space-y-2">
        <button
          type="button"
          onClick={() => setShowAddForm((v) => !v)}
          className="flex w-full items-center justify-between text-xs font-semibold uppercase tracking-wider text-quiet hover:text-strong transition"
        >
          <span>Add / Update Secret</span>
          <span className="text-[10px]">{showAddForm ? "▲" : "▼"}</span>
        </button>
        {!showAddForm && <p className="text-xs text-quiet">Click to expand and add or update a secret.</p>}
        {showAddForm && (
          <>
            <div className="flex gap-2">
              <input
                type="text"
                placeholder="KEY_NAME"
                value={newKey}
                onChange={(e) => setNewKey(e.target.value.toUpperCase())}
                className="font-mono w-40 shrink-0 rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-2 py-1.5 text-xs text-strong focus:outline-none focus:border-[color:var(--accent)]"
              />
              <input
                type="text"
                placeholder="Description (optional)"
                value={newDesc}
                onChange={(e) => setNewDesc(e.target.value)}
                className="min-w-0 flex-1 rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-2 py-1.5 text-xs text-strong focus:outline-none focus:border-[color:var(--accent)]"
              />
            </div>
            <div className="flex flex-col gap-2">
              <div className="relative flex-1">
                {showValue ? (
                  <textarea
                    placeholder="Secret value (paste multi-line keys here)"
                    value={newValue}
                    onChange={(e) => setNewValue(e.target.value)}
                    className="w-full h-32 rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-2 py-1.5 pr-8 text-xs text-strong font-mono focus:outline-none focus:border-[color:var(--accent)] resize-none"
                  />
                ) : (
                  <input
                    type="password"
                    placeholder="Secret value (paste multi-line keys here)"
                    value={newValue}
                    onChange={(e) => setNewValue(e.target.value)}
                    className="w-full rounded border border-[color:var(--border)] bg-[color:var(--surface)] px-2 py-1.5 pr-8 text-xs text-strong focus:outline-none focus:border-[color:var(--accent)]"
                  />
                )}
                <button
                  type="button"
                  onClick={() => setShowValue((v) => !v)}
                  className="absolute right-2 top-2 text-quiet hover:text-muted"
                >
                  {showValue ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}
                </button>
              </div>
              <button
                type="button"
                onClick={handleSave}
                disabled={saving || !newKey.trim() || !newValue.trim()}
                className={cn(
                  "flex items-center gap-1.5 rounded px-3 py-1.5 text-xs font-medium transition self-start",
                  "bg-[color:var(--accent)] text-white hover:bg-[color:var(--accent-strong)]",
                  "disabled:opacity-50 disabled:cursor-not-allowed",
                )}
              >
                {saving ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Plus className="h-3.5 w-3.5" />}
                {saving ? "Saving…" : "Save"}
              </button>
            </div>
            {saveError && <p className="text-xs text-danger">{saveError}</p>}
            <p className="text-xs text-quiet">
              Secrets are encrypted and injected into agent workspaces at provisioning time. Agents never expose them in output.
            </p>
          </>
        )}
      </div>
    </div>
  );
}
