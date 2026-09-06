(() => {
  "use strict";

  const MATH_SLOT = /@@MATH(\d+)@@/g;
  const ALLOWED_TAGS = new Set([
    "P", "H1", "H2", "H3", "H4", "UL", "OL", "LI", "STRONG", "B", "EM", "I",
    "CODE", "PRE", "BLOCKQUOTE", "BR", "SPAN", "DIV", "A", "HR",
    "MATH", "ANNOTATION", "ANNOTATION-XML", "SEMANTICS", "MROW", "MI", "MO", "MN",
    "MS", "MSUP", "MSUB", "MSUBSUP", "MFRAC", "MSQRT", "MTABLE", "MTD", "MTR",
    "MLABELEDTR", "MTEXT", "MSPACE", "MOVER", "MUNDER", "MUNDEROVER", "MROOT",
    "MENCLOSE", "MPADDED", "MPHANTOM", "MSTYLE", "MERROR", "MMULTISCRIPTS",
    "MGLYPH", "MPRESCRIPTS", "NONE",
    "SVG", "PATH", "LINE", "G", "RECT", "USE", "DEFS", "TITLE", "POLYGON",
    "POLYLINE", "ELLIPSE", "CIRCLE", "TEXT", "TSPAN"
  ]);
  const ALLOWED_ATTR = new Set([
    "class", "style", "href", "rel", "target", "aria-hidden", "aria-label",
    "role", "xmlns", "xmlns:xlink", "xlink:href", "viewbox", "d", "fill", "stroke",
    "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
    "stroke-dasharray", "transform", "width", "height", "x", "y", "cx", "cy", "r",
    "dx", "dy", "encoding", "mathvariant", "displaystyle", "scriptlevel", "open",
    "close", "separators", "columnalign", "rowalign", "columnspacing", "rowspacing",
    "focusable", "display", "accent", "stretchy", "separator", "linebreak",
    "preserveaspectratio", "overflow", "opacity", "clip-path", "clip-rule",
    "fill-rule", "vector-effect", "points"
  ]);
  const TEX_ONE_ARG = new Set([
    "sqrt", "vec", "hat", "bar", "dot", "ddot", "tilde", "overline", "underline",
    "mathbf", "mathrm", "mathbb", "mathcal", "mathit", "mathsf", "mathtt",
    "text", "textrm", "textbf", "textit", "operatorname", "boxed"
  ]);
  const TEX_TWO_ARG = new Set([
    "frac", "dfrac", "tfrac", "binom", "dbinom", "tbinom", "overset", "underset"
  ]);
  const KATEX_MACROS = {
    "\\C": "\\mathbb{C}",
    "\\R": "\\mathbb{R}",
    "\\N": "\\mathbb{N}",
    "\\Z": "\\mathbb{Z}",
    "\\Q": "\\mathbb{Q}"
  };

  function skipBraced(text, index) {
    if (text[index] !== "{") return index;
    let depth = 0;
    for (let cursor = index; cursor < text.length; cursor += 1) {
      if (text[cursor] === "{") depth += 1;
      else if (text[cursor] === "}") {
        depth -= 1;
        if (depth === 0) return cursor + 1;
      }
    }
    return text.length;
  }

  function skipOptional(text, index) {
    if (text[index] !== "[") return index;
    const end = text.indexOf("]", index);
    return end < 0 ? text.length : end + 1;
  }

  function texCommandEnd(text, start) {
    if (text[start] !== "\\") return start;
    let index = start + 1;
    if (index >= text.length) return index;
    if (!/[A-Za-z]/.test(text[index])) return index + 1;
    while (index < text.length && /[A-Za-z]/.test(text[index])) index += 1;
    const name = text.slice(start + 1, index);
    index = skipOptional(text, index);
    if (TEX_ONE_ARG.has(name)) {
      index = skipOptional(text, index);
      if (text[index] === "{") index = skipBraced(text, index);
      else if (text[index] && !/\s/.test(text[index]) && !"$\\".includes(text[index])) index += 1;
    } else if (TEX_TWO_ARG.has(name)) {
      if (text[index] === "{") index = skipBraced(text, index);
      if (text[index] === "{") index = skipBraced(text, index);
    } else if (name === "left") {
      if (text[index] === "\\") index = texCommandEnd(text, index);
      else if (text[index]) index += 1;
      const right = text.indexOf("\\right", index);
      if (right >= 0) index = texCommandEnd(text, right);
    }
    while (text[index] === "^" || text[index] === "_") {
      index += 1;
      if (text[index] === "{") index = skipBraced(text, index);
      else if (text[index]) index += 1;
    }
    return index;
  }

  function unescapeTexBackslashes(text) {
    let previous = "";
    let current = String(text || "");
    const pattern = /\\{2,}([A-Za-z]+|[()[\]])/g;
    while (current !== previous) {
      previous = current;
      current = current.replace(pattern, "\\$1");
    }
    return current;
  }

  function unicodeToTex(text) {
    let next = String(text || "")
      .replace(/√\s*\(([^()]*)\)/g, "\\sqrt{$1}")
      .replace(/√\s*\{([^{}]*)\}/g, "\\sqrt{$1}")
      .replace(/√([A-Za-z0-9]+)/g, "\\sqrt{$1}")
      .replace(/∜/g, "\\sqrt[4]")
      .replace(/∛/g, "\\sqrt[3]")
      .replace(/√/g, "\\sqrt")
      .replace(/∞/g, "\\infty")
      .replace(/×/g, "\\times")
      .replace(/·/g, "\\cdot")
      .replace(/±/g, "\\pm")
      .replace(/≤/g, "\\leq")
      .replace(/≥/g, "\\geq")
      .replace(/≠/g, "\\neq")
      .replace(/→/g, "\\to")
      .replace(/ℂ/g, "\\mathbb{C}")
      .replace(/ℝ/g, "\\mathbb{R}")
      .replace(/ℕ/g, "\\mathbb{N}")
      .replace(/ℤ/g, "\\mathbb{Z}");
    return next.replace(/\bsqrt\s*\(([^()]*)\)/g, "\\sqrt{$1}");
  }

  function wrapBareTex(text) {
    const source = String(text || "");
    let out = "";
    let index = 0;
    let mode = null;
    while (index < source.length) {
      if (!mode) {
        if (source.startsWith("$$", index)) {
          mode = "ddollar";
          out += "$$";
          index += 2;
          continue;
        }
        if (source.startsWith("\\[", index)) {
          mode = "bracket";
          out += "\\[";
          index += 2;
          continue;
        }
        if (source.startsWith("\\(", index)) {
          mode = "paren";
          out += "\\(";
          index += 2;
          continue;
        }
        if (source[index] === "$") {
          mode = "dollar";
          out += "$";
          index += 1;
          continue;
        }
        if (source[index] === "\\" && /[A-Za-z]/.test(source[index + 1] || "")) {
          let cursor = texCommandEnd(source, index);
          while (true) {
            let scan = cursor;
            while (source[scan] === " ") scan += 1;
            if ("+-*=<>,/".includes(source[scan] || "")) {
              scan += 1;
              while (source[scan] === " ") scan += 1;
            }
            if (source[scan] === "\\" && /[A-Za-z]/.test(source[scan + 1] || "")) {
              cursor = texCommandEnd(source, scan);
              continue;
            }
            break;
          }
          out += `$${source.slice(index, cursor)}$`;
          index = cursor;
          continue;
        }
        out += source[index];
        index += 1;
        continue;
      }
      if (mode === "ddollar" && source.startsWith("$$", index)) {
        out += "$$";
        index += 2;
        mode = null;
        continue;
      }
      if (mode === "bracket" && source.startsWith("\\]", index)) {
        out += "\\]";
        index += 2;
        mode = null;
        continue;
      }
      if (mode === "paren" && source.startsWith("\\)", index)) {
        out += "\\)";
        index += 2;
        mode = null;
        continue;
      }
      if (mode === "dollar" && source[index] === "$") {
        out += "$";
        index += 1;
        mode = null;
        continue;
      }
      out += source[index];
      index += 1;
    }
    return out;
  }

  function normalizeStudyMath(source) {
    return wrapBareTex(unicodeToTex(unescapeTexBackslashes(source)));
  }

  function stashMath(source) {
    const slots = [];
    const store = (tex, display) => {
      const key = `@@MATH${slots.length}@@`;
      slots.push({ tex: String(tex || "").trim(), display: Boolean(display) });
      return key;
    };
    let text = String(source || "");
    text = text.replace(/\$\$([\s\S]+?)\$\$/g, (_, tex) => store(tex, true));
    text = text.replace(/\\\[([\s\S]+?)\\\]/g, (_, tex) => store(tex, true));
    text = text.replace(/\\\(([\s\S]+?)\\\)/g, (_, tex) => store(tex, false));
    text = text.replace(/(^|[^\\$])\$([^$\n]+?)\$/g, (match, pre, tex) => {
      if (!String(tex).trim()) return match;
      return `${pre}${store(tex, false)}`;
    });
    return { text, slots };
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function inlineMarkdown(value) {
    let text = escapeHtml(value);
    text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
    text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    text = text.replace(/__([^_]+)__/g, "<strong>$1</strong>");
    text = text.replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>");
    text = text.replace(/(^|[^_])_([^_]+)_/g, "$1<em>$2</em>");
    text = text.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" rel="noopener noreferrer" target="_blank">$1</a>');
    return text;
  }

  function renderMarkdown(source) {
    const lines = String(source || "").replace(/\r\n/g, "\n").split("\n");
    const html = [];
    let index = 0;
    const flushParagraph = buffer => {
      const text = buffer.join(" ").trim();
      buffer.length = 0;
      if (text) html.push(`<p>${inlineMarkdown(text)}</p>`);
    };

    while (index < lines.length) {
      const line = lines[index];
      if (/^\s*```/.test(line)) {
        const fence = [];
        index += 1;
        while (index < lines.length && !/^\s*```/.test(lines[index])) {
          fence.push(lines[index]);
          index += 1;
        }
        index += 1;
        html.push(`<pre><code>${escapeHtml(fence.join("\n"))}</code></pre>`);
        continue;
      }
      if (/^\s*$/.test(line)) {
        index += 1;
        continue;
      }
      const heading = /^(#{1,4})\s+(.+)$/.exec(line);
      if (heading) {
        const level = heading[1].length;
        html.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
        index += 1;
        continue;
      }
      const section = /^(WHAT THIS SHOWS|WHY IT MATTERS|IN SIMPLE TERMS)\s*:?\s*(.*)$/i.exec(line.trim());
      if (section) {
        html.push(`<h2>${escapeHtml(section[1].replace(/\b\w/g, letter => letter.toUpperCase()))}</h2>`);
        if (section[2].trim()) html.push(`<p>${inlineMarkdown(section[2].trim())}</p>`);
        index += 1;
        continue;
      }
      if (/^\s*>\s?/.test(line)) {
        const quoted = [];
        while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
          quoted.push(lines[index].replace(/^\s*>\s?/, ""));
          index += 1;
        }
        html.push(`<blockquote>${inlineMarkdown(quoted.join(" "))}</blockquote>`);
        continue;
      }
      if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
        const ordered = /^\s*\d+\.\s+/.test(line);
        const items = [];
        while (index < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[index])) {
          items.push(`<li>${inlineMarkdown(lines[index].replace(/^\s*(?:[-*]|\d+\.)\s+/, ""))}</li>`);
          index += 1;
        }
        html.push(`<${ordered ? "ol" : "ul"}>${items.join("")}</${ordered ? "ol" : "ul"}>`);
        continue;
      }
      const paragraph = [];
      while (index < lines.length && lines[index].trim() &&
        !/^(#{1,4})\s+/.test(lines[index]) &&
        !/^\s*([-*]|\d+\.)\s+/.test(lines[index]) &&
        !/^\s*>\s?/.test(lines[index]) &&
        !/^\s*```/.test(lines[index])) {
        paragraph.push(lines[index].trim());
        index += 1;
      }
      flushParagraph(paragraph);
    }
    return html.join("");
  }

  function renderMathSlot(slot, options = {}) {
    const tex = slot.tex || "";
    const mathOutput = options.mathOutput === "mathml" ? "mathml" : "html";
    if (globalThis.katex?.renderToString) {
      try {
        let html = katex.renderToString(tex, {
          displayMode: slot.display,
          throwOnError: false,
          strict: "ignore",
          trust: true,
          macros: KATEX_MACROS,
          minRuleThickness: 0.05,
          output: mathOutput
        });
        /* Display MathML lives in an inline .katex span; mark it so canvas CSS can blockify. */
        if (mathOutput === "mathml" && slot.display) {
          html = html.replace('class="katex"', 'class="katex katex-display"');
        }
        return html;
      } catch (_) { /* Fall through to a readable math fallback. */ }
    }
    const tag = slot.display ? "div" : "span";
    return `<${tag} class="study-math-fallback">${escapeHtml(tex)}</${tag}>`;
  }

  function sanitizeNode(node) {
    if (node.nodeType === Node.TEXT_NODE) return;
    if (node.nodeType !== Node.ELEMENT_NODE) {
      node.remove();
      return;
    }
    const tag = node.tagName;
    if (!ALLOWED_TAGS.has(tag)) {
      const parent = node.parentNode;
      if (!parent) {
        node.remove();
        return;
      }
      while (node.firstChild) parent.insertBefore(node.firstChild, node);
      node.remove();
      return;
    }
    const mathTag = tag === "MATH" || tag === "ANNOTATION" || tag === "ANNOTATION-XML" ||
      tag === "SEMANTICS" || tag === "NONE" || (tag.startsWith("M") && tag.length <= 16);
    const svgTag = tag === "SVG" || tag === "PATH" || tag === "LINE" || tag === "G" ||
      tag === "RECT" || tag === "USE" || tag === "DEFS" || tag === "POLYGON" ||
      tag === "POLYLINE" || tag === "ELLIPSE" || tag === "CIRCLE" || tag === "TEXT" ||
      tag === "TSPAN";
    const katexTree = typeof node.closest === "function" && (
      node.closest(".katex") || node.closest("math") || node.closest("svg")
    );
    [...node.attributes].forEach(attr => {
      const name = attr.name.toLowerCase();
      const value = attr.value || "";
      if (name.startsWith("on") || name === "srcdoc") {
        node.removeAttribute(attr.name);
        return;
      }
      if ((name === "href" || name === "xlink:href") && !/^(https?:|mailto:|#)/i.test(value)) {
        node.removeAttribute(attr.name);
        return;
      }
      if (mathTag || svgTag || katexTree) return;
      if (!ALLOWED_ATTR.has(name) && !name.startsWith("aria-") && !name.startsWith("data-")) {
        node.removeAttribute(attr.name);
      }
    });
    [...node.childNodes].forEach(sanitizeNode);
  }

  function sanitizeHtml(html) {
    const template = document.createElement("template");
    template.innerHTML = html;
    [...template.content.childNodes].forEach(sanitizeNode);
    return template.content;
  }

  function renderStudyHtml(source, options = {}) {
    const protectedSource = stashMath(normalizeStudyMath(source));
    let html = renderMarkdown(protectedSource.text);
    html = html.replace(MATH_SLOT, (_, index) => {
      const slot = protectedSource.slots[Number(index)];
      return slot ? renderMathSlot(slot, options) : "";
    });
    return html;
  }

  function renderStudyMarkdown(source, options = {}) {
    const fragment = sanitizeHtml(renderStudyHtml(source, options));
    const wrap = document.createElement("div");
    wrap.className = "study-md";
    wrap.append(fragment);
    return wrap;
  }

  function hasMathMarkup(source) {
    const text = String(source || "");
    return /\$\$|\\\(|\\\[|(^|[^\\])\$[^$\n]+\$|\\begin\{|\\frac\b|\\vec\b|\\times\b|\\cdot\b|\\sqrt\b|\\sum\b|\\int\b|√|ℂ|\\\\mathbb/.test(text);
  }

  function hasRichMarkup(source) {
    const text = String(source || "");
    return hasMathMarkup(text) ||
      /(?:^|\n)\s{0,3}(#{1,4}\s|[-*]\s|\d+\.\s|>\s|```)/.test(text) ||
      /\*\*[^*]+\*\*|__[^_]+__|(^|[^*])\*[^*]+\*|`[^`]+`/.test(text);
  }

  globalThis.normalizeStudyMath = normalizeStudyMath;
  globalThis.renderStudyMarkdown = renderStudyMarkdown;
  globalThis.renderStudyHtml = renderStudyHtml;
  globalThis.hasMathMarkup = hasMathMarkup;
  globalThis.hasRichMarkup = hasRichMarkup;
})();
