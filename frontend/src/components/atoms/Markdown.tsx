"use client";

import {
  Children,
  cloneElement,
  isValidElement,
  memo,
  useState,
  useRef,
  useEffect,
  type HTMLAttributes,
  type ReactElement,
  type ReactNode,
} from "react";

import ReactMarkdown, { type Components } from "react-markdown";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";

import { cn } from "@/lib/utils";

type MarkdownCodeProps = HTMLAttributes<HTMLElement> & {
  node?: unknown;
  inline?: boolean;
};

const MENTION_PATTERN =
  /(^|[^A-Za-z0-9_])(@[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?)/g;

const renderMentionsInText = (text: string, keyPrefix: string): ReactNode => {
  let lastIndex = 0;
  let mentionCount = 0;
  const nodes: ReactNode[] = [];

  for (const match of text.matchAll(MENTION_PATTERN)) {
    const matchIndex = match.index ?? 0;
    const prefix = match[1] ?? "";
    const mention = match[2] ?? "";
    const mentionStart = matchIndex + prefix.length;

    if (matchIndex > lastIndex) {
      nodes.push(text.slice(lastIndex, matchIndex));
    }

    if (prefix) {
      nodes.push(prefix);
    }

    nodes.push(
      <span
        key={`${keyPrefix}-${mentionCount}`}
        className="font-semibold text-cyan-700"
      >
        {mention}
      </span>,
    );

    lastIndex = mentionStart + mention.length;
    mentionCount += 1;
  }

  if (nodes.length === 0) {
    return text;
  }

  if (lastIndex < text.length) {
    nodes.push(text.slice(lastIndex));
  }

  return nodes;
};

const renderMentions = (
  content: ReactNode,
  keyPrefix = "mention",
): ReactNode => {
  if (typeof content === "string") {
    return renderMentionsInText(content, keyPrefix);
  }
  if (
    content === null ||
    content === undefined ||
    typeof content === "boolean" ||
    typeof content === "number"
  ) {
    return content;
  }
  if (Array.isArray(content)) {
    return Children.map(content, (child, index) =>
      renderMentions(child, `${keyPrefix}-${index}`),
    );
  }
  if (isValidElement(content)) {
    if (typeof content.type === "string" && content.type === "code") {
      return content;
    }
    const childProps = content.props as { children?: ReactNode };
    if (childProps.children === undefined) {
      return content;
    }
    return cloneElement(
      content as ReactElement<{ children?: ReactNode }>,
      undefined,
      renderMentions(childProps.children, keyPrefix),
    );
  }
  return content;
};

const MARKDOWN_CODE_COMPONENTS: Components = {
  pre: ({ node: _node, className, ...props }) => (
    <pre
      className={cn(
        "my-3 overflow-x-auto rounded-lg bg-slate-800 p-3 text-xs leading-relaxed text-slate-100 dark:bg-slate-900 dark:text-slate-200",
        className,
      )}
      {...props}
    />
  ),
  code: (rawProps) => {
    // react-markdown passes `inline`, but the public `Components` typing doesn't
    // currently include it, so we pluck it safely here without leaking it to DOM.
    const {
      node: _node,
      inline,
      className,
      children,
      ...props
    } = rawProps as MarkdownCodeProps;
    const codeText = Array.isArray(children)
      ? children.join("")
      : String(children ?? "");
    const isInline =
      typeof inline === "boolean" ? inline : !codeText.includes("\n");

    if (isInline) {
      return (
        <code
          className={cn(
            "rounded bg-[color:var(--surface-strong)] px-1 py-0.5 font-mono text-[0.85em] text-strong",
            className,
          )}
          {...props}
        >
          {children}
        </code>
      );
    }

    // For fenced blocks, the parent <pre> handles the box styling.
    return (
      <code className={cn("font-mono", className)} {...props}>
        {children}
      </code>
    );
  },
};

const MARKDOWN_TABLE_COMPONENTS: Components = {
  table: ({ node: _node, className, ...props }) => (
    <div className="my-3 overflow-x-auto">
      <table className={cn("w-full border-collapse", className)} {...props} />
    </div>
  ),
  thead: ({ node: _node, className, ...props }) => (
    <thead className={cn("bg-[color:var(--surface-muted)]", className)} {...props} />
  ),
  tbody: ({ node: _node, className, ...props }) => (
    <tbody className={cn("divide-y divide-slate-100", className)} {...props} />
  ),
  tr: ({ node: _node, className, ...props }) => (
    <tr className={cn("align-top", className)} {...props} />
  ),
  th: ({ node: _node, className, children, ...props }) => (
    <th
      className={cn(
        "border border-[color:var(--border)] px-3 py-2 text-left text-xs font-semibold",
        className,
      )}
      {...props}
    >
      {renderMentions(children)}
    </th>
  ),
  td: ({ node: _node, className, children, ...props }) => (
    <td
      className={cn("border border-[color:var(--border)] px-3 py-2 align-top", className)}
      {...props}
    >
      {renderMentions(children)}
    </td>
  ),
};

const MARKDOWN_COMPONENTS_BASIC: Components = {
  ...MARKDOWN_TABLE_COMPONENTS,
  ...MARKDOWN_CODE_COMPONENTS,
  img: ({ node: _node, className, ...props }) => (
    <img
      className={cn("my-2 max-h-48 max-w-full rounded object-contain", className)}
      {...props}
    />
  ),
  a: ({ node: _node, className, children, ...props }) => (
    <a
      className={cn(
        "font-medium text-sky-700 underline decoration-sky-400 underline-offset-2 transition-colors hover:text-sky-800 hover:decoration-sky-600",
        className,
      )}
      target="_blank"
      rel="noopener noreferrer"
      {...props}
    >
      {renderMentions(children)}
    </a>
  ),
  p: ({ node: _node, className, children, ...props }) => (
    <p className={cn("mb-2 last:mb-0", className)} {...props}>
      {renderMentions(children)}
    </p>
  ),
  ul: ({ node: _node, className, ...props }) => (
    <ul className={cn("mb-2 list-disc pl-5", className)} {...props} />
  ),
  ol: ({ node: _node, className, ...props }) => (
    <ol className={cn("mb-2 list-decimal pl-5", className)} {...props} />
  ),
  li: ({ node: _node, className, children, ...props }) => (
    <li className={cn("mb-1", className)} {...props}>
      {renderMentions(children)}
    </li>
  ),
  strong: ({ node: _node, className, children, ...props }) => (
    <strong className={cn("font-semibold", className)} {...props}>
      {renderMentions(children)}
    </strong>
  ),
};

const MARKDOWN_COMPONENTS_DESCRIPTION: Components = {
  ...MARKDOWN_COMPONENTS_BASIC,
  p: ({ node: _node, className, children, ...props }) => (
    <p className={cn("mb-3 last:mb-0", className)} {...props}>
      {renderMentions(children)}
    </p>
  ),
  h1: ({ node: _node, className, children, ...props }) => (
    <h1 className={cn("mb-2 text-base font-semibold", className)} {...props}>
      {renderMentions(children)}
    </h1>
  ),
  h2: ({ node: _node, className, children, ...props }) => (
    <h2 className={cn("mb-2 text-sm font-semibold", className)} {...props}>
      {renderMentions(children)}
    </h2>
  ),
  h3: ({ node: _node, className, children, ...props }) => (
    <h3 className={cn("mb-2 text-sm font-semibold", className)} {...props}>
      {renderMentions(children)}
    </h3>
  ),
};

const MARKDOWN_REMARK_PLUGINS_BASIC = [remarkGfm];
const MARKDOWN_REMARK_PLUGINS_WITH_BREAKS = [remarkGfm, remarkBreaks];

export type MarkdownVariant = "basic" | "comment" | "description";

export const Markdown = memo(function Markdown({
  content,
  variant,
}: {
  content: string;
  variant: MarkdownVariant;
}) {
  const trimmed = content.trim();
  const remarkPlugins =
    variant === "comment"
      ? MARKDOWN_REMARK_PLUGINS_WITH_BREAKS
      : MARKDOWN_REMARK_PLUGINS_BASIC;
  const components =
    variant === "description"
      ? MARKDOWN_COMPONENTS_DESCRIPTION
      : MARKDOWN_COMPONENTS_BASIC;
  return (
    <ReactMarkdown remarkPlugins={remarkPlugins} components={components}>
      {trimmed}
    </ReactMarkdown>
  );
});

Markdown.displayName = "Markdown";

const COLLAPSE_LINE_HEIGHT = 24; // px per line
const COLLAPSE_MAX_LINES = 6;
const COLLAPSE_MAX_HEIGHT = COLLAPSE_LINE_HEIGHT * COLLAPSE_MAX_LINES;

export const CollapsibleMarkdown = memo(function CollapsibleMarkdown({
  content,
  variant = "description",
}: {
  content: string;
  variant?: MarkdownVariant;
}) {
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const innerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (innerRef.current) {
      setOverflows(innerRef.current.scrollHeight > COLLAPSE_MAX_HEIGHT + 4);
    }
  }, [content]);

  return (
    <div>
      <div
        className={cn(
          "relative overflow-hidden transition-all duration-200",
          !expanded && overflows && "max-h-[144px]",
        )}
      >
        <div ref={innerRef}>
          <Markdown content={content} variant={variant} />
        </div>
        {!expanded && overflows && (
          <div className="pointer-events-none absolute bottom-0 left-0 right-0 h-10 bg-gradient-to-t from-[color:var(--surface)] to-transparent" />
        )}
      </div>
      {overflows && (
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          className="mt-1 text-xs font-medium text-[color:var(--accent)] hover:underline"
        >
          {expanded ? "Show less" : "Show more"}
        </button>
      )}
    </div>
  );
});

CollapsibleMarkdown.displayName = "CollapsibleMarkdown";
