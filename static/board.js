(() => {
  "use strict";

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
  const route = boardId ? `/board/${encodeURIComponent(boardId)}` : location.pathname;

  const state = {
    data: {},
    masterWidth: 1600,
    masterHeight: 900,
    view: "enhanced",
    layout: "overlay",
    tool: "pen",
    color: "#183153",
    size: 4,
    strokes: [],
    history: [],
    future: [],
    drawing: null,
    corners: [
      { x: .08, y: .10 }, { x: .92, y: .10 },
      { x: .92, y: .90 }, { x: .08, y: .90 }
    ],
    professorMarkup: "",
    dirty: false
  };

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

  function toast(message, isError = false) {
    const element = $("#toast");
    element.textContent = message;
    element.style.background = isError ? "#9b321f" : "";
    element.hidden = false;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { element.hidden = true; }, 3200);
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
    const data = state.data;
    const sources = [data.assets, data.files, data.outputs, data];
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

  async function fetchJSON(url, options = {}) {
    const response = await fetch(url, {
      headers: { "Accept": "application/json", ...(options.headers || {}) },
      ...options
    });
    if (!response.ok) throw new Error(`Server returned ${response.status}`);
    return response.json();
  }

  async function loadData() {
    if (embedded && Object.keys(embedded).length) return embedded;
    try { return await fetchJSON(route); }
    catch (error) {
      console.warn("Could not load board JSON", error);
      return { id: boardId, error: error.message };
    }
  }

  function normalizedData(raw) {
    const board = raw.board && typeof raw.board === "object" ? { ...raw, ...raw.board } : raw;
    const width = Number(board.master_width || board.width || board.dimensions?.width);
    const height = Number(board.master_height || board.height || board.dimensions?.height);
    if (width > 0) state.masterWidth = width;
    if (height > 0) state.masterHeight = height;
    const saved = board.user_strokes || board.strokes || board.annotations;
    state.strokes = Array.isArray(saved) ? saved.map(normalizeStroke).filter(Boolean) : [];
    const corners = board.normalized_corners || board.corners_normalized;
    if (Array.isArray(corners) && corners.length === 4) {
      state.corners = corners.map(point => ({
        x: clamp(Number(point.x ?? point[0]), 0, 1),
        y: clamp(Number(point.y ?? point[1]), 0, 1)
      }));
    }
    return board;
  }

  function normalizeStroke(stroke) {
    if (!stroke) return null;
    const points = Array.isArray(stroke.points) ? stroke.points.map(point => ({
      x: Number(point.x ?? point[0]), y: Number(point.y ?? point[1])
    })).filter(point => Number.isFinite(point.x) && Number.isFinite(point.y)) : [];
    if (!points.length && typeof stroke.d === "string") {
      return { d: stroke.d, color: stroke.color || "#183153", size: Number(stroke.size || stroke.width || 4) };
    }
    if (!points.length) return null;
    return { points, color: stroke.color || "#183153", size: Number(stroke.size || stroke.width || 4) };
  }

  function isManualMode(data) {
    const status = String(data.status || data.mode || "").toLowerCase();
    return Boolean(
      data.needs_corners || data.requires_corners || data.manual_corners ||
      ["manual", "corners", "needs_corners", "corner_selection"].includes(status)
    );
  }

  function clamp(value, min, max) { return Math.min(max, Math.max(min, value)); }

  /* Manual corner selection */
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
        setCornerFromPointer(Number(handle.dataset.corner), event);
      });
      handle.addEventListener("keydown", event => {
        const directions = { ArrowLeft: [-1,0], ArrowRight: [1,0], ArrowUp: [0,-1], ArrowDown: [0,1] };
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

  function setCornerFromPointer(index, event) {
    const bounds = $("#corner-stage").getBoundingClientRect();
    state.corners[index] = {
      x: clamp((event.clientX - bounds.left) / bounds.width, 0, 1),
      y: clamp((event.clientY - bounds.top) / bounds.height, 0, 1)
    };
    renderCorners();
  }

  function renderCorners() {
    const stage = $("#corner-stage");
    const width = stage.clientWidth;
    const height = stage.clientHeight;
    if (!width || !height) return;
    $$(".corner-handle").forEach((handle, index) => {
      handle.style.left = `${state.corners[index].x * 100}%`;
      handle.style.top = `${state.corners[index].y * 100}%`;
    });
    const image = $("#corner-image");
    const pixelPoints = state.corners.map(point =>
      `${point.x * (image.naturalWidth || width)},${point.y * (image.naturalHeight || height)}`
    );
    $("#corner-polygon").setAttribute("points", pixelPoints.join(" "));
    $("#corner-lines").setAttribute("points", [...pixelPoints, pixelPoints[0]].join(" "));
  }

  async function submitCorners() {
    const button = $("#submit-corners");
    const errorBox = $("#corner-error");
    const image = $("#corner-image");
    const pixels = state.corners.map(point => ({
      x: clamp(Math.round(point.x * image.naturalWidth), 0, image.naturalWidth - 1),
      y: clamp(Math.round(point.y * image.naturalHeight), 0, image.naturalHeight - 1)
    }));
    const payload = {
      corners: pixels,
      normalized_corners: state.corners.map(point => ({ x: point.x, y: point.y })),
      image_width: image.naturalWidth,
      image_height: image.naturalHeight
    };
    button.disabled = true;
    button.textContent = "Correcting…";
    errorBox.hidden = true;
    let lastError;
    for (const url of [`${route}/corners`, route]) {
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Accept": "application/json" },
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

  /* Editor and SVG drawing */
  async function initEditor() {
    $("#corner-workspace").hidden = true;
    $("#editor-workspace").hidden = false;
    $("#board-name").textContent = state.data.title || state.data.name || `Board ${boardId || ""}`.trim();
    $("#drawing-svg").setAttribute("viewBox", `0 0 ${state.masterWidth} ${state.masterHeight}`);
    $("#drawing-svg").setAttribute("preserveAspectRatio", "none");
    $("#canvas-dimensions").textContent = `${state.masterWidth} × ${state.masterHeight} master canvas`;
    bindEditorControls();
    await loadProfessorSVG();
    renderStrokes();
    updateView();
    buildDebugGallery();
  }

  function bindEditorControls() {
    $$('input[name="board-view"]').forEach(input => input.addEventListener("change", () => {
      state.view = input.value;
      updateView();
    }));
    $$(".segmented button").forEach(button => button.addEventListener("click", () => {
      state.layout = button.dataset.layout;
      $$(".segmented button").forEach(item => item.classList.toggle("is-active", item === button));
      updateLayout();
    }));
    $$(".tool-button").forEach(button => button.addEventListener("click", () => {
      state.tool = button.dataset.tool;
      $$(".tool-button").forEach(item => {
        item.classList.toggle("is-active", item === button);
        item.setAttribute("aria-pressed", String(item === button));
      });
      $("#drawing-svg").classList.toggle("eraser", state.tool === "eraser");
    }));
    $$(".color-chip").forEach(button => button.addEventListener("click", () => {
      state.color = button.dataset.color;
      $$(".color-chip").forEach(item => {
        item.classList.toggle("is-active", item === button);
        item.setAttribute("aria-pressed", String(item === button));
      });
    }));
    $("#custom-color").addEventListener("input", event => {
      state.color = event.target.value;
      $$(".color-chip").forEach(item => item.classList.remove("is-active"));
    });
    $("#stroke-size").addEventListener("input", event => { state.size = Number(event.target.value); });
    $("#professor-layer-toggle").addEventListener("change", event => {
      $("#professor-svg-layer").style.display = event.target.checked ? "" : "none";
      updateLayout();
    });
    $("#user-layer-toggle").addEventListener("change", event => {
      $("#user-strokes").style.display = event.target.checked ? "" : "none";
    });
    $("#undo-button").addEventListener("click", undo);
    $("#redo-button").addEventListener("click", redo);
    $("#clear-button").addEventListener("click", clearInk);
    $("#save-button").addEventListener("click", saveStrokes);
    $("#export-button").addEventListener("click", exportSVG);
    window.addEventListener("keydown", handleShortcut);
    window.addEventListener("beforeunload", event => {
      if (!state.dirty) return;
      event.preventDefault();
      event.returnValue = "";
    });
    const svg = $("#drawing-svg");
    svg.addEventListener("pointerdown", beginDrawing);
    svg.addEventListener("pointermove", continueDrawing);
    svg.addEventListener("pointerup", finishDrawing);
    svg.addEventListener("pointercancel", cancelDrawing);
  }

  function pointInMaster(event) {
    const svg = $("#drawing-svg");
    const point = svg.createSVGPoint();
    point.x = event.clientX;
    point.y = event.clientY;
    const matrix = svg.getScreenCTM();
    return matrix ? point.matrixTransform(matrix.inverse()) : { x: 0, y: 0 };
  }

  function beginDrawing(event) {
    if (event.button !== 0 && event.pointerType === "mouse") return;
    event.preventDefault();
    const svg = $("#drawing-svg");
    svg.setPointerCapture(event.pointerId);
    if (state.tool === "eraser") {
      eraseAt(event);
      return;
    }
    state.drawing = {
      pointerId: event.pointerId,
      color: state.color,
      size: state.size,
      points: [pointInMaster(event)]
    };
    drawActive();
  }

  function continueDrawing(event) {
    if (state.tool === "eraser" && $("#drawing-svg").hasPointerCapture(event.pointerId)) {
      eraseAt(event);
      return;
    }
    if (!state.drawing || state.drawing.pointerId !== event.pointerId) return;
    const events = event.getCoalescedEvents ? event.getCoalescedEvents() : [event];
    events.forEach(item => state.drawing.points.push(pointInMaster(item)));
    drawActive();
  }

  function finishDrawing(event) {
    if (!state.drawing || state.drawing.pointerId !== event.pointerId) return;
    if (state.drawing.points.length === 1) {
      const point = state.drawing.points[0];
      state.drawing.points.push({ x: point.x + .01, y: point.y + .01 });
    }
    recordHistory();
    state.strokes.push(state.drawing);
    state.drawing = null;
    $("#active-stroke").setAttribute("d", "");
    markChanged();
    renderStrokes();
  }

  function cancelDrawing() {
    state.drawing = null;
    $("#active-stroke").setAttribute("d", "");
  }

  function pathFromPoints(points) {
    if (!points?.length) return "";
    if (points.length < 3) return `M ${points[0].x} ${points[0].y} L ${points.at(-1).x} ${points.at(-1).y}`;
    let path = `M ${points[0].x} ${points[0].y}`;
    for (let i = 1; i < points.length - 1; i++) {
      const middleX = (points[i].x + points[i + 1].x) / 2;
      const middleY = (points[i].y + points[i + 1].y) / 2;
      path += ` Q ${points[i].x} ${points[i].y} ${middleX} ${middleY}`;
    }
    const last = points.at(-1);
    return `${path} L ${last.x} ${last.y}`;
  }

  function strokePath(stroke) { return stroke.d || pathFromPoints(stroke.points); }

  function makePath(stroke, index) {
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", strokePath(stroke));
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", stroke.color);
    path.setAttribute("stroke-width", stroke.size);
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    path.dataset.strokeIndex = index;
    return path;
  }

  function drawActive() {
    const path = $("#active-stroke");
    path.setAttribute("d", pathFromPoints(state.drawing.points));
    path.setAttribute("stroke", state.drawing.color);
    path.setAttribute("stroke-width", state.drawing.size);
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
  }

  function renderStrokes() {
    const group = $("#user-strokes");
    group.replaceChildren(...state.strokes.map(makePath));
    $("#undo-button").disabled = !state.history.length;
    $("#redo-button").disabled = !state.future.length;
  }

  function eraseAt(event) {
    const point = pointInMaster(event);
    const radius = Math.max(12, state.size * 3);
    const index = state.strokes.findIndex(stroke => {
      if (!stroke.points) return false;
      return stroke.points.some(p => Math.hypot(p.x - point.x, p.y - point.y) <= radius);
    });
    if (index < 0) return;
    recordHistory();
    state.strokes.splice(index, 1);
    markChanged();
    renderStrokes();
  }

  function cloneStrokes(strokes = state.strokes) {
    return JSON.parse(JSON.stringify(strokes));
  }

  function recordHistory() {
    state.history.push(cloneStrokes());
    if (state.history.length > 100) state.history.shift();
    state.future = [];
  }

  function markChanged() {
    state.dirty = true;
    setSaveStatus("Unsaved changes");
  }

  function undo() {
    if (!state.history.length) return;
    state.future.push(cloneStrokes());
    state.strokes = state.history.pop();
    markChanged();
    renderStrokes();
  }

  function redo() {
    if (!state.future.length) return;
    state.history.push(cloneStrokes());
    state.strokes = state.future.pop();
    markChanged();
    renderStrokes();
  }

  function clearInk() {
    if (!state.strokes.length || !confirm("Clear all of your ink from this board?")) return;
    recordHistory();
    state.strokes = [];
    markChanged();
    renderStrokes();
  }

  function handleShortcut(event) {
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "z") return;
    event.preventDefault();
    event.shiftKey ? redo() : undo();
  }

  async function saveStrokes() {
    const button = $("#save-button");
    button.disabled = true;
    button.textContent = "Saving…";
    setSaveStatus("Saving…");
    try {
      await fetchJSON(`${route}/save`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          board_id: boardId,
          master_width: state.masterWidth,
          master_height: state.masterHeight,
          user_strokes: state.strokes,
          strokes: state.strokes
        })
      });
      state.dirty = false;
      setSaveStatus("Saved");
      toast("Your ink is saved.");
    } catch (error) {
      setSaveStatus("Save failed");
      toast(`Could not save: ${error.message}`, true);
    } finally {
      button.disabled = false;
      button.textContent = "Save";
    }
  }

  async function loadProfessorSVG() {
    const inline = state.data.svg || state.data.svg_markup || state.data.professor_svg;
    let source = typeof inline === "string" && inline.trim().startsWith("<") ? inline : "";
    if (!source) {
      const url = findAsset("professor_svg") || asUrl(state.data.svg_url) ||
        (boardId ? `${route}/svg` : "");
      if (url) {
        try {
          const response = await fetch(url);
          if (response.ok) source = await response.text();
        } catch (error) { console.warn("Professor SVG unavailable", error); }
      }
    }
    const safe = sanitizeSVG(source);
    if (!safe) return;
    state.professorMarkup = safe.outerHTML;
    safe.setAttribute("preserveAspectRatio", "none");
    safe.setAttribute("width", "100%");
    safe.setAttribute("height", "100%");
    $("#professor-svg-layer").replaceChildren(safe);
    const referenceCopy = safe.cloneNode(true);
    referenceCopy.setAttribute("aria-hidden", "true");
    $("#reference-professor-layer").replaceChildren(referenceCopy);
    const objectCount = safe.querySelectorAll("path,line,polyline,polygon,circle,ellipse,rect,text").length;
    $("#object-count").textContent = `${objectCount} object${objectCount === 1 ? "" : "s"}`;
  }

  function sanitizeSVG(markup) {
    if (!markup) return null;
    const documentNode = new DOMParser().parseFromString(markup, "image/svg+xml");
    const svg = documentNode.documentElement;
    if (svg.nodeName.toLowerCase() !== "svg" || documentNode.querySelector("parsererror")) return null;
    svg.querySelectorAll("script,foreignObject,iframe,object,embed").forEach(node => node.remove());
    svg.querySelectorAll('[id="user-ink"]').forEach(node => node.remove());
    svg.querySelectorAll('[data-role="background"]').forEach(node => node.remove());
    svg.querySelectorAll("*").forEach(node => {
      [...node.attributes].forEach(attribute => {
        const value = attribute.value.trim().toLowerCase();
        if (attribute.name.toLowerCase().startsWith("on") || value.startsWith("javascript:")) {
          node.removeAttribute(attribute.name);
        }
      });
      node.style.pointerEvents = "none";
    });
    return document.importNode(svg, true);
  }

  function updateView() {
    const debug = state.view === "debug";
    $("#debug-panel").hidden = !debug;
    $(".canvas-column").hidden = debug;
    if (debug) return;
    const image = $("#board-raster");
    const source = findAsset(state.view);
    $("#primary-label").textContent = state.view === "enhanced" ? "Enhanced master" :
      state.view[0].toUpperCase() + state.view.slice(1);
    if (state.view === "digitized") {
      image.src = findAsset("enhanced") || findAsset("corrected");
    } else {
      image.src = source;
    }
    const showsUserInk = ["enhanced", "digitized"].includes(state.view);
    $("#drawing-svg").style.display = showsUserInk ? "" : "none";
    $("#drawing-svg").style.pointerEvents = showsUserInk ? "" : "none";
    $("#canvas-empty").hidden = Boolean(image.src);
    image.onerror = () => { $("#canvas-empty").hidden = false; };
    image.onload = () => {
      $("#canvas-empty").hidden = true;
      if (!state.data.master_width && image.naturalWidth && state.view === "enhanced") {
        state.masterWidth = image.naturalWidth;
        state.masterHeight = image.naturalHeight;
        $("#drawing-svg").setAttribute("viewBox", `0 0 ${state.masterWidth} ${state.masterHeight}`);
      }
    };
    updateLayout();
  }

  function updateLayout() {
    const reference = $("#reference-frame");
    const primary = $("#primary-frame");
    const primaryImage = $("#board-raster");
    const professor = $("#professor-svg-layer");
    const referenceProfessor = $("#reference-professor-layer");
    const referenceRaster = $("#reference-raster");
    const isDigitized = state.view === "digitized";
    const sideBySide = isDigitized && state.layout === "side";
    const rasterizedVectors = findAsset("svg_raster");
    const professorVisible = $("#professor-layer-toggle").checked;

    $("#comparison-grid").classList.toggle("side-by-side", sideBySide);
    reference.hidden = !sideBySide;
    primary.style.backgroundImage = "";
    primary.style.backgroundSize = "";
    primaryImage.style.opacity = "1";
    primaryImage.src = isDigitized
      ? (findAsset("enhanced") || findAsset("corrected"))
      : findAsset(state.view);

    professor.style.display = isDigitized && !sideBySide && professorVisible ? "" : "none";
    professor.style.opacity = isDigitized && state.layout === "overlay" ? ".5" : "1";

    if (!sideBySide) return;
    $("#primary-label").textContent = "Enhanced master";
    $("#reference-label").textContent = "Digitized vectors";
    reference.style.aspectRatio = `${state.masterWidth} / ${state.masterHeight}`;
    if (rasterizedVectors) {
      referenceRaster.hidden = !professorVisible;
      referenceRaster.src = rasterizedVectors;
      referenceProfessor.style.display = "none";
    } else {
      referenceRaster.hidden = true;
      referenceRaster.removeAttribute("src");
      referenceProfessor.style.display = professorVisible ? "" : "none";
    }
  }

  function buildDebugGallery() {
    const confidence = state.data.confidence ?? state.data.detection_confidence ?? state.data.metrics?.confidence;
    if (confidence !== undefined && confidence !== null) {
      const numeric = Number(confidence);
      $("#confidence-badge").textContent = `Confidence ${numeric <= 1 ? Math.round(numeric * 100) : Math.round(numeric)}%`;
    }
    const cards = [
      ["Original", "Camera input", findAsset("original")],
      ["Corrected", "Perspective transform", findAsset("corrected")],
      ["Enhanced master", "Cleaned board raster", findAsset("enhanced")],
      ["Confidence", "Board detection confidence", findAsset("confidence")],
      ["Ink mask", "Combined detected writing", findAsset("ink_mask")],
      ["Black mask", "Detected black marker", findAsset("black_mask")],
      ["Red mask", "Detected red marker", findAsset("red_mask")],
      ["Blue mask", "Detected blue marker", findAsset("blue_mask")],
      ["Green mask", "Detected green marker", findAsset("green_mask")],
      ["SVG raster", "Vectors rendered in master coordinates", findAsset("svg_raster")],
      ["Master vs SVG", "Geometry-aligned visual comparison", findAsset("master_vs_svg")]
    ];
    $("#debug-gallery").replaceChildren(...cards.map(([name, detail, src]) => {
      const card = document.createElement("article");
      card.className = "debug-card";
      const figure = document.createElement("figure");
      if (src) {
        const image = new Image();
        image.alt = `${name} processing artifact`;
        image.loading = "lazy";
        image.src = src;
        image.addEventListener("error", () => {
          image.replaceWith(missingArtifact());
        });
        figure.append(image);
      } else figure.append(missingArtifact());
      const caption = document.createElement("figcaption");
      const strong = document.createElement("strong");
      const small = document.createElement("small");
      strong.textContent = name;
      small.textContent = src ? detail : `${detail} · not generated`;
      caption.append(strong, small);
      figure.append(caption);
      card.append(figure);
      return card;
    }));
  }

  function missingArtifact() {
    const missing = document.createElement("div");
    missing.className = "missing";
    missing.textContent = "Artifact unavailable";
    return missing;
  }

  function exportSVG() {
    const parser = new DOMParser();
    const professor = state.professorMarkup
      ? parser.parseFromString(state.professorMarkup, "image/svg+xml").documentElement.innerHTML
      : "";
    const user = state.strokes.map(stroke => {
      const d = strokePath(stroke).replace(/&/g, "&amp;").replace(/"/g, "&quot;");
      const color = String(stroke.color).replace(/[^#a-zA-Z0-9(),.%\s-]/g, "");
      return `<path d="${d}" fill="none" stroke="${color}" stroke-width="${Number(stroke.size)}" stroke-linecap="round" stroke-linejoin="round"/>`;
    }).join("");
    const output = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${state.masterWidth} ${state.masterHeight}" width="${state.masterWidth}" height="${state.masterHeight}"><rect width="100%" height="100%" fill="white"/><g id="professor-ink">${professor}</g><g id="user-ink">${user}</g></svg>`;
    const url = URL.createObjectURL(new Blob([output], { type: "image/svg+xml" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `board-${boardId || "export"}.svg`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast("SVG exported.");
  }

  async function start() {
    state.data = normalizedData(await loadData());
    if (state.data.error && !findAsset("original")) {
      toast("Board data could not be loaded.", true);
    }
    if (isManualMode(state.data)) initCorners();
    else await initEditor();
  }

  start().catch(error => {
    console.error(error);
    toast("The board could not be initialized.", true);
  });
})();
