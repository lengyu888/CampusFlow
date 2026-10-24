(function (global) {
  "use strict";

  const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);

  function safeHref(href) {
    if (/[\u0000-\u0020\u007f]/.test(href)) return null;
    try {
      const url = new URL(href);
      if (["http:", "https:", "mailto:"].includes(url.protocol)) return url.href;
    } catch (_) {
      // Relative links have no useful destination inside a chat message.
    }
    return null;
  }

  function splitTableRow(line) {
    const source = line.trim();
    const cells = [];
    let content = "";
    let position = 0;
    let lastPipe = -1;
    while (position < source.length) {
      const character = source[position];
      if (character === "\\" && position + 1 < source.length) {
        content += source.slice(position, position + 2);
        position += 2;
        continue;
      }
      if (character === "`") {
        let length = 1;
        while (source[position + length] === "`") length += 1;
        let end = position + length;
        let closing = -1;
        while ((end = source.indexOf("`", end)) >= 0) {
          let count = 1;
          while (source[end + count] === "`") count += 1;
          if (count === length) { closing = end + count; break; }
          end += count;
        }
        if (closing >= 0) {
          content += source.slice(position, closing);
          position = closing;
          continue;
        }
        content += source.slice(position, position + length);
        position += length;
        continue;
      }
      if (character === "|") {
        cells.push(content.trim());
        content = "";
        lastPipe = position;
      } else {
        content += character;
      }
      position += 1;
    }
    cells.push(content.trim());
    if (source.startsWith("|")) cells.shift();
    if (lastPipe === source.length - 1) cells.pop();
    return cells;
  }

  // Keep model HTML as visible text. Images never request a remote resource.
  const parser = global.marked ? new global.marked.Marked({
    gfm: true,
    breaks: true,
    renderer: {
      html({ text }) { return escapeHtml(text); },
      image({ text }) { return escapeHtml(text || "图片"); },
      checkbox({ checked }) { return checked ? "☑ " : "☐ "; },
      table(token) {
        const lines = token.raw.split(/\r?\n/);
        const header = splitTableRow(lines[0]);
        const rows = lines.slice(2).filter((line) => line.trim()).map(splitTableRow);
        // Marked truncates body rows to the header width; inspect raw source first.
        if (header.length !== token.header.length || rows.some((row) => row.length > header.length)) {
          return `<pre><code>${escapeHtml(token.raw)}</code></pre>`;
        }
        const unescapePipe = (text) => text.replace(/\\\|/g, "|");
        const needsRepair = rows.some((row, index) => row.some((cell, column) =>
          unescapePipe(cell) !== token.rows[index]?.[column]?.text));
        if (!needsRepair) return false;

        // Unescaped pipes inside matched code spans are literal content in chat.
        // Rebuild those cells from raw source instead of accepting truncated tokens.
        const alignment = (column) => ["left", "center", "right"].includes(token.align[column])
          ? ` align="${token.align[column]}"` : "";
        const cell = (text, column) =>
          `<td${alignment(column)}>${parser.parseInline(unescapePipe(text))}</td>`;
        const headings = token.header.map((item, column) =>
          `<th${alignment(column)}>${this.parser.parseInline(item.tokens)}</th>`).join("");
        const body = rows.map((row) => `<tr>${header.map((_, index) =>
          cell(row[index] || "", index)).join("")}</tr>`).join("");
        return `<table><thead><tr>${headings}</tr></thead><tbody>${body}</tbody></table>`;
      },
      link({ href, title, tokens }) {
        const label = this.parser.parseInline(tokens);
        const safe = safeHref(href);
        if (!safe) return label;
        const tooltip = title ? ` title="${escapeHtml(title)}"` : "";
        return `<a href="${escapeHtml(safe)}"${tooltip}>${label}</a>`;
      },
    },
  }) : null;

  const sanitizeOptions = {
    ALLOWED_TAGS: ["p", "br", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "em", "del",
      "ul", "ol", "li", "blockquote", "hr", "pre", "code", "a", "table", "thead", "tbody", "tr", "th", "td"],
    ALLOWED_ATTR: ["href", "title", "start", "align"],
    ALLOW_DATA_ATTR: false,
    ALLOW_ARIA_ATTR: false,
    RETURN_DOM_FRAGMENT: true,
  };

  function render(target, source) {
    const text = typeof source === "string" ? source : String(source ?? "");
    try {
      if (!parser || !global.DOMPurify?.isSupported) throw new Error("Markdown renderer unavailable");
      const fragment = global.DOMPurify.sanitize(parser.parse(text), sanitizeOptions);

      // Only constant attributes and validated URLs are added after sanitizing.
      fragment.querySelectorAll("a").forEach((link) => {
        const href = safeHref(link.getAttribute("href") || "");
        if (!href) {
          link.replaceWith(...link.childNodes);
          return;
        }
        link.href = href;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
      });
      fragment.querySelectorAll("table").forEach((table) => {
        const columns = table.querySelector("tr")?.children.length || 1;
        table.style.minWidth = `${Math.max(280, columns * 140)}px`;
        table.querySelectorAll("th").forEach((cell) => { cell.scope = "col"; });
        const scroller = target.ownerDocument.createElement("div");
        scroller.className = "markdown-table-scroll";
        scroller.setAttribute("role", "region");
        scroller.setAttribute("aria-label", "表格，可左右滚动");
        scroller.tabIndex = 0;
        table.replaceWith(scroller);
        scroller.append(table);
      });
      target.replaceChildren(fragment);
      target.classList.add("markdown-content");
      return true;
    } catch (_) {
      // A malformed reply or unavailable dependency must not hide the response.
      target.textContent = text;
      target.classList.remove("markdown-content");
      return false;
    }
  }

  global.CampusFlowMarkdown = Object.freeze({ render });
})(window);
