(() => {
  "use strict";

  const KATEX_MACROS = {
    "\\C": "\\mathbb{C}",
    "\\R": "\\mathbb{R}",
    "\\N": "\\mathbb{N}",
    "\\Z": "\\mathbb{Z}",
    "\\Q": "\\mathbb{Q}",
    "\\degree": "{}^{\\circ}",
    "\\degreeC": "{}^{\\circ}\\mathrm{C}",
    "\\circC": "{}^{\\circ}\\mathrm{C}",
    "\\AND": "\\operatorname{AND}",
    "\\OR": "\\operatorname{OR}",
    "\\NOT": "\\operatorname{NOT}",
    "\\XOR": "\\operatorname{XOR}",
    "\\TRUE": "\\mathrm{T}",
    "\\FALSE": "\\mathrm{F}"
  };
  const RICH_MARKUP = /(?:^|\n)\s{0,3}(?:#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s|```)|\*\*[^*]+\*\*|__[^_]+__|`[^`]+`/;
  const MATH_MARKUP = /\$\$|\\\(|\\\[|(^|[^\\])\$|\\begin\{|\\(?:frac|dfrac|tfrac|sqrt|vec|hat|bar|nabla|partial|sum|int|lim|alpha|beta|gamma|delta|theta|lambda|mu|pi|rho|sigma|phi|psi|omega|times|cdot|mathbb|mathbf|mathrm|text)\b/;
  const BARE_MATH_START = /\\(?:frac|dfrac|tfrac|binom|dbinom|tbinom|sqrt|vec|hat|bar|dot|ddot|tilde|overline|underline|mathbf|mathrm|mathbb|mathcal|mathit|mathsf|mathtt|text|operatorname|boxed|nabla|partial|sum|prod|int|oint|lim|infty|alpha|beta|gamma|delta|epsilon|theta|lambda|mu|nu|xi|pi|rho|sigma|tau|phi|chi|psi|omega|Delta|Gamma|Lambda|Omega|Phi|Pi|Psi|Sigma|Theta|Upsilon|Xi|times|cdot|pm|mp|leq|geq|neq|approx|equiv|in|notin|subset|supset|cup|cap|land|lor|neg|to|rightarrow|leftarrow|leftrightarrow|begin)\b/g;
  const ONE_ARG_COMMANDS = new Set([
    "sqrt", "vec", "hat", "bar", "dot", "ddot", "tilde", "overline", "underline",
    "mathbf", "mathrm", "mathbb", "mathcal", "mathit", "mathsf", "mathtt",
    "text", "textrm", "textbf", "textit", "texttt", "operatorname", "boxed"
  ]);
  const TWO_ARG_COMMANDS = new Set([
    "frac", "dfrac", "tfrac", "binom", "dbinom", "tbinom", "overset", "underset"
  ]);
  const IGNORED_BARE_MATH_PARENTS = new Set(["CODE", "PRE", "SCRIPT", "STYLE", "TEXTAREA", "A"]);
  let markdownParser = null;

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function unescapeLegacyNewlines(value) {
    return String(value ?? "")
      .replace(/\$(?:\\n)+\$/g, "\n\n")
      .replace(/\$(?:\n)+\$/g, "\n\n")
      .replace(/(?<!\\)\\n(?![A-Za-z])/g, "\n")
      .replace(/(?<!\\)\\t(?![A-Za-z])/g, "\t")
      .replace(/(?<!\\)\\r(?![A-Za-z])/g, "\n")
      .replace(/\$(\s*#{1,6}\s)/g, "$1");
  }

  /*
   * Old study guides could be persisted as a JSON wrapper or with literal
   * JSON newlines. This only recovers that transport damage; it never changes
   * valid Markdown or TeX stored by current code.
   */
  function coerceStudyMarkdown(source) {
    if (source && typeof source === "object") {
      return coerceStudyMarkdown(source.source ?? source.content ?? source.answer ?? "");
    }
    const text = String(source ?? "");
    const trimmed = text.trim();
    if (trimmed.startsWith("{") && /"(?:source|content|answer)"\s*:/.test(trimmed)) {
      try {
        const parsed = JSON.parse(trimmed);
        const nested = parsed?.source ?? parsed?.content ?? parsed?.answer;
        if (typeof nested === "string" && nested.trim() && nested !== text) {
          return coerceStudyMarkdown(nested);
        }
      } catch (_) {
        // A malformed historical wrapper remains readable as ordinary text.
      }
    }
    const realBreaks = (text.match(/\n/g) || []).length;
    const escapedBreaks = (text.match(/\\n(?![A-Za-z])/g) || []).length;
    return escapedBreaks > realBreaks + 2 ? unescapeLegacyNewlines(text) : text;
  }

  function katexOptions(options = {}) {
    return {
      displayMode: Boolean(options.display),
      throwOnError: true,
      strict: "ignore",
      trust: false,
      macros: KATEX_MACROS,
      minRuleThickness: 0.05,
      output: options.mathOutput === "mathml" ? "mathml" : "htmlAndMathml"
    };
  }

  function renderKatexMarkup(tex, options = {}) {
    try {
      return globalThis.katex.renderToString(String(tex ?? "").trim(), katexOptions(options));
    } catch (_) {
      const tag = options.display ? "div" : "span";
      return `<${tag} class="study-math-error" aria-label="Math could not be rendered">${escapeHtml(tex)}</${tag}>`;
    }
  }

  function createMarkdownParser(options = {}) {
    if (typeof globalThis.markdownit !== "function" ||
        typeof globalThis.texmath !== "function" ||
        !globalThis.katex?.renderToString) {
      throw new Error("The AI rich-text renderer did not load.");
    }
    const parser = globalThis.markdownit({
      html: false,
      linkify: true,
      breaks: false,
      typographer: false
    });
    parser.use(globalThis.texmath, {
      engine: globalThis.katex,
      delimiters: ["dollars", "brackets", "beg_end"],
      katexOptions: katexOptions(options)
    });
    parser.renderer.rules.math_inline = (tokens, index) =>
      renderKatexMarkup(tokens[index].content, options);
    parser.renderer.rules.math_inline_double = (tokens, index) =>
      `<div class="study-math-display">${renderKatexMarkup(tokens[index].content, { ...options, display: true })}</div>`;
    parser.renderer.rules.math_block = (tokens, index) =>
      `<div class="study-math-display">${renderKatexMarkup(tokens[index].content, { ...options, display: true })}</div>\n`;
    parser.renderer.rules.math_block_eqno = parser.renderer.rules.math_block;
    return parser;
  }

  function parserFor(options = {}) {
    if (options.mathOutput === "mathml") return createMarkdownParser(options);
    if (!markdownParser) markdownParser = createMarkdownParser();
    return markdownParser;
  }

  function sanitizedFragment(html) {
    if (!globalThis.DOMPurify?.sanitize) {
      throw new Error("The AI content sanitizer did not load.");
    }
    return globalThis.DOMPurify.sanitize(html, {
      RETURN_DOM_FRAGMENT: true,
      USE_PROFILES: { html: true, mathMl: true, svg: true },
      ADD_ATTR: ["aria-hidden", "aria-label", "role", "encoding"],
      FORBID_TAGS: ["style", "script", "iframe", "object", "embed", "form"],
      // Markdown HTML is disabled and KaTeX runs with trust:false, so style
      // attributes here can only come from KaTeX's own layout output.
      FORBID_ATTR: ["srcdoc"]
    });
  }

  function skipBalanced(text, index, open = "{", close = "}") {
    if (text[index] !== open) return index;
    let depth = 0;
    for (let cursor = index; cursor < text.length; cursor += 1) {
      if (text[cursor] === open && text[cursor - 1] !== "\\") depth += 1;
      if (text[cursor] === close && text[cursor - 1] !== "\\") {
        depth -= 1;
        if (depth === 0) return cursor + 1;
      }
    }
    return index;
  }

  function skipSpaces(text, index) {
    while (text[index] === " " || text[index] === "\t") index += 1;
    return index;
  }

  function commandEnd(text, start) {
    if (text[start] !== "\\" || !/[A-Za-z]/.test(text[start + 1] || "")) return start;
    let index = start + 1;
    while (/[A-Za-z]/.test(text[index] || "")) index += 1;
    const name = text.slice(start + 1, index);
    index = skipSpaces(text, index);
    if (text[index] === "[") {
      const optionalEnd = skipBalanced(text, index, "[", "]");
      if (optionalEnd > index) index = skipSpaces(text, optionalEnd);
    }
    const args = TWO_ARG_COMMANDS.has(name) ? 2 : ONE_ARG_COMMANDS.has(name) ? 1 : 0;
    for (let arg = 0; arg < args; arg += 1) {
      if (text[index] === "{") {
        const end = skipBalanced(text, index);
        if (end === index) return start;
        index = skipSpaces(text, end);
      }
    }
    if (name === "begin" && text[index] === "{") {
      const nameEnd = skipBalanced(text, index);
      const environment = text.slice(index + 1, nameEnd - 1);
      const closer = `\\end{${environment}}`;
      const end = text.indexOf(closer, nameEnd);
      if (end >= 0) return end + closer.length;
    }
    while (text[index] === "^" || text[index] === "_") {
      index += 1;
      if (text[index] === "{") {
        const end = skipBalanced(text, index);
        if (end === index) break;
        index = end;
      } else if (text[index]) {
        index += 1;
      }
    }
    return index;
  }

  function bareMathEnd(text, start) {
    let index = commandEnd(text, start);
    if (index <= start) return start;
    let lastGood = index;
    let guard = 0;
    while (index < text.length && guard++ < 200) {
      const beforeSpace = index;
      index = skipSpaces(text, index);
      const char = text[index] || "";
      if (!char || char === "\n" || /[.!?;:]/.test(char)) break;
      if (char === "\\" && /[A-Za-z]/.test(text[index + 1] || "")) {
        const end = commandEnd(text, index);
        if (end <= index) break;
        index = end;
        lastGood = index;
        continue;
      }
      if ("+-=*/<>|,()[]".includes(char)) {
        index += 1;
        lastGood = index;
        continue;
      }
      if (/[A-Za-z0-9]/.test(char)) {
        let end = index + 1;
        while (/[A-Za-z0-9]/.test(text[end] || "")) end += 1;
        if (end - index > 2 && beforeSpace !== index) break;
        index = end;
        while (text[index] === "^" || text[index] === "_") {
          index += 1;
          if (text[index] === "{") {
            const argEnd = skipBalanced(text, index);
            if (argEnd === index) break;
            index = argEnd;
          } else if (text[index]) index += 1;
        }
        lastGood = index;
        continue;
      }
      break;
    }
    return lastGood;
  }

  function renderBareMathIn(root, options = {}) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const textNodes = [];
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (!node.nodeValue?.includes("\\") || node.parentElement?.closest(".katex")) continue;
      if (node.parentElement && [...IGNORED_BARE_MATH_PARENTS].some(tag => node.parentElement.closest(tag))) continue;
      textNodes.push(node);
    }
    textNodes.forEach(node => {
      const text = node.nodeValue || "";
      BARE_MATH_START.lastIndex = 0;
      let match;
      let cursor = 0;
      let changed = false;
      const fragment = document.createDocumentFragment();
      while ((match = BARE_MATH_START.exec(text))) {
        const start = match.index;
        const end = bareMathEnd(text, start);
        if (end <= start) continue;
        const tex = text.slice(start, end).trim();
        try {
          globalThis.katex.renderToString(tex, { ...katexOptions(options), throwOnError: true });
        } catch (_) {
          BARE_MATH_START.lastIndex = Math.max(BARE_MATH_START.lastIndex, start + 1);
          continue;
        }
        fragment.append(document.createTextNode(text.slice(cursor, start)));
        const span = document.createElement("span");
        span.className = "study-bare-math";
        globalThis.katex.render(tex, span, katexOptions(options));
        fragment.append(span);
        cursor = end;
        BARE_MATH_START.lastIndex = end;
        changed = true;
      }
      if (!changed) return;
      fragment.append(document.createTextNode(text.slice(cursor)));
      node.replaceWith(fragment);
    });
  }

  function secureLinks(root) {
    root.querySelectorAll("a[href]").forEach(link => {
      const href = link.getAttribute("href") || "";
      if (!/^(https?:|mailto:|#)/i.test(href)) {
        link.removeAttribute("href");
        return;
      }
      if (/^https?:/i.test(href)) {
        link.target = "_blank";
        link.rel = "noopener noreferrer";
      }
    });
  }

  function renderSource(source, options = {}, inline = false) {
    const markdown = coerceStudyMarkdown(source);
    const parser = parserFor(options);
    const html = inline ? parser.renderInline(markdown) : parser.render(markdown);
    const fragment = sanitizedFragment(html);
    const staging = document.createElement(inline ? "span" : "div");
    staging.append(fragment);
    renderBareMathIn(staging, options);
    secureLinks(staging);
    return staging;
  }

  function renderStudyMarkdown(source, options = {}) {
    const wrap = document.createElement("div");
    wrap.className = "study-md ai-rich-text";
    try {
      const rendered = renderSource(source, options, false);
      wrap.append(...rendered.childNodes);
    } catch (error) {
      wrap.classList.add("ai-rich-text-error");
      wrap.textContent = "This response could not be formatted. Please try again.";
      console.error("AI rich-text rendering failed", error);
    }
    return wrap;
  }

  function renderStudyInline(source, options = {}) {
    const wrap = document.createElement("span");
    wrap.className = "study-md study-md-inline ai-rich-text";
    try {
      const rendered = renderSource(source, options, true);
      wrap.append(...rendered.childNodes);
    } catch (error) {
      wrap.classList.add("ai-rich-text-error");
      wrap.textContent = String(source ?? "");
      console.error("AI inline rendering failed", error);
    }
    return wrap;
  }

  function fillStudyRichText(target, source, options = {}) {
    if (!target) return;
    target.replaceChildren();
    if (source == null || source === "") return;
    target.append(renderStudyInline(source, options));
  }

  function hasMathMarkup(source) {
    MATH_MARKUP.lastIndex = 0;
    return MATH_MARKUP.test(String(source ?? ""));
  }

  function hasRichMarkup(source) {
    const text = String(source ?? "");
    return hasMathMarkup(text) || RICH_MARKUP.test(text);
  }

  globalThis.coerceStudyMarkdown = coerceStudyMarkdown;
  globalThis.renderStudyMarkdown = renderStudyMarkdown;
  globalThis.renderStudyInline = renderStudyInline;
  globalThis.fillStudyRichText = fillStudyRichText;
  globalThis.hasMathMarkup = hasMathMarkup;
  globalThis.hasRichMarkup = hasRichMarkup;
})();
