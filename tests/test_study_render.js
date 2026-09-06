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
load("static/vendor/markdown-it/markdown-it.min.js");
load("static/vendor/markdown-it-texmath/texmath.js");

const md = ctx.markdownit({ html: false, linkify: true });
md.use(ctx.texmath, {
  engine: ctx.katex,
  delimiters: ["dollars", "brackets", "beg_end"],
  katexOptions: { throwOnError: true, trust: false, strict: "ignore" }
});
const math = (tokens, index, displayMode = false) => ctx.katex.renderToString(
  tokens[index].content,
  { displayMode, throwOnError: true, trust: false, strict: "ignore" }
);
md.renderer.rules.math_inline = (tokens, index) => math(tokens, index);
md.renderer.rules.math_inline_double = (tokens, index) => math(tokens, index, true);
md.renderer.rules.math_block = (tokens, index) => math(tokens, index, true);
md.renderer.rules.math_block_eqno = md.renderer.rules.math_block;

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
  const html = md.render(source);
  assert(html.includes("class=\"katex"), `case ${index + 1} did not produce KaTeX`);
  assert(!html.includes("$F=ma$"), `case ${index + 1} leaked dollar-delimited source`);
  assert(!html.includes("\\(F=ma\\)"), `case ${index + 1} leaked paren-delimited source`);
  assert(!html.includes("\\[F=ma\\]"), `case ${index + 1} leaked bracket-delimited source`);
});

const mixed = md.render(cases[6]);
assert(mixed.includes("<h1>Energy</h1>"), "heading Markdown did not render");
assert(mixed.includes("<strong>Newton's law</strong>"), "bold Markdown did not render");
assert(mixed.includes("<ul>"), "list Markdown did not render");

const currency = md.render("The notebook costs $5 and the calculator costs $20.");
assert(currency.includes("$5") && currency.includes("$20"), "ordinary currency was treated as math");
assert(!currency.includes("class=\"katex"), "ordinary currency produced KaTeX");

const source = fs.readFileSync(path.join(ROOT, "static", "study-render.js"), "utf8");
assert(source.includes("renderBareMathIn"), "bare LaTeX compatibility rendering is missing");
assert(source.includes("DOMPurify.sanitize"), "AI HTML is not sanitized");
assert(source.includes("trust: false"), "KaTeX trust must remain disabled");
assert(!source.includes("template.innerHTML"), "custom HTML sanitizer should not return");

console.log("ok");
