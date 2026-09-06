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

assert(ctx.normalizeChemistryMarkdown("x2 + y2") === "x2 + y2",
  "ordinary undelimited math was mistaken for chemistry");
assert(ctx.normalizeChemistryMarkdown("$H_2O$") === "$H_2O$",
  "explicit chemistry LaTeX was rewritten");
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
assert(invalidNotation.includes("Notation unavailable") && !invalidNotation.includes("\\frac"),
  "invalid notation leaked raw LaTeX");

const source = fs.readFileSync(path.join(ROOT, "static", "study-render.js"), "utf8");
assert(source.includes("renderBareMathIn"), "bare LaTeX compatibility rendering is missing");
assert(source.includes("DOMPurify.sanitize"), "AI HTML is not sanitized");
assert(source.includes("trust: false"), "KaTeX trust must remain disabled");
assert(!source.includes("template.innerHTML"), "custom HTML sanitizer should not return");

console.log("ok");
