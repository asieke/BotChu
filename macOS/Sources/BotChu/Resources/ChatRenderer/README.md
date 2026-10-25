# Offline chat renderers

BotChu bundles these unmodified distributions from the npm registry:

- [Mermaid 12.2.0](https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4012.2.0):
  `dist/mermaid.min.js` and `LICENSE` from `mermaid@12.2.0`. The standalone bundle includes its
  dependencies and preserves their license notices at the end of the file.
- [KaTeX 0.19.0](https://github.com/KaTeX/KaTeX/releases/tag/v0.19.0): `dist/katex.min.js`,
  `dist/katex.min.css`, `dist/fonts/*.woff2` and `LICENSE` from `katex@0.19.0`.
  macOS 14+ WebKit uses the bundled WOFF2 fonts; the CSS's older font fallbacks are not needed.

`versions.json` records the npm tarball integrity hashes. `SHA256SUMS` covers the vendored files;
`macOS/test.sh` verifies them before running the tests. `index.html` and `renderer.js` are BotChu's
integration code, not part of either upstream distribution.

To update, download explicit versions with `npm pack --ignore-scripts` into a temporary directory,
verify each tarball's SHA-512 integrity against the registry metadata, and replace only the files
listed above. Preserve the license files and the Mermaid bundle's embedded dependency notices.
Update `versions.json` and `SHA256SUMS`, then run `scripts/test.sh` and visually review math,
flowcharts with subgraphs, sequence diagrams, light/dark appearance and incomplete streamed input.
Node/npm is only needed for this maintenance step; building and running BotChu needs neither.

The app uses a nonpersistent WebKit data store. Scripts run in WebKit's isolated client world.
The document's CSP allows local styles and fonts, blocks network resources and document scripts,
and permits no frames or form submission. Mermaid uses strict security with unsafe configuration
overrides locked; KaTeX uses `trust: false` and bounded macro expansion. Reply text is escaped
before becoming HTML. Unsupported input retains its source; no hosted rendering service is used.
