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
    "text", "textrm", "textbf", "textit", "texttt", "operatorname", "boxed"
  ]);
  const TEX_TWO_ARG = new Set([
    "frac", "dfrac", "tfrac", "binom", "dbinom", "tbinom", "overset", "underset"
  ]);
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
  const MATH_DIFF = /^(d(?:x|y|z|u|v|t|θ|\\theta))\b/;
  const MATH_TOKEN_RE = /@@MATH\d+@@/g;

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
    while (text[index] === " ") index += 1;
    if (TEX_ONE_ARG.has(name)) {
      index = skipOptional(text, index);
      while (text[index] === " ") index += 1;
      if (text[index] === "{") index = skipBraced(text, index);
      else if (text[index] && !/\s/.test(text[index]) && !"$\\".includes(text[index])) index += 1;
    } else if (TEX_TWO_ARG.has(name)) {
      while (text[index] === " ") index += 1;
      if (text[index] === "{") index = skipBraced(text, index);
      while (text[index] === " ") index += 1;
      if (text[index] === "{") index = skipBraced(text, index);
    } else if (name === "left") {
      if (text[index] === "\\") index = texCommandEnd(text, index);
      else if (text[index]) index += 1;
      const right = text.indexOf("\\right", index);
      if (right >= 0) index = texCommandEnd(text, right);
    } else if (name === "begin") {
      if (text[index] === "{") index = skipBraced(text, index);
      const end = text.indexOf("\\end", index);
      if (end >= 0) index = texCommandEnd(text, end);
    } else if (name === "end") {
      if (text[index] === "{") index = skipBraced(text, index);
    }
    while (text[index] === "^" || text[index] === "_") {
      index += 1;
      if (text[index] === "{") index = skipBraced(text, index);
      else if (text[index]) index += 1;
    }
    return index;
  }

  function unescapeStudyNewlines(text) {
    return String(text || "")
      .replace(/\$(?:\\n)+\$/g, "\n\n")
      .replace(/\$(?:\n)+\$/g, "\n\n")
      .replace(/\$\\n([A-Z][^$\n]{0,80})\$/g, "\n$1")
      .replace(/\$\\n(?![A-Za-z])/g, "\n")
      .replace(/\$\\n(?=[A-Z])/g, "\n")
      .replace(/\$\n([A-Z][^$\n]{0,80})\$/g, "\n$1")
      .replace(/(?<!\$)\$(?:\n+)(?!\$)/g, "\n")
      .replace(/\\n(?![A-Za-z])/g, "\n")
      .replace(/\\t(?![A-Za-z])/g, "\t")
      .replace(/\\r(?![A-Za-z])/g, "\n")
      .replace(/\$(\s*#{1,4}\s)/g, "$1");
  }

  function extractJsonStringField(raw, field) {
    const text = String(raw || "");
    const marker = `"${field}"`;
    const start = text.indexOf(marker);
    if (start < 0) return "";
    let cursor = text.indexOf(":", start + marker.length);
    if (cursor < 0) return "";
    cursor += 1;
    while (/\s/.test(text[cursor] || "")) cursor += 1;
    if (text[cursor] !== "\"") return "";
    cursor += 1;
    let out = "";
    while (cursor < text.length) {
      if (text.startsWith("$\\n$", cursor)) {
        out += "\n";
        cursor += 4;
        continue;
      }
      const char = text[cursor];
      if (char === "\\" && text[cursor + 1]) {
        const nxt = text[cursor + 1];
        out += ({ n: "\n", t: "\t", r: "\n", "\"": "\"", "\\": "\\" })[nxt] || nxt;
        cursor += 2;
        continue;
      }
      if (char === "\"") return out;
      out += char;
      cursor += 1;
    }
    return out;
  }

  function coerceStudyMarkdown(source) {
    const text = String(source || "");
    const trimmed = text.trim();
    if (trimmed.startsWith("{") && /"content"\s*:/.test(trimmed)) {
      try {
        const parsed = JSON.parse(trimmed);
        if (parsed && typeof parsed.content === "string" && parsed.content.trim()) {
          return coerceStudyMarkdown(parsed.content);
        }
      } catch (_) {
        const restored = trimmed.replace(/\$\\n\$/g, "\\n");
        try {
          const parsed = JSON.parse(restored);
          if (parsed && typeof parsed.content === "string" && parsed.content.trim()) {
            return coerceStudyMarkdown(parsed.content);
          }
        } catch (_) {
          const extracted = extractJsonStringField(trimmed, "content")
            || extractJsonStringField(restored, "content");
          if (extracted && extracted !== text) return coerceStudyMarkdown(extracted);
        }
      }
    }
    const realBreaks = (text.match(/\n/g) || []).length;
    const escapedBreaks = (text.match(/\\n(?![A-Za-z])/g) || []).length;
    if (escapedBreaks > realBreaks + 2 || /\$\\n/.test(text) || /\$\n+\s*#/.test(text)) {
      return unescapeStudyNewlines(text);
    }
    return text.replace(/\$(\s*#{1,4}\s)/g, "$1");
  }

  function unescapeTexBackslashes(text) {
    let previous = "";
    let current = String(text || "");
    const pattern = /\\{2,}([A-Za-z]+|[()[\],;:! ])/g;
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
      .replace(/ℤ/g, "\\mathbb{Z}")
      .replace(/Δ/g, "\\Delta")
      .replace(/δ/g, "\\delta")
      .replace(/°/g, "^{\\circ}")
      .replace(/⇌/g, "\\rightleftharpoons");
    return next.replace(/\bsqrt\s*\(([^()]*)\)/g, "\\sqrt{$1}");
  }

  function isProsePunctuation(source, index) {
    const char = source[index];
    if (char === "*" || char === "`") return true;
    if (char === "." || char === "!" || char === "?") {
      const next = source[index + 1] || "";
      return !next || /\s/.test(next) || next === "*" || /[A-Z]/.test(next);
    }
    if (char === ",") {
      const next = source[index + 1] || "";
      const after = source[index + 2] || "";
      return next === " " && /[A-Za-z]/.test(after);
    }
    return false;
  }

  function skipThinSpace(source, cursor) {
    if (source[cursor] !== "\\") return cursor;
    let slashes = 0;
    while (source[cursor + slashes] === "\\") slashes += 1;
    if (slashes >= 1 && ",;:! ".includes(source[cursor + slashes] || "")) {
      return cursor + slashes + 1;
    }
    const quad = source.slice(cursor).match(/^\\+(?:q?quad)\b/);
    return quad ? cursor + quad[0].length : cursor;
  }

  function isMathContinue(source, scan) {
    if (scan >= source.length || isProsePunctuation(source, scan)) return false;
    const char = source[scan];
    if (char === "\\") return skipThinSpace(source, scan) !== scan || /[A-Za-z]/.test(source[scan + 1] || "");
    if ("+-*=<>/()[]|".includes(char)) return true;
    if ((char === "." || char === ",") && /[0-9]/.test(source[scan + 1] || "")) return true;
    if (/[0-9]/.test(char)) return true;
    if (MATH_DIFF.test(source.slice(scan))) return true;
    if (/[A-Za-z]/.test(char) && !/[A-Za-z]/.test(source[scan + 1] || "")) return true;
    return false;
  }

  function extendMathRun(source, cursor) {
    while (cursor < source.length) {
      const char = source[cursor];
      if (char === "\n" || char === "#") break;
      if (char === " ") {
        let scan = cursor + 1;
        while (source[scan] === " ") scan += 1;
        if (!isMathContinue(source, scan)) break;
        cursor = scan;
        continue;
      }
      if (isProsePunctuation(source, cursor)) break;
      const thin = skipThinSpace(source, cursor);
      if (thin !== cursor) {
        cursor = thin;
        continue;
      }
      if (char === "{") {
        cursor = skipBraced(source, cursor);
        continue;
      }
      if ("+-*=<>/()[]|".includes(char)) {
        cursor += 1;
        continue;
      }
      if ((char === "." || char === ",") && /[0-9]/.test(source[cursor + 1] || "")) {
        cursor += 1;
        continue;
      }
      if (char === "\\" && /[A-Za-z]/.test(source[cursor + 1] || "")) {
        let nameEnd = cursor + 1;
        while (/[A-Za-z]/.test(source[nameEnd] || "")) nameEnd += 1;
        const name = source.slice(cursor + 1, nameEnd);
        if (name === "n" || name === "t" || name === "r") break;
        cursor = texCommandEnd(source, cursor);
        continue;
      }
      const diff = source.slice(cursor).match(MATH_DIFF);
      if (diff) {
        cursor += diff[0].length;
        continue;
      }
      if (/[A-Za-z]/.test(char) && !/[A-Za-z]/.test(source[cursor + 1] || "")) {
        cursor += 1;
        while (source[cursor] === "_" || source[cursor] === "^") {
          cursor += 1;
          if (source[cursor] === "{") cursor = skipBraced(source, cursor);
          else if (source[cursor]) cursor += 1;
        }
        continue;
      }
      if (/[0-9]/.test(char)) {
        while (/[0-9.]/.test(source[cursor] || "")) cursor += 1;
        while (source[cursor] === "_" || source[cursor] === "^") {
          cursor += 1;
          if (source[cursor] === "{") cursor = skipBraced(source, cursor);
          else if (source[cursor]) cursor += 1;
        }
        continue;
      }
      break;
    }
    return cursor;
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
          let nameEnd = index + 1;
          while (/[A-Za-z]/.test(source[nameEnd] || "")) nameEnd += 1;
          const name = source.slice(index + 1, nameEnd);
          if ((name === "n" || name === "t" || name === "r") && !/[A-Za-z]/.test(source[nameEnd] || "")) {
            out += name === "t" ? "\t" : "\n";
            index = nameEnd;
            continue;
          }
          const cursor = extendMathRun(source, texCommandEnd(source, index));
          out += `$${source.slice(index, cursor)}$`;
          if (/[A-Za-z]/.test(source[cursor] || "")) out += " ";
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

  function mergeSplitMathSpans(text) {
    const glue = "(?:\\s|[=+\\-*/,()\\[\\]|]|\\\\[,;:!]|\\b(?:dx|dy|dz|du|dv|dt)\\b|[A-Za-z]\\b|[0-9.]+|\\^|_)+";
    const pattern = new RegExp(`\\$([^$\\n]+)\\$(\\s*${glue}\\s*)\\$([^$\\n]+)\\$`);
    return String(text || "").split("\n").map(line => {
      let previous = "";
      let current = line;
      while (current !== previous) {
        previous = current;
        current = current.replace(pattern, (_, left, mid, right) => `$${left}${mid}${right}$`);
      }
      return current;
    }).join("\n");
  }

  function restoreSentenceSpacing(text) {
    return String(text || "")
      .replace(/(?<!\$)\$([A-Za-z])/g, "$ $1")
      .replace(/([.!?])\*([A-Za-z])/g, "$1 *$2");
  }

  function tidyTexCommands(text) {
    let next = String(text || "");
    next = next.replace(
      /\\(text|mathrm|mathbf|operatorname|textrm|textbf|texttt|mathsf|mathtt|mathit|boxed)\s*\{\s*([^{}]*?)\s*\}/g,
      "\\$1{$2}"
    );
    next = next.replace(
      /\\(text|mathrm|mathbf|operatorname|textrm|textbf|texttt|mathsf|mathtt|mathit)\{([^{}\n]{1,60})$/gm,
      "\\$1{$2}"
    );
    return next;
  }

  function countUnescapedDollars(line) {
    let count = 0;
    let escaped = false;
    for (const char of line) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char === "\\") {
        escaped = true;
        continue;
      }
      if (char === "$") count += 1;
    }
    return count;
  }

  function closeOrphanDollars(text) {
    return String(text || "").split("\n").map(line => {
      if (countUnescapedDollars(line) % 2 === 0) return line;
      const last = line.lastIndexOf("$");
      if (last < 0) return line;
      const after = line.slice(last + 1);
      if (!after.trim()) return `${line}$`;
      let end = last + 1;
      while (line[end] === " ") end += 1;
      if (line[end] === "\\") end = extendMathRun(line, texCommandEnd(line, end));
      else if (line[end]) end = extendMathRun(line, end + 1);
      if (end <= last + 1) return `${line}$`;
      if (end < line.length) return `${line.slice(0, end)}$${line.slice(end)}`;
      return `${line}$`;
    }).join("\n");
  }

  function normalizeStudyMath(source) {
    const cleaned = tidyTexCommands(
      unicodeToTex(unescapeTexBackslashes(coerceStudyMarkdown(source)))
    );
    return restoreSentenceSpacing(
      mergeSplitMathSpans(wrapBareTex(closeOrphanDollars(cleaned)))
    );
  }

  function looksLikeHeading(text, index) {
    return /^\s*#{1,4}\s/.test(text.slice(index));
  }

  function findDisplayClose(text, start, closer) {
    let index = start;
    let lines = 0;
    while (index < text.length) {
      if (text.startsWith(closer, index)) {
        return { end: index + closer.length, tex: text.slice(start, index) };
      }
      if (text[index] === "\n") {
        lines += 1;
        if (looksLikeHeading(text, index + 1) || lines > 40) {
          return { end: index, tex: text.slice(start, index) };
        }
      }
      index += 1;
    }
    return { end: text.length, tex: text.slice(start) };
  }

  function stashMath(source) {
    const slots = [];
    const store = (tex, display) => {
      const key = `@@MATH${slots.length}@@`;
      slots.push({ tex: String(tex || "").trim(), display: Boolean(display) });
      return key;
    };
    const text = String(source || "");
    let out = "";
    let index = 0;
    while (index < text.length) {
      if (text.startsWith("$$", index)) {
        const found = findDisplayClose(text, index + 2, "$$");
        out += store(found.tex, true);
        index = found.end;
        continue;
      }
      if (text.startsWith("\\[", index)) {
        const found = findDisplayClose(text, index + 2, "\\]");
        out += store(found.tex, true);
        index = found.end;
        continue;
      }
      if (text.startsWith("\\(", index)) {
        const close = text.indexOf("\\)", index + 2);
        const nl = text.indexOf("\n", index + 2);
        if (close >= 0 && (nl < 0 || close < nl + 200)) {
          out += store(text.slice(index + 2, close), false);
          index = close + 2;
          continue;
        }
      }
      if (text[index] === "$" && text[index + 1] !== "$") {
        const close = text.indexOf("$", index + 1);
        const nl = text.indexOf("\n", index + 1);
        if (close > index && (nl < 0 || close < nl) && text[close + 1] !== "$") {
          const tex = text.slice(index + 1, close);
          if (tex.trim()) out += store(tex, false);
          else out += "$$";
          index = close + 1;
          continue;
        }
        if (close > index && nl > index && close > nl && !looksLikeHeading(text, nl + 1)) {
          out += store(text.slice(index + 1, close), true);
          index = close + 1;
          continue;
        }
        let end = index + 1;
        while (text[end] === " ") end += 1;
        if (text[end] === "\\" || /[A-Za-z0-9]/.test(text[end] || "")) {
          end = text[end] === "\\"
            ? extendMathRun(text, texCommandEnd(text, end))
            : extendMathRun(text, end + 1);
          const tex = text.slice(index + 1, end);
          if (tex.trim()) {
            out += store(tex, false);
            index = end;
            continue;
          }
        }
      }
      out += text[index];
      index += 1;
    }
    return { text: out, slots };
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function inlineMarkdown(value) {
    const tokens = [];
    let text = String(value || "").replace(MATH_TOKEN_RE, match => {
      tokens.push(match);
      return `@@TOK${tokens.length - 1}@@`;
    });
    text = escapeHtml(text);
    text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
    text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    text = text.replace(/(^|[\s(])\*([^*\n]{1,48})\*(?=[\s.,;:!?)]|$)/g, (full, pre, body) => {
      if (body.includes(" ") && body.split(/\s+/).length > 4) return full;
      return `${pre}<em>${body}</em>`;
    });
    text = text.replace(/(^|[^A-Za-z0-9$\\])_([^_\s][^_\n]*?)_(?![A-Za-z0-9])/g, "$1<em>$2</em>");
    text = text.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" rel="noopener noreferrer" target="_blank">$1</a>');
    return text.replace(/@@TOK(\d+)@@/g, (_, index) => tokens[Number(index)] || "");
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

  function prepareTex(tex) {
    return tidyTexCommands(unescapeTexBackslashes(String(tex || "")
      .replace(/^\$+|\$+$/g, "")
      .replace(/Δ/g, "\\Delta")
      .replace(/δ/g, "\\delta")
      .replace(/°/g, "^{\\circ}")
      .replace(/⇌/g, "\\rightleftharpoons")));
  }

  function mathCandidates(tex) {
    const cleaned = prepareTex(tex);
    const unique = [cleaned];
    const swapped = cleaned.replace(/\\text\b/g, "\\mathrm");
    if (swapped !== cleaned) unique.push(swapped);
    const tight = cleaned.replace(/\s+/g, " ").trim();
    if (tight && tight !== cleaned) unique.push(tight);
    return unique;
  }

  function readableMathFallback(tex) {
    let next = String(tex || "");
    next = next.replace(/\\(text|mathrm|mathbf|operatorname|textrm|textbf|texttt|mathsf|mathtt|mathit)\{([^{}]*)\}/g, "$2");
    next = next.replace(/\\(land|wedge|cdot)\b/g, "∧");
    next = next.replace(/\\(lor|vee)\b/g, "∨");
    next = next.replace(/\\(neg|lnot|sim)\b/g, "¬");
    next = next.replace(/\\oplus\b/g, "⊕");
    next = next.replace(/\\otimes\b/g, "⊗");
    next = next.replace(/\\times\b/g, "×");
    next = next.replace(/\\cap\b/g, "∩");
    next = next.replace(/\\cup\b/g, "∪");
    next = next.replace(/\\in\b/g, "∈");
    next = next.replace(/\\notin\b/g, "∉");
    next = next.replace(/\\forall\b/g, "∀");
    next = next.replace(/\\exists\b/g, "∃");
    next = next.replace(/\\rightarrow\b|\\to\b|\\implies\b/g, "→");
    next = next.replace(/\\leftrightarrow\b|\\iff\b/g, "↔");
    next = next.replace(/\\leq\b/g, "≤");
    next = next.replace(/\\geq\b/g, "≥");
    next = next.replace(/\\neq\b/g, "≠");
    next = next.replace(/\\int\b/g, "∫");
    next = next.replace(/\\sum\b/g, "∑");
    next = next.replace(/\\[,;:! ]/g, " ");
    next = next.replace(/\\([A-Za-z]+)/g, "$1");
    return next.replace(/\s+/g, " ").trim() || String(tex || "").trim();
  }

  function renderKatex(tex, options) {
    return katex.renderToString(tex, {
      displayMode: options.display,
      throwOnError: false,
      strict: "ignore",
      trust: true,
      macros: KATEX_MACROS,
      minRuleThickness: 0.05,
      output: options.mathOutput
    });
  }

  function renderMathSlot(slot, options = {}) {
    const mathOutput = options.mathOutput === "mathml" ? "mathml" : "html";
    const renderOpts = { display: slot.display, mathOutput };
    if (globalThis.katex?.renderToString) {
      try {
        for (const candidate of mathCandidates(slot.tex || "")) {
          let html = renderKatex(candidate, renderOpts);
          if (html.includes("katex-error") && /\\ce\{/.test(candidate)) {
            html = renderKatex(candidate.replace(/\\ce\{([^{}]*)\}/g, (_, body) => `\\mathrm{${body}}`), renderOpts);
          }
          if (html && !html.includes("katex-error")) {
            if (mathOutput === "mathml" && slot.display) {
              html = html.replace('class="katex"', 'class="katex katex-display"');
            }
            return html;
          }
        }
      } catch (_) { /* Fall through to a readable math fallback. */ }
    }
    const tag = slot.display ? "div" : "span";
    return `<${tag} class="study-math-fallback">${escapeHtml(readableMathFallback(slot.tex || ""))}</${tag}>`;
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

  function unwrapInlineNodes(fragment) {
    let nodes = [...fragment.childNodes];
    while (nodes.length === 1 && nodes[0].nodeType === Node.ELEMENT_NODE &&
      ["P", "DIV", "H1", "H2", "H3", "H4"].includes(nodes[0].tagName)) {
      nodes = [...nodes[0].childNodes];
    }
    return nodes;
  }

  function renderStudyInline(source, options = {}) {
    const fragment = sanitizeHtml(renderStudyHtml(source, options));
    const wrap = document.createElement("span");
    wrap.className = "study-md study-md-inline";
    const nodes = unwrapInlineNodes(fragment);
    if (nodes.length) nodes.forEach(node => wrap.append(node));
    else wrap.textContent = String(source || "");
    return wrap;
  }

  function fillStudyRichText(target, source, options = {}) {
    if (!target) return;
    const text = source == null ? "" : String(source);
    target.replaceChildren();
    if (!text) return;
    if (!hasMathMarkup(text) && !hasRichMarkup(text)) {
      target.textContent = text;
      return;
    }
    target.append(renderStudyInline(text, options));
  }

  function hasMathMarkup(source) {
    const text = String(source || "");
    return /\$\$|\\\(|\\\[|(^|[^\\])\$|\\begin\{|\\frac\b|\\vec\b|\\times\b|\\cdot\b|\\sqrt\b|\\sum\b|\\int\b|\\text\b|\\land\b|\\lor\b|\\neg\b|√|ℂ|\\\\mathbb/.test(text);
  }

  function hasRichMarkup(source) {
    const text = String(source || "");
    return hasMathMarkup(text) ||
      /(?:^|\n)\s{0,3}(#{1,4}\s|[-*]\s|\d+\.\s|>\s|```)/.test(text) ||
      /\*\*[^*]+\*\*|__[^_]+__|(^|[^*])\*[^*]+\*|`[^`]+`/.test(text);
  }

  globalThis.normalizeStudyMath = normalizeStudyMath;
  globalThis.stashStudyMath = stashMath;
  globalThis.inlineStudyMarkdown = inlineMarkdown;
  globalThis.prepareStudyTex = prepareTex;
  globalThis.renderStudyMarkdown = renderStudyMarkdown;
  globalThis.renderStudyInline = renderStudyInline;
  globalThis.fillStudyRichText = fillStudyRichText;
  globalThis.renderStudyHtml = renderStudyHtml;
  globalThis.hasMathMarkup = hasMathMarkup;
  globalThis.hasRichMarkup = hasRichMarkup;
})();
