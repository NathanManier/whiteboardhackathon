"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.join(__dirname, "..");
const ctx = { console, setTimeout, clearTimeout };
ctx.globalThis = ctx;
ctx.window = ctx;
vm.createContext(ctx);

function load(relativePath) {
  vm.runInContext(fs.readFileSync(path.join(ROOT, relativePath), "utf8"), ctx);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

load("static/vendor/katex/katex.min.js");
load("static/vendor/katex/mhchem.min.js");
load("static/vendor/markdown-it/markdown-it.min.js");
load("static/vendor/markdown-it-texmath/texmath.js");
load("static/study-render.js");

const md = ctx.markdownit({ html: false, linkify: true });
md.use(ctx.texmath, {
  engine: ctx.katex,
  delimiters: ["dollars", "brackets", "beg_end"],
  katexOptions: { throwOnError: true, trust: false, strict: "ignore" }
});
const math = (tokens, index, displayMode = false) => ctx.renderStudyKatexMarkup(
  tokens[index].content,
  { display: displayMode }
);
md.renderer.rules.math_inline = (tokens, index) => math(tokens, index);
md.renderer.rules.math_inline_double = (tokens, index) => math(tokens, index, true);
md.renderer.rules.math_block = (tokens, index) => math(tokens, index, true);
md.renderer.rules.math_block_eqno = md.renderer.rules.math_block;
const render = source => md.render(ctx.normalizeChemistryMarkdown(source));

const cases = [
  "$F=ma$",
  "$$F=ma$$",
  "\\(F=ma\\)",
  "\\[F=ma\\]",
  "$\\frac{1}{2}mv^2$",
  "$\\nabla \\times \\vec{F}$",
  [
    "# Energy",
    "Use **Newton's law** $F=ma$.",
    "",
    "$$",
    "|\\vec{F}| = \\sqrt{F_x^2 + F_y^2}",
    "$$",
    "",
    "- Substitute the values."
  ].join("\n"),
  "$$\\begin{aligned}a&=b+c\\\\d&=e-f\\end{aligned}$$",
  "$$\\begin{bmatrix}a & b\\\\c & d\\end{bmatrix}$$",
  "Calculate the magnitude of $\\vec{F}=(3,4)$.",
  "Result: $x=2$. Then verify with $x^2=4$.",
  "$\\left\\{x\\in\\mathbb{R}:x\\ge 0\\right\\}$"
];

cases.forEach((source, index) => {
  const html = render(source);
  assert(html.includes("class=\"katex"), `case ${index + 1} did not produce KaTeX`);
  assert(!html.includes("$F=ma$"), `case ${index + 1} leaked dollar-delimited source`);
  assert(!html.includes("\\(F=ma\\)"), `case ${index + 1} leaked paren-delimited source`);
  assert(!html.includes("\\[F=ma\\]"), `case ${index + 1} leaked bracket-delimited source`);
});

const mixed = render(cases[6]);
assert(mixed.includes("<h1>Energy</h1>"), "heading Markdown did not render");
assert(mixed.includes("<strong>Newton's law</strong>"), "bold Markdown did not render");
assert(mixed.includes("<ul>"), "list Markdown did not render");

const currency = render("The notebook costs $5 and the calculator costs $20.");
assert(currency.includes("$5") && currency.includes("$20"), "ordinary currency was treated as math");
assert(!currency.includes("class=\"katex"), "ordinary currency produced KaTeX");

const notationMatrix = [
  "$x^2$", "$x_i$", "$\\frac{a}{b}$", "$\\sqrt{x}$",
  "$\\sum_{i=1}^{n} x_i$", "$\\int_0^1 x^2 dx$", "$\\vec{v}$",
  "$\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}$",
  "$H_2O$", "$CO_2$", "$CH_4$", "$NH_3$", "$C_6H_{12}O_6$",
  "$Na^+$", "$Cl^-$", "$Ca^{2+}$", "$SO_4^{2-}$", "$NH_4^+$",
  "$Fe^{3+}$", "$PO_4^{3-}$",
  "$H_2 + O_2 \\rightarrow H_2O$",
  "$2H_2 + O_2 \\rightarrow 2H_2O$",
  "$HCl + NaOH \\rightarrow NaCl + H_2O$",
  "$N_2 + 3H_2 \\rightleftharpoons 2NH_3$",
  "$H_2O_{(l)}$", "$CO_2_{(g)}$", "$NaCl_{(aq)}$", "$NaCl_{(s)}$",
  "$Ca(OH)_2$", "$Al_2(SO_4)_3$", "$CH_3COOH$",
  "$CuSO_4 \\cdot 5H_2O$", "${}^{14}C$", "${}^{235}U$",
  "$H-C-H$", "$C=C$", "$C\\equiv C$",
  "The reaction produces $H_2O$ and releases energy.",
  "The concentration of $H^+$ increases.",
  "The equation is $PV=nRT$.", "The acid is $H_2SO_4$.",
  "$[H^+] = 10^{-3}$", "$pH = -\\log[H^+]$",
  "$K_a = \\frac{[H^+][A^-]}{[HA]}$", "$E = mc^2$"
];
notationMatrix.forEach((source, index) => {
  const html = render(source);
  assert(html.includes("class=\"katex"), `notation matrix ${index + 1} did not render`);
});

const chemistryShorthand = [
  "H2O", "CO2", "CH4", "NH3", "C6H12O6",
  "H_2O", "Ca2+", "SO4^2-", "NH4+", "Fe3+", "PO4^3-",
  "H_2O_{(l)}", "CO_2_{(g)}", "NaCl(aq)", "NaCl(s)",
  "Ca(OH)2", "Al2(SO4)3", "CH3COOH", "{}^{14}C", "^{235}U",
  "H-C-H", "C=C", "C\\equivC", "H2+O2",
  "2H_2 + O_2 \\rightarrow 2H_2O",
  "N_2 + 3H_2 \\rightleftharpoons 2NH_3",
  "CuSO_4 \\cdot 5H_2O",
  "The acid is H2SO4 and the ion is SO4^2-."
];
chemistryShorthand.forEach((source, index) => {
  const normalized = ctx.normalizeChemistryMarkdown(source);
  const html = md.render(normalized);
  assert(normalized.includes("\\ce{") || /\\(rightarrow|rightleftharpoons|cdot|equiv)/.test(source),
    `chemistry shorthand ${index + 1} was not normalized`);
  assert(html.includes("class=\"katex"), `chemistry shorthand ${index + 1} did not render`);
});
assert(ctx.renderStudyKatexMarkup("H2O").includes("<msub>"),
  "delimited shorthand H2O did not render its subscript");
assert(ctx.renderStudyKatexMarkup("Ca2+").includes("<msup>"),
  "delimited shorthand Ca2+ did not render its ionic charge");
const ammonium = ctx.renderStudyKatexMarkup("NH4+");
assert(ammonium.includes("<msub>") && ammonium.includes("<msup>"),
  "delimited shorthand NH4+ did not render subscript and charge");

assert(ctx.normalizeChemistryMarkdown("x2 + y2") === "x2 + y2",
  "ordinary undelimited math was mistaken for chemistry");
assert(ctx.normalizeChemistryMarkdown("$H_2O$") === "$H_2O$",
  "explicit chemistry LaTeX was rewritten");
assert(ctx.normalizeChemistryMarkdown("Fluorine ($ce{F}$) and water ($ce{H2O}$).") ===
  "Fluorine ($\\ce{F}$) and water ($\\ce{H2O}$).",
  "a delimited mhchem command missing only its backslash was not repaired for display");
assert(render("Fluorine ($ce{F}$) and water ($ce{H2O}$).")
  .match(/class="katex/g)?.length >= 2,
  "repaired delimited mhchem commands did not render through KaTeX");
const repairedBoundary = ctx.normalizeChemistryMarkdown("Overview\n---### Connection Across the Lecture");
assert(repairedBoundary === "Overview\n---\n\n### Connection Across the Lecture",
  "a horizontal rule joined to a heading was not repaired for display");
assert(render("Overview\n---### Connection Across the Lecture").includes("<h3>Connection Across the Lecture</h3>"),
  "a repaired Markdown heading did not render structurally");
assert(ctx.normalizeChemistryMarkdown("`H2O`") === "`H2O`",
  "inline code was rewritten as chemistry");
assert(ctx.normalizeChemistryMarkdown("```text\nH2O\n```") === "```text\nH2O\n```",
  "fenced code was rewritten as chemistry");
assert(ctx.normalizeChemistryMarkdown("https://example.test/H2O") === "https://example.test/H2O",
  "a URL was rewritten as chemistry");
assert(render("\\ce{SO4^2-}").includes("class=\"katex"),
  "bare mhchem notation did not render");
const stateFallback = ctx.renderStudyKatexMarkup("CO_2_{(g)}");
assert(stateFallback.includes("class=\"katex") && !stateFallback.includes("study-math-error"),
  "chemical state notation did not use the mhchem fallback");
const invalidNotation = ctx.renderStudyKatexMarkup("\\frac");
assert(invalidNotation.includes("\\frac") && invalidNotation.includes("study-notation-fallback"),
  "malformed notation did not remain available as readable text");
assert(!invalidNotation.includes("Notation unavailable"),
  "malformed notation produced the removed unavailable placeholder");

const exactChemistryCases = [
  "H_2O",
  "CO_2",
  "C_6H_{12}O_6",
  "Na^+",
  "Ca^{2+}",
  "SO_4^{2-}",
  "PO_4^{3-}",
  "NH_4^+",
  "Fe^{3+}",
  "H_2 + O_2 \\rightarrow H_2O",
  "N_2 + 3H_2 \\rightleftharpoons 2NH_3",
  "H_2O_{(l)}",
  "NaCl_{(aq)}",
  "pH=-\\log[H^+]",
  "K_a=\\frac{[H^+][A^-]}{[HA]}"
];
exactChemistryCases.forEach((notation, index) => {
  const html = ctx.renderStudyKatexMarkup(notation);
  assert(html.includes("class=\"katex"), `required chemistry case ${index + 1} did not render`);
  assert(!html.includes("Notation unavailable"), `required chemistry case ${index + 1} was hidden`);
});

const readableCases = [
  ["H_2O", "H₂O"],
  ["CO_2", "CO₂"],
  ["C_6H_{12}O_6", "C₆H₁₂O₆"],
  ["Na^+", "Na⁺"],
  ["Ca^{2+}", "Ca²⁺"],
  ["SO_4^{2-}", "SO₄²⁻"],
  ["PO_4^{3-}", "PO₄³⁻"],
  ["NH_4^+", "NH₄⁺"],
  ["Fe^{3+}", "Fe³⁺"],
  ["H_2 + O_2 \\rightarrow H_2O", "H₂ + O₂ → H₂O"],
  ["N_2 + 3H_2 \\rightleftharpoons 2NH_3", "N₂ + 3H₂ ⇌ 2NH₃"],
  ["H_2O_{(l)}", "H₂O(l)"],
  ["NaCl_{(aq)}", "NaCl(aq)"],
  ["pH=-\\log[H^+]", "pH=-log[H⁺]"]
];
readableCases.forEach(([sourceNotation, expected], index) => {
  assert(ctx.readableNotationFallback(sourceNotation) === expected,
    `readable chemistry fallback ${index + 1} was not conservative and useful`);
});
assert(ctx.readableNotationFallback("Ca2+") === "Ca²⁺",
  "single-element shorthand charge was not normalized");
assert(ctx.readableNotationFallback("NH4+") === "NH₄⁺",
  "polyatomic shorthand charge was not normalized");
assert(ctx.readableNotationFallback("SO4^2-") === "SO₄²⁻",
  "ionic shorthand was not normalized");
assert(ctx.readableNotationFallback("H2O") === "H₂O",
  "plain chemistry did not receive a readable fallback");
assert(ctx.readableNotationFallback("\\ce{SO4^2-}") === "SO₄²⁻",
  "mhchem source did not receive a readable fallback");
assert(
  ctx.readableNotationFallback("K_a=\\frac{[H^+][A^-]}{[HA]}") ===
    "K_a=([H⁺][A⁻])/([HA])",
  "fraction fallback was not readable"
);

const mixedFallback = ctx.readableContentFallback(
  "The reaction\n\n$2H_2 + O_2 \\rightarrow 2H_2O$\n\nis balanced."
);
assert(mixedFallback.includes("The reaction") &&
  mixedFallback.includes("2H₂ + O₂ → 2H₂O") &&
  mixedFallback.includes("is balanced."), "mixed Markdown fallback lost surrounding prose");
const currencyFallback = ctx.readableContentFallback(
  "The notebook costs $5 and the calculator costs $20."
);
assert(currencyFallback.includes("$5") && currencyFallback.includes("$20"),
  "whole-content fallback damaged currency");
assert(ctx.readableContentFallback("Unicode water H₂O and sulfate SO₄²⁻.") ===
  "Unicode water H₂O and sulfate SO₄²⁻.", "Unicode chemistry was changed");

const originalRenderToString = ctx.katex.renderToString;
ctx.katex.renderToString = () => { throw new Error("forced renderer failure"); };
try {
  const forcedFormula = ctx.renderStudyKatexMarkup("SO_4^{2-}");
  assert(forcedFormula.includes("SO₄²⁻"), "forced chemistry failure did not use Unicode fallback");
  assert(!forcedFormula.includes("Notation unavailable"), "forced chemistry failure hid the formula");

  const forcedProblem = render("What is the charge of $SO_4^{2-}$?");
  assert(forcedProblem.includes("What is the charge of") && forcedProblem.includes("SO₄²⁻"),
    "practice problem disappeared when formula rendering failed");
  assert(!forcedProblem.includes("Notation unavailable"),
    "practice problem used the unavailable placeholder after forced failure");

  const forcedReaction = render(
    "The reaction\n\n$2H_2 + O_2 \\rightarrow 2H_2O$\n\nis balanced."
  );
  assert(forcedReaction.includes("The reaction") &&
    forcedReaction.includes("2H₂ + O₂ → 2H₂O") &&
    forcedReaction.includes("is balanced."), "mixed Markdown broke after forced renderer failure");

  [
    ["practice problem", "Balance $H_2 + O_2 \\rightarrow H_2O$."],
    ["Check My Work", "Your answer should contain $SO_4^{2-}$."],
    ["AI Explain", "The sulfate ion is $SO_4^{2-}$."],
    ["Study Guide", "Acid concentration uses $pH=-\\log[H^+]$."]
  ].forEach(([context, sourceText]) => {
    const html = render(sourceText);
    assert(html.replace(/<[^>]+>/g, "").trim(), `${context} became empty`);
    assert(!html.includes("Notation unavailable"), `${context} exposed an unavailable placeholder`);
  });

  const malformed = render("Keep this problem usable: $\\frac$.");
  assert(malformed.includes("Keep this problem usable") && malformed.includes("\\frac"),
    "malformed LaTeX removed its containing problem");
  const unsupported = render("Use $\\unsupportedcommand{H_2O}$ if needed.");
  assert(unsupported.includes("Use") && unsupported.includes("\\unsupportedcommand") &&
    unsupported.includes("H₂O"), "unsupported command did not preserve readable source");
  const escaped = ctx.renderStudyKatexMarkup("<img src=x onerror=alert(1)>");
  assert(escaped.includes("&lt;img") && !escaped.includes("<img"),
    "notation fallback did not escape untrusted source");
} finally {
  ctx.katex.renderToString = originalRenderToString;
}

const source = fs.readFileSync(path.join(ROOT, "static", "study-render.js"), "utf8");
assert(source.includes("renderBareMathIn"), "bare LaTeX compatibility rendering is missing");
assert(source.includes("DOMPurify.sanitize"), "AI HTML is not sanitized");
assert(source.includes("trust: false"), "KaTeX trust must remain disabled");
assert(!source.includes("template.innerHTML"), "custom HTML sanitizer should not return");
assert(!source.includes("Notation unavailable"), "removed notation placeholder remains in renderer");

console.log("ok");
