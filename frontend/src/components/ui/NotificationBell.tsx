"use client";

import { useEffect, useRef, useState } from "react";
import { Bell, CheckCheck, MessageSquare, GitPullRequestArrow, AtSign } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  useNotifications,
  type AppNotification,
} from "@/hooks/useNotifications";
import { useRouter } from "next/navigation";

function NotifIcon({ type }: { type: AppNotification["type"] }) {
  if (type === "comment_added")
    return <MessageSquare className="h-3.5 w-3.5 text-blue-500" />;
  if (type === "mention")
    return <AtSign className="h-3.5 w-3.5 text-purple-500" />;
  return <GitPullRequestArrow className="h-3.5 w-3.5 text-emerald-500" />;
}

function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

export function NotificationBell() {
  const { notifications, unreadCount, markAllRead, markOneRead, requestPermission } =
    useNotifications();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const router = useRouter();

  // Request browser notification permission on first unread
  useEffect(() => {
    if (unreadCount > 0) requestPermission();
  }, [unreadCount, requestPermission]);

  // Close on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  const handleNotifClick = async (n: AppNotification) => {
    if (!n.read) await markOneRead(n.id);
    if (n.board_id && n.task_id) {
      router.push(`/boards/${n.board_id}?task=${n.task_id}`);
    } else if (n.board_id) {
      router.push(`/boards/${n.board_id}`);
    }
    setOpen(false);
  };

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className={cn(
          "relative flex h-9 w-9 items-center justify-center rounded-lg border transition",
          "border-slate-200 text-slate-500 hover:border-slate-300 hover:bg-slate-50 hover:text-slate-700",
          "dark:border-slate-700 dark:text-slate-400 dark:hover:border-slate-600 dark:hover:bg-slate-800 dark:hover:text-slate-200",
          open && "border-slate-300 bg-slate-50 dark:border-slate-600 dark:bg-slate-800",
        )}
        aria-label="Notifications"
      >
        <Bell className="h-4 w-4" />
        {unreadCount > 0 && (
          <span className="absolute -right-1 -top-1 flex h-4 w-4 items-center justify-center rounded-full bg-red-500 text-[10px] font-bold text-white">
            {unreadCount > 9 ? "9+" : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div
          className={cn(
            "absolute right-0 top-11 z-50 w-80 overflow-hidden rounded-xl border shadow-lg",
            "border-slate-200 bg-white",
            "dark:border-slate-700 dark:bg-slate-900",
          )}
        >
          {/* Header */}
          <div className="flex items-center justify-between border-b border-slate-100 px-4 py-3 dark:border-slate-800">
            <span className="text-sm font-semibold text-slate-900 dark:text-slate-100">
              Notifications
            </span>
            {unreadCount > 0 && (
              <button
                type="button"
                onClick={markAllRead}
                className="flex items-center gap-1 text-xs text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
              >
                <CheckCheck className="h-3.5 w-3.5" />
                Mark all read
              </button>
            )}
          </div>

          {/* List */}
          <div className="max-h-96 overflow-y-auto">
            {notifications.length === 0 ? (
              <div className="py-8 text-center text-sm text-slate-400 dark:text-slate-500">
                No notifications yet
              </div>
            ) : (
              notifications.map((n) => (
                <button
                  key={n.id}
                  type="button"
                  onClick={() => handleNotifClick(n)}
                  className={cn(
                    "flex w-full items-start gap-3 border-b px-4 py-3 text-left transition last:border-b-0",
                    "border-slate-50 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-800",
                    !n.read && "bg-blue-50/60 dark:bg-blue-950/20",
                  )}
                >
                  <div className="mt-0.5 flex h-6 w-6 flex-shrink-0 items-center justify-center rounded-full bg-slate-100 dark:bg-slate-800">
                    <NotifIcon type={n.type} />
                  </div>
                  <div className="min-w-0 flex-1">
                    <p
                      className={cn(
                        "truncate text-sm",
                        n.read
                          ? "font-normal text-slate-600 dark:text-slate-400"
                          : "font-medium text-slate-900 dark:text-slate-100",
                      )}
                    >
                      {n.title}
                    </p>
                    <p className="mt-0.5 line-clamp-2 text-xs text-slate-400 dark:text-slate-500">
                      {n.body}
                    </p>
                    <p className="mt-1 text-[10px] text-slate-400 dark:text-slate-600">
                      {timeAgo(n.created_at)}
                    </p>
                  </div>
                  {!n.read && (
                    <div className="mt-1.5 h-2 w-2 flex-shrink-0 rounded-full bg-blue-500" />
                  )}
                </button>
              ))
            )}
          </div>
        </div>
      )}
    </div>
  );
}
