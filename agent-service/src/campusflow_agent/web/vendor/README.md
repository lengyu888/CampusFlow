# Markdown rendering dependencies

These fixed-version browser distributions are served locally. Runtime rendering
does not use a CDN or download JavaScript from third-party hosts.

| Library | Version | Upstream | Distribution | License files |
| --- | --- | --- | --- | --- |
| Marked | 18.1.1 | https://github.com/markedjs/marked | https://registry.npmjs.org/marked/-/marked-18.1.1.tgz (`lib/marked.umd.js`) | `marked-LICENSE` (MIT) |
| DOMPurify | 3.4.17 | https://github.com/cure53/DOMPurify | https://registry.npmjs.org/dompurify/-/dompurify-3.4.17.tgz (`dist/purify.min.js`) | `DOMPurify-LICENSE` (Apache-2.0), `DOMPurify-LICENSE-MPL` (MPL-2.0 alternative) |

The files and source maps are copied unchanged from their published packages;
versioned JavaScript filenames prevent cache conflicts. Preserve their copyright
headers and licenses when updating. Check the upstream security advisories and
rerun `agent-service/tests/web` tests before changing these versions.

`../markdown.js` escapes raw HTML and renders images as their alternative text,
then sanitizes the generated HTML with a restricted tag/attribute allowlist.
Only absolute HTTP, HTTPS and mailto links can be activated. Tables get a local
scroll container and code blocks remain escaped text. Rows with more cells than
the table header cause the complete table source to display as escaped code,
preserving cells that the upstream parser would otherwise discard. Pipes inside
matched inline code spans remain inside their cell.
