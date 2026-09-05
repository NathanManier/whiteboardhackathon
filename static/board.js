(() => {
  "use strict";

  const NS = "http://www.w3.org/2000/svg";
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const app = $("#board-app");
  if (!app) return;

  const embedded = (() => {
    try { return JSON.parse($("#board-data")?.textContent || "{}"); }
    catch (error) { console.warn("Invalid embedded board data", error); return {}; }
  })();
  const pathMatch = location.pathname.match(/\/board\/([^/]+)/);
  const boardId = app.dataset.boardId || embedded.id || embedded.board_id ||
    (pathMatch ? decodeURIComponent(pathMatch[1]) : "");
  const boardRoute = boardId ? `/board/${encodeURIComponent(boardId)}` : location.pathname;
  const editorApi = `/api/boards/${encodeURIComponent(boardId)}/editor`;
  const HISTORY_LIMIT = 80;
  const MIN_ZOOM = 0.08;
  const MAX_ZOOM = 24;

  const assetAliases = {
    original: ["original", "original_url", "input", "source"],
    corrected: ["corrected", "corrected_url", "warped", "rectified"],
    enhanced: ["enhanced", "enhanced_url", "master", "master_url"],
    digitized: ["digitized", "digitized_url", "svg_raster", "rendered_svg"],
    professor_svg: ["svg", "professor_svg", "vectors"],
    confidence: ["confidence", "confidence_url", "confidence_map", "detection"],
    ink_mask: ["ink_mask", "mask", "mask_url", "combined_mask"],
    black_mask: ["black_mask", "mask_black"],
    red_mask: ["red_mask", "mask_red"],
    blue_mask: ["blue_mask", "mask_blue"],
    green_mask: ["green_mask", "mask_green"],
    svg_raster: ["svg_raster", "digitized", "digitized_url", "rendered_svg"],
    master_vs_svg: ["master_vs_svg", "comparison", "comparison_url", "overlay", "validation"]
  };

  const state = {
    data: {},
    width: 1600,
    height: 900,
    revision: 0,
    camera: { x: 0, y: 0, width: 1600, height: 900 },
    objects: [],
    selected: new Set(),
    tool: "select",
    color: "#183153",
    size: 4,
    history: [],
    future: [],
    interaction: null,
    pointers: new Map(),
    spaceDown: false,
    dirty: false,
    saveTimer: 0,
    saving: false,
    saveAgain: false,
    importedMarkup: "",
    masterUrl: ""
  };

  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const clone = value => JSON.parse(JSON.stringify(value));
  const svgEl = (name, attributes = {}) => {
    const node = document.createElementNS(NS, name);
    Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, String(value)));
    return node;
  };
  const uid = prefix => {
    const random = globalThis.crypto?.randomUUID?.() ||
      `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    return `${prefix}-${random}`;
  };

  function toast(message, isError = false) {
    const element = $("#toast");
    element.textContent = message;
    element.style.background = isError ? "#9b321f" : "";
    element.hidden = false;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { element.hidden = true; }, 3000);
  }

  function setSaveStatus(message) {
    $("#save-status").textContent = message;
  }

  function asUrl(value) {
    if (!value || typeof value !== "string") return "";
    if (/^(https?:|data:|blob:|\/)/i.test(value)) return value;
    return boardId ? `/boards/${encodeURIComponent(boardId)}/${value.replace(/^\.?\//, "")}` : value;
  }

  function findAsset(kind) {
    const sources = [state.data.assets, state.data.files, state.data.outputs, state.data];
    for (const source of sources) {
      if (!source || typeof source !== "object") continue;
      for (const key of assetAliases[kind] || [kind]) {
        const value = source[key];
        if (typeof value === "string") return asUrl(value);
        if (value && typeof value === "object") {
          const nested = value.url || value.path || value.filename;
          if (nested) return asUrl(nested);
        }
      }
    }
    return "";
  }

  async function requestJSON(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: { Accept: "application/json", ...(options.headers || {}) }
    });
    if (!response.ok) {
      const error = new Error(`Server returned ${response.status}`);
      error.status = response.status;
      throw error;
    }
    return response.json();
  }

  function normalizeBoard(raw) {
    const board = raw?.board && typeof raw.board === "object" ? { ...raw, ...raw.board } : (raw || {});
    const width = Number(board.master_width || board.width || board.dimensions?.width);
    const height = Number(board.master_height || board.height || board.dimensions?.height);
    if (width > 0) state.width = width;
    if (height > 0) state.height = height;
    return board;
  }

  function legacyStroke(stroke) {
    if (!stroke) return null;
    const points = Array.isArray(stroke.points) ? stroke.points.map(point => ({
      x: Number(point.x ?? point[0]), y: Number(point.y ?? point[1])
    })).filter(point => Number.isFinite(point.x) && Number.isFinite(point.y)) : [];
    if (!points.length && typeof stroke.d !== "string") return null;
    return {
      id: stroke.id || uid("stroke"),
      type: stroke.type === "highlighter" ? "highlighter" : "stroke",
      points,
      d: typeof stroke.d === "string" ? stroke.d : undefined,
      color: stroke.color || "#183153",
      width: Math.max(.5, Number(stroke.width || stroke.size || 4)),
      opacity: Number.isFinite(Number(stroke.opacity)) ? Number(stroke.opacity) : 1,
      tx: Number(stroke.tx ?? stroke.translation?.x) || 0,
      ty: Number(stroke.ty ?? stroke.translation?.y) || 0,
      erasures: (Array.isArray(stroke.erasures) ? stroke.erasures :
        (Array.isArray(stroke.erase_paths) ? stroke.erase_paths : [])).map(erasure => ({
          ...erasure,
          points: Array.isArray(erasure.points) ? erasure.points.map(point => ({
            x: Number(point.x ?? point[0]), y: Number(point.y ?? point[1])
          })).filter(point => Number.isFinite(point.x) && Number.isFinite(point.y)) : undefined
        }))
    };
  }

  function normalizeObject(object) {
    if (!object || typeof object !== "object") return null;
    if (object.type === "text") {
      return {
        id: object.id || uid("text"),
        type: "text",
        x: Number(object.x) || 0,
        y: Number(object.y) || 0,
        width: Math.max(40, Number(object.width) || 240),
        height: Math.max(30, Number(object.height) || 90),
        text: String(object.text || ""),
        color: object.color || "#183153",
        fontSize: clamp(Number(object.fontSize || object.font_size || 28), 8, 240)
      };
    }
    if (object.type === "stroke" || object.type === "highlighter" || object.points || object.d) {
      return legacyStroke(object);
    }
    return null;
  }

  function adaptEditor(raw) {
    const source = raw?.editor && typeof raw.editor === "object" ? raw.editor : (raw || {});
    const legacy = state.data.user_strokes || state.data.strokes || state.data.annotations || [];
    const objects = Array.isArray(source.objects) ? source.objects : legacy;
    const needsMigration = objects.some(object => !object?.id) ||
      Number(source.schema_version || 0) !== 2;
    const camera = source.viewport || source.camera;
    state.revision = Math.max(0, Number(source.revision) || 0);
    state.objects = objects.map(normalizeObject).filter(Boolean);
    state.camera = validCamera(camera) ? {
      x: Number(camera.x), y: Number(camera.y),
      width: Number(camera.width), height: Number(camera.height)
    } : { x: 0, y: 0, width: state.width, height: state.height };
    if (needsMigration && state.objects.length) markChanged();
  }

  function validCamera(camera) {
    return camera && [camera.x, camera.y, camera.width, camera.height]
      .every(value => Number.isFinite(Number(value))) &&
      Number(camera.width) > 0 && Number(camera.height) > 0;
  }

  function isManualMode(data) {
    const status = String(data.status || data.mode || "").toLowerCase();
    return Boolean(data.needs_corners || data.requires_corners || data.manual_corners ||
      ["manual", "corners", "needs_corners", "corner_selection"].includes(status));
  }

  async function loadBoard() {
    if (Object.keys(embedded).length) return normalizeBoard(embedded);
    try { return normalizeBoard(await requestJSON(boardRoute)); }
    catch (error) {
      console.warn("Could not load board JSON", error);
      return normalizeBoard({ id: boardId, error: error.message });
    }
  }

  async function loadEditor() {
    let saved = state.data.editor || state.data.editor_state || null;
    if (boardId) {
      try { saved = await requestJSON(editorApi); }
      catch (error) {
        if (error.status !== 404) console.warn("Could not load editor state", error);
      }
    }
    adaptEditor(saved || {});
  }

  /* Existing manual corner-selection contract and normalized coordinates are preserved. */
  function initCorners() {
    $("#corner-workspace").hidden = false;
    $("#editor-workspace").hidden = true;
    const image = $("#corner-image");
    const source = findAsset("original") || asUrl(state.data.image_url || state.data.image);
    if (!source) {
      $("#corner-error").textContent = "The original image is unavailable. Return home and upload it again.";
      $("#corner-error").hidden = false;
      return;
    }
    const saved = state.data.normalized_corners || state.data.corners_normalized;
    state.corners = Array.isArray(saved) && saved.length === 4
      ? saved.map(point => ({
        x: clamp(Number(point.x ?? point[0]), 0, 1),
        y: clamp(Number(point.y ?? point[1]), 0, 1)
      }))
      : [{x:.08,y:.10},{x:.92,y:.10},{x:.92,y:.90},{x:.08,y:.90}];
    image.addEventListener("load", () => {
      $("#corner-overlay").setAttribute("viewBox", `0 0 ${image.naturalWidth} ${image.naturalHeight}`);
      renderCorners();
    }, { once: true });
    image.addEventListener("error", () => {
      $("#corner-error").textContent = "The original image could not be loaded.";
      $("#corner-error").hidden = false;
    }, { once: true });
    image.src = source;
    $$(".corner-handle").forEach(handle => {
      handle.addEventListener("pointerdown", event => {
        event.preventDefault();
        handle.setPointerCapture(event.pointerId);
      });
      handle.addEventListener("pointermove", event => {
        if (!handle.hasPointerCapture(event.pointerId)) return;
        const bounds = $("#corner-stage").getBoundingClientRect();
        state.corners[Number(handle.dataset.corner)] = {
          x: clamp((event.clientX - bounds.left) / bounds.width, 0, 1),
          y: clamp((event.clientY - bounds.top) / bounds.height, 0, 1)
        };
        renderCorners();
      });
      handle.addEventListener("keydown", event => {
        const directions = { ArrowLeft:[-1,0], ArrowRight:[1,0], ArrowUp:[0,-1], ArrowDown:[0,1] };
        if (!directions[event.key]) return;
        event.preventDefault();
        const point = state.corners[Number(handle.dataset.corner)];
        point.x = clamp(point.x + directions[event.key][0] * .005, 0, 1);
        point.y = clamp(point.y + directions[event.key][1] * .005, 0, 1);
        renderCorners();
      });
    });
    $("#reset-corners").addEventListener("click", () => {
      state.corners = [{x:.08,y:.10},{x:.92,y:.10},{x:.92,y:.90},{x:.08,y:.90}];
      renderCorners();
    });
    $("#submit-corners").addEventListener("click", submitCorners);
  }

  function renderCorners() {
    const stage = $("#corner-stage");
    const image = $("#corner-image");
    if (!stage.clientWidth || !stage.clientHeight) return;
    $$(".corner-handle").forEach((handle, index) => {
      handle.style.left = `${state.corners[index].x * 100}%`;
      handle.style.top = `${state.corners[index].y * 100}%`;
    });
    const points = state.corners.map(point =>
      `${point.x * (image.naturalWidth || stage.clientWidth)},${point.y * (image.naturalHeight || stage.clientHeight)}`
    );
    $("#corner-polygon").setAttribute("points", points.join(" "));
    $("#corner-lines").setAttribute("points", [...points, points[0]].join(" "));
  }

  async function submitCorners() {
    const button = $("#submit-corners");
    const errorBox = $("#corner-error");
    const image = $("#corner-image");
    const payload = {
      corners: state.corners.map(point => ({
        x: clamp(Math.round(point.x * image.naturalWidth), 0, image.naturalWidth - 1),
        y: clamp(Math.round(point.y * image.naturalHeight), 0, image.naturalHeight - 1)
      })),
      normalized_corners: state.corners.map(point => ({ x: point.x, y: point.y })),
      image_width: image.naturalWidth,
      image_height: image.naturalHeight
    };
    button.disabled = true;
    button.textContent = "Correcting…";
    errorBox.hidden = true;
    let lastError;
    for (const url of [`${boardRoute}/corners`, boardRoute]) {
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json", Accept: "application/json" },
          body: JSON.stringify(payload)
        });
        if (!response.ok) {
          lastError = new Error(`Server returned ${response.status}`);
          if ([404, 405].includes(response.status)) continue;
          throw lastError;
        }
        const result = await response.json().catch(() => ({}));
        if (result.redirect || result.url) location.assign(result.redirect || result.url);
        else location.reload();
        return;
      } catch (error) { lastError = error; }
    }
    button.disabled = false;
    button.textContent = "Correct board";
    errorBox.textContent = `Could not save corners. ${lastError?.message || "Please try again."}`;
    errorBox.hidden = false;
  }

  function pathFromPoints(points) {
    if (!points?.length) return "";
    if (points.length < 3) {
      const last = points.at(-1);
      return `M ${points[0].x} ${points[0].y} L ${last.x + .01} ${last.y + .01}`;
    }
    let path = `M ${points[0].x} ${points[0].y}`;
    for (let index = 1; index < points.length - 1; index++) {
      const next = points[index + 1];
      path += ` Q ${points[index].x} ${points[index].y} ${(points[index].x + next.x) / 2} ${(points[index].y + next.y) / 2}`;
    }
    const last = points.at(-1);
    return `${path} L ${last.x} ${last.y}`;
  }

  const strokePath = object => object.d || pathFromPoints(object.points);

  function sanitizeSVG(markup) {
    if (!markup) return null;
    const parsed = new DOMParser().parseFromString(markup, "image/svg+xml");
    const svg = parsed.documentElement;
    if (svg.nodeName.toLowerCase() !== "svg" || parsed.querySelector("parsererror")) return null;
    svg.querySelectorAll("script,foreignObject,iframe,object,embed").forEach(node => node.remove());
    svg.querySelectorAll('[id="user-ink"],[data-role="background"]').forEach(node => node.remove());
    svg.querySelectorAll("*").forEach(node => {
      [...node.attributes].forEach(attribute => {
        const name = attribute.name.toLowerCase();
        const value = attribute.value.trim().toLowerCase();
        if (name.startsWith("on") || value.startsWith("javascript:")) node.removeAttribute(attribute.name);
      });
      node.style.pointerEvents = "none";
    });
    return document.importNode(svg, true);
  }

  async function loadImportedSVG() {
    const inline = state.data.svg_markup ||
      (typeof state.data.svg === "string" && state.data.svg.trim().startsWith("<") ? state.data.svg : "");
    let markup = inline || "";
    if (!markup) {
      const url = findAsset("professor_svg") || asUrl(state.data.svg_url) ||
        (boardId ? `${boardRoute}/svg` : "");
      if (url) {
        try {
          const response = await fetch(url);
          if (response.ok) markup = await response.text();
        } catch (error) { console.warn("Imported SVG unavailable", error); }
      }
    }
    const safe = sanitizeSVG(markup);
    if (!safe) return;
    safe.setAttribute("x", "0");
    safe.setAttribute("y", "0");
    safe.setAttribute("width", state.width);
    safe.setAttribute("height", state.height);
    safe.setAttribute("preserveAspectRatio", "none");
    safe.setAttribute("aria-hidden", "true");
    state.importedMarkup = safe.outerHTML;
    $("#imported-layer").replaceChildren(safe);
  }

  function applyCamera() {
    const camera = state.camera;
    $("#world-scene").setAttribute("viewBox", `${camera.x} ${camera.y} ${camera.width} ${camera.height}`);
    const zoom = state.width / camera.width;
    $("#zoom-label").textContent = `${Math.round(zoom * 100)}%`;
    if (!$("#text-editor").hidden) positionTextEditor();
  }

  function fitCamera() {
    state.camera = { x: 0, y: 0, width: state.width, height: state.height };
    applyCamera();
    markChanged();
  }

  /* Convert pointer pixels through SVG CTM so every tool works in world coordinates. */
  function clientToWorld(clientX, clientY) {
    const svg = $("#world-scene");
    const point = svg.createSVGPoint();
    point.x = clientX;
    point.y = clientY;
    const matrix = svg.getScreenCTM();
    return matrix ? point.matrixTransform(matrix.inverse()) : { x: 0, y: 0 };
  }

  function worldToClient(x, y) {
    const svg = $("#world-scene");
    const point = svg.createSVGPoint();
    point.x = x;
    point.y = y;
    const matrix = svg.getScreenCTM();
    return matrix ? point.matrixTransform(matrix) : { x: 0, y: 0 };
  }

  function zoomAt(factor, clientX, clientY) {
    const old = state.camera;
    const anchor = clientToWorld(clientX, clientY);
    const newWidth = clamp(old.width / factor, state.width / MAX_ZOOM, state.width / MIN_ZOOM);
    const actual = old.width / newWidth;
    const newHeight = old.height / actual;
    state.camera = {
      x: anchor.x - (anchor.x - old.x) / actual,
      y: anchor.y - (anchor.y - old.y) / actual,
      width: newWidth,
      height: newHeight
    };
    applyCamera();
    markChanged();
  }

  function snapshot() {
    return clone(state.objects);
  }

  /* History stores bounded before-action snapshots, not individual pointer samples. */
  function commitLogicalAction(before) {
    if (JSON.stringify(before) === JSON.stringify(state.objects)) return false;
    state.history.push(before);
    if (state.history.length > HISTORY_LIMIT) state.history.shift();
    state.future = [];
    markChanged();
    updateHistoryButtons();
    return true;
  }

  function undo() {
    if (!state.history.length) return;
    closeTextEditor(true);
    state.future.push(snapshot());
    state.objects = state.history.pop();
    state.selected.clear();
    markChanged();
    renderScene();
  }

  function redo() {
    if (!state.future.length) return;
    closeTextEditor(true);
    state.history.push(snapshot());
    state.objects = state.future.pop();
    state.selected.clear();
    markChanged();
    renderScene();
  }

  function updateHistoryButtons() {
    $("#undo-button").disabled = !state.history.length;
    $("#redo-button").disabled = !state.future.length;
  }

  function markChanged() {
    state.dirty = true;
    if (state.saving) state.saveAgain = true;
    setSaveStatus("Unsaved changes");
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(() => saveEditor(false), 1200);
  }

  function payload() {
    const objects = state.objects.map(object => {
      if (object.type === "text") {
        return {
          id: object.id, type: "text", text: object.text,
          x: object.x, y: object.y, width: object.width, height: object.height,
          font_size: object.fontSize, color: object.color,
          translation: { x: 0, y: 0 }
        };
      }
      return {
        id: object.id, type: object.type, points: object.points,
        color: object.color, width: object.width, opacity: object.opacity,
        translation: { x: object.tx || 0, y: object.ty || 0 },
        erasures: (object.erasures || []).map(erasure => ({
          points: erasure.points, width: erasure.width
        }))
      };
    });
    return {
      schema_version: 2,
      revision: state.revision,
      viewport: clone(state.camera),
      objects
    };
  }

  /* Editor persistence uses one versioned document; revision is server-controlled. */
  async function saveEditor(showToast = false) {
    clearTimeout(state.saveTimer);
    if (!state.dirty || !boardId) return;
    if (state.saving) {
      state.saveAgain = true;
      return;
    }
    state.saving = true;
    $("#save-button").disabled = true;
    setSaveStatus("Saving…");
    try {
      const result = await requestJSON(editorApi, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          "If-Match": String(state.revision)
        },
        body: JSON.stringify(payload())
      });
      const saved = result?.editor || result || {};
      state.revision = Math.max(state.revision, Number(saved.revision) || state.revision + 1);
      state.dirty = state.saveAgain;
      setSaveStatus(state.dirty ? "Unsaved changes" : "Saved");
      if (showToast) toast("Board saved.");
    } catch (error) {
      setSaveStatus(error.status === 409 ? "Save conflict" : "Save failed");
      if (showToast || error.status === 409) {
        toast(error.status === 409 ? "This board changed elsewhere. Reload before overwriting." :
          `Could not save: ${error.message}`, true);
      }
    } finally {
      state.saving = false;
      $("#save-button").disabled = false;
      if (state.saveAgain) {
        state.saveAgain = false;
        saveEditor(false);
      }
    }
  }

  function unloadSave() {
    if (!state.dirty || !boardId) return;
    const body = JSON.stringify(payload());
    try {
      fetch(editorApi, {
        method: "PUT",
        headers: { "Content-Type": "application/json", "If-Match": String(state.revision) },
        body,
        keepalive: true
      }).catch(() => {
        if (navigator.sendBeacon) {
          navigator.sendBeacon(`${editorApi}?_method=PUT`, new Blob([body], { type: "application/json" }));
        }
      });
    } catch (_) {
      if (navigator.sendBeacon) {
        navigator.sendBeacon(`${editorApi}?_method=PUT`, new Blob([body], { type: "application/json" }));
      }
    }
  }

  function objectBounds(object) {
    if (object.type === "text") {
      return { x: object.x, y: object.y, width: object.width, height: object.height };
    }
    const points = object.points || [];
    if (points.length) {
      const xs = points.map(point => point.x);
      const ys = points.map(point => point.y);
      const pad = object.width / 2;
      return {
        x: Math.min(...xs) - pad, y: Math.min(...ys) - pad,
        width: Math.max(...xs) - Math.min(...xs) + pad * 2,
        height: Math.max(...ys) - Math.min(...ys) + pad * 2
      };
    }
    const rendered = $(`[data-object-id="${CSS.escape(object.id)}"]`);
    if (rendered) {
      try {
        const box = rendered.getBBox();
        return {
          x: box.x + (object.tx || 0), y: box.y + (object.ty || 0),
          width: box.width, height: box.height
        };
      } catch (_) { /* Detached SVG nodes have no box. */ }
    }
    return { x: 0, y: 0, width: 0, height: 0 };
  }

  function intersects(a, b) {
    return a.x <= b.x + b.width && a.x + a.width >= b.x &&
      a.y <= b.y + b.height && a.y + a.height >= b.y;
  }

  function pointInPolygon(point, polygon) {
    let inside = false;
    for (let index = 0, previous = polygon.length - 1; index < polygon.length; previous = index++) {
      const a = polygon[index];
      const b = polygon[previous];
      const crosses = (a.y > point.y) !== (b.y > point.y) &&
        point.x < (b.x - a.x) * (point.y - a.y) / ((b.y - a.y) || Number.EPSILON) + a.x;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  function lassoSelectsObject(object, polygon) {
    if (polygon.length < 3) return false;
    const bounds = objectBounds(object);
    const lassoBounds = unionBounds([{ type: "stroke", points: polygon, width: 0 }]);
    if (!intersects(bounds, lassoBounds)) return false;
    const samples = object.type === "text"
      ? [
          { x: bounds.x, y: bounds.y },
          { x: bounds.x + bounds.width, y: bounds.y },
          { x: bounds.x + bounds.width, y: bounds.y + bounds.height },
          { x: bounds.x, y: bounds.y + bounds.height },
          { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 }
        ]
      : (object.points || []).map(point => ({
          x: point.x + (object.tx || 0), y: point.y + (object.ty || 0)
        }));
    return samples.some(point => pointInPolygon(point, polygon)) ||
      polygon.some(point =>
        point.x >= bounds.x && point.x <= bounds.x + bounds.width &&
        point.y >= bounds.y && point.y <= bounds.y + bounds.height
      );
  }

  function unionBounds(objects) {
    if (!objects.length) return { x: 0, y: 0, width: state.width, height: state.height };
    const bounds = objects.map(objectBounds);
    const left = Math.min(...bounds.map(box => box.x));
    const top = Math.min(...bounds.map(box => box.y));
    const right = Math.max(...bounds.map(box => box.x + box.width));
    const bottom = Math.max(...bounds.map(box => box.y + box.height));
    const pad = Math.max(12, Math.max(right - left, bottom - top) * .03);
    return {
      x: left - pad, y: top - pad,
      width: Math.max(1, right - left + pad * 2),
      height: Math.max(1, bottom - top + pad * 2)
    };
  }

  function renderText(object) {
    const group = svgEl("g", { "data-object-id": object.id, tabindex: "0" });
    const hit = svgEl("rect", {
      x: object.x, y: object.y, width: object.width, height: object.height,
      fill: "transparent", stroke: "none", "pointer-events": "all"
    });
    const text = svgEl("text", {
      x: object.x + 5, y: object.y + object.fontSize,
      fill: object.color, "font-size": object.fontSize,
      "font-family": "system-ui, sans-serif", "pointer-events": "none"
    });
    const maxChars = Math.max(1, Math.floor((object.width - 10) / (object.fontSize * .58)));
    const lines = [];
    String(object.text).split("\n").forEach(paragraph => {
      const words = paragraph.split(/\s+/);
      let line = "";
      words.forEach(word => {
        const candidate = line ? `${line} ${word}` : word;
        if (candidate.length > maxChars && line) {
          lines.push(line);
          line = word;
        } else line = candidate;
      });
      lines.push(line);
    });
    lines.slice(0, Math.max(1, Math.floor(object.height / (object.fontSize * 1.2)))).forEach((line, index) => {
      const tspan = svgEl("tspan", {
        x: object.x + 5,
        dy: index ? object.fontSize * 1.2 : 0
      });
      tspan.textContent = line;
      text.append(tspan);
    });
    group.append(hit, text);
    return group;
  }

  function renderStroke(object) {
    const group = svgEl("g", {
      "data-object-id": object.id,
      transform: `translate(${object.tx || 0} ${object.ty || 0})`
    });
    const path = svgEl("path", {
      d: strokePath(object), fill: "none", stroke: object.color,
      "stroke-width": object.width, "stroke-opacity": object.opacity,
      "stroke-linecap": "round", "stroke-linejoin": "round",
      "pointer-events": "stroke"
    });
    if (object.erasures?.length) {
      const maskId = `mask-${object.id.replace(/[^a-zA-Z0-9_-]/g, "")}`;
      const mask = svgEl("mask", {
        id: maskId, maskUnits: "userSpaceOnUse",
        x: -state.width, y: -state.height, width: state.width * 3, height: state.height * 3
      });
      mask.append(svgEl("rect", {
        x: -state.width, y: -state.height, width: state.width * 3, height: state.height * 3,
        fill: "white"
      }));
      object.erasures.forEach(erasure => mask.append(svgEl("path", {
        d: erasure.d || pathFromPoints(erasure.points), fill: "none", stroke: "black", "stroke-width": erasure.width,
        "stroke-linecap": "round", "stroke-linejoin": "round"
      })));
      $("#scene-defs").append(mask);
      path.setAttribute("mask", `url(#${maskId})`);
    }
    group.append(path);
    return group;
  }

  function renderSelection() {
    const layer = $("#interaction-layer");
    const selectedObjects = state.objects.filter(object => state.selected.has(object.id));
    selectedObjects.forEach(object => {
      const box = objectBounds(object);
      layer.append(svgEl("rect", {
        x: box.x, y: box.y, width: box.width, height: box.height,
        fill: "none", stroke: "#3977d5",
        "stroke-width": Math.max(1, state.camera.width / 900),
        "stroke-dasharray": `${state.camera.width / 300} ${state.camera.width / 450}`,
        "pointer-events": "none"
      }));
      if (selectedObjects.length === 1 && object.type === "text") {
        layer.append(svgEl("circle", {
          cx: object.x + object.width, cy: object.y + object.height,
          r: Math.max(6, state.camera.width / 150),
          fill: "#fff", stroke: "#3977d5",
          "stroke-width": Math.max(1, state.camera.width / 900),
          "data-resize-id": object.id, "pointer-events": "all"
        }));
      }
    });
  }

  function renderScene() {
    const defs = $("#scene-defs");
    const user = $("#user-layer");
    const interaction = $("#interaction-layer");
    defs.replaceChildren();
    user.replaceChildren();
    interaction.replaceChildren();
    state.objects.forEach(object => user.append(
      object.type === "text" ? renderText(object) : renderStroke(object)
    ));
    if (state.interaction?.kind === "draw" || state.interaction?.kind === "pixel") {
      const active = state.interaction;
      interaction.append(svgEl("path", {
        d: pathFromPoints(active.points), fill: "none",
        stroke: active.kind === "pixel" ? "#dd3f32" : active.color,
        "stroke-opacity": active.kind === "pixel" ? .55 : active.opacity,
        "stroke-width": active.width, "stroke-linecap": "round",
        "stroke-linejoin": "round", "pointer-events": "none"
      }));
    } else if (state.interaction?.kind === "lasso") {
      interaction.append(svgEl("path", {
        d: `${pathFromPoints(state.interaction.points)} Z`,
        fill: "#3977d5", "fill-opacity": .08, stroke: "#3977d5",
        "stroke-width": Math.max(1, state.camera.width / 900),
        "stroke-dasharray": `${state.camera.width / 300} ${state.camera.width / 450}`,
        "stroke-linejoin": "round"
      }));
    }
    renderSelection();
    $("#object-count").textContent = `${state.objects.length} object${state.objects.length === 1 ? "" : "s"}`;
    updateHistoryButtons();
  }

  function setTool(tool) {
    closeTextEditor(true);
    state.tool = tool;
    $("#world-scene").dataset.tool = tool;
    $$(".tool-button").forEach(button => {
      const active = button.dataset.tool === tool;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
  }

  function updateSelectedTextStyle(property, value) {
    const selectedText = state.objects.filter(
      object => object.type === "text" && state.selected.has(object.id)
    );
    if (!selectedText.length) return;
    const before = snapshot();
    selectedText.forEach(object => { object[property] = value; });
    commitLogicalAction(before);
    renderScene();
  }

  function beginPan(event) {
    state.interaction = {
      kind: "pan", pointerId: event.pointerId,
      client: { x: event.clientX, y: event.clientY },
      camera: clone(state.camera)
    };
    $("#world-scene").classList.add("is-panning");
  }

  function beginPinch() {
    const points = [...state.pointers.values()];
    if (points.length < 2) return;
    state.interaction = {
      kind: "pinch",
      distance: Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y),
      midpoint: { x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 },
      camera: clone(state.camera)
    };
  }

  function hitObject(event) {
    return event.target.closest?.("[data-object-id]")?.dataset.objectId || "";
  }

  function pointerDown(event) {
    if (event.pointerType === "mouse" && event.button !== 0 && event.button !== 1) return;
    event.preventDefault();
    const svg = $("#world-scene");
    svg.setPointerCapture(event.pointerId);
    state.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (state.pointers.size === 2 && event.pointerType !== "mouse") {
      state.interaction = null;
      beginPinch();
      renderScene();
      return;
    }
    if (event.button === 1 || state.spaceDown) {
      beginPan(event);
      return;
    }
    const point = clientToWorld(event.clientX, event.clientY);
    const hit = hitObject(event);
    const resizeId = event.target.dataset?.resizeId;
    if (resizeId) {
      const object = state.objects.find(item => item.id === resizeId);
      state.interaction = { kind: "resize", pointerId: event.pointerId, object, start: point, before: snapshot(),
        original: { width: object.width, height: object.height } };
      return;
    }
    if (state.tool === "pen" || state.tool === "highlighter") {
      state.interaction = {
        kind: "draw", pointerId: event.pointerId, before: snapshot(), points: [point],
        objectType: state.tool === "highlighter" ? "highlighter" : "stroke",
        color: state.color,
        width: state.tool === "highlighter" ? Math.max(18, state.size * 3) : state.size,
        opacity: state.tool === "highlighter" ? .28 : 1
      };
      renderScene();
      return;
    }
    if (state.tool === "text") {
      const before = snapshot();
      const object = {
        id: uid("text"), type: "text", x: point.x, y: point.y,
        width: Math.min(260, state.width / 3), height: 90,
        text: "", color: state.color, fontSize: Math.max(18, state.size * 4)
      };
      state.objects.push(object);
      state.selected = new Set([object.id]);
      commitLogicalAction(before);
      renderScene();
      openTextEditor(object);
      return;
    }
    if (state.tool === "object-eraser") {
      state.interaction = { kind: "object-erase", pointerId: event.pointerId, before: snapshot() };
      eraseWholeObject(hit);
      return;
    }
    if (state.tool === "pixel-eraser") {
      state.interaction = {
        kind: "pixel", pointerId: event.pointerId, before: snapshot(), points: [point],
        width: Math.max(12, state.size * 3)
      };
      renderScene();
      return;
    }
    if (state.tool === "select") {
      if (hit) {
        if (event.shiftKey) {
          if (state.selected.has(hit)) state.selected.delete(hit);
          else state.selected.add(hit);
        } else if (!state.selected.has(hit)) state.selected = new Set([hit]);
        state.interaction = {
          kind: "move", pointerId: event.pointerId, start: point,
          before: snapshot(), moved: false
        };
      } else {
        if (!event.shiftKey) state.selected.clear();
        state.interaction = { kind: "lasso", pointerId: event.pointerId, points: [point] };
      }
      renderScene();
    }
  }

  function pointerMove(event) {
    if (state.pointers.has(event.pointerId)) {
      state.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    }
    const interaction = state.interaction;
    if (!interaction) return;
    if (interaction.kind === "pinch") {
      const points = [...state.pointers.values()];
      if (points.length < 2) return;
      const distance = Math.max(1, Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y));
      const midpoint = { x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 };
      state.camera = clone(interaction.camera);
      zoomAt(distance / interaction.distance, interaction.midpoint.x, interaction.midpoint.y);
      const before = clientToWorld(interaction.midpoint.x, interaction.midpoint.y);
      const after = clientToWorld(midpoint.x, midpoint.y);
      state.camera.x += before.x - after.x;
      state.camera.y += before.y - after.y;
      applyCamera();
      return;
    }
    if (interaction.pointerId !== event.pointerId) return;
    if (interaction.kind === "pan") {
      const svg = $("#world-scene");
      const rect = svg.getBoundingClientRect();
      state.camera.x = interaction.camera.x -
        (event.clientX - interaction.client.x) * interaction.camera.width / rect.width;
      state.camera.y = interaction.camera.y -
        (event.clientY - interaction.client.y) * interaction.camera.height / rect.height;
      applyCamera();
      return;
    }
    const samples = event.getCoalescedEvents ? event.getCoalescedEvents() : [event];
    if (interaction.kind === "draw" || interaction.kind === "pixel") {
      samples.forEach(sample => interaction.points.push(clientToWorld(sample.clientX, sample.clientY)));
      renderScene();
      return;
    }
    const point = clientToWorld(event.clientX, event.clientY);
    if (interaction.kind === "lasso") {
      interaction.points.push(point);
      renderScene();
    } else if (interaction.kind === "move") {
      const dx = point.x - interaction.start.x;
      const dy = point.y - interaction.start.y;
      state.objects = clone(interaction.before);
      state.objects.filter(object => state.selected.has(object.id)).forEach(object => moveObject(object, dx, dy));
      interaction.moved = Math.hypot(dx, dy) > state.camera.width / 1000;
      renderScene();
    } else if (interaction.kind === "resize") {
      interaction.object.width = Math.max(40, interaction.original.width + point.x - interaction.start.x);
      interaction.object.height = Math.max(30, interaction.original.height + point.y - interaction.start.y);
      renderScene();
    } else if (interaction.kind === "object-erase") {
      eraseWholeObject(hitObject(event));
    }
  }

  function moveObject(object, dx, dy) {
    if (object.type === "text") {
      object.x += dx;
      object.y += dy;
    } else if (object.points?.length) {
      object.points.forEach(point => { point.x += dx; point.y += dy; });
    } else if (object.d) {
      object.tx = (object.tx || 0) + dx;
      object.ty = (object.ty || 0) + dy;
    }
  }

  function eraseWholeObject(id) {
    if (!id) return;
    const index = state.objects.findIndex(object => object.id === id);
    if (index < 0) return;
    state.objects.splice(index, 1);
    state.selected.delete(id);
    renderScene();
  }

  function finishPixelEraser(interaction) {
    if (interaction.points.length < 2) return;
    const eraserBounds = unionBounds([{
      type: "stroke", points: interaction.points, width: interaction.width
    }]);
    state.objects.filter(object =>
      ["stroke", "highlighter"].includes(object.type) && intersects(objectBounds(object), eraserBounds)
    )
      .forEach(object => {
        let touched = !object.points?.length;
        if (object.points?.length) {
          const threshold = (object.width + interaction.width) / 2;
          touched = object.points.some(strokePoint => interaction.points.some(erasePoint =>
            Math.hypot(strokePoint.x - erasePoint.x, strokePoint.y - erasePoint.y) <= threshold
          ));
        }
        // Pixel erasure is persisted per user stroke as a black path in that stroke's mask.
        if (touched) {
          object.erasures ||= [];
          object.erasures.push({
            id: uid("erase"),
            points: interaction.points.map(point => ({
              x: point.x - (object.tx || 0),
              y: point.y - (object.ty || 0)
            })),
            width: interaction.width
          });
        }
      });
  }

  function pointerUp(event) {
    state.pointers.delete(event.pointerId);
    const interaction = state.interaction;
    if (!interaction) return;
    if (interaction.kind === "pinch") {
      if (state.pointers.size < 2) {
        state.interaction = null;
        markChanged();
      }
      return;
    }
    if (interaction.pointerId !== event.pointerId) return;
    if (interaction.kind === "draw") {
      state.objects.push({
        id: uid("stroke"), type: interaction.objectType, points: interaction.points,
        color: interaction.color, width: interaction.width,
        opacity: interaction.opacity, erasures: []
      });
      commitLogicalAction(interaction.before);
    } else if (interaction.kind === "pixel") {
      finishPixelEraser(interaction);
      commitLogicalAction(interaction.before);
    } else if (interaction.kind === "object-erase" || interaction.kind === "resize" ||
      (interaction.kind === "move" && interaction.moved)) {
      commitLogicalAction(interaction.before);
    } else if (interaction.kind === "lasso") {
      state.objects.filter(object => lassoSelectsObject(object, interaction.points))
        .forEach(object => state.selected.add(object.id));
    }
    state.interaction = null;
    $("#world-scene").classList.remove("is-panning");
    if (interaction.kind === "pan") markChanged();
    renderScene();
  }

  function pointerCancel(event) {
    state.pointers.delete(event.pointerId);
    const interaction = state.interaction;
    if (interaction?.before) state.objects = interaction.before;
    state.interaction = null;
    $("#world-scene").classList.remove("is-panning");
    renderScene();
  }

  function openTextEditor(object) {
    const editor = $("#text-editor");
    editor.dataset.objectId = object.id;
    editor.value = object.text;
    editor.style.color = object.color;
    editor.style.fontSize = `${Math.max(12, object.fontSize * state.width / state.camera.width)}px`;
    editor.hidden = false;
    editor.dataset.before = JSON.stringify(snapshot());
    positionTextEditor();
    editor.focus();
    editor.select();
  }

  function positionTextEditor() {
    const editor = $("#text-editor");
    const object = state.objects.find(item => item.id === editor.dataset.objectId);
    if (!object) {
      editor.hidden = true;
      return;
    }
    const frame = $("#primary-frame").getBoundingClientRect();
    const topLeft = worldToClient(object.x, object.y);
    const bottomRight = worldToClient(object.x + object.width, object.y + object.height);
    editor.style.left = `${topLeft.x - frame.left}px`;
    editor.style.top = `${topLeft.y - frame.top}px`;
    editor.style.width = `${Math.max(80, bottomRight.x - topLeft.x)}px`;
    editor.style.height = `${Math.max(42, bottomRight.y - topLeft.y)}px`;
  }

  function closeTextEditor(commit) {
    const editor = $("#text-editor");
    if (editor.hidden) return;
    const object = state.objects.find(item => item.id === editor.dataset.objectId);
    const before = JSON.parse(editor.dataset.before || "[]");
    if (object) {
      if (commit) object.text = editor.value;
      else state.objects = before;
    }
    editor.hidden = true;
    editor.removeAttribute("data-object-id");
    if (commit) commitLogicalAction(before);
    renderScene();
  }

  function deleteSelection() {
    if (!state.selected.size) return;
    const before = snapshot();
    state.objects = state.objects.filter(object => !state.selected.has(object.id));
    state.selected.clear();
    commitLogicalAction(before);
    renderScene();
  }

  function handleKeyDown(event) {
    if (event.target === $("#text-editor")) {
      if (event.key === "Escape") {
        event.preventDefault();
        closeTextEditor(false);
      }
      if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
        event.preventDefault();
        closeTextEditor(true);
      }
      return;
    }
    if (event.code === "Space") {
      state.spaceDown = true;
      event.preventDefault();
    }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") {
      event.preventDefault();
      event.shiftKey ? redo() : undo();
    } else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "y") {
      event.preventDefault();
      redo();
    } else if ((event.key === "Delete" || event.key === "Backspace") && state.tool === "select") {
      event.preventDefault();
      deleteSelection();
    } else if (event.key === "Escape") {
      state.selected.clear();
      renderScene();
    }
  }

  function bindEditor() {
    $$(".tool-button").forEach(button =>
      button.addEventListener("click", () => setTool(button.dataset.tool)));
    $$(".color-chip").forEach(button => button.addEventListener("click", () => {
      state.color = button.dataset.color;
      updateSelectedTextStyle("color", state.color);
      $$(".color-chip").forEach(item => {
        const active = item === button;
        item.classList.toggle("is-active", active);
        item.setAttribute("aria-pressed", String(active));
      });
    }));
    $("#custom-color").addEventListener("input", event => {
      state.color = event.target.value;
      $$(".color-chip").forEach(item => item.classList.remove("is-active"));
    });
    $("#custom-color").addEventListener("change", event => {
      updateSelectedTextStyle("color", event.target.value);
    });
    $("#stroke-size").addEventListener("input", event => { state.size = Number(event.target.value); });
    $("#stroke-size").addEventListener("change", event => {
      updateSelectedTextStyle("fontSize", Math.max(8, Number(event.target.value) * 4));
    });
    $("#master-layer-toggle").addEventListener("change", event => {
      $("#master-layer").style.display = event.target.checked ? "" : "none";
    });
    $("#professor-layer-toggle").addEventListener("change", event => {
      $("#imported-layer").style.display = event.target.checked ? "" : "none";
    });
    $("#user-layer-toggle").addEventListener("change", event => {
      $("#user-layer").style.display = event.target.checked ? "" : "none";
      $("#interaction-layer").style.display = event.target.checked ? "" : "none";
    });
    $("#undo-button").addEventListener("click", undo);
    $("#redo-button").addEventListener("click", redo);
    $("#save-button").addEventListener("click", () => saveEditor(true));
    $("#clear-button").addEventListener("click", () => {
      if (!state.objects.length || !confirm("Clear all editable user objects?")) return;
      const before = snapshot();
      state.objects = [];
      state.selected.clear();
      commitLogicalAction(before);
      renderScene();
    });
    $("#zoom-in").addEventListener("click", () => {
      const rect = $("#world-scene").getBoundingClientRect();
      zoomAt(1.25, rect.left + rect.width / 2, rect.top + rect.height / 2);
    });
    $("#zoom-out").addEventListener("click", () => {
      const rect = $("#world-scene").getBoundingClientRect();
      zoomAt(.8, rect.left + rect.width / 2, rect.top + rect.height / 2);
    });
    $("#fit-button").addEventListener("click", fitCamera);
    $("#export-button").addEventListener("click", () => exportBoard("svg"));
    $("#export-png").addEventListener("click", () => exportBoard("png"));
    const svg = $("#world-scene");
    svg.addEventListener("pointerdown", pointerDown);
    svg.addEventListener("pointermove", pointerMove);
    svg.addEventListener("pointerup", pointerUp);
    svg.addEventListener("pointercancel", pointerCancel);
    svg.addEventListener("dblclick", event => {
      const id = hitObject(event);
      const object = state.objects.find(item => item.id === id && item.type === "text");
      if (object) openTextEditor(object);
    });
    svg.addEventListener("wheel", event => {
      event.preventDefault();
      zoomAt(Math.exp(-event.deltaY * .0015), event.clientX, event.clientY);
    }, { passive: false });
    $("#text-editor").addEventListener("blur", () => closeTextEditor(true));
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("keyup", event => {
      if (event.code === "Space") state.spaceDown = false;
    });
    window.addEventListener("pagehide", unloadSave);
    window.addEventListener("resize", () => {
      if (!$("#text-editor").hidden) positionTextEditor();
    });
  }

  function escapeXML(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function exportObject(object) {
    if (object.type === "text") {
      const lines = escapeXML(object.text).split("\n");
      const tspans = lines.map((line, index) =>
        `<tspan x="${object.x + 5}" dy="${index ? object.fontSize * 1.2 : 0}">${line}</tspan>`
      ).join("");
      return `<text x="${object.x + 5}" y="${object.y + object.fontSize}" fill="${escapeXML(object.color)}" font-size="${object.fontSize}" font-family="system-ui, sans-serif">${tspans}</text>`;
    }
    const id = `export-mask-${object.id.replace(/[^a-zA-Z0-9_-]/g, "")}`;
    const erasures = object.erasures || [];
    const mask = erasures.length ? `<mask id="${id}" maskUnits="userSpaceOnUse" x="${-state.width}" y="${-state.height}" width="${state.width * 3}" height="${state.height * 3}"><rect x="${-state.width}" y="${-state.height}" width="${state.width * 3}" height="${state.height * 3}" fill="white"/>${erasures.map(erasure => `<path d="${escapeXML(erasure.d || pathFromPoints(erasure.points))}" fill="none" stroke="black" stroke-width="${Number(erasure.width)}" stroke-linecap="round" stroke-linejoin="round"/>`).join("")}</mask>` : "";
    const transform = object.tx || object.ty
      ? ` transform="translate(${Number(object.tx) || 0} ${Number(object.ty) || 0})"` : "";
    const path = `<path d="${escapeXML(strokePath(object))}" fill="none" stroke="${escapeXML(object.color)}" stroke-width="${Number(object.width)}" stroke-opacity="${Number(object.opacity)}" stroke-linecap="round" stroke-linejoin="round"${transform}${erasures.length ? ` mask="url(#${id})"` : ""}/>`;
    return `${mask}${path}`;
  }

  async function imageDataUrl(url) {
    if (!url) return "";
    if (url.startsWith("data:")) return url;
    const response = await fetch(url);
    if (!response.ok) throw new Error("Master image could not be embedded");
    const blob = await response.blob();
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  }

  async function buildExportSVG() {
    const scope = $("#export-scope").value;
    const bounds = scope === "content" ? unionBounds(state.objects) :
      { x: 0, y: 0, width: state.width, height: state.height };
    const master = await imageDataUrl(state.masterUrl);
    const imported = state.importedMarkup || "";
    const objects = state.objects.map(exportObject).join("");
    return `<svg xmlns="${NS}" viewBox="${bounds.x} ${bounds.y} ${bounds.width} ${bounds.height}" width="${Math.ceil(bounds.width)}" height="${Math.ceil(bounds.height)}"><rect x="${bounds.x}" y="${bounds.y}" width="${bounds.width}" height="${bounds.height}" fill="white"/>${master ? `<image href="${escapeXML(master)}" x="0" y="0" width="${state.width}" height="${state.height}" preserveAspectRatio="none"/>` : ""}<g id="imported-vectors">${imported}</g><g id="user-objects">${objects}</g></svg>`;
  }

  function downloadBlob(blob, extension) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `board-${boardId || "export"}.${extension}`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1500);
  }

  async function exportBoard(format) {
    try {
      setSaveStatus(`Exporting ${format.toUpperCase()}…`);
      const markup = await buildExportSVG();
      if (format === "svg") {
        downloadBlob(new Blob([markup], { type: "image/svg+xml" }), "svg");
      } else {
        const parsed = new DOMParser().parseFromString(markup, "image/svg+xml").documentElement;
        const width = Number(parsed.getAttribute("width"));
        const height = Number(parsed.getAttribute("height"));
        const scale = Math.min(
          2,
          4096 / Math.max(width, height),
          Math.sqrt(16_000_000 / Math.max(1, width * height))
        );
        const canvas = document.createElement("canvas");
        canvas.width = Math.max(1, Math.round(width * scale));
        canvas.height = Math.max(1, Math.round(height * scale));
        const image = new Image();
        const url = URL.createObjectURL(new Blob([markup], { type: "image/svg+xml" }));
        await new Promise((resolve, reject) => {
          image.onload = resolve;
          image.onerror = reject;
          image.src = url;
        });
        canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
        URL.revokeObjectURL(url);
        const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/png"));
        if (!blob) throw new Error("PNG encoding failed");
        downloadBlob(blob, "png");
      }
      setSaveStatus(state.dirty ? "Unsaved changes" : "Saved");
      toast(`${format.toUpperCase()} exported.`);
    } catch (error) {
      setSaveStatus(state.dirty ? "Unsaved changes" : "Ready");
      toast(`Export failed: ${error.message}`, true);
    }
  }

  async function initEditor() {
    $("#corner-workspace").hidden = true;
    $("#editor-workspace").hidden = false;
    $("#board-name").textContent = state.data.title || state.data.name || `Board ${boardId || ""}`.trim();
    state.masterUrl = findAsset("enhanced") || findAsset("corrected");
    const master = $("#master-image");
    master.setAttribute("width", state.width);
    master.setAttribute("height", state.height);
    if (state.masterUrl) {
      master.setAttribute("href", state.masterUrl);
      master.addEventListener("error", () => { $("#canvas-empty").hidden = false; }, { once: true });
    } else $("#canvas-empty").hidden = false;
    $("#world-scene").setAttribute("viewBox", `0 0 ${state.width} ${state.height}`);
    $("#canvas-dimensions").textContent = `${state.width} × ${state.height} master canvas`;
    bindEditor();
    await Promise.all([loadEditor(), loadImportedSVG()]);
    applyCamera();
    renderScene();
    setTool("select");
    setSaveStatus(state.dirty ? "Unsaved changes" : "Saved");
  }

  async function start() {
    state.data = await loadBoard();
    if (isManualMode(state.data)) initCorners();
    else await initEditor();
  }

  start().catch(error => {
    console.error(error);
    toast("The board could not be initialized.", true);
  });
})();
