import { createElement, type HTMLAttributes, type ReactNode } from "react";
import ReactMarkdown, {
  defaultUrlTransform,
  type Components,
} from "react-markdown";
import remarkGfm from "remark-gfm";
type HeadingInfo = { text: string; level: number; offset?: number };
// Read the parsed heading, including inline code and image alt text.
function nodeText(node: {
  value?: unknown;
  properties?: { alt?: unknown };
  children?: unknown[];
}): string {
  if (typeof node.value === "string") return node.value;
  if (typeof node.properties?.alt === "string") return node.properties.alt;
  return (node.children || [])
    .map((child) => nodeText(child as typeof node))
    .join("");
}
export default function MarkdownPreview({
  text,
  onLink,
  maxCharacters = 120_000,
  renderImage,
  headingProps,
  allowFileLinks = false,
}: {
  text: string;
  onLink: (href: string) => void;
  /** null removes the shelf's character cap; native bounds reader input to 2 MiB. */
  maxCharacters?: number | null;
  renderImage?: (image: {
    source: string;
    alt: string;
    title?: string;
  }) => ReactNode;
  headingProps?: (heading: HeadingInfo) => HTMLAttributes<HTMLHeadingElement>;
  allowFileLinks?: boolean;
}) {
  const headings: Components = {};
  if (headingProps) {
    for (const level of [1, 2, 3, 4, 5, 6]) {
      const tag = `h${level}` as "h1";
      headings[tag] = ({ node, children }) =>
        createElement(
          tag,
          headingProps({
            text: node ? nodeText(node) : "",
            level,
            offset: node?.position?.start.offset,
          }),
          children,
        );
    }
  }
  return (
    <div className="markdown">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        urlTransform={(url, key, node) =>
          renderImage && node.tagName === "img" && key === "src"
            ? url // Only the supplied renderer sees this source; never an HTML img src.
            : allowFileLinks && key === "href" && /^file:/i.test(url)
              ? url
              : defaultUrlTransform(url)
        }
        components={{
          ...headings,
          a: ({ href, children }) => (
            <a
              href={href}
              onClick={(event) => {
                event.preventDefault();
                if (href) onLink(href);
              }}
            >
              {children}
            </a>
          ),
          img: ({ src, alt, title }) =>
            renderImage ? (
              renderImage({
                source: typeof src === "string" ? src : "",
                alt: alt || "",
                title,
              })
            ) : (
              <span className="muted">[Image: {alt || "embedded image"}]</span>
            ),
        }}
      >
        {maxCharacters === null ? text : text.slice(0, maxCharacters)}
      </ReactMarkdown>
    </div>
  );
}
