import {
  File,
  Folder,
  FileText,
  FileCode2,
  Image,
  Link2,
  Table2,
  Archive,
  FileJson,
  Music2,
  Film,
  Command,
  type LucideIcon,
} from "lucide-react";
import type { ShelfItem } from "@/shared";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import type { ComponentProps, ReactNode } from "react";
import { cn } from "@/lib/utils";
export function ItemIcon({
  kind,
  extension = "",
  className,
}: {
  kind: ShelfItem["kind"];
  extension?: string;
  className?: string;
}) {
  const ext = extension.replace(/^\./, "").toLowerCase();
  let Icon: LucideIcon = File;
  let color = "neutral";
  if (kind === "folder") {
    Icon = Folder;
    color = "blue";
  } else if (kind === "url") {
    Icon = Link2;
    color = "blue";
  } else if (kind === "text" || /^(md|txt|rtf|docx?|pdf)$/.test(ext)) {
    Icon = FileText;
    color = ext === "pdf" ? "rose" : "violet";
  } else if (/^(png|jpe?g|gif|webp|svg|heic|avif)$/.test(ext)) {
    Icon = Image;
    color = "green";
  } else if (/^(csv|xlsx?|tsv)$/.test(ext)) {
    Icon = Table2;
    color = "green";
  } else if (/^(json|jsonl)$/.test(ext)) {
    Icon = FileJson;
    color = "amber";
  } else if (/^(zip|tar|gz|dmg)$/.test(ext)) {
    Icon = Archive;
    color = "amber";
  } else if (/^(mp3|wav|m4a|aac)$/.test(ext)) {
    Icon = Music2;
    color = "rose";
  } else if (/^(mp4|mov|webm)$/.test(ext)) {
    Icon = Film;
    color = "violet";
  } else if (/^(tsx?|jsx?|py|swift|html|css|sh|rs|go|yaml|yml)$/.test(ext)) {
    Icon = FileCode2;
    color = "amber";
  }
  return (
    <span className={cn("file-icon", `file-icon-${color}`, className)}>
      <Icon size={19} strokeWidth={1.65} />
    </span>
  );
}
export function IconButton({
  label,
  children,
  className,
  ...props
}: ComponentProps<typeof Button> & { label: string; children: ReactNode }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label={label}
          className={cn("icon-button", className)}
          {...props}
        >
          {children}
        </Button>
      </TooltipTrigger>
      <TooltipContent side="bottom">{label}</TooltipContent>
    </Tooltip>
  );
}
export function Shortcut({ children }: { children: ReactNode }) {
  return <kbd>{children}</kbd>;
}
export function Brand({ small = false }: { small?: boolean }) {
  return (
    <span
      className={cn("brand-mark", small && "brand-small")}
      aria-hidden="true"
    >
      <span />
      <span />
      <span />
    </span>
  );
}
export function EmptyState({
  icon: Icon = Command,
  title,
  description,
  children,
}: {
  icon?: LucideIcon;
  title: string;
  description: string;
  children?: ReactNode;
}) {
  return (
    <div className="empty-state">
      <div className="empty-icon">
        <Icon size={25} strokeWidth={1.4} />
      </div>
      <h3>{title}</h3>
      <p>{description}</p>
      {children && <div className="empty-actions">{children}</div>}
    </div>
  );
}
