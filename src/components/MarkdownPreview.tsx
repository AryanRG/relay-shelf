import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
export default function MarkdownPreview({
  text,
  onLink,
}: {
  text: string;
  onLink: (href: string) => void;
}) {
  return (
    <div className="markdown">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
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
          img: ({ alt }) => (
            <span className="muted">[Image: {alt || "embedded image"}]</span>
          ),
        }}
      >
        {text.slice(0, 120_000)}
      </ReactMarkdown>
    </div>
  );
}
