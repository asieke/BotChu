// Trusted app code, injected into WebKit's isolated client world. Reply content is escaped in
// BotChuCore; the CSP blocks remote resources and scripts in the document's own world.
(() => {
    const content = document.getElementById('content');
    const diagrams = new Map();
    let revision = 0;
    let nextID = 0;
    let diagramQueue = Promise.resolve();
    // The app shows the reply at the first height reported, so nothing is reported until the
    // first render is complete, its math typeset and diagrams drawn (or a second and a half has
    // passed): a reply never shows its source first, or grows and shrinks as it renders.
    let complete = false;
    const report = () => window.webkit.messageHandlers.layout.postMessage(content.getBoundingClientRect().height);
    const finish = () => { if (!complete) { complete = true; report(); } };

    new ResizeObserver(() => { if (complete) report(); }).observe(content);

    function showDiagram(section, svg) {
        const diagram = section.querySelector('.diagram');
        diagram.innerHTML = svg;
        const drawing = diagram.querySelector('svg');
        if (drawing?.viewBox.baseVal.width) {
            diagram.style.setProperty('--diagram-width', drawing.viewBox.baseVal.width + 'px');
        }
        section.querySelector('details').open = false;
        section.querySelector('.diagram-size').hidden = false;
    }

    window.renderReply = async (html, dark) => {
        const current = ++revision;
        if (current === 1) setTimeout(finish, 1500);
        document.documentElement.dataset.appearance = dark ? 'dark' : 'light';
        document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
        content.innerHTML = html;
        for (const element of content.querySelectorAll('.tex')) {
            const source = element.textContent;
            try {
                if (element.dataset.tex.length > 16000) throw new Error('Expression is too large');
                katex.render(element.dataset.tex, element, {
                    displayMode: element.dataset.display === 'true',
                    output: 'htmlAndMathml', throwOnError: true, trust: false,
                    strict: 'ignore', maxSize: 20, maxExpand: 1000
                });
            } catch {
                // KaTeX may clear the element before throwing. Restore the delimited source.
                element.textContent = source;
                element.classList.add('math-source');
            }
        }
        const sections = Array.from(content.querySelectorAll('.diagram-block'));
        const render = async () => {
            await document.fonts.ready;
            for (const section of sections) {
                if (current !== revision) return;
                const source = section.querySelector('code').textContent;
                const key = (dark ? 'dark:' : 'light:') + source;
                if (diagrams.has(key)) { showDiagram(section, diagrams.get(key)); continue; }
                if (source.length > 50000) continue;
                const stage = document.createElement('div');
                stage.style.cssText = 'position:absolute;left:-100000px;top:0;visibility:hidden';
                document.body.append(stage);
                try {
                    mermaid.initialize({
                        startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
                        maxTextSize: 50000, maxEdges: 500, htmlLabels: false,
                        theme: dark ? 'dark' : 'default', fontFamily: '-apple-system, sans-serif',
                        secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges',
                                 'suppressErrorRendering', 'htmlLabels', 'themeCSS']
                    });
                    const { svg } = await mermaid.render('diagram-' + (++nextID), source, stage);
                    diagrams.set(key, svg);
                    if (diagrams.size > 16) diagrams.delete(diagrams.keys().next().value);
                    if (current === revision) showDiagram(section, svg);
                } catch {
                    // Leave the source visible until it can be rendered; no error SVG is inserted.
                } finally {
                    stage.remove();
                }
            }
        };
        // Mermaid has shared configuration. Serialize renders and discard stale streamed replies.
        diagramQueue = diagramQueue.then(render, render);
        try { await diagramQueue; } finally { finish(); }
    };

    document.addEventListener('click', event => {
        const copy = event.target.closest('button.copy-code');
        if (copy) {
            const code = copy.closest('.code-block, .diagram-block').querySelector('code').textContent;
            window.webkit.messageHandlers.copyCode.postMessage(code);
            copy.textContent = 'Copied';
            setTimeout(() => { copy.textContent = copy.closest('.diagram-block') ? 'Copy source' : 'Copy'; }, 1500);
        }
        const size = event.target.closest('button.diagram-size');
        if (size) {
            const diagram = size.closest('.diagram-block').querySelector('.diagram');
            size.textContent = diagram.classList.toggle('actual-size') ? 'Fit' : 'Actual size';
        }
    });
})();
