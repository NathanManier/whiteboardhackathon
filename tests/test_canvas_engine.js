"use strict";

const engine = require("../static/canvas-engine.js");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function circlePath(cx, cy, r, inner) {
  const steps = 48;
  const ring = (radius) => {
    const pts = [];
    for (let i = 0; i < steps; i++) {
      const a = (Math.PI * 2 * i) / steps;
      pts.push(`${cx + Math.cos(a) * radius} ${cy + Math.sin(a) * radius}`);
    }
    return `M ${pts[0]} L ${pts.slice(1).join(" L ")} Z`;
  };
  return inner ? `${ring(r)} ${ring(inner)}` : ring(r);
}

const oPath = circlePath(40, 40, 18, 9);
const simplified = engine.simplifyPath(oPath, 0.8, 3);
assert(engine.subpathCount(oPath) === 2, "source O has hole");
assert(engine.subpathCount(simplified) === 2, "simplified O keeps hole");
assert(engine.commandCount(simplified) >= 8, "simplified O is not a blob");

const tiny = "M 10 10 L 10.4 10 L 10.4 10.4 L 10 10.4 Z";
assert(engine.simplifyPath(tiny, 4, 3) === tiny, "tiny punctuation stays intact");

const epsilon = engine.screenSpaceEpsilon({
  bbox: { x: 0, y: 0, width: 6, height: 6 },
  sx: 1, sy: 1
}, 0.25, 2.8);
assert(epsilon < 2, `small-object epsilon must stay small, got ${epsilon}`);

const rect = { left: 100, top: 50, width: 800, height: 500 };
const camera = { x: 40, y: 20, width: 1600, height: 1000 };
const mid = { x: 500, y: 300 };
const focus = engine.screenToCanvas(mid.x, mid.y, camera, rect);
const screen = engine.canvasToScreen(focus.x, focus.y, camera, rect);
assert(Math.abs(screen.x - mid.x) < 1e-6, "canvasToScreen inverse x");
assert(Math.abs(screen.y - mid.y) < 1e-6, "canvasToScreen inverse y");

const pinched = engine.pinchCamera({
  startCamera: camera,
  startDistance: 100,
  startMidpoint: mid,
  currentDistance: 140,
  currentMidpoint: { x: 520, y: 310 },
  rect,
  zoomLatched: true,
  basis: 1600
});
const after = engine.canvasToScreen(focus.x, focus.y, pinched, rect);
assert(Math.abs(after.x - 520) < 0.02, `pinch midpoint x drifted ${after.x}`);
assert(Math.abs(after.y - 310) < 0.02, `pinch midpoint y drifted ${after.y}`);

const broken = engine.sanitizeCamera({ x: NaN, y: Infinity, width: 0, height: -4 }, rect, { basis: 1600 });
assert(Number.isFinite(broken.x) && Number.isFinite(broken.y), "sanitized pan is finite");
assert(broken.width > 0 && broken.height > 0, "sanitized zoom is positive");

const level = engine.chooseLevel({ zoom: 0.2, screenSize: 8, commandCount: 12 });
assert(level === engine.LEVEL.FULL, "small symbols stay full fidelity");

const practiceMetrics = engine.practiceCardMetrics({ width: 1600, height: 900 });
assert(practiceMetrics.width >= 500 && practiceMetrics.width <= 700, "practice width is substantial");
assert(practiceMetrics.height >= 300 && practiceMetrics.height <= 450, "practice height is substantial");
const sourceBoard = { x: 0, y: 0, width: 1600, height: 900 };
const practice = engine.placePracticeCards({
  count: 2,
  anchor: { x: 280, y: 220, width: 320, height: 180 },
  board: sourceBoard,
  card: practiceMetrics,
  obstacles: [sourceBoard]
});
assert(practice.length === 2, "two practice cards are placed");
assert(!engine.intersects(practice[0], practice[1]), "practice cards do not overlap");
assert(!engine.intersects(practice[0], sourceBoard), "practice card avoids source board");
assert(practice[1].x - (practice[0].x + practice[0].width) >= 100, "practice cards have deliberate spacing");

console.log("canvas-engine tests passed");
