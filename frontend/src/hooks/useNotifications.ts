"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { getLocalAuthToken, isLocalAuthMode } from "@/auth/localAuth";

export interface AppNotification {
  id: string;
  type: "status_changed" | "comment_added" | "mention";
  title: string;
  body: string;
  read: boolean;
  board_id: string | null;
  task_id: string | null;
  created_at: string;
}

const API = (process.env.NEXT_PUBLIC_API_URL ?? "").replace(/\/+$/, "");

type ClerkGlobal = { session?: { getToken: () => Promise<string> } | null };

async function getAuthHeader(): Promise<HeadersInit> {
  if (isLocalAuthMode()) {
    const t = getLocalAuthToken();
    return t ? { Authorization: `Bearer ${t}` } : {};
  }
  try {
    const clerk = (window as unknown as { Clerk?: ClerkGlobal }).Clerk;
    const token = await clerk?.session?.getToken();
    return token ? { Authorization: `Bearer ${token}` } : {};
  } catch {
    return {};
  }
}

export function useNotifications() {
  const [notifications, setNotifications] = useState<AppNotification[]>([]);
  const [loading, setLoading] = useState(true);
  const sinceRef = useRef<string>(new Date().toISOString());
  const abortRef = useRef<AbortController | null>(null);

  // Initial fetch
  const fetchAll = useCallback(async () => {
    try {
      const h = await getAuthHeader();
      const res = await fetch(`${API}/api/v1/notifications?limit=40`, {
        headers: h,
      });
      if (!res.ok) return;
      const data: AppNotification[] = await res.json();
      setNotifications(data);
      if (data.length > 0) {
        sinceRef.current = data[0].created_at;
      }
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchAll();
  }, [fetchAll]);

  // SSE stream via fetch (supports custom auth headers)
  useEffect(() => {
    let cancelled = false;

    const connect = async () => {
      const ctrl = new AbortController();
      abortRef.current = ctrl;
      try {
        const h = await getAuthHeader();
        const url = `${API}/api/v1/notifications/stream?since=${encodeURIComponent(sinceRef.current)}`;
        const res = await fetch(url, {
          headers: { ...h, Accept: "text/event-stream" },
          signal: ctrl.signal,
        });
        if (!res.ok || !res.body) return;

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (!cancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const parts = buffer.split("\n\n");
          buffer = parts.pop() ?? "";
          for (const chunk of parts) {
            let eventType = "message";
            let data = "";
            for (const line of chunk.split("\n")) {
              if (line.startsWith("event:")) eventType = line.slice(6).trim();
              if (line.startsWith("data:")) data = line.slice(5).trim();
            }
            if (eventType === "notification" && data) {
              try {
                const notif: AppNotification = JSON.parse(data);
                sinceRef.current = notif.created_at;
                setNotifications((prev) => {
                  if (prev.some((n) => n.id === notif.id)) return prev;
                  return [notif, ...prev];
                });
                // Browser push notification
                if (
                  typeof window !== "undefined" &&
                  "Notification" in window &&
                  window.Notification.permission === "granted"
                ) {
                  new window.Notification(notif.title, {
                    body: notif.body,
                    icon: "/favicon.ico",
                    tag: notif.id,
                  });
                }
              } catch {
                // ignore parse errors
              }
            }
          }
        }
      } catch {
        // fetch error / aborted
      }
      // Reconnect after 5s if not cancelled
      if (!cancelled) {
        setTimeout(connect, 5000);
      }
    };

    connect();
    return () => {
      cancelled = true;
      abortRef.current?.abort();
    };
  }, []);

  const markAllRead = useCallback(async () => {
    const h = await getAuthHeader();
    await fetch(`${API}/api/v1/notifications/read-all`, {
      method: "PATCH",
      headers: h,
    });
    setNotifications((prev) => prev.map((n) => ({ ...n, read: true })));
  }, []);

  const markOneRead = useCallback(async (id: string) => {
    const h = await getAuthHeader();
    await fetch(`${API}/api/v1/notifications/${id}/read`, {
      method: "PATCH",
      headers: h,
    });
    setNotifications((prev) =>
      prev.map((n) => (n.id === id ? { ...n, read: true } : n))
    );
  }, []);

  const requestPermission = useCallback(async () => {
    if (typeof window === "undefined" || !("Notification" in window)) return;
    if (window.Notification.permission === "default") {
      await window.Notification.requestPermission();
    }
  }, []);

  const unreadCount = notifications.filter((n) => !n.read).length;

  return {
    notifications,
    unreadCount,
    loading,
    markAllRead,
    markOneRead,
    requestPermission,
  };
}
