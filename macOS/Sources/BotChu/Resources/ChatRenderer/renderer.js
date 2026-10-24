// Trusted app code, injected into WebKit's isolated client world. Reply content is escaped in
// BotChuCore; the CSP blocks remote resources and scripts in the document's own world.
(() => {
    const content = document.getElementById('content');
    const diagrams = new Map();
    // Typeset math by its source, so a revision doesn't typeset its unchanged expressions again.
    const typeset = new Map();
    // The markup each block shown was made from: a revision keeps the blocks it doesn't change,
    // with their math and diagrams, and a reply being written changes only its last ones.
    const sources = new WeakMap();
    let revision = 0;
    // The app's revision of the reply shown, reported with its height.
    let shown = 0;
    let nextID = 0;
    let diagramQueue = Promise.resolve();
    // The app shows the reply at the first height reported, so nothing is reported until the
    // first render is complete, its math typeset and diagrams drawn (or a second and a half has
    // passed): a reply never shows its source first, or grows and shrinks as it renders.
    let complete = false;
    const report = () => window.webkit.messageHandlers.layout.postMessage({
        height: content.getBoundingClientRect().height, revision: shown
    });
    const finish = () => { if (!complete) { complete = true; report(); } };

    new ResizeObserver(() => { if (complete) report(); }).observe(content);

    const markup = node => node.nodeType === Node.ELEMENT_NODE ? node.outerHTML : node.textContent;

    function typesetMath(element) {
        const key = element.dataset.display + ':' + element.dataset.tex;
        let math = typeset.get(key);
        if (math === undefined) {
            try {
                if (element.dataset.tex.length > 16000) throw new Error('Expression is too large');
                math = katex.renderToString(element.dataset.tex, {
                    displayMode: element.dataset.display === 'true',
                    output: 'htmlAndMathml', throwOnError: true, trust: false,
                    strict: 'ignore', maxSize: 20, maxExpand: 1000
                });
            } catch {
                math = null;
            }
            typeset.set(key, math);
            if (typeset.size > 500) typeset.delete(typeset.keys().next().value);
        }
        // An expression KaTeX can't typeset keeps its delimited source.
        if (math === null) element.classList.add('math-source');
        else element.innerHTML = math;
    }

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

    window.renderReply = async (html, dark, appRevision) => {
        const current = ++revision;
        if (current === 1) setTimeout(finish, 1500);
        const appearance = dark ? 'dark' : 'light';
        const sameAppearance = document.documentElement.dataset.appearance === appearance;
        document.documentElement.dataset.appearance = appearance;
        document.documentElement.style.colorScheme = appearance;
        const incoming = document.createElement('template');
        incoming.innerHTML = html;
        const next = Array.from(incoming.content.childNodes);
        const existing = Array.from(content.childNodes);
        let kept = 0;
        if (sameAppearance) {
            while (kept < next.length && kept < existing.length && sources.get(existing[kept]) === markup(next[kept])) kept++;
        }
        for (const node of existing.slice(kept)) node.remove();
        const added = next.slice(kept);
        for (const node of added) {
            sources.set(node, markup(node));
            content.append(node);
        }
        shown = appRevision ?? current;
        for (const node of added) {
            if (node.nodeType !== Node.ELEMENT_NODE) continue;
            for (const element of node.querySelectorAll('.tex')) typesetMath(element);
        }
        const render = async () => {
            await document.fonts.ready;
            for (const section of content.querySelectorAll('.diagram-block')) {
                // A newer revision's render follows, and draws what this one leaves.
                if (current !== revision) return;
                if (section.dataset.drawn) continue;
                const source = section.querySelector('code').textContent;
                const key = (dark ? 'dark:' : 'light:') + source;
                if (diagrams.has(key)) {
                    const svg = diagrams.get(key);
                    if (svg) showDiagram(section, svg);
                    section.dataset.drawn = svg ? 'drawn' : 'failed';
                    continue;
                }
                if (source.length > 50000) { section.dataset.drawn = 'failed'; continue; }
                const stage = document.createElement('div');
                stage.style.cssText = 'position:absolute;left:-100000px;top:0;visibility:hidden';
                document.body.append(stage);
                let svg = null;
                try {
                    mermaid.initialize({
                        startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
                        maxTextSize: 50000, maxEdges: 500, htmlLabels: false,
                        theme: dark ? 'dark' : 'default', fontFamily: '-apple-system, sans-serif',
                        secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges',
                                 'suppressErrorRendering', 'htmlLabels', 'themeCSS']
                    });
                    ({ svg } = await mermaid.render('diagram-' + (++nextID), source, stage));
                } catch {
                    // Leave the source visible until it can be rendered; no error SVG is inserted.
                } finally {
                    stage.remove();
                }
                diagrams.set(key, svg);
                if (diagrams.size > 16) diagrams.delete(diagrams.keys().next().value);
                if (current !== revision || !section.isConnected) return;
                if (svg) showDiagram(section, svg);
                section.dataset.drawn = svg ? 'drawn' : 'failed';
            }
        };
        // Mermaid has shared configuration. Serialize renders and leave stale ones to the newest.
        diagramQueue = diagramQueue.then(render, render);
        try { await diagramQueue; } finally { if (complete) report(); else finish(); }
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
