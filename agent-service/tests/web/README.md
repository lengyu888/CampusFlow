# Web Markdown regression checks

The application uses the vendored browser files in `src/campusflow_agent/web`;
these Node dependencies are used only for tests.

With Node.js 22.22.2+, 24.15.0+ or 26+ and pnpm 11.19.0 (the versions supported by jsdom 30.1.2):

```shell
pnpm --dir agent-service/tests/web install --frozen-lockfile
pnpm --dir agent-service/tests/web test
```

The jsdom checks cover mixed formatting, GFM table cells and alignment, escaped
pipes, overflow-row content preservation, code blocks, malicious HTML and URLs, fallback text, and the real
`appendMessage` path used both for current chat and restored history. They do not
verify browser layout or touch the database, backend APIs, or model credentials.

For visual acceptance, serve the repository root with a local development HTTP
server and open `/agent-service/tests/web/preview.html`. The sample loads the real
local renderer and styles by relative paths, has no API calls, and is never
linked from the application's UI. Check desktop and narrow phone widths, table
scrolling and code scrolling separately from the jsdom checks.
