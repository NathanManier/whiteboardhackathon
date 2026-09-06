"use strict";

const pencil = require("../static/pencil-tools.js");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const caps = pencil.detectPencilCapabilities({
  PointerEvent: function PointerEvent() {},
  matchMedia: () => ({ matches: false }),
  navigator: {}
});
assert(caps.nativeSqueeze === false, "web adapter must not claim native squeeze");
assert(caps.nativeToolPicker === false, "web adapter must not claim PKToolPicker");
assert(caps.nativeHaptics === false, "web adapter must not claim native Pencil haptics");
assert(caps.nativeDoubleTap === false, "web adapter must not claim hardware double-tap");
assert(caps.nativeBarrelRoll === false, "web adapter must not claim native barrel roll");
assert(caps.implementation === "web-contextual-palette", "implementation id must stay honest");

assert(pencil.toolShortLabel("select") === "Lasso", "lasso short label");
assert(pencil.toolShortLabel("object-eraser") === "Object", "object eraser short label");
assert(pencil.canonicalizeTool("object_eraser") === "object-eraser", "object eraser alias");
assert(pencil.canonicalizeTool("lasso") === "select", "lasso maps to existing select tool");
assert(pencil.isInkTool("marker"), "marker is an ink tool");
assert(pencil.isInkTool("pencil"), "pencil is an ink tool");
assert(pencil.toolObjectType("highlighter") === "highlighter", "highlighter keeps existing object type");
assert(pencil.toolObjectType("marker") === "stroke", "marker stays on the stroke pipeline");
assert(pencil.toolUsesOpacity("pen"), "pen exposes opacity");
assert(!pencil.toolUsesOpacity("pixel-eraser"), "pixel eraser does not expose opacity");

const state = pencil.createToolState();
assert(state.tool === "pen", "default tool is pen");
assert(state.toolbarVisible === false, "default chrome is focus / canvas mode");
assert(state.byTool.pen.width === 4, "pen preset width");
assert(state.byTool.marker.opacity === 0.55, "marker is translucent");
assert(state.byTool.highlighter.opacity === 0.28, "highlighter keeps wash opacity");
assert(state.byTool.pencil.width < state.byTool.pen.width, "pencil is thinner than pen");

const restored = pencil.applyPrefs(pencil.createToolState(), {
  tool: "marker",
  byTool: { marker: { color: "#dc2626", width: 20 } }
});
assert(restored.tool === "marker", "prefs restore tool");
assert(restored.byTool.marker.color === "#dc2626", "prefs restore color");
assert(restored.byTool.marker.width === 20, "prefs restore width");

assert(pencil.effectiveStrokeWidth(10, null, 0.5) === 10, "missing pressure uses base width");
assert(pencil.effectiveStrokeWidth(10, 0, 0.5) === 10, "zero pressure uses base width");
const hard = pencil.effectiveStrokeWidth(10, 1, 0.5);
const light = pencil.effectiveStrokeWidth(10, 0.2, 0.5);
assert(hard > 10 && light < 10, "pressure sensitivity scales width when available");
assert(pencil.averagePressure([{ x: 1, y: 1 }, { x: 2, y: 2, p: 0.6 }]) === 0.6, "average ignores missing pressure");

const viewport = {
  width: 1024,
  height: 768,
  left: 0,
  top: 0,
  safe: { top: 20, right: 12, bottom: 18, left: 10 }
};
const size = { width: 280, height: 320 };
const right = pencil.placePalette({ x: 1000, y: 400 }, size, viewport);
assert(right.x + size.width <= 1024 - 12, "palette stays inside the right safe edge");
assert(right.x < 1000, "palette appears to the left near the right edge");

const top = pencil.placePalette({ x: 400, y: 24 }, size, viewport);
assert(top.y >= 20 + 12, "palette stays below the top safe inset");
assert(top.y > 24, "palette appears below a top-edge Pencil point");

const bottom = pencil.placePalette({ x: 400, y: 750 }, size, viewport);
assert(bottom.y + size.height <= 768 - 18, "palette stays above the bottom safe inset");
assert(bottom.y + size.height <= 750, "palette appears above a bottom-edge Pencil point");

const storage = {
  data: {},
  getItem(key) { return this.data[key] || null; },
  setItem(key, value) { this.data[key] = String(value); }
};
pencil.savePrefs(restored, storage);
const loaded = pencil.loadPrefs(storage);
assert(loaded.tool === "marker", "prefs persist across loads");
assert(loaded.byTool.marker.color === "#dc2626", "color persists as an editor preference");

const adapter = new pencil.PencilInteractionAdapter({ PointerEvent: function PointerEvent() {} });
let squeezed = 0;
adapter.onSqueeze(() => { squeezed += 1; });
adapter.ingestNativeEvent("squeeze", { position: { x: 10, y: 12 } });
assert(squeezed === 1, "future native bridge can fire squeeze without a fake Safari API");
assert(adapter.getPreferredAction() === "showContextualPalette", "web preferred action is the contextual palette");

console.log("pencil-tools tests passed");
