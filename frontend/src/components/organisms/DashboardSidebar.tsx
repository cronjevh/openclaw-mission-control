"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  Activity,
  BarChart3,
  Bot,
  Boxes,
  CheckCircle2,
  Folder,
  Building2,
  LayoutGrid,
  Network,
  Settings,
  Store,
  Tags,
} from "lucide-react";

import { useAuth } from "@/auth/clerk";
import { ApiError } from "@/api/mutator";
import { GlobalSearch } from "@/components/ui/GlobalSearch";
import { useOrganizationMembership } from "@/lib/use-organization-membership";
import {
  type healthzHealthzGetResponse,
  useHealthzHealthzGet,
} from "@/api/generated/default/default";
import { cn } from "@/lib/utils";

export function DashboardSidebar() {
  const pathname = usePathname();
  const { isSignedIn } = useAuth();
  const { isAdmin } = useOrganizationMembership(isSignedIn);
  const healthQuery = useHealthzHealthzGet<healthzHealthzGetResponse, ApiError>(
    {
      query: {
        refetchInterval: 30_000,
        refetchOnMount: "always",
        retry: false,
      },
      request: { cache: "no-store" },
    },
  );

  const okValue = healthQuery.data?.data?.ok;
  const systemStatus: "unknown" | "operational" | "degraded" =
    okValue === true
      ? "operational"
      : okValue === false
        ? "degraded"
        : healthQuery.isError
          ? "degraded"
          : "unknown";
  const statusLabel =
    systemStatus === "operational"
      ? "All systems operational"
      : systemStatus === "unknown"
        ? "System status unavailable"
        : "System degraded";

  return (
    <aside className="flex h-full min-h-0 w-[260px] flex-col border-r border-[color:var(--border)] bg-[color:var(--surface)]">
      <div className="flex-1 min-h-0 overflow-y-auto px-3 py-4">
        <nav className="space-y-4 text-sm">
          <div className="mb-2">
            <GlobalSearch />
          </div>
          <div>
            <p className="px-3 text-[11px] font-semibold uppercase tracking-wider text-quiet">
              Overview
            </p>
            <div className="mt-1 space-y-1">
              <Link
                href="/dashboard"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname === "/dashboard"
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <BarChart3 className="h-4 w-4" />
                Dashboard
              </Link>
              <Link
                href="/activity"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname.startsWith("/activity")
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <Activity className="h-4 w-4" />
                Live feed
              </Link>
            </div>
          </div>

          <div>
            <p className="px-3 text-[11px] font-semibold uppercase tracking-wider text-quiet">
              Boards
            </p>
            <div className="mt-1 space-y-1">
              <Link
                href="/board-groups"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname.startsWith("/board-groups")
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <Folder className="h-4 w-4" />
                Board groups
              </Link>
              <Link
                href="/boards"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname.startsWith("/boards")
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <LayoutGrid className="h-4 w-4" />
                Boards
              </Link>
              <Link
                href="/tags"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname.startsWith("/tags")
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <Tags className="h-4 w-4" />
                Tags
              </Link>
              <Link
                href="/approvals"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname.startsWith("/approvals")
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <CheckCircle2 className="h-4 w-4" />
                Approvals
              </Link>
              {isAdmin ? (
                <Link
                  href="/custom-fields"
                  className={cn(
                    "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                    pathname.startsWith("/custom-fields")
                      ? "bg-[color:var(--info-soft)] text-info font-medium"
                      : "hover:bg-[color:var(--surface-strong)]",
                  )}
                >
                  <Settings className="h-4 w-4" />
                  Custom fields
                </Link>
              ) : null}
            </div>
          </div>

          <div>
            {isAdmin ? (
              <>
                <p className="px-3 text-[11px] font-semibold uppercase tracking-wider text-quiet">
                  Skills
                </p>
                <div className="mt-1 space-y-1">
                  <Link
                    href="/skills/marketplace"
                    className={cn(
                      "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                      pathname === "/skills" ||
                        pathname.startsWith("/skills/marketplace")
                        ? "bg-[color:var(--info-soft)] text-info font-medium"
                        : "hover:bg-[color:var(--surface-strong)]",
                    )}
                  >
                    <Store className="h-4 w-4" />
                    Marketplace
                  </Link>
                  <Link
                    href="/skills/packs"
                    className={cn(
                      "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                      pathname.startsWith("/skills/packs")
                        ? "bg-[color:var(--info-soft)] text-info font-medium"
                        : "hover:bg-[color:var(--surface-strong)]",
                    )}
                  >
                    <Boxes className="h-4 w-4" />
                    Packs
                  </Link>
                </div>
              </>
            ) : null}
          </div>

          <div>
            <p className="px-3 text-[11px] font-semibold uppercase tracking-wider text-quiet">
              Administration
            </p>
            <div className="mt-1 space-y-1">
              <Link
                href="/organization"
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                  pathname.startsWith("/organization")
                    ? "bg-[color:var(--info-soft)] text-info font-medium"
                    : "hover:bg-[color:var(--surface-strong)]",
                )}
              >
                <Building2 className="h-4 w-4" />
                Organization
              </Link>
              {isAdmin ? (
                <Link
                  href="/gateways"
                  className={cn(
                    "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                    pathname.startsWith("/gateways")
                      ? "bg-[color:var(--info-soft)] text-info font-medium"
                      : "hover:bg-[color:var(--surface-strong)]",
                  )}
                >
                  <Network className="h-4 w-4" />
                  Gateways
                </Link>
              ) : null}
              {isAdmin ? (
                <Link
                  href="/agents"
                  className={cn(
                    "flex items-center gap-3 rounded-lg px-3 py-2.5 text-muted transition",
                    pathname.startsWith("/agents")
                      ? "bg-[color:var(--info-soft)] text-info font-medium"
                      : "hover:bg-[color:var(--surface-strong)]",
                  )}
                >
                  <Bot className="h-4 w-4" />
                  Agents
                </Link>
              ) : null}
            </div>
          </div>
        </nav>
      </div>
      <div className="border-t border-[color:var(--border)] p-4">
        <div className="flex items-center gap-2 text-xs text-quiet">
          <span
            className={cn(
              "h-2 w-2 rounded-full",
              systemStatus === "operational" && "bg-[color:var(--success)]",
              systemStatus === "degraded" && "bg-[color:var(--danger)]",
              systemStatus === "unknown" && "bg-[color:var(--surface-strong)]",
            )}
          />
          {statusLabel}
        </div>
      </div>
    </aside>
  );
}
