(() => {
  "use strict";

  /*
    Web-native Apple-Pencil-style tool model.

    This module does not implement Apple PencilKit APIs. Safari pages cannot
    create a native tool picker or receive system squeeze / double-tap
    callbacks. A future native iPad wrapper can call ingestNativeEvent() or
    post a pencil-native-bridge message to reuse this same tool state.
  */

  const PREFS_KEY = "boardlift-pencil-prefs";
  const IMPLEMENTATION = "web-contextual-palette";

  const DRAWING_TOOLS = [
    "pen",
    "marker",
    "pencil",
    "highlighter",
    "object-eraser",
    "pixel-eraser",
    "lasso",
    "select"
  ];

  const INK_TOOLS = new Set(["pen", "marker", "pencil", "highlighter"]);
  const ERASER_TOOLS = new Set(["object-eraser", "pixel-eraser"]);
  const WIDTH_TOOLS = new Set(["pen", "marker", "pencil", "highlighter", "object-eraser", "pixel-eraser"]);
  const COLOR_TOOLS = new Set(["pen", "marker", "pencil", "highlighter", "select", "lasso"]);
  const OPACITY_TOOLS = new Set(["pen", "marker", "pencil", "highlighter"]);

  const TOOL_ALIASES = {
    object_eraser: "object-eraser",
    pixel_eraser: "pixel-eraser",
    lasso: "select",
    objectEraser: "object-eraser",
    pixelEraser: "pixel-eraser"
  };

  const TOOL_LABELS = {
    pen: "Pen",
    marker: "Marker",
    pencil: "Pencil",
    highlighter: "Highlighter",
    "object-eraser": "Object eraser",
    "pixel-eraser": "Pixel eraser",
    lasso: "Lasso",
    select: "Lasso"
  };

  const TOOL_SHORT_LABELS = {
    pen: "Pen",
    marker: "Marker",
    pencil: "Pencil",
    highlighter: "Highlight",
    "object-eraser": "Object",
    "pixel-eraser": "Pixel",
    lasso: "Lasso",
    select: "Lasso"
  };

  const PALETTE_COLORS = [
    { id: "black", color: "#111827", label: "Black" },
    { id: "gray", color: "#4b5563", label: "Dark gray" },
    { id: "red", color: "#dc2626", label: "Red" },
    { id: "blue", color: "#2563eb", label: "Blue" },
    { id: "green", color: "#16a34a", label: "Green" },
    { id: "yellow", color: "#eab308", label: "Yellow" },
    { id: "orange", color: "#ea580c", label: "Orange" },
    { id: "purple", color: "#7c3aed", label: "Purple" }
  ];

  const PRESETS = {
    pen: {
      color: "#111827",
      width: 4,
      opacity: 1,
      pressureSensitivity: 0.42,
      objectType: "stroke",
      ink: "pen"
    },
    marker: {
      color: "#2563eb",
      width: 14,
      opacity: 0.55,
      pressureSensitivity: 0.12,
      objectType: "stroke",
      ink: "marker"
    },
    pencil: {
      color: "#374151",
      width: 2.4,
      opacity: 0.78,
      pressureSensitivity: 0.72,
      objectType: "stroke",
      ink: "pencil"
    },
    highlighter: {
      color: "#eab308",
      width: 18,
      opacity: 0.28,
      pressureSensitivity: 0.08,
      objectType: "highlighter",
      ink: "highlighter"
    },
    "object-eraser": {
      color: "#9ca3af",
      width: 16,
      opacity: 1,
      pressureSensitivity: 0,
      objectType: null,
      ink: "object-eraser"
    },
    "pixel-eraser": {
      color: "#dd3f32",
      width: 16,
      opacity: 1,
      pressureSensitivity: 0,
      objectType: null,
      ink: "pixel-eraser"
    },
    select: {
      color: "#111827",
      width: 4,
      opacity: 1,
      pressureSensitivity: 0,
      objectType: null,
      ink: "lasso"
    }
  };

  const WIDTH_PRESETS = {
    pen: { small: 2, medium: 4, large: 7 },
    marker: { small: 9, medium: 14, large: 22 },
    pencil: { small: 1.2, medium: 2.4, large: 4 },
    highlighter: { small: 12, medium: 18, large: 28 },
    "object-eraser": { small: 8, medium: 16, large: 28 },
    "pixel-eraser": { small: 8, medium: 16, large: 28 }
  };

  const ICONS = {
    pen: '<path d="m4.2 20 4.2-1.1 10.2-10.2a2.15 2.15 0 0 0-3-3L5.4 15.9 4.2 20Z"/><path d="m13.2 7.2 3.6 3.6"/>',
    marker: '<path d="M8 20h8"/><path d="m8.4 20 2-9.2h3.2l2 9.2"/><path d="M9.6 6.4c0-2 4.8-2 4.8 0v4.2H9.6Z"/>',
    highlighter: '<path d="m6.2 16.2 3.6-8.6h4.4l3.6 8.6"/><path d="M7.6 12.4h8.8"/><path d="M6 19.2h12"/>',
    pencil: '<path d="m14.4 4.6 5 5L8.2 20.8H3.2v-5L14.4 4.6Z"/><path d="m12.2 6.8 5 5"/><path d="M3.2 18.2 5.8 20.8"/>',
    lasso: '<path d="M7 5.2c3 2 7 2 10 0"/><path d="M6 10.2c4 2 8 2 12 0"/><path d="M7 15.2c3 2 7 2 10 0"/>',
    "object-eraser": '<path d="M5 15.2 13.1 7l4 4-8.1 8.2H5v-4Z"/><path d="m13.1 7 2.4-2.4a2 2 0 0 1 2.8 2.8L16 10.8"/>',
    "pixel-eraser": '<path d="M4.4 16.4h15.2"/><path d="m7.2 16.4 2.8-8.2h4l2.8 8.2"/><path d="M9.2 12.2h5.6"/>',
    undo: '<path d="M7.2 8.2 3.8 11.6 7.2 15"/><path d="M4.2 11.6H14a5 5 0 1 1 0 10"/>',
    redo: '<path d="M16.8 8.2 20.2 11.6 16.8 15"/><path d="M19.8 11.6H10a5 5 0 1 0 0 10"/>',
    pin: '<path d="M9.2 3.6h5.6l.8 6.2 2.2 2.4H6.2l2.2-2.4L9.2 3.6Z"/><path d="M12 12.2v8.2"/>',
    tools: '<path d="M8.4 4.8h7.2v3.2H8.4z"/><path d="M5.6 11.2h12.8v3.2H5.6z"/><path d="M8.4 17.6h7.2v3.2H8.4z"/>',
    focus: '<path d="M5 9V5h4"/><path d="M15 5h4v4"/><path d="M19 15v4h-4"/><path d="M9 19H5v-4"/>'
  };

  function canonicalizeTool(tool) {
    if (!tool) return "pen";
    const mapped = TOOL_ALIASES[tool] || tool;
    return DRAWING_TOOLS.includes(mapped) ? mapped : "pen";
  }

  function isInkTool(tool) {
    return INK_TOOLS.has(canonicalizeTool(tool));
  }

  function isEraserTool(tool) {
    return ERASER_TOOLS.has(canonicalizeTool(tool));
  }

  function toolUsesColor(tool) {
    return COLOR_TOOLS.has(canonicalizeTool(tool));
  }

  function toolUsesOpacity(tool) {
    return OPACITY_TOOLS.has(canonicalizeTool(tool));
  }

  function toolUsesWidth(tool) {
    return WIDTH_TOOLS.has(canonicalizeTool(tool));
  }

  function toolLabel(tool) {
    return TOOL_LABELS[canonicalizeTool(tool)] || "Tool";
  }

  function toolShortLabel(tool) {
    const id = canonicalizeTool(tool);
    return TOOL_SHORT_LABELS[id] || TOOL_LABELS[id] || "Tool";
  }

  function toolPreset(tool) {
    const id = canonicalizeTool(tool);
    return PRESETS[id] || PRESETS.pen;
  }

  function toolObjectType(tool) {
    return toolPreset(tool).objectType || "stroke";
  }

  function cloneConfig(config) {
    return JSON.parse(JSON.stringify(config));
  }

  function createToolState(overrides = {}) {
    const byTool = {};
    Object.keys(PRESETS).forEach(tool => {
      const preset = PRESETS[tool];
      byTool[tool] = {
        color: preset.color,
        width: preset.width,
        opacity: preset.opacity,
        pressureSensitivity: preset.pressureSensitivity
      };
    });
    const state = {
      tool: "pen",
      byTool,
      toolbarVisible: false,
      autoHideToolbar: false
    };
    return applyPrefs(state, overrides);
  }

  function applyPrefs(state, prefs = {}) {
    const next = state || createToolState();
    if (prefs.tool) next.tool = canonicalizeTool(prefs.tool);
    if (typeof prefs.toolbarVisible === "boolean") next.toolbarVisible = prefs.toolbarVisible;
    if (typeof prefs.autoHideToolbar === "boolean") next.autoHideToolbar = prefs.autoHideToolbar;
    const source = prefs.byTool || {};
    Object.keys(source).forEach(key => {
      const tool = canonicalizeTool(key);
      if (!next.byTool[tool]) return;
      const incoming = source[key] || {};
      if (typeof incoming.color === "string" && /^#[0-9A-Fa-f]{6}$/.test(incoming.color)) {
        next.byTool[tool].color = incoming.color.toLowerCase();
      }
      if (Number.isFinite(Number(incoming.width))) {
        next.byTool[tool].width = Math.min(48, Math.max(0.8, Number(incoming.width)));
      }
      if (Number.isFinite(Number(incoming.opacity))) {
        next.byTool[tool].opacity = Math.min(1, Math.max(0.08, Number(incoming.opacity)));
      }
      if (Number.isFinite(Number(incoming.pressureSensitivity))) {
        next.byTool[tool].pressureSensitivity = Math.min(1, Math.max(0, Number(incoming.pressureSensitivity)));
      }
    });
    return next;
  }

  function serializePrefs(state) {
    return {
      tool: canonicalizeTool(state?.tool),
      toolbarVisible: Boolean(state?.toolbarVisible),
      autoHideToolbar: Boolean(state?.autoHideToolbar),
      byTool: cloneConfig(state?.byTool || {})
    };
  }

  function loadPrefs(storage) {
    const store = storage || (typeof localStorage !== "undefined" ? localStorage : null);
    if (!store) return createToolState();
    try {
      const raw = store.getItem(PREFS_KEY);
      if (!raw) return createToolState();
      return applyPrefs(createToolState(), JSON.parse(raw));
    } catch (_) {
      return createToolState();
    }
  }

  function savePrefs(state, storage) {
    const store = storage || (typeof localStorage !== "undefined" ? localStorage : null);
    if (!store) return false;
    try {
      store.setItem(PREFS_KEY, JSON.stringify(serializePrefs(state)));
      return true;
    } catch (_) {
      return false;
    }
  }

  function detectPointerCapabilities(win = globalThis) {
    const PointerEventCtor = win.PointerEvent;
    const proto = PointerEventCtor && PointerEventCtor.prototype;
    let probe = null;
    try {
      probe = typeof PointerEventCtor === "function" ? new PointerEventCtor("pointermove") : null;
    } catch (_) {
      probe = null;
    }
    const has = name => Boolean(probe && name in probe) || Boolean(proto && name in proto);
    const media = query => {
      try {
        return Boolean(win.matchMedia?.(query)?.matches);
      } catch (_) {
        return false;
      }
    };
    return {
      pointerEvents: typeof PointerEventCtor === "function",
      penPointerType: typeof PointerEventCtor === "function",
      coalescedEvents: typeof proto?.getCoalescedEvents === "function",
      predictedEvents: typeof proto?.getPredictedEvents === "function",
      pressure: has("pressure"),
      tiltX: has("tiltX"),
      tiltY: has("tiltY"),
      twistProperty: has("twist"),
      altitudeAngle: has("altitudeAngle"),
      azimuthAngle: has("azimuthAngle"),
      hoverMedia: media("(hover: hover)"),
      hover: false,
      vibration: typeof win.navigator?.vibrate === "function"
    };
  }

  function detectPencilCapabilities(win = globalThis) {
    return {
      ...detectPointerCapabilities(win),
      nativeSqueeze: false,
      nativeToolPicker: false,
      nativeHaptics: false,
      nativeDoubleTap: false,
      nativeBarrelRoll: false,
      implementation: IMPLEMENTATION
    };
  }

  function effectiveStrokeWidth(baseWidth, pressure, sensitivity) {
    const base = Number(baseWidth);
    const width = Number.isFinite(base) ? base : 4;
    const amount = Number(sensitivity);
    if (!Number.isFinite(amount) || amount <= 0) return width;
    const raw = Number(pressure);
    if (!Number.isFinite(raw) || raw <= 0) return width;
    const t = Math.min(1, Math.max(0, raw));
    return Math.max(0.6, width * (1 + (t - 0.5) * 2 * amount));
  }

  function averagePressure(points) {
    if (!Array.isArray(points) || !points.length) return null;
    let total = 0;
    let count = 0;
    points.forEach(point => {
      const value = Number(point?.p ?? point?.pressure);
      if (Number.isFinite(value) && value > 0) {
        total += value;
        count += 1;
      }
    });
    return count ? total / count : null;
  }

  function viewportInsets(win = globalThis) {
    const root = win.document?.documentElement;
    const style = root && win.getComputedStyle ? win.getComputedStyle(root) : null;
    const read = name => {
      const raw = style?.getPropertyValue(name);
      const value = Number.parseFloat(raw);
      return Number.isFinite(value) ? value : 0;
    };
    return {
      top: read("--safe-top") || 0,
      right: read("--safe-right") || 0,
      bottom: read("--safe-bottom") || 0,
      left: read("--safe-left") || 0
    };
  }

  function readSafeArea(win = globalThis) {
    const vv = win.visualViewport;
    const fallback = {
      top: 0,
      right: 0,
      bottom: 0,
      left: 0
    };
    if (!win.document) return fallback;
    try {
      const probe = win.document.createElement("div");
      probe.style.cssText = [
        "position:fixed",
        "top:0",
        "left:0",
        "width:0",
        "height:0",
        "padding-top:env(safe-area-inset-top, 0px)",
        "padding-right:env(safe-area-inset-right, 0px)",
        "padding-bottom:env(safe-area-inset-bottom, 0px)",
        "padding-left:env(safe-area-inset-left, 0px)",
        "visibility:hidden",
        "pointer-events:none"
      ].join(";");
      win.document.documentElement.append(probe);
      const styles = win.getComputedStyle(probe);
      const insets = {
        top: Number.parseFloat(styles.paddingTop) || 0,
        right: Number.parseFloat(styles.paddingRight) || 0,
        bottom: Number.parseFloat(styles.paddingBottom) || 0,
        left: Number.parseFloat(styles.paddingLeft) || 0
      };
      probe.remove();
      return insets;
    } catch (_) {
      return fallback;
    }
  }

  function currentViewport(win = globalThis) {
    const vv = win.visualViewport;
    const width = vv?.width || win.innerWidth || 1024;
    const height = vv?.height || win.innerHeight || 768;
    const left = vv?.offsetLeft || 0;
    const top = vv?.offsetTop || 0;
    return {
      width,
      height,
      left,
      top,
      safe: readSafeArea(win)
    };
  }

  function boxOverlap(a, b) {
    return a.x < b.x + b.width && a.x + a.width > b.x &&
      a.y < b.y + b.height && a.y + a.height > b.y;
  }

  function clampBox(x, y, size, bounds) {
    const width = size.width;
    const height = size.height;
    const nextX = Math.min(bounds.right - width, Math.max(bounds.left, x));
    const nextY = Math.min(bounds.bottom - height, Math.max(bounds.top, y));
    return { x: nextX, y: nextY };
  }

  function placePalette(anchor, size, viewport, avoid = []) {
    const point = {
      x: Number(anchor?.x) || 0,
      y: Number(anchor?.y) || 0
    };
    const width = Math.max(160, Number(size?.width) || 280);
    const height = Math.max(120, Number(size?.height) || 300);
    const view = viewport || { width: 1024, height: 768, left: 0, top: 0, safe: {} };
    const pad = 12;
    const gap = 28;
    const safe = view.safe || {};
    const bounds = {
      left: (view.left || 0) + (safe.left || 0) + pad,
      top: (view.top || 0) + (safe.top || 0) + pad,
      right: (view.left || 0) + view.width - (safe.right || 0) - pad,
      bottom: (view.top || 0) + view.height - (safe.bottom || 0) - pad
    };
    const pointBox = {
      x: point.x - 18,
      y: point.y - 18,
      width: 36,
      height: 36
    };
    const obstacles = [pointBox, ...avoid.filter(Boolean)];
    const candidates = [
      { x: point.x + gap, y: point.y - height - gap },
      { x: point.x - width - gap, y: point.y - height - gap },
      { x: point.x + gap, y: point.y + gap },
      { x: point.x - width - gap, y: point.y + gap },
      { x: point.x - width / 2, y: point.y - height - gap },
      { x: point.x - width / 2, y: point.y + gap }
    ];
    if (point.x > (view.left || 0) + view.width * 0.72) {
      candidates.unshift({ x: point.x - width - gap, y: point.y - height / 2 });
    }
    if (point.y < (view.top || 0) + view.height * 0.22) {
      candidates.unshift({ x: point.x - width / 2, y: point.y + gap });
    }
    if (point.y > (view.top || 0) + view.height * 0.78) {
      candidates.unshift({ x: point.x - width / 2, y: point.y - height - gap });
    }

    let best = null;
    let bestScore = -Infinity;
    candidates.forEach(candidate => {
      const placed = clampBox(candidate.x, candidate.y, { width, height }, bounds);
      const box = { x: placed.x, y: placed.y, width, height };
      let score = 80;
      if (boxOverlap(box, pointBox)) score -= 140;
      obstacles.forEach(obstacle => {
        if (obstacle !== pointBox && boxOverlap(box, obstacle)) score -= 90;
      });
      const overflowX = Math.max(0, bounds.left - box.x) + Math.max(0, box.x + width - bounds.right);
      const overflowY = Math.max(0, bounds.top - box.y) + Math.max(0, box.y + height - bounds.bottom);
      score -= overflowX + overflowY;
      const dx = (box.x + width / 2) - point.x;
      const dy = (box.y + height / 2) - point.y;
      score -= Math.hypot(dx, dy) * 0.04;
      if (score > bestScore) {
        bestScore = score;
        best = placed;
      }
    });
    return best || clampBox(point.x + gap, point.y + gap, { width, height }, bounds);
  }

  class PencilInteractionAdapter {
    constructor(win = globalThis) {
      this.win = win;
      this.capabilities = detectPencilCapabilities(win);
      this.preferredAction = "showContextualPalette";
      this._squeeze = new Set();
      this._doubleTap = new Set();
      this._hover = null;
      this._lastPen = null;
      this._twist = null;
      this._onOpen = null;
      this._onClose = null;
    }

    openPalette(position) {
      this._onOpen?.(position || this.getLastPenPosition());
    }

    closePalette() {
      this._onClose?.();
    }

    getPreferredAction() {
      return this.preferredAction;
    }

    onSqueeze(callback) {
      if (typeof callback !== "function") return () => {};
      this._squeeze.add(callback);
      return () => this._squeeze.delete(callback);
    }

    onDoubleTap(callback) {
      if (typeof callback !== "function") return () => {};
      this._doubleTap.add(callback);
      return () => this._doubleTap.delete(callback);
    }

    getHoverPose() {
      return this._hover;
    }

    getLastPenPosition() {
      return this._lastPen;
    }

    getBarrelRoll() {
      return this._twist;
    }

    notePenPose(event) {
      if (!event || event.pointerType !== "pen") return;
      const pose = {
        x: event.clientX,
        y: event.clientY,
        pressure: Number(event.pressure),
        tiltX: Number(event.tiltX),
        tiltY: Number(event.tiltY),
        twist: Number(event.twist),
        altitudeAngle: Number(event.altitudeAngle),
        azimuthAngle: Number(event.azimuthAngle),
        buttons: event.buttons,
        hovering: event.buttons === 0
      };
      this._lastPen = { x: pose.x, y: pose.y };
      if (pose.hovering) {
        this._hover = pose;
        this.capabilities.hover = true;
      }
      if (Number.isFinite(pose.twist)) this._twist = pose.twist;
    }

    bindHost(handlers = {}) {
      this._onOpen = handlers.openPalette || null;
      this._onClose = handlers.closePalette || null;
    }

    ingestNativeEvent(kind, detail = {}) {
      if (kind === "squeeze") this._squeeze.forEach(callback => callback(detail));
      if (kind === "doubleTap" || kind === "double-tap") {
        this._doubleTap.forEach(callback => callback(detail));
      }
      if (kind === "hover" && detail) {
        this._hover = detail;
        this.capabilities.hover = true;
      }
      if (kind === "preferredAction" && typeof detail.action === "string") {
        this.preferredAction = detail.action;
      }
    }
  }

  function svgIcon(name) {
    return `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ""}</svg>`;
  }

  function closestWidthKey(tool, width) {
    const presets = WIDTH_PRESETS[canonicalizeTool(tool)];
    if (!presets) return "";
    return Object.entries(presets).sort((a, b) => (
      Math.abs(a[1] - width) - Math.abs(b[1] - width)
    ))[0]?.[0] || "";
  }

  function buildPalette(root) {
    if (!root) return null;
    root.className = "pencil-palette";
    root.setAttribute("role", "dialog");
    root.setAttribute("aria-label", "Pencil tools");
    root.setAttribute("aria-hidden", "true");
    root.innerHTML = `
      <div class="pencil-palette-inner">
        <div class="palette-tools" role="toolbar" aria-label="Drawing tools">
          ${["pen", "marker", "highlighter", "pencil", "select", "object-eraser", "pixel-eraser"].map(tool => `
            <button type="button" class="palette-tool" data-tool="${tool}"
              aria-label="${toolLabel(tool)}" title="${toolLabel(tool)}" aria-pressed="false">
              ${svgIcon(tool === "select" ? "lasso" : tool)}
              <span class="palette-tool-label">${toolShortLabel(tool)}</span>
            </button>
          `).join("")}
        </div>
        <div class="palette-preview" aria-hidden="true">
          <svg viewBox="0 0 200 36" class="palette-preview-stroke" preserveAspectRatio="xMidYMid meet">
            <path d="M14 18 C 50 12, 78 24, 108 18 S 158 14, 186 18"></path>
          </svg>
        </div>
        <div class="palette-colors" role="group" aria-label="Colors">
          ${PALETTE_COLORS.map(item => `
            <button type="button" class="palette-color" data-color="${item.color}"
              style="--chip:${item.color}" aria-label="${item.label}" title="${item.label}"
              aria-pressed="false"></button>
          `).join("")}
          <label class="palette-custom-color" title="Custom color">
            <span class="visually-hidden">Custom color</span>
            <input id="palette-custom-color" type="color" value="#111827" aria-label="Custom color">
          </label>
        </div>
        <div class="palette-widths" role="group" aria-label="Stroke width">
          <button type="button" class="palette-width" data-width-preset="small" aria-label="Small stroke" title="Small">
            <span class="width-swatch" data-size="s"></span>
          </button>
          <button type="button" class="palette-width" data-width-preset="medium" aria-label="Medium stroke" title="Medium">
            <span class="width-swatch" data-size="m"></span>
          </button>
          <button type="button" class="palette-width" data-width-preset="large" aria-label="Large stroke" title="Large">
            <span class="width-swatch" data-size="l"></span>
          </button>
          <label class="palette-slider">
            <span class="visually-hidden">Stroke width</span>
            <input id="palette-width-slider" type="range" min="1" max="36" step="0.2" value="4" aria-label="Stroke width">
          </label>
        </div>
        <label class="palette-slider palette-opacity">
          <span>Opacity</span>
          <input id="palette-opacity-slider" type="range" min="0.08" max="1" step="0.02" value="1" aria-label="Opacity">
        </label>
        <div class="palette-history">
          <button type="button" class="palette-history-button" data-history="undo" aria-label="Undo" title="Undo" disabled>
            ${svgIcon("undo")}<span>Undo</span>
          </button>
          <button type="button" class="palette-history-button" data-history="redo" aria-label="Redo" title="Redo" disabled>
            ${svgIcon("redo")}<span>Redo</span>
          </button>
        </div>
      </div>
    `;
    return root;
  }

  function buildToolChip(root) {
    if (!root) return null;
    root.className = "pencil-tool-chip";
    root.type = root.tagName === "BUTTON" ? "button" : root.type;
    root.setAttribute("aria-label", "Open Pencil tools");
    root.setAttribute("title", "Pencil tools");
    root.innerHTML = `${svgIcon("pen")}<span class="chip-label">Tools</span>`;
    return root;
  }

  function syncPalette(root, snapshot = {}) {
    if (!root) return;
    const tool = canonicalizeTool(snapshot.tool);
    const config = snapshot.config || toolPreset(tool);
    root.querySelectorAll(".palette-tool").forEach(button => {
      const active = canonicalizeTool(button.dataset.tool) === tool;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
    root.querySelectorAll(".palette-color").forEach(button => {
      const active = (button.dataset.color || "").toLowerCase() === String(config.color || "").toLowerCase();
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
    const custom = root.querySelector("#palette-custom-color");
    if (custom && config.color) custom.value = config.color;
    const widthKey = closestWidthKey(tool, config.width);
    root.querySelectorAll(".palette-width").forEach(button => {
      button.classList.toggle("is-active", button.dataset.widthPreset === widthKey);
    });
    const widthSlider = root.querySelector("#palette-width-slider");
    if (widthSlider && Number.isFinite(Number(config.width))) {
      widthSlider.value = String(config.width);
    }
    const opacityRow = root.querySelector(".palette-opacity");
    if (opacityRow) opacityRow.hidden = !toolUsesOpacity(tool);
    const opacitySlider = root.querySelector("#palette-opacity-slider");
    if (opacitySlider && Number.isFinite(Number(config.opacity))) {
      opacitySlider.value = String(config.opacity);
    }
    const colors = root.querySelector(".palette-colors");
    if (colors) colors.hidden = !toolUsesColor(tool);
    const widths = root.querySelector(".palette-widths");
    if (widths) widths.hidden = !toolUsesWidth(tool);
    const preview = root.querySelector(".palette-preview-stroke path");
    if (preview) {
      const visual = Math.max(2, Math.min(7.5, (Number(config.width) || 4) * 0.42));
      preview.setAttribute("stroke", config.color || "#111827");
      preview.setAttribute("stroke-width", String(visual));
      preview.setAttribute("stroke-opacity", String(config.opacity ?? 1));
      preview.setAttribute("data-ink", toolPreset(tool).ink || tool);
    }
    root.querySelectorAll("[data-history='undo']").forEach(button => {
      button.disabled = !snapshot.canUndo;
    });
    root.querySelectorAll("[data-history='redo']").forEach(button => {
      button.disabled = !snapshot.canRedo;
    });
  }

  function syncToolChip(root, snapshot = {}) {
    if (!root) return;
    const tool = canonicalizeTool(snapshot.tool);
    const config = snapshot.config || toolPreset(tool);
    root.innerHTML = `${svgIcon(tool === "select" ? "lasso" : tool)}<span class="chip-label">${toolLabel(tool)}</span>`;
    root.style.setProperty("--chip-ink", config.color || "#111827");
    root.setAttribute("aria-label", `Open Pencil tools, current tool ${toolLabel(tool)}`);
  }

  const api = {
    PREFS_KEY,
    IMPLEMENTATION,
    DRAWING_TOOLS,
    INK_TOOLS,
    PRESETS,
    PALETTE_COLORS,
    WIDTH_PRESETS,
    ICONS,
    canonicalizeTool,
    isInkTool,
    isEraserTool,
    toolUsesColor,
    toolUsesOpacity,
    toolUsesWidth,
    toolLabel,
    toolShortLabel,
    toolPreset,
    toolObjectType,
    createToolState,
    applyPrefs,
    serializePrefs,
    loadPrefs,
    savePrefs,
    detectPencilCapabilities,
    PencilInteractionAdapter,
    effectiveStrokeWidth,
    averagePressure,
    placePalette,
    currentViewport,
    readSafeArea,
    viewportInsets,
    svgIcon,
    buildPalette,
    buildToolChip,
    syncPalette,
    syncToolChip,
    closestWidthKey
  };

  globalThis.PencilTools = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})();
