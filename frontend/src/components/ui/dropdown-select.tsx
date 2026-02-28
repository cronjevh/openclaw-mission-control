"use client";

import * as React from "react";
import { Check, ChevronDown } from "lucide-react";

import { cn } from "@/lib/utils";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import {
  Command,
  CommandEmpty,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";

export type DropdownSelectOption = {
  value: string;
  label: string;
  disabled?: boolean;
  icon?: React.ElementType<{ className?: string }>;
  iconClassName?: string;
};

type DropdownSelectProps = {
  value?: string;
  onValueChange: (value: string) => void;
  options: DropdownSelectOption[];
  placeholder?: string;
  ariaLabel: string;
  disabled?: boolean;
  triggerClassName?: string;
  contentClassName?: string;
  itemClassName?: string;
  searchEnabled?: boolean;
  searchPlaceholder?: string;
  emptyMessage?: string;
};

const resolvePlaceholder = (ariaLabel: string, placeholder?: string) => {
  if (placeholder) return placeholder;
  const trimmed = ariaLabel.trim();
  if (!trimmed) return "Select an option";
  return trimmed.endsWith("...") ? trimmed : `${trimmed}...`;
};

const resolveSearchPlaceholder = (
  ariaLabel: string,
  searchPlaceholder?: string,
) => {
  if (searchPlaceholder) return searchPlaceholder;
  const cleaned = ariaLabel.replace(/^select\s+/i, "").trim();
  if (!cleaned) return "Search...";
  const value = `Search ${cleaned}`;
  return value.endsWith("...") ? value : `${value}...`;
};

export default function DropdownSelect({
  value,
  onValueChange,
  options,
  placeholder,
  ariaLabel,
  disabled = false,
  triggerClassName,
  contentClassName,
  itemClassName,
  searchEnabled = true,
  searchPlaceholder,
  emptyMessage,
}: DropdownSelectProps) {
  const [open, setOpen] = React.useState(false);
  const [searchValue, setSearchValue] = React.useState("");
  const listRef = React.useRef<HTMLDivElement | null>(null);
  const selectedOption = options.find((option) => option.value === value);
  const resolvedPlaceholder = resolvePlaceholder(ariaLabel, placeholder);
  const triggerLabel = selectedOption?.label ?? value ?? "";
  const SelectedIcon = selectedOption?.icon;
  const selectedIconClassName = selectedOption?.iconClassName;
  const showPlaceholder = !triggerLabel;
  const resolvedSearchPlaceholder = searchEnabled
    ? resolveSearchPlaceholder(ariaLabel, searchPlaceholder)
    : "";

  const handleOpenChange = (nextOpen: boolean) => {
    setOpen(nextOpen);
    if (!nextOpen) setSearchValue("");
  };

  const handleSelect = (nextValue: string) => {
    if (nextValue !== value) onValueChange(nextValue);
    handleOpenChange(false);
  };

  React.useEffect(() => {
    if (!open) return;
    if (listRef.current) listRef.current.scrollTop = 0;
  }, [open, searchValue]);

  return (
    <Popover open={open} onOpenChange={handleOpenChange}>
      <PopoverTrigger asChild>
        <button
          type="button"
          aria-label={ariaLabel}
          aria-expanded={open}
          aria-haspopup="listbox"
          disabled={disabled}
          className={cn(
            "inline-flex h-10 w-auto cursor-pointer items-center justify-between gap-2 rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] px-3 py-2 text-sm font-medium text-[color:var(--text)] shadow-sm transition-colors hover:bg-[color:var(--surface-strong)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)] disabled:cursor-not-allowed disabled:opacity-50",
            open && "bg-[color:var(--surface-strong)]",
            triggerClassName,
          )}
        >
          <span
            className={cn(
              "flex min-w-0 items-center gap-2 truncate",
              showPlaceholder && "text-[color:var(--text-quiet)]",
            )}
          >
            {SelectedIcon ? (
              <SelectedIcon
                className={cn("h-4 w-4 text-[color:var(--text-muted)]", selectedIconClassName)}
              />
            ) : null}
            <span className="truncate">
              {showPlaceholder ? resolvedPlaceholder : triggerLabel}
            </span>
          </span>
          <ChevronDown
            className={cn(
              "h-4 w-4 shrink-0 text-[color:var(--text-quiet)] transition-transform",
              open && "rotate-180",
            )}
          />
        </button>
      </PopoverTrigger>
      <PopoverContent
        align="start"
        sideOffset={6}
        className={cn(
          "w-[var(--radix-popover-trigger-width)] min-w-[12rem] overflow-hidden rounded-xl border border-[color:var(--border)] bg-[color:var(--surface)] p-0 shadow-[var(--shadow-float)]",
          contentClassName,
        )}
      >
        <Command label={ariaLabel} className="w-full bg-transparent">
          {searchEnabled ? (
            <CommandInput
              value={searchValue}
              onValueChange={setSearchValue}
              placeholder={resolvedSearchPlaceholder}
              autoFocus
              className="text-sm"
            />
          ) : null}
          <CommandList ref={listRef} className="max-h-64 p-1">
            <CommandEmpty className="px-3 py-6 text-center text-sm text-[color:var(--text-muted)]">
              {emptyMessage ?? "No results found."}
            </CommandEmpty>
            {options.map((option) => {
              const isSelected = value === option.value;
              const OptionIcon = option.icon;
              return (
                <CommandItem
                  key={option.value}
                  value={option.value}
                  keywords={[option.label, option.value]}
                  disabled={option.disabled}
                  onSelect={handleSelect}
                  className={cn(
                    "flex cursor-pointer items-center justify-between gap-2 rounded-lg px-3 py-2.5 text-sm text-[color:var(--text)] transition-colors data-[selected=true]:bg-[color:var(--surface-strong)]",
                    isSelected ? "font-semibold" : "font-medium",
                    itemClassName,
                  )}
                >
                  <span className="flex min-w-0 items-center gap-2">
                    {OptionIcon ? (
                      <OptionIcon
                        className={cn(
                          "h-4 w-4 text-[color:var(--text-muted)]",
                          option.iconClassName,
                        )}
                      />
                    ) : null}
                    <span className="truncate">{option.label}</span>
                  </span>
                  {isSelected ? (
                    <Check className="h-4 w-4 text-[color:var(--accent)]" />
                  ) : null}
                </CommandItem>
              );
            })}
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
