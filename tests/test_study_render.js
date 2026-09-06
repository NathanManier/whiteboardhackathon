"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ctx = { console };
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(
  fs.readFileSync(path.join(__dirname, "..", "static", "study-render.js"), "utf8"),
  ctx
);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const sample = `# Lecture Study Guide

## 1. What This Lecture Covered
Trigonometric integrals and Gibbs free energy.

## 4. Important Equations
$$
\\int u \\, dv = uv - \\int v \\, du
$$

$K_w = K_a \\cdot K_b = 1.0 \\times 10^{-14}$

$\\Delta G = \\Delta G^{\\circ} + RT \\ln Q$

$\\text{H}_3\\text{PO}_4$ stepwise dissociation.

$$
\\sqrt{a^2 - x^2}, \\quad x = a \\sin\\theta
$$

Unclosed display should not eat the next heading:
$$
\\int \\sec\\theta \\, d\\theta
## 5. Worked Examples
Keep this heading.
`;

const normalized = ctx.normalizeStudyMath(sample);
const stashed = ctx.stashStudyMath(normalized);

assert(normalized.includes("\\int"), "normalized should keep integrals");
assert(normalized.includes("\\Delta G"), "normalized should keep Gibbs delta");
assert(!/K<em>/.test(normalized), "K_w should not be italicized in normalize");

const headingSurvived = stashed.text.split("\n").some(line => line.startsWith("## 5. Worked Examples"));
assert(headingSurvived, `heading after unclosed $$ was swallowed:\n${stashed.text}`);

const mathTex = stashed.slots.map(slot => slot.tex).join("\n");
assert(mathTex.includes("\\int"), `integrals should be stashed, got:\n${mathTex}`);
assert(mathTex.includes("\\Delta G") || mathTex.includes("\\ln Q"), `Gibbs should be stashed, got:\n${mathTex}`);
assert(mathTex.includes("H") && mathTex.includes("PO"), `phosphoric acid should be stashed, got:\n${mathTex}`);
assert(!stashed.text.includes("## 5") || headingSurvived, "worked examples heading missing");

const chemistryLine = ctx.normalizeStudyMath("The pair is K_w = K_a \\cdot K_b in water.");
assert(!chemistryLine.includes("<em>"), "markdown italic should not run in normalize");
assert(chemistryLine.includes("$"), "chemistry equation should be wrapped");

const gibbs = ctx.normalizeStudyMath("Nonstandard free energy: \\Delta G = \\Delta G^{\\circ} + RT \\ln Q");
assert(
  /\$\\Delta G = \\Delta G\^?\{\\circ\} \+ RT \\ln Q\$/.test(gibbs) ||
    gibbs.includes("$\\Delta G = \\Delta G^{\\circ} + RT \\ln Q$") ||
    /\\Delta G = \\Delta G/.test(gibbs) && gibbs.includes("$") && !gibbs.includes("$\\Delta$ G"),
  `Gibbs should wrap as one formula, got: ${gibbs}`
);

const ibp = ctx.normalizeStudyMath("Integration by parts: \\int u \\, dv = uv - \\int v \\, du");
assert(
  ibp.includes("$") && ibp.includes("\\int u") && !ibp.includes("$\\int$ u"),
  `IBP should wrap as one formula, got: ${ibp}`
);

const doubled = ctx.prepareStudyTex("\\int u \\\\, dv = uv - \\int v \\\\, du");
assert(
  doubled.includes("\\,") && !doubled.includes("\\\\,"),
  `thin space should be a single backslash, got: ${JSON.stringify(doubled)}`
);

const glued = ctx.normalizeStudyMath("set x = a \\sin\\theta.*After integrating keep the triangle.");
assert(
  glued.includes("After") && !glued.includes("theta.*After") && !glued.includes("$.After"),
  `should keep a space before After, got: ${glued}`
);

const longItalic = ctx.inlineStudyMarkdown("*After integrating in terms of theta, use a right-triangle setup to convert back to x.*");
assert(!longItalic.includes("<em>"), `long sentence should stay roman, got: ${longItalic}`);

const shortItalic = ctx.inlineStudyMarkdown("This is *not* true.");
assert(shortItalic.includes("<em>not</em>"), `short emphasis should still italicize, got: ${shortItalic}`);

const orphanText = ctx.normalizeStudyMath("Let $\\text{F} denote false.");
assert(
  orphanText.includes("$\\text{F}$") || /\$\\text\{F\}\$/.test(orphanText),
  `unclosed $\\text{F} should be closed, got: ${orphanText}`
);
const orphanStash = ctx.stashStudyMath(orphanText);
assert(
  orphanStash.slots.some(slot => /\\text\{F\}/.test(slot.tex)),
  `\\text{F} should be stashed, got ${JSON.stringify(orphanStash)}`
);
assert(
  !/\$\\text/.test(orphanStash.text),
  `raw $\\text should not remain, got: ${orphanStash.text}`
);

const spacedText = ctx.normalizeStudyMath("The flag is \\text { F } after the op.");
assert(
  /\\text\{F\}/.test(spacedText) || /\\text\{ F \}/.test(spacedText),
  `\\text { F } should tidy, got: ${spacedText}`
);

const booleanLine = ctx.stashStudyMath(ctx.normalizeStudyMath("$\\text{F} \\land \\text{T}$ means false AND true."));
assert(booleanLine.slots.length >= 1, "boolean line should stash math");
assert(!booleanLine.text.includes("$\\text"), `boolean raw dollar leftover: ${booleanLine.text}`);

console.log("ok");
