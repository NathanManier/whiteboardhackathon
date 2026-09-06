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
  const MIN_ZOOM = globalThis.BoardEngine?.MIN_ZOOM || 0.04;
  const MAX_ZOOM = globalThis.BoardEngine?.MAX_ZOOM || 64;
  const PINCH_ZOOM_SLOP = 16;
  const DISPLAY_CELL = 240;
  const Pencil = globalThis.PencilTools || null;
  const TOOLS = new Set([
    "select", "lasso", "pen", "marker", "pencil", "highlighter",
    "object-eraser", "pixel-eraser"
  ]);

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
    groups: [],
    importedObjects: [],
    importedTransforms: {},
    selected: new Set(),
    tool: "pen",
    toolConfig: Pencil ? Pencil.createToolState() : null,
    toolbarVisible: true,
    autoHideToolbar: false,
    paletteMode: "closed",
    lastPenScreen: null,
    pencilCapabilities: Pencil ? Pencil.detectPencilCapabilities() : null,
    penSize: 4,
    penColor: "#111827",
    highlighterSize: 18,
    highlighterColor: "#eab308",
    eraserSize: 16,
    color: "#111827",
    size: 4,
    history: [],
    future: [],
    interaction: null,
    pointers: new Map(),
    activePointerIds: new Set(),
    spaceDown: false,
    dirty: false,
    saveTimer: 0,
    saving: false,
    saveAgain: false,
    importedMarkup: "",
    masterUrl: "",
    capturedPointer: null,
    captureSerial: 0,
    releasingCapture: false,
    importedMap: { x: 0, y: 0, scaleX: 1, scaleY: 1 },
    historyTimer: 0,
    pendingHistory: [],
    cachedSceneRect: null,
    liveNode: null,
    liveInkRaf: 0,
    penHud: { strokes: 0, downs: 0, moves: 0, ups: 0, lastRaw: 0, lastRendered: 0, lastFinal: 0 },
    studyInteractions: [],
    activeStudyId: null,
    pendingStudyId: null,
    studyRequestToken: 0,
    explaining: false,
    pendingStudyQuestion: "",
    pendingStudyAction: "",
    cameraGesture: "idle",
    cameraRaf: 0,
    cameraHudAt: 0,
    viewportBox: { width: 0, height: 0 },
    lastTool: "select",
    clipboard: null,
    cachedSelectionUnion: null,
    displayLevel: "full",
    lastPenTap: null,
    geometryCache: null,
    spatial: null,
    displayCells: new Map(),
    commandTotal: 0,
    visibleCount: 0,
    culledCount: 0,
    svgNodeCount: 0,
    cullTimer: 0,
    navigating: false,
    fingerTap: null,
    perf: null,
    twoFingerTap: null,
    sourceBoards: [],
    lecture: {
      folderId: "",
      folderName: "",
      workspaceId: "",
      isLecture: false,
      boards: [],
      studyGuide: null,
      stale: false
    },
    pendingImportedId: ""
  };

  /* Authoritative high-frequency Pencil buffer. Never wait on React/save/render. */
  let activeInk = null;
  let studyGuideBusy = false;
  let studyGuideProgressTimer = 0;

  const DEBUG_EDITOR = (() => {
    try {
      return /(?:\?|&|#)editorDebug=1\b/.test(`${location.search}${location.hash}`) ||
        localStorage.getItem("boardlift-editor-debug") === "1";
    } catch (_) { return false; }
  })();
  const DEBUG_STUDY = (() => {
    try {
      return DEBUG_EDITOR ||
        /(?:\?|&|#)studyDebug=1\b/.test(`${location.search}${location.hash}`) ||
        localStorage.getItem("boardlift-study-debug") === "1";
    } catch (_) { return false; }
  })();
  const DEBUG_PERF = (() => {
    try {
      return DEBUG_EDITOR ||
        /(?:\?|&|#)perf=1\b/.test(`${location.search}${location.hash}`) ||
        localStorage.getItem("boardlift-perf") === "1";
    } catch (_) { return false; }
  })();
  const Engine = globalThis.BoardEngine || {};
  const LOD = Engine.LEVEL || { FULL: "full", INTERACTION: "interaction", NAVIGATION: "navigation" };

  function editorLog(event, detail) {
    if (!DEBUG_EDITOR) return;
    if (detail !== undefined) console.info(`[editor] ${event}`, detail);
    else console.info(`[editor] ${event}`);
  }

  function studyLog(event, detail) {
    if (!DEBUG_STUDY) return;
    if (detail !== undefined) console.info(`[study] ${event}`, detail);
    else console.info(`[study] ${event}`);
  }

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
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(payload.error || payload.message || `Server returned ${response.status}`);
      error.status = response.status;
      throw error;
    }
    return payload;
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
    const points = Array.isArray(stroke.points) ? stroke.points.map(point => {
      const next = {
        x: Number(point.x ?? point[0]), y: Number(point.y ?? point[1])
      };
      const pressure = Number(point.p ?? point.pressure);
      if (Number.isFinite(pressure)) next.p = clamp(pressure, 0, 1);
      const tiltX = Number(point.tiltX);
      const tiltY = Number(point.tiltY);
      if (Number.isFinite(tiltX)) next.tiltX = tiltX;
      if (Number.isFinite(tiltY)) next.tiltY = tiltY;
      return next;
    }).filter(point => Number.isFinite(point.x) && Number.isFinite(point.y)) : [];
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
      sx: Number(stroke.sx ?? stroke.scaleX ?? stroke.scale?.x) || 1,
      sy: Number(stroke.sy ?? stroke.scaleY ?? stroke.scale?.y) || 1,
      erasures: (Array.isArray(stroke.erasures) ? stroke.erasures :
        (Array.isArray(stroke.erase_paths) ? stroke.erase_paths : [])).map(erasure => ({
          ...erasure,
          points: Array.isArray(erasure.points) ? erasure.points.map(point => ({
            x: Number(point.x ?? point[0]), y: Number(point.y ?? point[1])
          })).filter(point => Number.isFinite(point.x) && Number.isFinite(point.y)) : undefined
        })),
      boardId: stroke.boardId || stroke.board_id || "",
      origin: stroke.origin || "student",
      folderId: stroke.folderId || stroke.folder_id || "",
      createdAt: Number(stroke.createdAt || stroke.created_at) || 0
    };
  }

  function normalizeObject(object) {
    if (!object || typeof object !== "object") return null;
    if (object.type === "text") {
      const role = object.role === "ai_practice_problem" || object.role === "practice_problem"
        ? "ai_practice_problem" : "";
      return {
        id: object.id || uid("text"),
        type: "text",
        x: Number(object.x) || 0,
        y: Number(object.y) || 0,
        width: Math.max(4, Number(object.width) || 40),
        height: Math.max(4, Number(object.height) || 20),
        text: String(object.text || ""),
        color: object.color || "#183153",
        fontSize: clamp(Number(object.fontSize || object.font_size || 28), 8, 240),
        wrapWidth: Number(object.wrapWidth || object.wrap_width) || 0,
        role,
        practiceProblemId: object.practiceProblemId || object.practice_problem_id || "",
        sourceStudyInteractionId: object.sourceStudyInteractionId || object.source_study_interaction_id || "",
        generatedAt: Number(object.generatedAt || object.generated_at) || 0,
        boardId: object.boardId || object.board_id || "",
        origin: object.origin || (role === "ai_practice_problem" ? "ai_practice" : ""),
        folderId: object.folderId || object.folder_id || "",
        createdAt: Number(object.createdAt || object.created_at) || 0
      };
    }
    if (object.type === "path") {
      const d = typeof object.d === "string" ? object.d : "";
      if (!d) return null;
      return {
        id: object.id || uid("path"),
        type: "path",
        d,
        color: object.color || object.fill || "#183153",
        fill: object.fill || object.color || "#183153",
        width: Math.max(0, Number(object.width) || 0),
        opacity: Number.isFinite(Number(object.opacity)) ? Number(object.opacity) : 1,
        tx: Number(object.tx ?? object.translation?.x) || 0,
        ty: Number(object.ty ?? object.translation?.y) || 0,
        sx: Number(object.sx ?? object.scaleX ?? object.scale?.x) || 1,
        sy: Number(object.sy ?? object.scaleY ?? object.scale?.y) || 1,
        bbox: object.bbox && typeof object.bbox === "object" ? object.bbox : null,
        sourceD: d,
        sourceRevision: 1,
        boardId: object.boardId || object.board_id || "",
        origin: object.origin || "student",
        folderId: object.folderId || object.folder_id || "",
        createdAt: Number(object.createdAt || object.created_at) || 0
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
    const schema = Number(source.schema_version || 0);
    const needsMigration = objects.some(object => !object?.id) || (schema > 0 && schema < 2);
    const camera = source.viewport || source.camera;
    state.revision = Math.max(0, Number(source.revision) || 0);
    state.objects = objects.map(normalizeObject).filter(Boolean);
    state.groups = Array.isArray(source.groups) ? source.groups.map(normalizeGroup).filter(Boolean) : [];
    state.importedTransforms = source.imported_transforms && typeof source.imported_transforms === "object"
      ? source.imported_transforms : {};
    state.sourceBoards = normalizeSourceBoards(source.source_boards || source.sourceBoards || state.data.source_boards);
    state.camera = validCamera(camera) ? {
      x: Number(camera.x), y: Number(camera.y),
      width: Number(camera.width), height: Number(camera.height)
    } : paddedBoardCamera();
    if (needsMigration && state.objects.length) markChanged();
  }

  function normalizeSourceBoards(value) {
    if (!Array.isArray(value)) return [];
    return value.filter(item => item && (item.board_id || item.boardId)).map((item, index) => ({
      boardId: item.boardId || item.board_id,
      boardOrder: Number(item.boardOrder || item.board_order || index + 1) || index + 1,
      x: Number(item.x) || 0,
      y: Number(item.y) || 0,
      width: Math.max(1, Number(item.width) || state.width),
      height: Math.max(1, Number(item.height) || state.height),
      label: item.label || `Whiteboard ${index + 1}`
    }));
  }

  function lectureBoardsFromData(data = state.data) {
    const members = Array.isArray(data.lecture_boards || data.lectureBoards)
      ? (data.lecture_boards || data.lectureBoards) : [];
    if (members.length) {
      return members.map((item, index) => ({
        boardId: item.boardId || item.id,
        boardOrder: Number(item.boardOrder || item.board_order || index + 1) || index + 1,
        x: Number(item.x) || 0,
        y: Number(item.y) || 0,
        width: Math.max(1, Number(item.width) || state.width),
        height: Math.max(1, Number(item.height) || state.height),
        label: item.label || `Whiteboard ${index + 1}`,
        svgUrl: item.svgUrl || item.svg_url || professorSvgUrl(item.boardId || item.id),
        name: item.name || item.label || `Whiteboard ${index + 1}`,
        status: item.status || "ready"
      })).filter(item => item.status === "ready" || item.boardId === boardId);
    }
    return state.sourceBoards.length ? state.sourceBoards.map(item => ({
      ...item,
      svgUrl: professorSvgUrl(item.boardId),
      name: item.label
    })) : [{
      boardId, boardOrder: 1, x: 0, y: 0, width: state.width, height: state.height,
      label: "Whiteboard 1", svgUrl: professorSvgUrl(boardId), name: "Whiteboard 1"
    }];
  }

  function applyLectureData(data = state.data) {
    state.lecture.folderId = data.folder_id || data.folderId || "";
    state.lecture.folderName = data.folder_name || data.folderName || "";
    state.lecture.workspaceId = data.workspace_board_id || data.workspaceBoardId || boardId;
    state.lecture.isLecture = Boolean(data.is_lecture || data.isLecture || state.lecture.folderId);
    state.lecture.studyGuide = data.study_guide || data.studyGuide || null;
    state.lecture.stale = Boolean(data.study_guide_stale || data.studyGuideStale || state.lecture.studyGuide?.stale);
    if (!state.sourceBoards.length) {
      state.sourceBoards = normalizeSourceBoards(data.source_boards || lectureBoardsFromData(data));
    }
    const kicker = $("#lecture-kicker");
    if (kicker) {
      kicker.textContent = state.lecture.isLecture ? "Lecture workspace" : "Study canvas";
    }
    const guideButton = $("#study-guide-button");
    if (guideButton) guideButton.hidden = !state.lecture.folderId;
    syncStudyGuideButton();
  }

  function normalizeGroup(group) {
    if (!group || typeof group !== "object" || !group.id || !Array.isArray(group.children)) return null;
    const transform = group.transform || {};
    return {
      id: String(group.id),
      type: "group",
      children: group.children.map(String),
      transform: {
        x: Number(transform.x) || 0,
        y: Number(transform.y) || 0,
        scaleX: Number(transform.scaleX) || 1,
        scaleY: Number(transform.scaleY) || 1,
        rotation: Number(transform.rotation) || 0
      }
    };
  }

  function validCamera(camera) {
    return camera && [camera.x, camera.y, camera.width, camera.height]
      .every(value => Number.isFinite(Number(value))) &&
      Number(camera.width) > 0 && Number(camera.height) > 0 &&
      Number(camera.width) !== Infinity && Number(camera.height) !== Infinity;
  }

  function isManualMode(data) {
    const status = String(data.status || data.mode || "").toLowerCase();
    if (["ready", "complete", "processing"].includes(status)) return false;
    return Boolean(data.needs_corners || data.requires_corners ||
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

  function objectTransformValue(tx = 0, ty = 0, sx = 1, sy = 1) {
    const translate = `translate(${Number(tx) || 0} ${Number(ty) || 0})`;
    if ((Number(sx) || 1) === 1 && (Number(sy) || 1) === 1) return translate;
    return `${translate} scale(${Number(sx) || 1} ${Number(sy) || 1})`;
  }

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
    });
    return svg;
  }

  function parseViewBox(svg) {
    const parts = String(svg.getAttribute("viewBox") || "").trim().split(/[\s,]+/).map(Number);
    if (parts.length === 4 && parts.every(Number.isFinite) && parts[2] > 0 && parts[3] > 0) {
      return { x: parts[0], y: parts[1], width: parts[2], height: parts[3] };
    }
    const width = Number(svg.getAttribute("width")) || state.width;
    const height = Number(svg.getAttribute("height")) || state.height;
    return { x: 0, y: 0, width, height };
  }

  function importedPrefix(sourceBoardId) {
    return !sourceBoardId || sourceBoardId === boardId ? "" : `${sourceBoardId.slice(0, 8)}_`;
  }

  function professorSvgUrl(sourceBoardId) {
    if (sourceBoardId === boardId) {
      return findAsset("professor_svg") || `/boards/${encodeURIComponent(sourceBoardId)}/board.svg`;
    }
    return sourceBoardId ? `/boards/${encodeURIComponent(sourceBoardId)}/board.svg` : "";
  }

  async function fetchBoardSvg(board) {
    const url = board.svgUrl || professorSvgUrl(board.boardId);
    if (!url) return "";
    try {
      const response = await fetch(url);
      if (response.ok) return await response.text();
    } catch (error) {
      console.warn("Imported SVG unavailable", error);
    }
    return "";
  }

  function mountImportedBoard(board, markup, layer) {
    const safe = sanitizeSVG(markup);
    if (!safe) return [];
    const viewBox = parseViewBox(safe);
    const scaleX = board.width / viewBox.width;
    const scaleY = board.height / viewBox.height;
    const map = { x: viewBox.x, y: viewBox.y, scaleX, scaleY };
    const wrap = svgEl("g", {
      class: "source-board-ink",
      "data-source-board": board.boardId,
      transform: `translate(${board.x} ${board.y})`
    });
    const needsMap = Math.abs(scaleX - 1) > 1e-6 || Math.abs(scaleY - 1) > 1e-6 ||
      viewBox.x !== 0 || viewBox.y !== 0;
    let host = wrap;
    if (needsMap) {
      host = svgEl("g", {
        transform: `scale(${scaleX} ${scaleY}) translate(${-viewBox.x} ${-viewBox.y})`
      });
      wrap.append(host);
    }
    layer.append(wrap);
    const prefix = importedPrefix(board.boardId);
    return [...safe.querySelectorAll("path")].map((path, index) => {
      const original = /^[A-Za-z0-9_.-]{1,64}$/.test(path.id || "")
        ? path.id : `ink-region-${String(index).padStart(5, "0")}`;
      const id = `${prefix}${original}`.slice(0, 64);
      const saved = state.importedTransforms?.[id] || state.importedTransforms?.[original] || {};
      const tx = Number(saved.x) || 0;
      const ty = Number(saved.y) || 0;
      const sx = Number(saved.scaleX) || 1;
      const sy = Number(saved.scaleY) || 1;
      const deleted = Boolean(saved.deleted);
      const wrapper = svgEl("g", {
        id: `${id}-wrap`,
        class: "imported-object",
        "data-object-id": id,
        "data-board-id": board.boardId,
        transform: objectTransformValue(tx, ty, sx, sy)
      });
      if (deleted) wrapper.setAttribute("display", "none");
      const node = document.importNode(path, true);
      node.id = id;
      node.dataset.objectId = id;
      node.dataset.boardId = board.boardId;
      node.style.pointerEvents = "visiblePainted";
      const sourceD = node.getAttribute("d") || "";
      node.dataset.sourceD = sourceD;
      wrapper.append(node);
      host.append(wrapper);
      let box = { x: 0, y: 0, width: 0, height: 0 };
      try { box = node.getBBox(); } catch (_) {}
      return {
        id, type: "imported", bbox: box,
        color: node.getAttribute("fill") || node.getAttribute("stroke") || "",
        color_class: node.getAttribute("data-ink") || "",
        tx, ty, sx, sy, deleted,
        node: wrapper, path: node, locked: false,
        sourceD,
        sourceRevision: 1,
        commandCount: Engine.commandCount ? Engine.commandCount(sourceD) : 0,
        displayLevel: LOD.FULL,
        boardId: board.boardId,
        boardOrder: board.boardOrder,
        originX: board.x,
        originY: board.y,
        map
      };
    });
  }

  /* Paths leave the source SVG so they are not clipped to the photographed board. */
  async function loadImportedSVG() {
    const layer = $("#imported-layer");
    layer.replaceChildren();
    const boards = lectureBoardsFromData();
    if (!state.sourceBoards.length) {
      state.sourceBoards = boards.map(item => ({
        boardId: item.boardId, boardOrder: item.boardOrder, x: item.x, y: item.y,
        width: item.width, height: item.height, label: item.label
      }));
    }
    state.importedMap = { x: 0, y: 0, scaleX: 1, scaleY: 1 };
    const objects = [];
    for (const board of boards) {
      const markup = await fetchBoardSvg(board);
      if (!markup) continue;
      objects.push(...mountImportedBoard(board, markup, layer));
    }
    state.importedObjects = objects;
    state.importedMarkup = layer.innerHTML;
    state.commandTotal = objects.reduce((sum, item) => sum + (item.commandCount || 0), 0);
    renderBoardPapers(boards);
    rebuildSpatialIndex();
    buildImportedDisplay();
    prepareDerivedGeometry();
  }

  function renderBoardPapers(boards = lectureBoardsFromData()) {
    const papers = $("#board-papers");
    const single = $("#board-paper");
    const edge = $("#board-paper-edge");
    if (single) single.setAttribute("hidden", "");
    if (edge) edge.setAttribute("hidden", "");
    if (!papers) return;
    papers.replaceChildren();
    boards.forEach(board => {
      papers.append(svgEl("rect", {
        class: "source-board-paper",
        x: board.x, y: board.y, width: board.width, height: board.height,
        fill: "#f7f6f2", stroke: "#e4e1d8",
        "stroke-width": Math.max(1, board.width / 900),
        "pointer-events": "none"
      }));
      const label = svgEl("text", {
        class: "source-board-label",
        x: board.x + 12,
        y: board.y - 10,
        fill: "#8a93a3",
        "font-size": Math.max(12, Math.min(18, board.width / 90)),
        "font-family": "system-ui, sans-serif",
        "pointer-events": "none"
      });
      label.textContent = board.label || `Whiteboard ${board.boardOrder}`;
      papers.append(label);
    });
  }

  function refreshSceneRect() {
    const svg = $("#world-scene");
    state.cachedSceneRect = svg
      ? svg.getBoundingClientRect()
      : { left: 0, top: 0, width: 0, height: 0 };
    return state.cachedSceneRect;
  }

  function sceneRect() {
    const cached = state.cachedSceneRect;
    if (cached && cached.width > 0 && cached.height > 0) return cached;
    return refreshSceneRect();
  }

  function sceneAspect(rect = sceneRect()) {
    return rect.width > 0 && rect.height > 0 ? rect.width / rect.height : state.width / state.height;
  }

  function cameraBasis() {
    const bounds = lectureContentBounds();
    return Math.max(state.width, bounds.width, 1);
  }

  function cameraZoom(camera = state.camera, rect = sceneRect()) {
    if (Engine.cameraZoom) return Engine.cameraZoom(camera, rect);
    return rect.width > 0 ? rect.width / camera.width : state.width / camera.width;
  }

  function clampCameraSize(width) {
    return clamp(width, cameraBasis() / MAX_ZOOM, cameraBasis() / MIN_ZOOM);
  }

  function cameraWithAspect(camera, aspect = sceneAspect()) {
    if (Engine.sanitizeCamera) {
      return Engine.sanitizeCamera(camera, {
        width: sceneRect().width,
        height: sceneRect().width / (aspect || 1),
        left: 0,
        top: 0
      }, { minZoom: MIN_ZOOM, maxZoom: MAX_ZOOM, basis: cameraBasis() });
    }
    const width = clampCameraSize(camera.width);
    const height = width / (aspect || 1);
    const x = Number.isFinite(camera.x) ? camera.x : 0;
    const y = Number.isFinite(camera.y) ? camera.y : 0;
    return { x, y, width, height };
  }

  function cameraPanZoom(camera = state.camera, rect = sceneRect()) {
    if (Engine.cameraAsPanZoom) return Engine.cameraAsPanZoom(camera, rect);
    return { panX: camera.x, panY: camera.y, zoom: cameraZoom(camera, rect) };
  }

  function syncViewportBox(rect = sceneRect()) {
    const svg = $("#world-scene");
    if (!svg || !rect.width || !rect.height) return rect;
    const width = Math.max(1, rect.width);
    const height = Math.max(1, rect.height);
    const current = svg.getAttribute("viewBox") || "";
    const next = `0 0 ${width} ${height}`;
    if (current !== next) svg.setAttribute("viewBox", next);
    state.viewportBox = { width, height };
    return rect;
  }

  function updateHitfill(camera = state.camera) {
    const hit = $("#canvas-hitfill");
    if (!hit) return;
    const zoom = Math.max(MIN_ZOOM, cameraZoom(camera));
    const margin = Math.max(180, 220 / zoom);
    hit.setAttribute("x", String(camera.x - margin));
    hit.setAttribute("y", String(camera.y - margin));
    hit.setAttribute("width", String(camera.width + margin * 2));
    hit.setAttribute("height", String(camera.height + margin * 2));
  }

  function applyCameraPlane(camera = state.camera, rect = sceneRect()) {
    const world = $("#camera-world");
    const html = $("#canvas-html-world");
    if (Engine.applySceneTransform) {
      const mapped = Engine.applySceneTransform(world, html, camera, rect);
      updateHitfill(camera);
      return mapped;
    }
    const zoom = cameraZoom(camera, rect);
    if (world) {
      world.style.transform = "none";
      world.setAttribute("transform", `translate(${-camera.x * zoom} ${-camera.y * zoom}) scale(${zoom})`);
    }
    if (html) {
      html.style.transform = `scale(${zoom}) translate(${-camera.x}px, ${-camera.y}px)`;
      html.style.transformOrigin = "0 0";
    }
    updateHitfill(camera);
    return { zoom };
  }

  function setNavigating(active) {
    state.navigating = Boolean(active);
    const world = $("#camera-world");
    world?.classList.toggle("is-navigating", state.navigating);
    if (world && cameraZoom() > 4) world.style.willChange = "auto";
    if (state.perf) state.perf.level = "full";
  }

  function updateZoomLabel(camera = state.camera) {
    const label = $("#zoom-label");
    if (label) label.textContent = `${Math.round(cameraZoom(camera) * 100)}%`;
  }

  function applyCamera({ hud = true, overlays = true } = {}) {
    const camera = state.camera = cameraWithAspect(state.camera);
    syncViewportBox();
    applyCameraPlane(camera);
    if (hud) updateZoomLabel(camera);
    if (overlays) {
      syncStudyMarkerScale();
      positionExplainButton();
    } else {
      positionExplainButton({ cheap: true });
    }
    if (state.perf) {
      state.perf.zoom = cameraZoom(camera);
      state.perf.gesture = state.cameraGesture || state.interaction?.kind || "idle";
      state.perf.pointers = state.activePointerIds.size;
    }
    if (state.navigating) refreshViewportCull({ moving: true });
  }

  function scheduleIncomingReveal() {
    scheduleViewportCull();
  }

  function scheduleCameraFrame({ hud = false, overlays = false } = {}) {
    if (state.cameraRaf) {
      state.cameraFlushHud = state.cameraFlushHud || hud;
      state.cameraFlushOverlays = state.cameraFlushOverlays || overlays;
      return;
    }
    state.cameraFlushHud = hud;
    state.cameraFlushOverlays = overlays;
    state.cameraRaf = requestAnimationFrame(() => {
      state.cameraRaf = 0;
      const moving = state.navigating || ["pan", "pinch"].includes(state.cameraGesture);
      const hudNow = state.cameraFlushHud || !moving || (nowMs() - (state.cameraHudAt || 0) > 80);
      applyCamera({
        hud: hudNow,
        overlays: state.cameraFlushOverlays || !moving
      });
      if (hudNow) state.cameraHudAt = nowMs();
    });
  }

  function nowMs() {
    return performance.now();
  }

  function defaultCamera() {
    const bounds = lectureContentBounds();
    const padX = bounds.width * .08;
    const padY = bounds.height * .08;
    const contentW = bounds.width + padX * 2;
    const contentH = bounds.height + padY * 2;
    const aspect = sceneAspect();
    let width;
    let height;
    if (contentW / contentH > aspect) {
      width = contentW;
      height = width / aspect;
    } else {
      height = contentH;
      width = height * aspect;
    }
    return {
      x: bounds.x + (bounds.width - width) / 2,
      y: bounds.y + (bounds.height - height) / 2,
      width,
      height
    };
  }

  const paddedBoardCamera = defaultCamera;

  function resetView() {
    const before = clone(state.camera);
    state.camera = defaultCamera();
    applyCamera();
    editorLog("CAMERA RESET", {
      before, after: clone(state.camera), zoom: cameraZoom()
    });
    markChanged();
  }

  function syncCameraAspect() {
    refreshSceneRect();
    syncViewportBox();
    const cam = state.camera;
    const aspect = sceneAspect();
    if (!aspect || !cam.width) return;
    if (Math.abs(cam.width / cam.height - aspect) < 1e-4) return;
    const cy = cam.y + cam.height / 2;
    state.camera = { x: cam.x, y: cy - (cam.width / aspect) / 2, width: cam.width, height: cam.width / aspect };
    applyCamera();
  }

  /* Screen ↔ canvas uses one camera matrix: screen = canvas * zoom + pan. */
  function screenToCanvas(clientX, clientY, camera = state.camera, rect = sceneRect()) {
    if (Engine.screenToCanvas && rect.width && rect.height) {
      return Engine.screenToCanvas(clientX, clientY, camera, rect);
    }
    if (!rect.width || !rect.height) return { x: camera.x, y: camera.y };
    const zoom = cameraZoom(camera, rect);
    return {
      x: camera.x + (clientX - rect.left) / zoom,
      y: camera.y + (clientY - rect.top) / zoom
    };
  }

  function canvasToScreen(x, y, camera = state.camera, rect = sceneRect()) {
    if (Engine.canvasToScreen && rect.width && rect.height) {
      return Engine.canvasToScreen(x, y, camera, rect);
    }
    if (!rect.width || !rect.height) return { x: rect.left, y: rect.top };
    const zoom = cameraZoom(camera, rect);
    return {
      x: rect.left + (x - camera.x) * zoom,
      y: rect.top + (y - camera.y) * zoom
    };
  }

  const screenToCanvasPoint = screenToCanvas;
  const canvasToScreenPoint = canvasToScreen;
  const clientToWorld = screenToCanvas;
  const worldToClient = canvasToScreen;

  function zoomAt(factor, clientX, clientY) {
    const rect = sceneRect();
    const old = state.camera;
    const focus = screenToCanvas(clientX, clientY, old, rect);
    const next = cameraWithAspect({
      x: old.x, y: old.y, width: old.width / factor, height: old.height / factor
    });
    state.camera = cameraWithAspect({
      x: focus.x - (clientX - rect.left) * next.width / rect.width,
      y: focus.y - (clientY - rect.top) * next.height / rect.height,
      width: next.width,
      height: next.height
    });
    scheduleCameraFrame({ hud: true, overlays: true });
  }

  function snapshot() {
    return {
      objects: clone(state.objects),
      groups: clone(state.groups),
      importedTransforms: Object.fromEntries(state.importedObjects.map(object => [object.id, {
        x: object.tx || 0, y: object.ty || 0,
        scaleX: object.sx || 1, scaleY: object.sy || 1,
        deleted: Boolean(object.deleted)
      }]))
    };
  }

  function restore(snapshotValue) {
    state.objects = clone(snapshotValue?.objects || []);
    state.groups = clone(snapshotValue?.groups || []);
    const transforms = snapshotValue?.importedTransforms || {};
    state.importedObjects.forEach(object => {
      const transform = transforms[object.id] || {};
      object.tx = Number(transform.x) || 0;
      object.ty = Number(transform.y) || 0;
      object.sx = Number(transform.scaleX) || 1;
      object.sy = Number(transform.scaleY) || 1;
      object.deleted = Boolean(transform.deleted);
      if (object.node) {
        if (object.deleted) object.node.setAttribute("display", "none");
        else object.node.removeAttribute("display");
      }
    });
    buildImportedDisplay();
  }

  /* History stores bounded before-action snapshots, not individual pointer samples. */
  function commitLogicalAction(before, { force = false } = {}) {
    if (!force && JSON.stringify(before) === JSON.stringify(snapshot())) return false;
    state.history.push(before);
    if (state.history.length > HISTORY_LIMIT) state.history.shift();
    state.future = [];
    markChanged();
    updateHistoryButtons();
    return true;
  }

  function flushPendingHistory() {
    if (!state.pendingHistory.length) return;
    const entries = state.pendingHistory.splice(0).map(item => (
      typeof item === "function" ? item() : item
    ));
    entries.forEach(snapshotEntry => {
      state.history.push(snapshotEntry);
      if (state.history.length > HISTORY_LIMIT) state.history.shift();
    });
    if (entries.length) state.future = [];
    updateHistoryButtons();
  }

  function undo() {
    flushPendingHistory();
    if (!state.history.length) return;
    state.future.push(snapshot());
    restore(state.history.pop());
    state.selected.clear();
    markChanged();
    renderScene();
    editorLog("UNDO", { remaining: state.history.length });
  }

  function redo() {
    flushPendingHistory();
    if (!state.future.length) return;
    state.history.push(snapshot());
    restore(state.future.pop());
    state.selected.clear();
    markChanged();
    renderScene();
    editorLog("REDO", { remaining: state.future.length });
  }

  function updateHistoryButtons() {
    const undoable = Boolean(state.history.length);
    const redoable = Boolean(state.future.length);
    $$("[data-history='undo']").forEach(button => { button.disabled = !undoable; });
    $$("[data-history='redo']").forEach(button => { button.disabled = !redoable; });
    const undoButton = $("#undo-button");
    const redoButton = $("#redo-button");
    if (undoButton) undoButton.disabled = !undoable;
    if (redoButton) redoButton.disabled = !redoable;
  }

  function inkIsActive() {
    return Boolean(activeInk || state.interaction?.kind === "draw");
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
          wrap_width: object.wrapWidth || undefined,
          role: object.role || undefined,
          practice_problem_id: object.practiceProblemId || undefined,
          source_study_interaction_id: object.sourceStudyInteractionId || undefined,
          generated_at: object.generatedAt || undefined,
          board_id: object.boardId || undefined,
          origin: object.origin || undefined,
          folder_id: object.folderId || state.lecture.folderId || undefined,
          created_at: object.createdAt || undefined,
          translation: { x: 0, y: 0 }
        };
      }
      if (object.type === "path") {
        return {
          id: object.id, type: "path", d: object.d || object.sourceD,
          color: object.color, fill: object.fill || object.color,
          width: object.width || 0, opacity: object.opacity,
          translation: { x: object.tx || 0, y: object.ty || 0 },
          scaleX: object.sx || 1, scaleY: object.sy || 1,
          board_id: object.boardId || undefined,
          origin: object.origin || "student",
          folder_id: object.folderId || state.lecture.folderId || undefined,
          created_at: object.createdAt || undefined
        };
      }
      return {
        id: object.id, type: object.type, points: object.points,
        color: object.color, width: object.width, opacity: object.opacity,
        translation: { x: object.tx || 0, y: object.ty || 0 },
        scaleX: object.sx || 1, scaleY: object.sy || 1,
        erasures: (object.erasures || []).map(erasure => ({
          points: erasure.points, width: erasure.width
        })),
        board_id: object.boardId || undefined,
        origin: object.origin || "student",
        folder_id: object.folderId || state.lecture.folderId || undefined,
        created_at: object.createdAt || undefined
      };
    });
    return {
      schema_version: 4,
      revision: state.revision,
      viewport: clone(state.camera),
      objects,
      groups: clone(state.groups),
      imported_transforms: Object.fromEntries(state.importedObjects.map(object =>
        [object.id, { x: object.tx || 0, y: object.ty || 0,
          scaleX: object.sx || 1, scaleY: object.sy || 1,
          deleted: Boolean(object.deleted) }])),
      source_boards: (state.sourceBoards.length ? state.sourceBoards : lectureBoardsFromData()).map(item => ({
        board_id: item.boardId,
        board_order: item.boardOrder,
        x: item.x, y: item.y, width: item.width, height: item.height,
        label: item.label
      }))
    };
  }

  /* Editor persistence uses one versioned document; revision is server-controlled. */
  async function flushEditorSave() {
    clearTimeout(state.saveTimer);
    state.saveTimer = 0;
    let guard = 0;
    while ((inkIsActive() || state.saving) && guard++ < 80) {
      await new Promise(resolve => setTimeout(resolve, 40));
    }
    if (state.dirty && boardId) await saveEditor(false);
  }

  async function saveEditor(showToast = false) {
    clearTimeout(state.saveTimer);
    if (inkIsActive()) {
      state.saveTimer = setTimeout(() => saveEditor(showToast), 400);
      return;
    }
    if (!state.dirty || !boardId) return;
    if (state.saving) {
      state.saveAgain = true;
      return;
    }
    state.saving = true;
    if ($("#save-button")) $("#save-button").disabled = true;
    if ($("#header-save-button")) $("#header-save-button").disabled = true;
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
      if ($("#save-button")) $("#save-button").disabled = false;
      if ($("#header-save-button")) $("#header-save-button").disabled = false;
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

  function importedWorldBounds(object) {
    const map = object.map || state.importedMap || { x: 0, y: 0, scaleX: 1, scaleY: 1 };
    const sx = object.sx || 1;
    const sy = object.sy || 1;
    const tx = object.tx || 0;
    const ty = object.ty || 0;
    const originX = Number(object.originX) || 0;
    const originY = Number(object.originY) || 0;
    return {
      x: originX + ((object.bbox.x * sx) + tx - map.x) * map.scaleX,
      y: originY + ((object.bbox.y * sy) + ty - map.y) * map.scaleY,
      width: (object.bbox.width || 0) * sx * map.scaleX,
      height: (object.bbox.height || 0) * sy * map.scaleY
    };
  }

  function sourceBoardFor(object) {
    const id = object?.boardId;
    return (state.sourceBoards || []).find(item => item.boardId === id) || null;
  }

  function lectureContentBounds() {
    const boards = state.sourceBoards.length ? state.sourceBoards : lectureBoardsFromData();
    if (!boards.length) {
      return { x: 0, y: 0, width: state.width, height: state.height };
    }
    const left = Math.min(...boards.map(item => item.x));
    const top = Math.min(...boards.map(item => item.y));
    const right = Math.max(...boards.map(item => item.x + item.width));
    const bottom = Math.max(...boards.map(item => item.y + item.height));
    return { x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) };
  }

  function isBoardFillingObject(object) {
    if (object?.type !== "imported") return false;
    const board = sourceBoardFor(object);
    const width = board?.width || state.width;
    const height = board?.height || state.height;
    const box = importedWorldBounds(object);
    return box.width >= width * .85 && box.height >= height * .85;
  }

  function objectBounds(object) {
    if (!object) return { x: 0, y: 0, width: 0, height: 0 };
    if (object._worldBounds) return object._worldBounds;
    if (object?.type === "group") return cacheWorldBounds(object, groupBounds(object));
    if (object?.type === "imported") return cacheWorldBounds(object, transformedBounds(importedWorldBounds(object), object.id));
    if (object.type === "text") {
      return cacheWorldBounds(object, transformedBounds({ x: object.x, y: object.y, width: object.width, height: object.height }, object.id));
    }
    if (object.type === "path" && object.bbox) {
      return cacheWorldBounds(object, transformedBounds({
        x: object.bbox.x * (object.sx || 1) + (object.tx || 0),
        y: object.bbox.y * (object.sy || 1) + (object.ty || 0),
        width: (object.bbox.width || 0) * Math.abs(object.sx || 1),
        height: (object.bbox.height || 0) * Math.abs(object.sy || 1)
      }, object.id));
    }
    const points = object.points || [];
    if (points.length) {
      const sx = object.sx || 1;
      const sy = object.sy || 1;
      const tx = object.tx || 0;
      const ty = object.ty || 0;
      const xs = points.map(point => point.x * sx + tx);
      const ys = points.map(point => point.y * sy + ty);
      const pad = (object.width / 2) * Math.max(Math.abs(sx), Math.abs(sy));
      return cacheWorldBounds(object, transformedBounds({
        x: Math.min(...xs) - pad,
        y: Math.min(...ys) - pad,
        width: Math.max(...xs) - Math.min(...xs) + pad * 2,
        height: Math.max(...ys) - Math.min(...ys) + pad * 2
      }, object.id));
    }
    const rendered = $(`[data-object-id="${CSS.escape(object.id)}"]`);
    if (rendered) {
      try {
        const box = rendered.getBBox();
        return cacheWorldBounds(object, transformedBounds({
          x: box.x + (object.tx || 0), y: box.y + (object.ty || 0),
          width: box.width, height: box.height
        }, object.id));
      } catch (_) { /* Detached SVG nodes have no box. */ }
    }
    return cacheWorldBounds(object, { x: 0, y: 0, width: 0, height: 0 });
  }

  function cacheWorldBounds(object, box) {
    object._worldBounds = box;
    return box;
  }

  function invalidateWorldBounds(object) {
    if (!object) return;
    object._worldBounds = null;
    object._eraseBounds = null;
    state.boundsEpoch = (state.boundsEpoch || 0) + 1;
    state.cachedSelectionUnion = null;
    if (state.spatial && object.id) state.spatial.remove(object.id);
    if (object.type === "group") {
      object.children.map(findObject).forEach(invalidateWorldBounds);
    }
  }

  function ensureSpatial() {
    if (state.spatial || !Engine.SpatialHash) return state.spatial;
    const bounds = lectureContentBounds();
    const cell = Math.max(160, Math.min(512, Math.round(Math.max(bounds.width, bounds.height) / 12)));
    state.spatial = new Engine.SpatialHash(cell);
    return state.spatial;
  }

  function indexObject(object) {
    const spatial = ensureSpatial();
    if (!spatial || !object || object.deleted) return;
    const box = objectBounds(object);
    if (box.width || box.height) spatial.upsert(object.id, box);
  }

  function rebuildSpatialIndex() {
    if (!Engine.SpatialHash) return;
    const bounds = lectureContentBounds();
    const cell = Math.max(160, Math.min(512, Math.round(Math.max(bounds.width, bounds.height) / 12)));
    state.spatial = new Engine.SpatialHash(cell);
    allObjects().forEach(indexObject);
    state.groups.forEach(indexObject);
  }

  function querySpatial(box, pad = 0) {
    const area = pad ? { x: box.x - pad, y: box.y - pad, width: box.width + pad * 2, height: box.height + pad * 2 } : box;
    if (!state.spatial) return allObjects().map(object => ({ id: object.id, box: objectBounds(object) }));
    return state.spatial.query(area);
  }

  function viewportCanvasRect(marginPx = 96) {
    const zoom = Math.max(0.01, cameraZoom());
    const margin = marginPx / zoom;
    const camera = state.camera;
    return {
      x: camera.x - margin,
      y: camera.y - margin,
      width: camera.width + margin * 2,
      height: camera.height + margin * 2
    };
  }

  function restoreSourcePath(object) {
    if (!object?.path || !object.sourceD) return;
    if (object.path.getAttribute("d") !== object.sourceD) {
      object.path.setAttribute("d", object.sourceD);
    }
    object.displayLevel = LOD.FULL;
  }

  function applyObjectDisplayLevel(object) {
    restoreSourcePath(object);
  }

  function isIdentityImported(object) {
    return Math.abs(object.tx || 0) < 1e-6 && Math.abs(object.ty || 0) < 1e-6 &&
      Math.abs((object.sx || 1) - 1) < 1e-6 && Math.abs((object.sy || 1) - 1) < 1e-6;
  }

  function importedNeedsPromote(object) {
    if (!object || object.deleted || state.selected.has(object.id) || !isIdentityImported(object)) {
      return Boolean(object);
    }
    let parent = parentGroup(object.id);
    while (parent) {
      const transform = parent.transform || {};
      if (transform.x || transform.y ||
        Math.abs((transform.scaleX || 1) - 1) > 1e-6 ||
        Math.abs((transform.scaleY || 1) - 1) > 1e-6 ||
        transform.rotation) {
        return true;
      }
      parent = parentGroup(parent.id);
    }
    return false;
  }

  function importedDisplayHost(object) {
    return object.path?.parentElement?.parentElement ||
      object.node?.parentElement ||
      $("#imported-layer");
  }

  function ensureDisplayLayer(host) {
    if (!host) return null;
    let layer = host.querySelector(":scope > .display-cache");
    if (!layer) {
      layer = svgEl("g", { class: "display-cache", "pointer-events": "none" });
      host.insertBefore(layer, host.firstChild || null);
    }
    return layer;
  }

  function displayPathForObject(object) {
    return object.sourceD || "";
  }

  function hideImportedLogical(object, hidden) {
    if (!object?.node) return;
    if (hidden) {
      object.logicalParent = object.node.parentElement || object.logicalParent || importedDisplayHost(object);
      if (object.node.parentElement) object.node.remove();
      object.node.setAttribute("data-batched", "1");
      object.batched = true;
    } else {
      const parent = object.logicalParent || importedDisplayHost(object);
      if (parent && !object.node.isConnected) parent.append(object.node);
      object.node.removeAttribute("data-batched");
      if (!object.deleted) object.node.removeAttribute("display");
      object.batched = false;
    }
  }

  function rebuildDisplayCell(cellKey) {
    const cell = state.displayCells.get(cellKey);
    if (!cell) return;
    const layer = cell.layer;
    if (!layer) return;
    [...layer.querySelectorAll(`[data-display-cell="${CSS.escape(cellKey)}"]`)].forEach(node => node.remove());
    const members = cell.ids
      .map(id => state.importedObjects.find(item => item.id === id))
      .filter(object => object && !object.deleted && !object.promoted && object.sourceD);
    const groups = new Map();
    members.forEach(object => {
      const style = Engine.visualStyleKey
        ? Engine.visualStyleKey(object.path || object)
        : `${object.color_class || object.color}|evenodd|1|0`;
      if (!groups.has(style)) groups.set(style, []);
      groups.get(style).push({
        ...object,
        bbox: object.bbox,
        sourceD: displayPathForObject(object)
      });
    });
    let nodes = 0;
    groups.forEach((items, style) => {
      const [, rule, opacity, strokeWidth] = style.split("|");
      const representative = items[0]?.path;
      const fill = items.reduce((best, item) => {
        const value = item.path?.getAttribute("fill") || item.color || "";
        const hex = String(value).match(/^#([0-9a-f]{6})$/i);
        if (!hex) return best;
        const n = parseInt(hex[1], 16);
        const lum = 0.3 * ((n >> 16) & 255) + 0.59 * ((n >> 8) & 255) + 0.11 * (n & 255);
        if (!best.value || lum < best.lum) return { value, lum };
        return best;
      }, { value: representative?.getAttribute("fill") || items[0]?.color || "#183153", lum: 999 }).value;
      const stroke = representative?.getAttribute("stroke") || "none";
      const simple = [];
      const holed = [];
      items.forEach(item => {
        const parts = Engine.subpathCount ? Engine.subpathCount(item.sourceD) : 1;
        if (parts > 1) holed.push(item);
        else simple.push(item);
      });
      const bins = [];
      if (simple.length) bins.push(simple);
      holed.forEach(item => bins.push([item]));
      bins.forEach((bin, index) => {
        const d = Engine.combinePathData ? Engine.combinePathData(bin) : bin.map(item => item.sourceD).join(" ");
        if (!d) return;
        const path = svgEl("path", {
          class: "display-batch",
          "data-display-cell": cellKey,
          "data-batch-index": String(index),
          d,
          fill: fill || "#183153",
          "fill-rule": bin.length > 1 ? "nonzero" : (representative?.getAttribute("fill-rule") || rule || "evenodd"),
          "fill-opacity": opacity || "1",
          "pointer-events": "none"
        });
        if (stroke && stroke !== "none") {
          path.setAttribute("stroke", stroke);
          path.setAttribute("stroke-width", strokeWidth || representative?.getAttribute("stroke-width") || "1");
        }
        layer.append(path);
        nodes += 1;
      });
    });
    cell.nodeCount = nodes;
    cell.bounds = Engine.cellBounds
      ? Engine.cellBounds(cellKey, DISPLAY_CELL)
      : { x: 0, y: 0, width: DISPLAY_CELL, height: DISPLAY_CELL };
    if (members.length) {
      const boxes = members.map(object => object.bbox).filter(Boolean);
      if (boxes.length) {
        const x = Math.min(...boxes.map(box => box.x));
        const y = Math.min(...boxes.map(box => box.y));
        const right = Math.max(...boxes.map(box => box.x + box.width));
        const bottom = Math.max(...boxes.map(box => box.y + box.height));
        cell.bounds = { x, y, width: right - x, height: bottom - y };
      }
    }
  }

  function assignImportedCell(object) {
    const local = object.bbox || { x: 0, y: 0, width: 1, height: 1 };
    return Engine.displayCellKey
      ? Engine.displayCellKey(local, DISPLAY_CELL)
      : "0:0";
  }

  function promoteImported(object, { rebuild = true } = {}) {
    if (!object || object.type !== "imported") return;
    restoreSourcePath(object);
    object.promoted = true;
    hideImportedLogical(object, false);
    if (object.deleted) object.node?.setAttribute("display", "none");
    const key = object.cellKey;
    if (key && state.displayCells.has(key)) {
      const cell = state.displayCells.get(key);
      cell.ids = cell.ids.filter(id => id !== object.id);
      if (rebuild) rebuildDisplayCell(key);
    }
  }

  function demoteImported(object, { rebuild = true } = {}) {
    if (!object || object.deleted || !isIdentityImported(object) || state.selected.has(object.id)) return;
    object.promoted = false;
    const host = importedDisplayHost(object);
    const layer = ensureDisplayLayer(host);
    const key = assignImportedCell(object);
    object.cellKey = key;
    if (!state.displayCells.has(key)) {
      state.displayCells.set(key, { key, ids: [], layer, bounds: null, nodeCount: 0 });
    }
    const cell = state.displayCells.get(key);
    cell.layer = layer;
    if (!cell.ids.includes(object.id)) cell.ids.push(object.id);
    hideImportedLogical(object, true);
    if (rebuild) rebuildDisplayCell(key);
  }

  function buildImportedDisplay() {
    state.displayCells = new Map();
    state.importedObjects.forEach(object => {
      restoreSourcePath(object);
      object.promoted = false;
      object.batched = false;
      object.cellKey = "";
    });
    const dirty = new Set();
    state.importedObjects.forEach(object => {
      if (object.deleted || !object.sourceD) return;
      if (!isIdentityImported(object) || state.selected.has(object.id)) {
        promoteImported(object, { rebuild: false });
        return;
      }
      demoteImported(object, { rebuild: false });
      if (object.cellKey) dirty.add(object.cellKey);
    });
    dirty.forEach(rebuildDisplayCell);
    refreshViewportCull({ moving: false });
  }

  function syncImportedDisplay() {
    const dirty = new Set();
    state.importedObjects.forEach(object => {
      const interactive = importedNeedsPromote(object);
      if (interactive && (object.batched || !object.promoted)) {
        promoteImported(object, { rebuild: false });
        if (object.cellKey) dirty.add(object.cellKey);
      } else if (!interactive && object.promoted) {
        demoteImported(object, { rebuild: false });
        if (object.cellKey) dirty.add(object.cellKey);
      }
    });
    dirty.forEach(rebuildDisplayCell);
  }

  function worldBoxForDisplayCell(cell) {
    const first = cell.ids.map(id => state.importedObjects.find(item => item.id === id)).find(Boolean);
    const originX = first?.originX || 0;
    const originY = first?.originY || 0;
    const map = first?.map || { x: 0, y: 0, scaleX: 1, scaleY: 1 };
    const box = cell.bounds || { x: 0, y: 0, width: DISPLAY_CELL, height: DISPLAY_CELL };
    return {
      x: originX + (box.x - map.x) * map.scaleX,
      y: originY + (box.y - map.y) * map.scaleY,
      width: box.width * map.scaleX,
      height: box.height * map.scaleY
    };
  }

  function refreshViewportCull({ moving = false } = {}) {
    const selected = state.selected;
    const view = viewportCanvasRect(moving ? 280 : 160);
    const hit = Engine.intersects || intersects;
    let visible = 0;
    let culled = 0;
    let svgNodes = 0;
    state.displayCells.forEach(cell => {
      const box = worldBoxForDisplayCell(cell);
      const near = hit(box, view);
      const key = cell.key;
      const nodes = key && cell.layer
        ? [...cell.layer.querySelectorAll(`[data-display-cell="${CSS.escape(key)}"]`)]
        : [];
      nodes.forEach(node => {
        if (near) {
          node.removeAttribute("visibility");
          node.removeAttribute("data-culled");
          svgNodes += 1;
        } else {
          node.setAttribute("visibility", "hidden");
          node.setAttribute("data-culled", "1");
        }
      });
      if (near) visible += cell.ids.length;
      else culled += cell.ids.length;
    });
    state.importedObjects.forEach(object => {
      if (object.deleted || object.batched) return;
      const box = objectBounds(object);
      const near = selected.has(object.id) || hit(box, view);
      if (!near) {
        if (object.node?.getAttribute("data-culled") !== "1") {
          object.node?.setAttribute("data-culled", "1");
          object.node?.setAttribute("visibility", "hidden");
        }
        culled += 1;
        return;
      }
      if (object.node?.getAttribute("data-culled") === "1") {
        object.node.removeAttribute("data-culled");
        object.node.removeAttribute("visibility");
      }
      visible += 1;
      svgNodes += 1;
    });
    state.visibleCount = visible;
    state.culledCount = culled;
    state.svgNodeCount = svgNodes + state.objects.length;
    state.displayLevel = LOD.FULL;
    if (state.perf) {
      state.perf.visible = visible;
      state.perf.culled = culled;
      state.perf.svgObjects = state.svgNodeCount;
      state.perf.pathCommands = state.commandTotal;
      state.perf.level = "full";
    }
  }

  function prepareDerivedGeometry() {
    if (!Engine.GeometryCache) return;
    state.geometryCache ||= new Engine.GeometryCache();
    const objects = state.importedObjects.filter(object =>
      !object.deleted && object.sourceD && (object.commandCount || 0) > 90
    );
    let index = 0;
    const step = deadline => {
      const budget = typeof deadline?.timeRemaining === "function" ? deadline.timeRemaining() : 8;
      const start = nowMs();
      while (index < objects.length && nowMs() - start < Math.max(4, budget)) {
        const object = objects[index++];
        state.geometryCache.ensure(object, LOD.FULL, 1);
        state.geometryCache.ensure(object, LOD.PERCEPTUAL || "perceptual", 1);
      }
      if (index < objects.length) {
        if (Engine.idle) Engine.idle(step);
        else setTimeout(() => step({ timeRemaining: () => 8 }), 16);
      }
    };
    if (Engine.idle) Engine.idle(step);
    else setTimeout(() => step({ timeRemaining: () => 8 }), 0);
  }

  function scheduleViewportCull() {
    if (state.cullRaf) return;
    state.cullRaf = requestAnimationFrame(() => {
      state.cullRaf = 0;
      refreshViewportCull({ moving: state.navigating });
    });
  }

  function scheduleViewportMaintenance() {
    clearTimeout(state.cullTimer);
    state.cullTimer = setTimeout(() => refreshViewportCull({ moving: false }), 90);
  }

  function allObjects() {
    return [...state.objects, ...state.importedObjects.filter(object => !object.deleted)];
  }

  function findObject(id) {
    return allObjects().find(object => object.id === id) || state.groups.find(group => group.id === id);
  }

  function parentGroup(id) {
    return state.groups.find(group => group.children.includes(id));
  }

  function groupTransform(group) {
    const transform = group?.transform || {};
    return {
      x: Number(transform.x) || 0, y: Number(transform.y) || 0,
      scaleX: Number(transform.scaleX) || 1, scaleY: Number(transform.scaleY) || 1
    };
  }

  function transformedBounds(bounds, id) {
    let result = { ...bounds };
    let parent = parentGroup(id);
    while (parent) {
      const transform = groupTransform(parent);
      result = {
        x: result.x * transform.scaleX + transform.x,
        y: result.y * transform.scaleY + transform.y,
        width: result.width * Math.abs(transform.scaleX),
        height: result.height * Math.abs(transform.scaleY)
      };
      parent = parentGroup(parent.id);
    }
    return result;
  }

  function groupBounds(group) {
    const children = group.children.map(findObject).filter(Boolean);
    if (!children.length) return { x: 0, y: 0, width: 0, height: 0 };
    const bounds = children.map(objectBounds);
    const left = Math.min(...bounds.map(box => box.x));
    const top = Math.min(...bounds.map(box => box.y));
    const right = Math.max(...bounds.map(box => box.x + box.width));
    const bottom = Math.max(...bounds.map(box => box.y + box.height));
    return { x: left, y: top, width: right - left, height: bottom - top };
  }

  function topLevelItems() {
    const nested = new Set(state.groups.flatMap(group => group.children));
    return [...state.groups.filter(group => !nested.has(group.id)),
      ...allObjects().filter(object => !nested.has(object.id))];
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

  function lassoSelectsObject(object, polygon, lassoBounds = null) {
    if (polygon.length < 3 || isBoardFillingObject(object)) return false;
    const bounds = objectBounds(object);
    const area = lassoBounds || unionBounds([{ type: "stroke", points: polygon, width: 0 }]);
    if (!intersects(bounds, area)) return false;
    const samples = ["text", "imported", "group"].includes(object.type)
      ? [
          { x: bounds.x, y: bounds.y },
          { x: bounds.x + bounds.width, y: bounds.y },
          { x: bounds.x + bounds.width, y: bounds.y + bounds.height },
          { x: bounds.x, y: bounds.y + bounds.height },
          { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 }
        ]
      : (object.points || []).map(point => ({
          x: point.x * (object.sx || 1) + (object.tx || 0),
          y: point.y * (object.sy || 1) + (object.ty || 0)
        }));
    const contained = samples.filter(point => pointInPolygon(point, polygon)).length;
    return contained >= Math.max(1, Math.ceil(samples.length * .65));
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

  function textUsesRichRender(object) {
    const text = String(object?.text || "");
    if (object?.role === "ai_practice_problem") return true;
    return typeof globalThis.hasRichMarkup === "function"
      ? globalThis.hasRichMarkup(text)
      : /\$\$|\\\(|\\\[|(^|[^\\])\$/.test(text);
  }

  function textMeasureHost() {
    let host = $("#canvas-text-measure");
    if (host) return host;
    host = document.createElement("div");
    host.id = "canvas-text-measure";
    host.className = "canvas-text-measure canvas-rich-text";
    host.setAttribute("aria-hidden", "true");
    document.body.append(host);
    return host;
  }

  function wrapPlainLines(text, fontSize, maxWidth) {
    const canvas = wrapPlainLines.canvas || (wrapPlainLines.canvas = document.createElement("canvas"));
    const ctx = canvas.getContext("2d");
    ctx.font = `${fontSize}px system-ui, -apple-system, sans-serif`;
    const lines = [];
    String(text || "").split("\n").forEach(paragraph => {
      if (!paragraph) {
        lines.push("");
        return;
      }
      const words = paragraph.split(/\s+/);
      let line = "";
      words.forEach(word => {
        const candidate = line ? `${line} ${word}` : word;
        if (maxWidth && ctx.measureText(candidate).width > maxWidth && line) {
          lines.push(line);
          line = word;
        } else line = candidate;
      });
      lines.push(line);
    });
    const width = Math.max(1, ...lines.map(line => ctx.measureText(line).width));
    const height = Math.max(fontSize, lines.length * fontSize * 1.2);
    return { lines, width, height };
  }

  function canvasRichMarkdown(text) {
    const renderer = globalThis.renderStudyMarkdown;
    if (typeof renderer === "function") return renderer(text);
    const node = document.createElement("span");
    node.textContent = text || "";
    return node;
  }

  function richTextContentOffset(object) {
    const fontSize = Math.max(8, Number(object.fontSize) || 24);
    const pad = Math.max(2, fontSize * 0.08);
    const signifier = object.role === "ai_practice_problem" ? Math.max(10, fontSize * 0.7) : 0;
    return {
      x: pad + signifier,
      y: pad,
      width: Math.max(4, (Number(object.width) || 4) - pad * 2 - signifier),
      height: Math.max(4, (Number(object.height) || 4) - pad * 2),
      fontSize,
      color: object.color || "#183153"
    };
  }

  function syncHtmlOverlayCamera() {
    applyCameraPlane(state.camera, sceneRect());
  }

  function applyHtmlOverlayBox(el, object) {
    const local = richTextContentOffset(object);
    const world = transformedBounds({
      x: object.x + local.x,
      y: object.y + local.y,
      width: local.width,
      height: local.height
    }, object.id);
    const scale = local.width ? world.width / local.width : 1;
    el.style.left = `${world.x}px`;
    el.style.top = `${world.y}px`;
    el.style.width = `${local.width}px`;
    el.style.fontSize = `${local.fontSize}px`;
    el.style.color = local.color;
    el.style.lineHeight = "1.28";
    el.style.transform = scale === 1 ? "none" : `scale(${scale})`;
  }

  function upsertHtmlOverlayItem(object) {
    const world = $("#canvas-html-world");
    if (!world || !object || object.deleted || object.type !== "text" || !textUsesRichRender(object)) {
      removeHtmlOverlayItem(object?.id);
      return;
    }
    let el = world.querySelector(`[data-object-id="${CSS.escape(object.id)}"]`);
    if (!el) {
      el = document.createElement("div");
      el.className = "canvas-html-text canvas-rich-text";
      el.dataset.objectId = object.id;
      world.append(el);
    }
    el.replaceChildren(canvasRichMarkdown(object.text));
    applyHtmlOverlayBox(el, object);
    const editing = $("#text-editor-overlay")?.dataset.objectId;
    el.hidden = editing === object.id;
  }

  function removeHtmlOverlayItem(id) {
    if (!id) return;
    $("#canvas-html-world")?.querySelector(`[data-object-id="${CSS.escape(id)}"]`)?.remove();
  }

  function applyHtmlOverlayVisual(object) {
    if (!object || object.type !== "text" || !textUsesRichRender(object)) return;
    const el = $("#canvas-html-world")?.querySelector(`[data-object-id="${CSS.escape(object.id)}"]`);
    if (!el) return;
    applyHtmlOverlayBox(el, object);
  }

  function renderHtmlOverlay() {
    const world = $("#canvas-html-world");
    if (!world) return;
    world.replaceChildren();
    state.objects.forEach(object => {
      if (object.deleted || object.type !== "text" || !textUsesRichRender(object)) return;
      upsertHtmlOverlayItem(object);
    });
    syncHtmlOverlayCamera();
  }

  function measureRichText(text, fontSize, wrapWidth, color) {
    const host = textMeasureHost();
    const maxWidth = Math.max(40, wrapWidth || fontSize * 28);
    host.style.cssText = [
      "position:absolute", "left:-12000px", "top:0", "visibility:hidden",
      "pointer-events:none", "width:max-content", `max-width:${maxWidth}px`,
      `font-size:${fontSize}px`, "line-height:1.28",
      `color:${color || "#183153"}`, "font-family:system-ui,-apple-system,sans-serif"
    ].join(";");
    host.replaceChildren();
    host.append(canvasRichMarkdown(text));
    const width = Math.max(4, host.scrollWidth || host.offsetWidth || 4);
    const height = Math.max(4, host.scrollHeight || host.offsetHeight || 4);
    return { width, height };
  }

  function intendedWrapWidth(object) {
    if (Number(object.wrapWidth) > 0) return object.wrapWidth;
    const existing = Number(object.width);
    if (existing > object.fontSize * 4) return existing;
    return object.fontSize * 28;
  }

  function measureRenderedText(object) {
    const fontSize = Math.max(8, Number(object.fontSize) || 24);
    const pad = Math.max(2, fontSize * 0.08);
    const signifier = object.role === "ai_practice_problem" ? Math.max(10, fontSize * 0.7) : 0;
    let width;
    let height;
    if (textUsesRichRender(object)) {
      const measured = measureRichText(
        object.text, fontSize, intendedWrapWidth(object), object.color
      );
      width = measured.width;
      height = measured.height;
    } else {
      const measured = wrapPlainLines(object.text, fontSize, intendedWrapWidth(object));
      width = measured.width;
      height = measured.height;
    }
    return {
      width: Math.max(4, width + pad * 2 + signifier),
      height: Math.max(4, height + pad * 2),
      pad,
      signifier
    };
  }

  function fitTextObject(object) {
    if (!object || object.type !== "text") return object;
    const size = measureRenderedText(object);
    object.width = size.width;
    object.height = size.height;
    return object;
  }

  function renderText(object) {
    const size = measureRenderedText(object);
    object.width = size.width;
    object.height = size.height;
    const group = svgEl("g", {
      "data-object-id": object.id,
      tabindex: "0",
      transform: `translate(${object.x} ${object.y})`
    });
    const hit = svgEl("rect", {
      class: "text-hit",
      x: 0, y: 0, width: object.width, height: object.height,
      fill: "transparent", stroke: "none", "pointer-events": "all"
    });
    group.append(hit);
    if (object.role === "ai_practice_problem") {
      const mark = svgEl("text", {
        class: "practice-signifier",
        x: size.pad + size.signifier * 0.35,
        y: size.pad + object.fontSize * 0.72,
        "font-size": Math.max(9, object.fontSize * 0.42),
        "text-anchor": "middle",
        fill: "#6aa8e6",
        "font-family": "Times New Roman, serif",
        "font-weight": "700",
        "pointer-events": "none",
        "aria-hidden": "true"
      });
      mark.textContent = "?";
      group.append(mark);
    }
    const contentX = size.pad + size.signifier;
    const contentY = size.pad;
    if (textUsesRichRender(object)) {
      /* HTML overlay renders KaTeX; SVG foreignObject leaks positioned math to the page. */
      return group;
    }
    const wrapped = wrapPlainLines(object.text, object.fontSize, intendedWrapWidth(object));
    const text = svgEl("text", {
      x: contentX,
      y: contentY + object.fontSize,
      fill: object.color, "font-size": object.fontSize,
      "font-family": "system-ui, sans-serif", "pointer-events": "none"
    });
    wrapped.lines.forEach((line, index) => {
      const tspan = svgEl("tspan", {
        x: contentX,
        dy: index ? object.fontSize * 1.2 : 0
      });
      tspan.textContent = line;
      text.append(tspan);
    });
    group.append(text);
    return group;
  }

  function renderStroke(object) {
    const group = svgEl("g", {
      "data-object-id": object.id,
      transform: objectTransformValue(object.tx, object.ty, object.sx, object.sy)
    });
    const ink = object.ink || (object.type === "highlighter" ? "highlighter" : "pen");
    const path = svgEl("path", {
      d: strokePath(object), fill: "none", stroke: object.color,
      "stroke-width": object.width, "stroke-opacity": object.opacity,
      "stroke-linecap": "round", "stroke-linejoin": "round",
      "pointer-events": "stroke",
      "data-ink": ink
    });
    if (object.erasures?.length) {
      const maskId = `mask-${object.id.replace(/[^a-zA-Z0-9_-]/g, "")}`;
      $("#scene-defs")?.querySelector(`#${CSS.escape(maskId)}`)?.remove();
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

  function renderPath(object) {
    const group = svgEl("g", {
      "data-object-id": object.id,
      transform: objectTransformValue(object.tx, object.ty, object.sx, object.sy)
    });
    const path = svgEl("path", {
      d: object.d || object.sourceD || "",
      fill: object.fill || object.color || "#183153",
      "fill-opacity": object.opacity ?? 1,
      stroke: "none",
      "pointer-events": "visiblePainted"
    });
    if (object.width) {
      path.setAttribute("stroke", object.color || object.fill || "#183153");
      path.setAttribute("stroke-width", String(object.width));
    }
    group.append(path);
    return group;
  }

  function selectedItems() {
    return [...state.selected].map(findObject).filter(Boolean);
  }

  function selectedUnionBounds() {
    const selectionKey = `${state.boundsEpoch || 0}:${[...state.selected].join(",")}`;
    if (state.cachedSelectionUnion && state.cachedSelectionKey === selectionKey) {
      return state.cachedSelectionUnion;
    }
    const items = selectedItems();
    if (!items.length) {
      state.cachedSelectionUnion = null;
      state.cachedSelectionKey = "";
      return null;
    }
    const bounds = items.map(objectBounds);
    const left = Math.min(...bounds.map(box => box.x));
    const top = Math.min(...bounds.map(box => box.y));
    const right = Math.max(...bounds.map(box => box.x + box.width));
    const bottom = Math.max(...bounds.map(box => box.y + box.height));
    const pad = Math.max(4, state.camera.width / 400);
    const union = {
      x: left - pad, y: top - pad,
      width: Math.max(1, right - left + pad * 2),
      height: Math.max(1, bottom - top + pad * 2)
    };
    state.cachedSelectionUnion = union;
    state.cachedSelectionKey = selectionKey;
    return union;
  }

  function invalidateSelectionUnion() {
    state.cachedSelectionUnion = null;
    state.cachedSelectionKey = "";
  }

  function pointInRect(point, box) {
    return box && point.x >= box.x && point.x <= box.x + box.width &&
      point.y >= box.y && point.y <= box.y + box.height;
  }

  function renderSelection() {
    const layer = $("#interaction-layer");
    const union = selectedUnionBounds();
    if (!union) return;
    const stroke = Math.max(1, state.camera.width / 900);
    const handle = Math.max(stroke * 8, state.camera.width / 70);
    layer.append(svgEl("rect", {
      x: union.x, y: union.y, width: union.width, height: union.height,
      fill: "#3977d5", "fill-opacity": .04, stroke: "#3977d5",
      "stroke-width": stroke,
      "stroke-dasharray": `${state.camera.width / 300} ${state.camera.width / 450}`,
      "data-selection-box": "1",
      "pointer-events": "all"
    }));
    const handles = [
      ["nw", union.x, union.y],
      ["n", union.x + union.width / 2, union.y],
      ["ne", union.x + union.width, union.y],
      ["e", union.x + union.width, union.y + union.height / 2],
      ["se", union.x + union.width, union.y + union.height],
      ["s", union.x + union.width / 2, union.y + union.height],
      ["sw", union.x, union.y + union.height],
      ["w", union.x, union.y + union.height / 2]
    ];
    handles.forEach(([name, x, y]) => {
      layer.append(svgEl("rect", {
        x: x - handle / 2, y: y - handle / 2, width: handle, height: handle,
        fill: "#ffffff", stroke: "#3977d5", "stroke-width": stroke,
        rx: handle / 6, ry: handle / 6,
        "data-resize": name,
        "pointer-events": "all"
      }));
    });
  }

  function renderScene() {
    if (inkIsActive()) return;
    const defs = $("#scene-defs");
    const user = $("#user-layer");
    const interaction = $("#interaction-layer");
    state.perf?.markRender?.();
    defs.replaceChildren();
    user.replaceChildren();
    interaction.replaceChildren();
    const childIds = new Set(state.groups.flatMap(group => group.children));
    state.objects.filter(object => !childIds.has(object.id)).forEach(object => user.append(renderNode(object.id)));
    state.groups.filter(group => !childIds.has(group.id)).forEach(group => user.append(renderNode(group.id)));
    renderImportedTransforms();
    syncImportedDisplay();
    refreshViewportCull({ moving: false });
    syncLiveOverlay();
    renderSelection();
    renderStudyMarkers();
    renderHtmlOverlay();
    const count = $("#object-count");
    if (count) count.textContent = `${state.objects.length} object${state.objects.length === 1 ? "" : "s"}`;
    updateHistoryButtons();
    updateSelectionActions();
    positionExplainButton();
  }

  function liveOverlayAttributes(interaction) {
    if (interaction.kind === "lasso") {
      return {
        d: `${pathFromPoints(interaction.points)} Z`,
        fill: "#3977d5",
        "fill-opacity": .08,
        stroke: "#3977d5",
        "stroke-width": Math.max(1, state.camera.width / 900),
        "stroke-dasharray": `${state.camera.width / 300} ${state.camera.width / 450}`,
        "stroke-linejoin": "round"
      };
    }
    return null;
  }

  function livePathFromPoints(points) {
    if (!points?.length) return "";
    let path = `M ${points[0].x} ${points[0].y}`;
    if (points.length === 1) return `${path} L ${points[0].x + .01} ${points[0].y + .01}`;
    for (let index = 1; index < points.length; index++) {
      path += ` L ${points[index].x} ${points[index].y}`;
    }
    return path;
  }

  function ensureLiveStroke(interaction) {
    const persistent = $("#live-ink");
    if (persistent) {
      if (interaction.liveNode !== persistent) {
        persistent.setAttribute("stroke", interaction.kind === "pixel" ? "#dd3f32" : interaction.color);
        persistent.setAttribute("stroke-opacity", String(interaction.kind === "pixel" ? .55 : interaction.opacity));
        persistent.setAttribute("stroke-width", String(interaction.width));
        persistent.setAttribute("data-ink", interaction.ink || interaction.tool || "pen");
        persistent.setAttribute("visibility", "visible");
        interaction.liveNode = persistent;
        state.liveNode = persistent;
      }
      return persistent;
    }
    let live = interaction.liveNode;
    if (live?.isConnected) return live;
    live = svgEl("path", {
      "data-live": "1",
      fill: "none",
      stroke: interaction.kind === "pixel" ? "#dd3f32" : interaction.color,
      "stroke-opacity": interaction.kind === "pixel" ? .55 : interaction.opacity,
      "stroke-width": interaction.width,
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      "pointer-events": "none",
      "data-ink": interaction.ink || interaction.tool || "pen"
    });
    $("#interaction-layer")?.append(live);
    interaction.liveNode = live;
    state.liveNode = live;
    return live;
  }

  function flushLiveStroke(interaction) {
    if (!interaction) return;
    const path = interaction.liveD || livePathFromPoints(interaction.points);
    if (!path) return;
    ensureLiveStroke(interaction).setAttribute("d", path);
    interaction.renderedCount = interaction.points.length;
  }

  function scheduleLiveStroke(interaction) {
    if (state.liveInkRaf) return;
    state.liveInkRaf = requestAnimationFrame(() => {
      state.liveInkRaf = 0;
      if (state.interaction === interaction || activeInk === interaction) {
        flushLiveStroke(interaction);
      }
    });
  }

  function appendLivePoints(interaction, points) {
    if (!points?.length) return;
    if (!interaction.liveD) interaction.liveD = livePathFromPoints(points);
    else {
      for (const point of points) interaction.liveD += ` L ${point.x} ${point.y}`;
    }
    scheduleLiveStroke(interaction);
  }

  function pointerSamples(event) {
    const coalesced = event.getCoalescedEvents?.();
    return coalesced?.length ? coalesced : [event];
  }

  function ingestDrawSamples(interaction, event) {
    const camera = interaction.drawCamera || state.camera;
    const rect = interaction.sceneRect || sceneRect();
    const added = [];
    pointerSamples(event).forEach(sample => {
      const stamp = sample.timeStamp;
      if (Number.isFinite(stamp) && stamp < (interaction.lastSampleAt ?? -1)) return;
      const next = screenToCanvas(sample.clientX, sample.clientY, camera, rect);
      const pressure = Number(sample.pressure);
      if (Number.isFinite(pressure) && pressure > 0) next.p = pressure;
      if (Number.isFinite(Number(sample.tiltX))) next.tiltX = Number(sample.tiltX);
      if (Number.isFinite(Number(sample.tiltY))) next.tiltY = Number(sample.tiltY);
      if (Number.isFinite(stamp) && stamp === interaction.lastSampleAt) {
        const prev = interaction.points.at(-1);
        if (prev && prev.x === next.x && prev.y === next.y) return;
      }
      if (Number.isFinite(stamp)) interaction.lastSampleAt = stamp;
      interaction.points.push(next);
      interaction.current = next;
      added.push(next);
    });
    interaction.rawCount = interaction.points.length;
    appendLivePoints(interaction, added);
    if (interaction.kind === "draw" && interaction.liveNode && added.length) {
      const latest = interaction.points.at(-1);
      const liveWidth = Pencil
        ? Pencil.effectiveStrokeWidth(
          interaction.baseWidth || interaction.width,
          latest?.p,
          interaction.pressureSensitivity || 0
        )
        : interaction.width;
      interaction.liveNode.setAttribute("stroke-width", String(liveWidth));
    }
    return added;
  }

  function isStalePointerEvent(event, interaction) {
    return Boolean(event && interaction &&
      Number.isFinite(interaction.startedAt) &&
      event.timeStamp < interaction.startedAt);
  }

  function updatePenHud() {
    const el = $("#pen-debug");
    if (!el) return;
    const hud = state.penHud;
    el.textContent = `Pencil strokes: ${hud.strokes}  last raw/render/final: ${hud.lastRaw}/${hud.lastRendered}/${hud.lastFinal}`;
  }

  function syncLiveOverlay() {
    const interaction = state.interaction;
    if (interaction && (interaction.kind === "draw" || interaction.kind === "pixel")) {
      appendLivePoints(interaction, interaction.liveD ? [] : interaction.points);
      if (interaction.liveNode && interaction.liveD) {
        interaction.liveNode.setAttribute("d", interaction.liveD);
      }
      return;
    }
    const layer = $("#interaction-layer");
    const attributes = interaction ? liveOverlayAttributes(interaction) : null;
    let live = layer.querySelector("[data-live='1']");
    if (!attributes) {
      live?.remove();
      return;
    }
    if (!live) {
      live = svgEl("path", { "data-live": "1", "pointer-events": "none" });
      layer.append(live);
    }
    Object.entries(attributes).forEach(([key, value]) => live.setAttribute(key, String(value)));
  }

  function updateSelectionActions() {
    const selected = [...state.selected].map(findObject).filter(Boolean);
    const groupButton = $("#group-button");
    const ungroupButton = $("#ungroup-button");
    if (groupButton) groupButton.disabled = selected.length < 2;
    if (ungroupButton) ungroupButton.disabled = !selected.some(item => item.type === "group");
    syncToolControls();
    positionExplainButton();
  }

  function groupSelection() {
    const ids = [...state.selected].filter(id => findObject(id));
    if (ids.length < 2) return;
    const before = snapshot();
    const nested = new Set(ids.flatMap(id => {
      const group = state.groups.find(item => item.id === id);
      return group ? group.children : [];
    }));
    const children = ids.filter(id => !nested.has(id));
    const group = {
      id: uid("group"), type: "group", children,
      transform: { x: 0, y: 0, scaleX: 1, scaleY: 1, rotation: 0 }
    };
    state.groups.push(group);
    state.selected = new Set([group.id]);
    commitLogicalAction(before);
    renderScene();
  }

  function bakeGroupTransform(group) {
    const transform = groupTransform(group);
    group.children.map(findObject).filter(Boolean).forEach(object => {
      if (object.type === "group") {
        object.transform.x = (object.transform.x || 0) * transform.scaleX + transform.x;
        object.transform.y = (object.transform.y || 0) * transform.scaleY + transform.y;
        object.transform.scaleX = (object.transform.scaleX || 1) * transform.scaleX;
        object.transform.scaleY = (object.transform.scaleY || 1) * transform.scaleY;
        object.transform.rotation = (object.transform.rotation || 0) + (group.transform.rotation || 0);
      } else if (object.type === "text") {
        object.x = object.x * transform.scaleX + transform.x;
        object.y = object.y * transform.scaleY + transform.y;
        object.fontSize = Math.max(8, object.fontSize * Math.min(Math.abs(transform.scaleX), Math.abs(transform.scaleY)));
        fitTextObject(object);
      } else if (object.type === "stroke" || object.type === "highlighter") {
        object.points.forEach(point => {
          point.x = point.x * transform.scaleX + transform.x;
          point.y = point.y * transform.scaleY + transform.y;
        });
      } else if (object.type === "path") {
        object.tx = (object.tx || 0) * transform.scaleX + transform.x;
        object.ty = (object.ty || 0) * transform.scaleY + transform.y;
        object.sx = (object.sx || 1) * transform.scaleX;
        object.sy = (object.sy || 1) * transform.scaleY;
      } else if (object.type === "imported") {
        object.tx = (object.tx || 0) * transform.scaleX + transform.x;
        object.ty = (object.ty || 0) * transform.scaleY + transform.y;
        object.sx = (object.sx || 1) * transform.scaleX;
        object.sy = (object.sy || 1) * transform.scaleY;
      }
    });
  }

  function ungroupSelection() {
    const selectedGroups = state.groups.filter(group => state.selected.has(group.id));
    if (!selectedGroups.length) return;
    const before = snapshot();
    selectedGroups.forEach(group => {
      bakeGroupTransform(group);
      state.groups = state.groups.filter(item => item.id !== group.id);
    });
    state.selected = new Set(selectedGroups.flatMap(group => group.children));
    commitLogicalAction(before);
    renderScene();
  }

  function renderNode(id) {
    const group = state.groups.find(item => item.id === id);
    if (group) {
      const transform = group.transform || {};
      const node = svgEl("g", {
        "data-group-id": group.id,
        transform: `translate(${transform.x || 0} ${transform.y || 0}) scale(${transform.scaleX || 1} ${transform.scaleY || 1}) rotate(${transform.rotation || 0})`
      });
      group.children.forEach(childId => {
        const child = findObject(childId);
        if (child && child.type !== "imported") node.append(renderNode(childId));
      });
      return node;
    }
    const object = findObject(id);
    if (!object || object.type === "imported") return svgEl("g");
    if (object.type === "text") return renderText(object);
    if (object.type === "path") return renderPath(object);
    return renderStroke(object);
  }

  function importedTransformValue(object) {
    const parts = [];
    let parent = parentGroup(object.id);
    while (parent) {
      const transform = parent.transform || {};
      parts.unshift(`translate(${transform.x || 0} ${transform.y || 0}) scale(${transform.scaleX || 1} ${transform.scaleY || 1}) rotate(${transform.rotation || 0})`);
      parent = parentGroup(parent.id);
    }
    parts.push(objectTransformValue(object.tx, object.ty, object.sx, object.sy));
    return parts.join(" ");
  }

  function applyImportedTransform(object) {
    if (!object?.node) return;
    object.node.setAttribute("transform", importedTransformValue(object));
    if (importedNeedsPromote(object) && object.batched) promoteImported(object);
  }

  function renderImportedTransforms() {
    state.importedObjects.forEach(applyImportedTransform);
  }

  function isDrawPointer(event) {
    return event.pointerType === "pen" || event.pointerType === "mouse";
  }

  function isTouchPointer(event) {
    return event.pointerType === "touch";
  }

  function rememberPointer(event) {
    state.pointers.set(event.pointerId, {
      x: event.clientX, y: event.clientY, type: event.pointerType
    });
    state.activePointerIds.add(event.pointerId);
  }

  function forgetPointer(pointerId) {
    state.pointers.delete(pointerId);
    state.activePointerIds.delete(pointerId);
  }

  function touchPointers() {
    return [...state.pointers.entries()].filter(([, pointer]) => pointer.type === "touch");
  }

  function canonicalTool(tool = state.tool) {
    return Pencil ? Pencil.canonicalizeTool(tool) : (tool === "lasso" ? "select" : tool);
  }

  function isInkTool(tool = state.tool) {
    return Pencil ? Pencil.isInkTool(tool) : (tool === "pen" || tool === "highlighter");
  }

  function currentToolRecord(tool = state.tool) {
    const id = canonicalTool(tool);
    return state.toolConfig?.byTool?.[id] || null;
  }

  function currentToolWidth() {
    const tool = canonicalTool();
    const record = currentToolRecord(tool);
    if (record && Number.isFinite(Number(record.width))) {
      if (tool === "highlighter" || tool === "pixel-eraser") return Math.max(8, Number(record.width));
      return Number(record.width);
    }
    if (tool === "highlighter") return Math.max(8, state.highlighterSize);
    if (tool === "pixel-eraser") return Math.max(8, state.eraserSize);
    return state.penSize;
  }

  function currentToolColor() {
    const record = currentToolRecord();
    if (record?.color) return record.color;
    return canonicalTool() === "highlighter" ? state.highlighterColor : state.penColor;
  }

  function currentToolOpacity() {
    const record = currentToolRecord();
    if (record && Number.isFinite(Number(record.opacity))) return Number(record.opacity);
    return canonicalTool() === "highlighter" ? .28 : 1;
  }

  function currentPressureSensitivity() {
    const record = currentToolRecord();
    if (record && Number.isFinite(Number(record.pressureSensitivity))) {
      return Number(record.pressureSensitivity);
    }
    return Pencil ? Pencil.toolPreset(state.tool).pressureSensitivity : 0;
  }

  function persistPencilPrefs() {
    if (!Pencil || !state.toolConfig) return;
    state.toolConfig.tool = canonicalTool();
    state.toolConfig.toolbarVisible = state.toolbarVisible;
    state.toolConfig.autoHideToolbar = state.autoHideToolbar;
    clearTimeout(persistPencilPrefs.timer);
    persistPencilPrefs.timer = setTimeout(() => Pencil.savePrefs(state.toolConfig), 160);
  }

  function selectedTextObjects() {
    return selectedItems().filter(item => item.type === "text");
  }

  function applyTextSizeToSelection(fontSize) {
    const targets = selectedTextObjects();
    if (!targets.length) return;
    const next = clamp(Number(fontSize), 8, 240);
    const before = snapshot();
    targets.forEach(object => {
      object.fontSize = next;
      fitTextObject(object);
    });
    commitLogicalAction(before);
    renderScene();
  }

  function syncToolControls() {
    const sizeControl = $("#stroke-size")?.closest(".size-control");
    const textControl = $("#text-size-control");
    const colorTools = $(".color-tools");
    const sizeInput = $("#stroke-size");
    const textInput = $("#text-size");
    const texts = selectedTextObjects();
    const editingText = state.tool === "select" && texts.length > 0;
    const tool = canonicalTool();
    const usesSize = !editingText && (Pencil ? Pencil.toolUsesWidth(tool) : (
      tool === "pen" || tool === "highlighter" || tool === "pixel-eraser"
    ));
    const usesColor = !editingText && (Pencil ? Pencil.toolUsesColor(tool) : (
      tool === "pen" || tool === "highlighter" || tool === "select"
    ));
    if (sizeControl) sizeControl.hidden = !usesSize;
    if (textControl) textControl.hidden = !editingText;
    if (colorTools) colorTools.hidden = !usesColor;
    if (editingText && textInput) textInput.value = String(Math.round(texts[0].fontSize || 24));
    if (sizeInput) sizeInput.value = String(currentToolWidth());
    state.size = currentToolWidth();
    state.color = currentToolColor();
    const color = state.color;
    $$(".color-chip").forEach(item => {
      const active = item.dataset.color === color;
      item.classList.toggle("is-active", active);
      item.setAttribute("aria-pressed", String(active));
    });
    const custom = $("#custom-color");
    if (custom) custom.value = color;
    syncPencilPalette();
  }

  function captureDrawingPointer(event) {
    const token = ++state.captureSerial;
    /* Touch stays uncaptured so a second finger can pinch. Pen/mouse capture
       plus window-level listeners keep rapid Pencil strokes from going missing. */
    if (event.pointerType === "touch") return token;
    const svg = $("#world-scene");
    try {
      svg.setPointerCapture(event.pointerId);
      state.capturedPointer = event.pointerId;
    } catch (_) { /* Window listeners still finish the gesture. */ }
    return token;
  }

  function releaseCapturedPointer(pointerId) {
    const svg = $("#world-scene");
    const id = pointerId ?? state.capturedPointer;
    if (id == null || !svg) return;
    state.releasingCapture = true;
    try {
      if (svg.hasPointerCapture?.(id)) svg.releasePointerCapture(id);
    } catch (_) { /* Capture may already be gone. */ }
    state.releasingCapture = false;
    if (state.capturedPointer === id) state.capturedPointer = null;
  }

  function recaptureIfNeeded(event) {
    const svg = $("#world-scene");
    if (!svg || state.interaction?.pointerId !== event.pointerId) return;
    if (svg.hasPointerCapture?.(event.pointerId)) return;
    if (["pan", "pinch"].includes(state.interaction.kind)) return;
    try { svg.setPointerCapture(event.pointerId); } catch (_) {}
    editorLog("POINTER CAPTURE", { action: "recapture", pointerId: event.pointerId });
  }

  function cancelTransientInteraction(reason = "cancel") {
    const interaction = state.interaction;
    if (interaction?.pointerId != null) releaseCapturedPointer(interaction.pointerId);
    if (interaction && (interaction.kind === "move" || interaction.kind === "resize") && interaction.before) {
      restore(interaction.before);
    }
    if (interaction?.kind === "draw") {
      activeInk = null;
      setPaletteDrawingLock(false);
    }
    state.interaction = null;
    state.pointers.clear();
    state.activePointerIds.clear();
    state.cameraGesture = "idle";
    $("#world-scene")?.classList.remove("is-panning");
    editorLog("POINTER CANCEL", { reason, kind: interaction?.kind || null });
  }

  function maybePencilDoubleTap() {
    /* Safari does not expose Apple Pencil hardware double-tap to the web. */
    return false;
  }

  function setTool(tool) {
    const next = canonicalTool(tool);
    if (!TOOLS.has(next) && next !== "select") return;
    const previous = state.tool;
    if (previous !== next) state.lastTool = previous;
    if (state.interaction) {
      const kind = state.interaction.kind;
      if (kind === "draw" || kind === "pixel" || kind === "lasso" || kind === "object-erase") {
        finishPointerInteraction(null, { reason: "tool-change", pointerId: state.interaction.pointerId });
      } else {
        cancelTransientInteraction("tool-change");
        renderScene();
      }
    }
    state.tool = next;
    if (state.toolConfig) state.toolConfig.tool = next;
    const scene = $("#world-scene");
    if (scene) scene.dataset.tool = next;
    $$(".tool-button, .palette-tool").forEach(button => {
      const active = canonicalTool(button.dataset.tool) === next;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-pressed", String(active));
    });
    syncToolMirrors();
    syncToolControls();
    persistPencilPrefs();
    if (previous !== next) editorLog("TOOL CHANGE", { from: previous, to: next });
  }

  function syncToolMirrors() {
    const tool = canonicalTool();
    const record = currentToolRecord(tool);
    if (!record) return;
    if (tool === "highlighter") {
      state.highlighterColor = record.color;
      state.highlighterSize = record.width;
    } else if (tool === "pixel-eraser" || tool === "object-eraser") {
      state.eraserSize = record.width;
    } else if (isInkTool(tool)) {
      state.penColor = record.color;
      state.penSize = record.width;
    }
    state.color = currentToolColor();
    state.size = currentToolWidth();
  }

  function setInkColor(color, { applySelection = false } = {}) {
    if (typeof color !== "string" || !/^#[0-9A-Fa-f]{6}$/.test(color)) return;
    const next = color.toLowerCase();
    const tool = canonicalTool();
    const record = currentToolRecord(tool);
    if (record && (Pencil ? Pencil.toolUsesColor(tool) : true)) record.color = next;
    if (tool === "highlighter") state.highlighterColor = next;
    else if (isInkTool(tool)) state.penColor = next;
    else if (tool === "select") {
      const pen = currentToolRecord("pen");
      if (pen) pen.color = next;
      state.penColor = next;
    }
    state.color = next;
    persistPencilPrefs();
    syncToolControls();
    if (applySelection) applyColorToSelection(next);
  }

  function setInkWidth(width) {
    const value = Number(width);
    if (!Number.isFinite(value)) return;
    const tool = canonicalTool();
    const next = clamp(value, 0.8, 48);
    const record = currentToolRecord(tool);
    if (record && (Pencil ? Pencil.toolUsesWidth(tool) : true)) record.width = next;
    if (tool === "highlighter") state.highlighterSize = next;
    else if (tool === "pixel-eraser" || tool === "object-eraser") state.eraserSize = next;
    else state.penSize = next;
    state.size = next;
    persistPencilPrefs();
    syncToolControls();
  }

  function setInkOpacity(opacity) {
    const value = Number(opacity);
    if (!Number.isFinite(value)) return;
    const tool = canonicalTool();
    const record = currentToolRecord(tool);
    if (record && (Pencil ? Pencil.toolUsesOpacity(tool) : isInkTool(tool))) {
      record.opacity = clamp(value, 0.08, 1);
    }
    persistPencilPrefs();
    syncPencilPalette();
  }

  function applyColorToSelection(color) {
    const targets = state.objects.filter(object =>
      state.selected.has(object.id) && ["stroke", "highlighter", "text", "path"].includes(object.type)
    );
    if (!targets.length) return;
    const before = snapshot();
    targets.forEach(object => {
      object.color = color;
      if (object.type === "path") object.fill = color;
    });
    commitLogicalAction(before);
    renderScene();
  }

  function paletteHost() {
    return $("#pencil-palette");
  }

  function toolChipHost() {
    return $("#pencil-tool-chip");
  }

  function hoverCursorHost() {
    return $("#pencil-hover-cursor");
  }

  function studyUiOpen() {
    return Boolean(
      ($("#study-sheet") && !$("#study-sheet").hidden) ||
      ($("#study-drawer") && !$("#study-drawer").hidden)
    );
  }

  function avoidRectsForPalette() {
    const boxes = [];
    [".workspace-header", "#study-sheet", "#study-drawer", "#selection-actions"].forEach(selector => {
      const node = $(selector);
      if (!node || node.hidden) return;
      const rect = node.getBoundingClientRect();
      if (rect.width && rect.height) {
        boxes.push({ x: rect.left, y: rect.top, width: rect.width, height: rect.height });
      }
    });
    return boxes;
  }

  function lastPaletteAnchor() {
    return state.lastPenScreen ||
      state.pencilAdapter?.getHoverPose?.() ||
      state.pencilAdapter?.getLastPenPosition?.() ||
      null;
  }

  function defaultPaletteAnchor() {
    const chip = toolChipHost();
    if (chip && !chip.hidden) {
      const rect = chip.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top };
    }
    const view = Pencil?.currentViewport?.() || {
      width: window.innerWidth, height: window.innerHeight, left: 0, top: 0, safe: {}
    };
    return {
      x: view.left + view.width * 0.5,
      y: view.top + view.height * 0.72
    };
  }

  function paletteViewport() {
    const view = Pencil?.currentViewport?.() || {
      width: window.innerWidth, height: window.innerHeight, left: 0, top: 0, safe: {}
    };
    const header = $(".workspace-header");
    const headerBottom = header ? header.getBoundingClientRect().bottom : 0;
    return {
      ...view,
      safe: {
        ...(view.safe || {}),
        top: Math.max(view.safe?.top || 0, Math.max(0, headerBottom - (view.top || 0)))
      }
    };
  }

  function positionPencilPalette(anchor) {
    const host = paletteHost();
    if (!host || !Pencil || !host.classList.contains("is-open")) return;
    const size = {
      width: host.offsetWidth || 292,
      height: host.offsetHeight || 320
    };
    const placed = Pencil.placePalette(
      anchor || lastPaletteAnchor() || defaultPaletteAnchor(),
      size,
      paletteViewport(),
      avoidRectsForPalette()
    );
    host.style.left = `${Math.round(placed.x)}px`;
    host.style.top = `${Math.round(placed.y)}px`;
  }

  function syncPencilPalette() {
    if (!Pencil) return;
    const host = paletteHost();
    const chip = toolChipHost();
    const snapshot = {
      tool: canonicalTool(),
      config: currentToolRecord() || Pencil.toolPreset(state.tool),
      mode: state.paletteMode,
      canUndo: Boolean(state.history.length),
      canRedo: Boolean(state.future.length)
    };
    Pencil.syncPalette(host, snapshot);
    Pencil.syncToolChip(chip, snapshot);
    if (state.paletteMode !== "closed") positionPencilPalette();
  }

  function setPaletteDrawingLock(active) {
    document.body.classList.toggle("is-inking", Boolean(active));
    paletteHost()?.classList.toggle("is-drawing", Boolean(active));
  }

  function closePencilPalette() {
    const host = paletteHost();
    if (!host) {
      state.paletteMode = "closed";
      return;
    }
    host.classList.remove("is-open");
    host.setAttribute("aria-hidden", "true");
    host.inert = true;
    state.paletteMode = "closed";
    const toggle = $("#pencil-palette-button");
    if (toggle) {
      toggle.classList.remove("is-open");
      toggle.setAttribute("aria-expanded", "false");
    }
    const chip = toolChipHost();
    if (chip) chip.hidden = false;
  }

  function openPencilPalette(position) {
    const host = paletteHost();
    if (!host || !Pencil) return;
    const anchor = position || lastPaletteAnchor() || defaultPaletteAnchor();
    if (anchor) state.lastPenScreen = { x: anchor.x, y: anchor.y };
    host.inert = false;
    host.setAttribute("aria-hidden", "false");
    host.classList.add("is-open");
    state.paletteMode = "temporary";
    const toggle = $("#pencil-palette-button");
    if (toggle) {
      toggle.classList.add("is-open");
      toggle.setAttribute("aria-expanded", "true");
    }
    const chip = toolChipHost();
    if (chip) chip.hidden = true;
    syncPencilPalette();
    positionPencilPalette(anchor);
    requestAnimationFrame(() => positionPencilPalette(anchor));
  }

  function togglePencilPalette(position) {
    if (state.paletteMode === "closed") openPencilPalette(position);
    else closePencilPalette();
  }

  function setToolbarVisible(visible, { persist = true } = {}) {
    const next = Boolean(visible);
    const camera = {
      x: state.camera.x, y: state.camera.y,
      width: state.camera.width, height: state.camera.height
    };
    const tool = state.tool;
    state.toolbarVisible = next;
    document.body.classList.toggle("is-focus-mode", !next);
    const button = $("#focus-mode-button");
    if (button) {
      button.setAttribute("aria-pressed", String(!next));
      button.title = next ? "Focus Mode" : "Show editing toolbar";
      button.setAttribute("aria-label", next ? "Focus Mode" : "Show editing toolbar");
    }
    if (persist) persistPencilPrefs();
    requestAnimationFrame(() => {
      state.camera.x = camera.x;
      state.camera.y = camera.y;
      state.camera.width = camera.width;
      state.tool = tool;
      syncCameraAspect();
    });
  }

  function applyPencilChrome() {
    setToolbarVisible(state.toolbarVisible, { persist: false });
    const auto = $("#auto-hide-toolbar");
    if (auto) auto.checked = Boolean(state.autoHideToolbar);
    const chip = toolChipHost();
    if (chip) chip.hidden = state.paletteMode !== "closed";
  }

  function noteToolbarIdle() {
    clearTimeout(noteToolbarIdle.timer);
    if (!state.autoHideToolbar || !state.toolbarVisible) return;
    noteToolbarIdle.timer = setTimeout(() => {
      if (!state.autoHideToolbar || inkIsActive()) return;
      setToolbarVisible(false);
    }, 8000);
  }

  function hidePencilUiForStudy() {
    if (state.paletteMode !== "closed") closePencilPalette();
    const chip = toolChipHost();
    if (chip) chip.hidden = true;
  }

  function restorePencilUiAfterStudy() {
    const chip = toolChipHost();
    if (chip) chip.hidden = state.paletteMode !== "closed";
    syncPencilPalette();
  }

  function hideHoverCursor() {
    const cursor = hoverCursorHost();
    if (cursor) cursor.hidden = true;
  }

  function updateHoverCursor(event) {
    const cursor = hoverCursorHost();
    if (!cursor || !event || event.pointerType !== "pen" || event.buttons !== 0 || inkIsActive()) {
      hideHoverCursor();
      return;
    }
    const rect = sceneRect();
    const zoom = rect.width && state.camera.width ? rect.width / state.camera.width : 1;
    const size = Math.max(6, currentToolWidth() * zoom);
    cursor.hidden = false;
    cursor.style.width = `${size}px`;
    cursor.style.height = `${size}px`;
    cursor.style.left = `${event.clientX}px`;
    cursor.style.top = `${event.clientY}px`;
    cursor.style.borderColor = currentToolColor();
  }

  function notePenPose(event) {
    if (!event || event.pointerType !== "pen") return;
    state.lastPenScreen = { x: event.clientX, y: event.clientY };
    state.pencilAdapter?.notePenPose?.(event);
    if (event.buttons === 0) updateHoverCursor(event);
    else hideHoverCursor();
  }

  function eventFromEditorChrome(event) {
    const node = event.target;
    if (!node || typeof node.closest !== "function") return false;
    return Boolean(node.closest(
      "#study-sheet, #study-drawer, #pencil-palette, #pencil-tool-chip, #chrome-menu, #gestures-help"
    ));
  }

  function logCamera(phase, extra = {}) {
    const interaction = state.interaction;
    editorLog(`CAMERA ${phase}`, {
      pointerType: extra.pointerType || interaction?.pointerType || null,
      pointerId: extra.pointerId ?? interaction?.pointerId ?? null,
      activeTouchIds: touchPointers().map(([id]) => id),
      gesture: interaction?.kind || "idle",
      ...cameraPanZoom(),
      ...extra
    });
  }

  function beginFingerTap(event) {
    if (event.pointerType !== "touch") return;
    if (!state.fingerTap) {
      state.fingerTap = {
        startedAt: nowMs(),
        origins: new Map(),
        maxFingers: 0,
        maxTravel: 0,
        maxDistDelta: 0,
        lastDistance: 0
      };
    }
    const tap = state.fingerTap;
    tap.origins.set(event.pointerId, { x: event.clientX, y: event.clientY });
    tap.maxFingers = Math.max(tap.maxFingers, tap.origins.size);
    if (tap.origins.size >= 2) {
      const points = [...tap.origins.values()];
      tap.lastDistance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
    }
  }

  function noteFingerTapMove(event) {
    const tap = state.fingerTap;
    if (!tap || event.pointerType !== "touch") return;
    const origin = tap.origins.get(event.pointerId);
    if (origin) {
      tap.maxTravel = Math.max(tap.maxTravel, Math.hypot(event.clientX - origin.x, event.clientY - origin.y));
    }
    if (tap.origins.size >= 2) {
      const points = [...state.pointers.values()].filter(pointer => pointer.type === "touch");
      if (points.length >= 2) {
        const distance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
        if (tap.lastDistance) {
          tap.maxDistDelta = Math.max(tap.maxDistDelta, Math.abs(distance - tap.lastDistance));
        }
        tap.lastDistance = distance;
      }
    }
  }

  function finishFingerTap() {
    const tap = state.fingerTap;
    state.fingerTap = null;
    if (!tap) return false;
    const duration = nowMs() - tap.startedAt;
    if (duration > 320 || tap.maxTravel > 16 || tap.maxDistDelta > 18) return false;
    if (tap.maxFingers === 2) {
      undo();
      editorLog("TOUCH UNDO", { duration, travel: tap.maxTravel });
      return true;
    }
    if (tap.maxFingers >= 3) {
      redo();
      editorLog("TOUCH REDO", { duration, travel: tap.maxTravel });
      return true;
    }
    return false;
  }

  function endCameraGesture(reason = "idle") {
    const wasCamera = state.interaction && ["pan", "pinch"].includes(state.interaction.kind);
    if (wasCamera && touchPointers().length === 0) finishFingerTap();
    if (wasCamera) {
      logCamera("END", { reason, ...cameraPanZoom() });
      markChanged();
    }
    if (wasCamera) state.interaction = null;
    state.cameraGesture = "idle";
    $("#world-scene")?.classList.remove("is-panning");
    setNavigating(false);
    applyCamera({ hud: true, overlays: true });
    scheduleViewportMaintenance();
  }

  function beginPan(event) {
    refreshSceneRect();
    state.cameraGesture = "pan";
    state.interaction = {
      kind: "pan",
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      startedAt: event.timeStamp,
      tool: state.tool,
      client: { x: event.clientX, y: event.clientY },
      camera: clone(state.camera),
      sceneRect: sceneRect()
    };
    $("#world-scene").classList.add("is-panning");
    setNavigating(true);
    logCamera("START", {
      kind: "pan", pointerId: event.pointerId, pointerType: event.pointerType
    });
  }

  function beginPanFromPointer(pointerId, pointer) {
    refreshSceneRect();
    state.cameraGesture = "pan";
    state.interaction = {
      kind: "pan",
      pointerId,
      pointerType: "touch",
      startedAt: performance.now(),
      tool: state.tool,
      client: { x: pointer.x, y: pointer.y },
      camera: clone(state.camera),
      sceneRect: sceneRect()
    };
    $("#world-scene").classList.add("is-panning");
    setNavigating(true);
    logCamera("START", { kind: "pan", pointerId, pointerType: "touch", reason: "pinch-to-pan" });
  }

  function beginPinch() {
    const points = touchPointers().map(([, pointer]) => pointer);
    if (points.length < 2) return;
    refreshSceneRect();
    const distance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
    const midpoint = { x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 };
    state.cameraGesture = "pinch";
    state.interaction = {
      kind: "pinch",
      pointerType: "touch",
      startedAt: performance.now(),
      tool: state.tool,
      distance: Math.max(1, distance),
      midpoint,
      camera: clone(state.camera),
      sceneRect: sceneRect(),
      zoomLatched: false
    };
    $("#world-scene").classList.add("is-panning");
    setNavigating(true);
    logCamera("START", { kind: "pinch", initialDistance: distance });
  }

  function syncCameraFromTouches() {
    const touches = touchPointers();
    if (touches.length === 0) {
      endCameraGesture("no-touches");
      return;
    }
    if (touches.length === 1) {
      const [id, pointer] = touches[0];
      if (state.interaction?.kind !== "pan" || state.interaction.pointerId !== id) {
        beginPanFromPointer(id, pointer);
      }
      return;
    }
    if (state.interaction?.kind !== "pinch") beginPinch();
  }

  function applyPanCamera(clientX, clientY) {
    const interaction = state.interaction;
    if (!interaction || interaction.kind !== "pan") return;
    const rect = interaction.sceneRect || sceneRect();
    const start = interaction.camera;
    if (!rect.width || !rect.height) return;
    state.camera = cameraWithAspect({
      x: start.x - (clientX - interaction.client.x) * start.width / rect.width,
      y: start.y - (clientY - interaction.client.y) * start.height / rect.height,
      width: start.width,
      height: start.height
    });
    scheduleCameraFrame();
  }

  function applyPinchCamera() {
    const interaction = state.interaction;
    if (!interaction || interaction.kind !== "pinch") return;
    const points = touchPointers().map(([, pointer]) => pointer);
    if (points.length < 2) return;
    const rect = interaction.sceneRect || sceneRect();
    if (!rect.width || !rect.height) return;
    const start = interaction.camera;
    const currentDistance = Math.max(1, Math.hypot(
      points[0].x - points[1].x, points[0].y - points[1].y
    ));
    const midpoint = {
      x: (points[0].x + points[1].x) / 2,
      y: (points[0].y + points[1].y) / 2
    };
    interaction.lastMidpoint = midpoint;
    if (!interaction.zoomLatched &&
      Math.abs(currentDistance - interaction.distance) >= PINCH_ZOOM_SLOP) {
      interaction.zoomLatched = true;
    }
    const next = Engine.pinchCamera
      ? Engine.pinchCamera({
        startCamera: start,
        startDistance: interaction.distance,
        startMidpoint: interaction.midpoint,
        currentDistance,
        currentMidpoint: midpoint,
        rect,
        zoomLatched: interaction.zoomLatched,
        minZoom: MIN_ZOOM,
        maxZoom: MAX_ZOOM,
        basis: cameraBasis()
      })
      : null;
    if (next) {
      state.camera = cameraWithAspect(next);
    } else {
      const factor = interaction.zoomLatched ? currentDistance / interaction.distance : 1;
      const width = clampCameraSize(start.width / factor);
      const height = width / sceneAspect(rect);
      const focus = screenToCanvas(interaction.midpoint.x, interaction.midpoint.y, start, rect);
      state.camera = cameraWithAspect({
        x: focus.x - (midpoint.x - rect.left) * width / rect.width,
        y: focus.y - (midpoint.y - rect.top) * height / rect.height,
        width,
        height
      });
    }
    scheduleCameraFrame();
  }

  function forgetTouchPointers() {
    [...state.pointers.entries()].forEach(([id, pointer]) => {
      if (pointer.type === "touch") forgetPointer(id);
    });
  }

  function eventFromStudyUi(event) {
    return eventFromEditorChrome(event);
  }

  function blurStudyUi() {
    const active = document.activeElement;
    if (active && typeof active.closest === "function" &&
        active.closest("#study-sheet, #study-drawer")) {
      active.blur();
    }
  }

  function resetGestureState(reason = "study-ui") {
    if (state.interaction?.kind === "draw" || inkIsActive()) return;
    const preserved = { panX: state.camera.x, panY: state.camera.y, zoom: cameraZoom() };
    const previous = {
      gesture: state.interaction?.kind || state.cameraGesture || "idle",
      pointerIds: [...state.activePointerIds],
      interactionPointer: state.interaction?.pointerId ?? null
    };
    if (state.interaction && ["pan", "pinch"].includes(state.interaction.kind)) {
      endCameraGesture(reason);
    } else if (state.interaction) {
      cancelTransientInteraction(reason);
    }
    state.pointers.clear();
    state.activePointerIds.clear();
    state.cameraGesture = "idle";
    state.interaction = null;
    releaseCapturedPointer();
    $("#world-scene")?.classList.remove("is-panning");
    setNavigating(false);
    refreshSceneRect();
    studyLog("GESTURE RESET", {
      reason,
      previousGesture: previous.gesture,
      previousPointerIds: previous.pointerIds,
      previousPointer: previous.interactionPointer,
      preservedPanX: preserved.panX,
      preservedPanY: preserved.panY,
      preservedZoom: preserved.zoom,
      ...cameraPanZoom()
    });
    logCamera("GESTURE RESET", {
      reason,
      preservedPanX: preserved.panX,
      preservedPanY: preserved.panY,
      preservedZoom: preserved.zoom,
      ...cameraPanZoom()
    });
  }

  function recoverCameraIfStuck() {
    const interaction = state.interaction;
    if (!interaction || !["pan", "pinch"].includes(interaction.kind)) return;
    if (interaction.pointerType === "touch" && touchPointers().length === 0) {
      endCameraGesture("orphaned");
    }
  }

  function hitObject(event) {
    const target = event.target.closest?.("[data-group-id],[data-object-id]");
    const direct = target?.dataset.groupId || target?.dataset.objectId || "";
    if (direct && findObject(direct) && !isBoardFillingObject(findObject(direct))) return direct;
    const point = screenToCanvas(event.clientX, event.clientY);
    const hits = objectsAtPoint(point, Math.max(2, 4 / cameraZoom()));
    const object = hits.find(item => !item.deleted && !isBoardFillingObject(item));
    return object?.id || "";
  }

  function hitResizeHandle(event) {
    return event.target?.dataset?.resize || event.target?.closest?.("[data-resize]")?.dataset?.resize || "";
  }

  function captureItemTransforms(items) {
    return items.map(object => ({
      id: object.id,
      type: object.type,
      tx: object.tx || 0,
      ty: object.ty || 0,
      sx: object.sx || 1,
      sy: object.sy || 1,
      x: object.x,
      y: object.y,
      width: object.width,
      height: object.height,
      fontSize: object.fontSize,
      wrapWidth: object.wrapWidth,
      transform: object.transform ? { ...object.transform } : null
    }));
  }

  function scaleObjectFromStart(start, origin, scaleX, scaleY) {
    const object = findObject(start.id);
    if (!object) return;
    invalidateEraseBounds(object);
    if (object.type === "group" && start.transform) {
      object.transform.scaleX = start.transform.scaleX * scaleX;
      object.transform.scaleY = start.transform.scaleY * scaleY;
      object.transform.x = start.transform.x * scaleX + origin.x * (1 - scaleX);
      object.transform.y = start.transform.y * scaleY + origin.y * (1 - scaleY);
      return;
    }
    if (object.type === "imported") {
      const map = state.importedMap || { x: 0, y: 0, scaleX: 1, scaleY: 1 };
      object.sx = start.sx * scaleX;
      object.sy = start.sy * scaleY;
      object.tx = start.tx * scaleX + map.x * (1 - scaleX) + origin.x * (1 - scaleX) / (map.scaleX || 1);
      object.ty = start.ty * scaleY + map.y * (1 - scaleY) + origin.y * (1 - scaleY) / (map.scaleY || 1);
      return;
    }
    if (object.type === "text") {
      const handle = state.interaction?.handle || "";
      object.x = start.x * scaleX + origin.x * (1 - scaleX);
      object.y = start.y * scaleY + origin.y * (1 - scaleY);
      if (["e", "w"].includes(handle)) {
        object.fontSize = start.fontSize;
        object.wrapWidth = Math.max((start.fontSize || 24) * 4, (start.wrapWidth || start.width) * scaleX);
        object.width = Math.max(4, start.width * scaleX);
        object.height = start.height;
      } else {
        const uniform = ["n", "s"].includes(handle) ? scaleY : Math.min(scaleX, scaleY);
        object.fontSize = Math.max(8, start.fontSize * uniform);
        object.width = Math.max(4, start.width * uniform);
        object.height = Math.max(4, start.height * uniform);
      }
      return;
    }
    object.sx = start.sx * scaleX;
    object.sy = start.sy * scaleY;
    object.tx = start.tx * scaleX + origin.x * (1 - scaleX);
    object.ty = start.ty * scaleY + origin.y * (1 - scaleY);
  }

  function resizeOrigin(handle, bounds) {
    const origins = {
      nw: { x: bounds.x + bounds.width, y: bounds.y + bounds.height },
      n: { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height },
      ne: { x: bounds.x, y: bounds.y + bounds.height },
      e: { x: bounds.x, y: bounds.y + bounds.height / 2 },
      se: { x: bounds.x, y: bounds.y },
      s: { x: bounds.x + bounds.width / 2, y: bounds.y },
      sw: { x: bounds.x + bounds.width, y: bounds.y },
      w: { x: bounds.x + bounds.width, y: bounds.y + bounds.height / 2 }
    };
    return origins[handle] || { x: bounds.x, y: bounds.y };
  }

  function objectsAtPoint(point, radius = 0) {
    const box = { x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2 };
    const candidates = querySpatial(box, Math.max(8, radius));
    const found = [];
    candidates.forEach(item => {
      const object = findObject(item.id);
      if (!object || object.deleted || isBoardFillingObject(object)) return;
      const bounds = item.box || objectBounds(object);
      if (point.x >= bounds.x - radius && point.x <= bounds.x + bounds.width + radius &&
        point.y >= bounds.y - radius && point.y <= bounds.y + bounds.height + radius) {
        found.push(object);
      }
    });
    return found;
  }

  function appendUserObject(object) {
    const childIds = new Set(state.groups.flatMap(group => group.children));
    if (childIds.has(object.id)) return;
    $("#user-layer")?.append(renderNode(object.id));
    upsertHtmlOverlayItem(object);
    const count = $("#object-count");
    if (count) count.textContent = `${state.objects.length} object${state.objects.length === 1 ? "" : "s"}`;
  }

  function commitLiveStroke(interaction, reason) {
    if (!interaction.points?.length) {
      removeLiveOverlay();
      editorLog("STROKE FINALIZE", {
        pointerId: interaction.pointerId, points: 0, reason, empty: true
      });
      return;
    }
    const previousObjects = state.objects;
    const rawPath = interaction.liveD || livePathFromPoints(interaction.points);
    const avgPressure = Pencil ? Pencil.averagePressure(interaction.points) : null;
    const committedWidth = Pencil
      ? Pencil.effectiveStrokeWidth(
        interaction.baseWidth || interaction.width,
        avgPressure,
        interaction.pressureSensitivity || 0
      )
      : interaction.width;
    const object = {
      id: uid("stroke"), type: interaction.objectType,
      points: interaction.points,
      d: rawPath,
      color: interaction.color, width: committedWidth,
      opacity: interaction.opacity, tx: 0, ty: 0, sx: 1, sy: 1, erasures: [],
      ink: interaction.ink || interaction.tool || "pen",
      origin: "student",
      folderId: state.lecture.folderId || "",
      createdAt: Date.now() / 1000
    };
    state.objects = previousObjects.concat(object);
    indexObject(object);
    const live = $("#live-ink");
    if (live?.getAttribute("d")) {
      const group = svgEl("g", { "data-object-id": object.id });
      const path = live.cloneNode();
      path.removeAttribute("id");
      path.removeAttribute("visibility");
      path.setAttribute("pointer-events", "stroke");
      group.append(path);
      $("#user-layer")?.append(group);
    } else {
      appendUserObject(object);
    }
    removeLiveOverlay();
    const hud = state.penHud;
    hud.strokes += 1;
    hud.lastRaw = interaction.rawCount || interaction.points.length;
    hud.lastRendered = interaction.renderedCount || interaction.points.length;
    hud.lastFinal = interaction.points.length;
    updatePenHud();
    const count = $("#object-count");
    if (count) count.textContent = `${state.objects.length} object${state.objects.length === 1 ? "" : "s"}`;
    editorLog("STROKE FINALIZE", {
      id: object.id,
      pointerId: interaction.pointerId,
      points: object.points.length,
      raw: hud.lastRaw,
      rendered: hud.lastRendered,
      final: hud.lastFinal,
      reason,
      tool: interaction.tool
    });
    const groupsAtCommit = state.groups;
    const importedAtCommit = state.importedObjects;
    queueHistoryCommit(() => ({
      objects: typeof structuredClone === "function"
        ? structuredClone(previousObjects)
        : clone(previousObjects),
      groups: clone(groupsAtCommit),
      importedTransforms: Object.fromEntries(importedAtCommit.map(item => [item.id, {
        x: item.tx || 0, y: item.ty || 0,
        scaleX: item.sx || 1, scaleY: item.sy || 1,
        deleted: Boolean(item.deleted)
      }]))
    }));
  }

  function queueHistoryCommit(entry) {
    state.pendingHistory.push(entry);
    if (state.historyTimer) return;
    const flushHistory = () => {
      state.historyTimer = 0;
      if (inkIsActive()) {
        state.historyTimer = setTimeout(flushHistory, 32);
        return;
      }
      const entries = state.pendingHistory.splice(0).map(item => (
        typeof item === "function" ? item() : item
      ));
      entries.forEach(snapshotEntry => {
        state.history.push(snapshotEntry);
        if (state.history.length > HISTORY_LIMIT) state.history.shift();
      });
      if (entries.length) {
        state.future = [];
        markChanged();
        updateHistoryButtons();
      }
    };
    state.historyTimer = setTimeout(flushHistory, 0);
  }

  function removeLiveOverlay() {
    if (state.liveInkRaf) {
      cancelAnimationFrame(state.liveInkRaf);
      state.liveInkRaf = 0;
    }
    const persistent = $("#live-ink");
    if (persistent) {
      persistent.setAttribute("d", "");
      persistent.setAttribute("visibility", "hidden");
    }
    if (state.liveNode && state.liveNode !== persistent) state.liveNode.remove();
    $("#interaction-layer")?.querySelector("[data-live='1']")?.remove();
    state.liveNode = null;
  }

  function pointerDown(event) {
    if (event.pointerType === "mouse" && event.button !== 0 && event.button !== 1) return;
    event.preventDefault();
    const drawing = isDrawPointer(event);
    const sameStuckPointer = state.interaction &&
      state.interaction.pointerId === event.pointerId &&
      drawing;
    if (sameStuckPointer) {
      finishPointerInteraction(event, { reason: "reentry" });
    } else if (drawing && state.interaction &&
      (state.interaction.kind === "pan" || state.interaction.kind === "pinch")) {
      endCameraGesture("pencil-preempt");
    } else if (drawing && state.interaction &&
      state.interaction.pointerId !== event.pointerId) {
      finishPointerInteraction(null, {
        reason: "superseded", pointerId: state.interaction.pointerId
      });
    }
    rememberPointer(event);
    beginFingerTap(event);
    notePenPose(event);
    state.penHud.downs += 1;
    if (event.pointerType !== "touch") {
      try { $("#world-scene")?.focus({ preventScroll: true }); } catch (_) {}
    }
    editorLog("PEN DOWN", {
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      tool: state.tool,
      buttons: event.buttons,
      pressure: event.pressure,
      timestamp: event.timeStamp
    });
    if (isTouchPointer(event)) {
      if (state.interaction && !["pan", "pinch"].includes(state.interaction.kind)) {
        forgetPointer(event.pointerId);
        return;
      }
      recoverCameraIfStuck();
      logCamera("DOWN", {
        pointerId: event.pointerId, pointerType: event.pointerType
      });
      syncCameraFromTouches();
      return;
    }
    if (event.button === 1 || state.spaceDown) {
      beginPan(event);
      return;
    }
    const captureToken = captureDrawingPointer(event);
    const liveRect = sceneRect();
    const liveCamera = {
      x: state.camera.x, y: state.camera.y,
      width: state.camera.width, height: state.camera.height
    };
    const point = screenToCanvas(event.clientX, event.clientY, liveCamera, liveRect);
    const tool = canonicalTool();
    if (isInkTool(tool) && maybePencilDoubleTap(event)) {
      releaseCapturedPointer(event.pointerId);
      return;
    }
    if (isInkTool(tool)) {
      const handle = hitResizeHandle(event);
      const union = selectedUnionBounds();
      if (handle && union && state.selected.size) {
        state.interaction = {
          kind: "resize",
          pointerId: event.pointerId,
          pointerType: event.pointerType,
          captureToken,
          startedAt: event.timeStamp,
          tool,
          handle,
          origin: resizeOrigin(handle, union),
          startBounds: union,
          start: point,
          current: point,
          before: snapshot(),
          startTransforms: captureItemTransforms(selectedItems()),
          sceneRect: liveRect,
          startCamera: liveCamera,
          moved: false
        };
        return;
      }
      if (union && state.selected.size && pointInRect(point, union) && !event.shiftKey) {
        state.interaction = {
          kind: "move",
          pointerId: event.pointerId,
          pointerType: event.pointerType,
          captureToken,
          startedAt: event.timeStamp,
          tool,
          start: point,
          current: point,
          startScreen: { x: event.clientX, y: event.clientY },
          startCanvas: point,
          startCamera: clone(state.camera),
          sceneRect: liveRect,
          startTransforms: captureItemTransforms(selectedItems()),
          before: snapshot(),
          moved: false
        };
        return;
      }
      const interaction = {
        kind: "draw",
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        captureToken,
        startedAt: event.timeStamp,
        lastSampleAt: event.timeStamp,
        tool,
        start: point,
        startScreen: { x: event.clientX, y: event.clientY },
        current: point,
        points: [Object.assign({}, point, Number.isFinite(event.pressure) && event.pressure > 0
          ? { p: event.pressure } : {})],
        rawCount: 1,
        renderedCount: 0,
        usedRaw: false,
        objectType: Pencil ? Pencil.toolObjectType(tool) : (tool === "highlighter" ? "highlighter" : "stroke"),
        ink: Pencil ? Pencil.toolPreset(tool).ink : tool,
        color: currentToolColor(),
        width: currentToolWidth(),
        baseWidth: currentToolWidth(),
        opacity: currentToolOpacity(),
        pressureSensitivity: currentPressureSensitivity(),
        sceneRect: liveRect,
        drawCamera: liveCamera,
        liveD: "",
        liveNode: null
      };
      activeInk = interaction;
      state.interaction = interaction;
      setPaletteDrawingLock(true);
      if (state.paletteMode === "temporary") closePencilPalette();
      appendLivePoints(interaction, [point]);
      flushLiveStroke(interaction);
      editorLog("STROKE BEGIN", {
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        tool,
        width: interaction.width,
        timestamp: event.timeStamp
      });
      return;
    }
    if (tool === "object-eraser") {
      state.interaction = {
        kind: "object-erase",
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        captureToken,
        startedAt: event.timeStamp,
        tool,
        start: point,
        current: point,
        lastPoint: point,
        before: null,
        erased: false,
        erasedIds: new Set(),
        sceneRect: liveRect,
        startCamera: liveCamera
      };
      eraseAlongSegment(point, point);
      return;
    }
    if (tool === "pixel-eraser") {
      state.interaction = {
        kind: "pixel",
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        captureToken,
        startedAt: event.timeStamp,
        tool,
        start: point,
        current: point,
        points: [point],
        width: currentToolWidth(),
        sceneRect: liveRect,
        drawCamera: liveCamera,
        liveD: "",
        liveNode: null
      };
      appendLivePoints(state.interaction, [point]);
      return;
    }
    if (tool === "select") {
      const handle = hitResizeHandle(event);
      const union = selectedUnionBounds();
      if (handle && union && state.selected.size) {
        state.interaction = {
          kind: "resize",
          pointerId: event.pointerId,
          pointerType: event.pointerType,
          captureToken,
          startedAt: event.timeStamp,
          tool,
          handle,
          origin: resizeOrigin(handle, union),
          startBounds: union,
          start: point,
          current: point,
          before: snapshot(),
          startTransforms: captureItemTransforms(selectedItems()),
          sceneRect: liveRect,
          startCamera: liveCamera,
          moved: false
        };
        editorLog("OBJECT TRANSFORM", { action: "resize-start", handle, ids: [...state.selected] });
        return;
      }
      const onSelection = event.target?.dataset?.selectionBox === "1" || pointInRect(point, union);
      if (onSelection && !event.shiftKey && state.selected.size) {
        state.interaction = {
          kind: "move",
          pointerId: event.pointerId,
          pointerType: event.pointerType,
          captureToken,
          startedAt: event.timeStamp,
          tool,
          start: point,
          current: point,
          startScreen: { x: event.clientX, y: event.clientY },
          startCanvas: point,
          startCamera: clone(state.camera),
          sceneRect: liveRect,
          startTransforms: captureItemTransforms(selectedItems()),
          before: snapshot(),
          moved: false
        };
        editorLog("DRAG START", {
          ids: [...state.selected],
          startScreen: { x: event.clientX, y: event.clientY },
          objectStart: selectedItems().map(item => ({
            id: item.id,
            x: item.tx ?? item.transform?.x ?? item.x,
            y: item.ty ?? item.transform?.y ?? item.y
          })),
          zoom: cameraZoom()
        });
        return;
      }
      const hit = hitObject(event);
      const hitObjectRef = hit ? findObject(hit) : null;
      if (hit && hitObjectRef && !hitObjectRef.deleted && !isBoardFillingObject(hitObjectRef)) {
        const hitGroup = state.groups.find(group => group.id === hit);
        const selectableId = hitGroup ? hitGroup.id : (parentGroup(hit)?.id || hit);
        if (event.shiftKey) {
          if (state.selected.has(selectableId)) state.selected.delete(selectableId);
          else state.selected.add(selectableId);
        } else if (!state.selected.has(selectableId)) state.selected = new Set([selectableId]);
        state.interaction = {
          kind: "move",
          pointerId: event.pointerId,
          pointerType: event.pointerType,
          captureToken,
          startedAt: event.timeStamp,
          tool,
          start: point,
          current: point,
          startScreen: { x: event.clientX, y: event.clientY },
          startCanvas: point,
          startCamera: clone(state.camera),
          sceneRect: liveRect,
          startTransforms: captureItemTransforms(selectedItems()),
          before: snapshot(),
          moved: false
        };
        editorLog("DRAG START", {
          ids: [...state.selected],
          startScreen: { x: event.clientX, y: event.clientY },
          objectStart: selectedItems().map(item => ({
            id: item.id,
            x: item.tx ?? item.transform?.x ?? item.x,
            y: item.ty ?? item.transform?.y ?? item.y
          })),
          zoom: cameraZoom()
        });
        const layer = $("#interaction-layer");
        layer.replaceChildren();
        renderSelection();
        return;
      }
      if (!event.shiftKey) state.selected.clear();
      state.interaction = {
        kind: "lasso",
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        captureToken,
        startedAt: event.timeStamp,
        tool,
        start: point,
        current: point,
        points: [point],
        sceneRect: liveRect,
        startCamera: liveCamera
      };
      const layer = $("#interaction-layer");
      layer.replaceChildren();
      syncLiveOverlay();
      editorLog("SELECTION START", { pointerId: event.pointerId });
    }
  }

  function pointerMove(event) {
    if (eventFromStudyUi(event) && !state.pointers.has(event.pointerId) &&
        state.interaction?.pointerId !== event.pointerId) {
      return;
    }
    notePenPose(event);
    if (state.interaction || state.pointers.has(event.pointerId)) {
      event.preventDefault();
    }
    if (state.pointers.has(event.pointerId)) {
      state.pointers.set(event.pointerId, {
        x: event.clientX, y: event.clientY, type: event.pointerType
      });
      noteFingerTapMove(event);
    }
    const interaction = state.interaction;
    if (!interaction) return;
    if (isStalePointerEvent(event, interaction)) return;
    if (interaction.kind === "pinch") {
      applyPinchCamera();
      return;
    }
    if (interaction.pointerId !== event.pointerId) return;
    if (interaction.kind === "pan") {
      applyPanCamera(event.clientX, event.clientY);
      return;
    }
    const samples = pointerSamples(event);
    if (interaction.kind === "draw") {
      state.penHud.moves += 1;
      ingestDrawSamples(interaction, event);
      if (DEBUG_EDITOR && interaction.points.length % 24 === 0) {
        editorLog("PEN MOVE", { points: interaction.points.length, timestamp: event.timeStamp });
      }
      return;
    }
    if (interaction.kind === "pixel") {
      ingestDrawSamples(interaction, event);
      return;
    }
    if (interaction.kind === "object-erase") {
      const camera = interaction.startCamera || state.camera;
      const rect = interaction.sceneRect || sceneRect();
      let previous = interaction.lastPoint || interaction.current;
      samples.forEach(sample => {
        const next = screenToCanvas(sample.clientX, sample.clientY, camera, rect);
        eraseAlongSegment(previous, next);
        previous = next;
      });
      interaction.lastPoint = previous;
      interaction.current = previous;
      return;
    }
    const camera = interaction.startCamera || interaction.drawCamera || state.camera;
    const rect = interaction.sceneRect || sceneRect();
    const point = screenToCanvas(event.clientX, event.clientY, camera, rect);
    interaction.current = point;
    if (interaction.kind === "lasso") {
      interaction.points.push(point);
      syncLiveOverlay();
    } else if (interaction.kind === "move") {
      const dx = point.x - interaction.startCanvas.x;
      const dy = point.y - interaction.startCanvas.y;
      (interaction.startTransforms || []).forEach(start => applyMoveFromStart(start, dx, dy));
      applySelectionVisuals();
      interaction.moved = Math.hypot(dx, dy) > state.camera.width / 1000;
      const layer = $("#interaction-layer");
      layer.replaceChildren();
      renderSelection();
    } else if (interaction.kind === "resize") {
      const bounds = interaction.startBounds;
      const origin = interaction.origin;
      let scaleX = 1;
      let scaleY = 1;
      if (bounds.width) scaleX = (point.x - origin.x) / (interaction.start.x - origin.x || bounds.width);
      if (bounds.height) scaleY = (point.y - origin.y) / (interaction.start.y - origin.y || bounds.height);
      if (["n", "s"].includes(interaction.handle)) scaleX = 1;
      if (["e", "w"].includes(interaction.handle)) scaleY = 1;
      scaleX = clamp(Math.abs(scaleX) || 1, 0.05, 40);
      scaleY = clamp(Math.abs(scaleY) || 1, 0.05, 40);
      interaction.startTransforms.forEach(start => scaleObjectFromStart(start, origin, scaleX, scaleY));
      applySelectionVisuals();
      interaction.moved = true;
      const layer = $("#interaction-layer");
      layer.replaceChildren();
      renderSelection();
    }
  }

  function moveObject(object, dx, dy) {
    if (object.type === "group") {
      object.transform.x = (object.transform.x || 0) + dx;
      object.transform.y = (object.transform.y || 0) + dy;
      return;
    }
    if (object.type === "imported") {
      const map = state.importedMap || { scaleX: 1, scaleY: 1 };
      object.tx = (object.tx || 0) + dx / (map.scaleX || 1);
      object.ty = (object.ty || 0) + dy / (map.scaleY || 1);
      return;
    }
    if (object.type === "text") {
      object.x += dx;
      object.y += dy;
      return;
    }
    object.tx = (object.tx || 0) + dx;
    object.ty = (object.ty || 0) + dy;
  }

  function applyMoveFromStart(start, dx, dy) {
    const object = findObject(start.id);
    if (!object) return;
    invalidateEraseBounds(object);
    if (object.type === "group" && start.transform) {
      object.transform.x = start.transform.x + dx;
      object.transform.y = start.transform.y + dy;
      return;
    }
    if (object.type === "imported") {
      const map = state.importedMap || { scaleX: 1, scaleY: 1 };
      object.tx = start.tx + dx / (map.scaleX || 1);
      object.ty = start.ty + dy / (map.scaleY || 1);
      return;
    }
    if (object.type === "text") {
      object.x = start.x + dx;
      object.y = start.y + dy;
      return;
    }
    object.tx = start.tx + dx;
    object.ty = start.ty + dy;
  }

  function applySelectionVisuals() {
    const seen = new Set();
    const visit = object => {
      if (!object || seen.has(object.id)) return;
      seen.add(object.id);
      applyObjectVisual(object);
      if (object.type === "group") {
        object.children.map(findObject).filter(Boolean).forEach(visit);
      }
    };
    selectedItems().forEach(visit);
    syncStudyMarkerAnchors();
  }

  function applyObjectVisual(object) {
    if (object.type === "imported") {
      applyImportedTransform(object);
      return;
    }
    const node = object.type === "group"
      ? $(`[data-group-id="${CSS.escape(object.id)}"]`)
      : $(`[data-object-id="${CSS.escape(object.id)}"]`);
    if (!node) return;
    if (object.type === "group") {
      const transform = object.transform || {};
      node.setAttribute("transform",
        `translate(${transform.x || 0} ${transform.y || 0}) scale(${transform.scaleX || 1} ${transform.scaleY || 1}) rotate(${transform.rotation || 0})`);
      return;
    }
    if (object.type === "path") {
      node.setAttribute("transform", objectTransformValue(object.tx, object.ty, object.sx, object.sy));
      return;
    }
    if (object.type === "text") {
      node.setAttribute("transform", `translate(${object.x} ${object.y})`);
      const hit = node.querySelector("rect.text-hit, rect");
      if (hit) {
        hit.setAttribute("width", String(object.width));
        hit.setAttribute("height", String(object.height));
      }
      const label = node.querySelector("text:not(.practice-signifier)");
      if (label) label.setAttribute("font-size", String(object.fontSize));
      applyHtmlOverlayVisual(object);
      return;
    }
    node.setAttribute("transform", objectTransformValue(object.tx, object.ty, object.sx, object.sy));
  }

  function expandBounds(box, pad) {
    return {
      x: box.x - pad,
      y: box.y - pad,
      width: box.width + pad * 2,
      height: box.height + pad * 2
    };
  }

  function pointInBounds(point, box) {
    return point.x >= box.x && point.x <= box.x + box.width &&
      point.y >= box.y && point.y <= box.y + box.height;
  }

  function segmentsIntersect(a1, a2, b1, b2) {
    const dx1 = a2.x - a1.x;
    const dy1 = a2.y - a1.y;
    const dx2 = b2.x - b1.x;
    const dy2 = b2.y - b1.y;
    const denom = dx1 * dy2 - dy1 * dx2;
    if (Math.abs(denom) < 1e-12) return false;
    const cx = b1.x - a1.x;
    const cy = b1.y - a1.y;
    const t = (cx * dy2 - cy * dx2) / denom;
    const u = (cx * dy1 - cy * dx1) / denom;
    return t >= 0 && t <= 1 && u >= 0 && u <= 1;
  }

  function distPointToSegment(point, a, b) {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 1e-12) return Math.hypot(point.x - a.x, point.y - a.y);
    const t = clamp(((point.x - a.x) * dx + (point.y - a.y) * dy) / len2, 0, 1);
    return Math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy));
  }

  function segmentHitsRect(a, b, box) {
    if (pointInBounds(a, box) || pointInBounds(b, box)) return true;
    const x1 = box.x;
    const y1 = box.y;
    const x2 = box.x + box.width;
    const y2 = box.y + box.height;
    return segmentsIntersect(a, b, { x: x1, y: y1 }, { x: x2, y: y1 }) ||
      segmentsIntersect(a, b, { x: x2, y: y1 }, { x: x2, y: y2 }) ||
      segmentsIntersect(a, b, { x: x2, y: y2 }, { x: x1, y: y2 }) ||
      segmentsIntersect(a, b, { x: x1, y: y2 }, { x: x1, y: y1 });
  }

  function segmentsTooClose(a1, a2, b1, b2, threshold) {
    if (segmentsIntersect(a1, a2, b1, b2)) return true;
    return distPointToSegment(a1, b1, b2) <= threshold ||
      distPointToSegment(a2, b1, b2) <= threshold ||
      distPointToSegment(b1, a1, a2) <= threshold ||
      distPointToSegment(b2, a1, a2) <= threshold;
  }

  function eraserBounds(object) {
    if (object._eraseBounds) return object._eraseBounds;
    object._eraseBounds = objectBounds(object);
    return object._eraseBounds;
  }

  function invalidateEraseBounds(object) {
    invalidateWorldBounds(object);
  }

  function transformedStrokePoint(object, point) {
    return {
      x: point.x * (object.sx || 1) + (object.tx || 0),
      y: point.y * (object.sy || 1) + (object.ty || 0)
    };
  }

  function strokeHitsEraserSegment(object, from, to, radius) {
    const points = object.points;
    if (!points?.length) return true;
    const width = (object.width || 0) * Math.max(Math.abs(object.sx || 1), Math.abs(object.sy || 1));
    const threshold = radius + width / 2;
    let previous = transformedStrokePoint(object, points[0]);
    if (points.length === 1) return distPointToSegment(previous, from, to) <= threshold;
    for (let index = 1; index < points.length; index++) {
      const next = transformedStrokePoint(object, points[index]);
      if (segmentsTooClose(from, to, previous, next, threshold)) return true;
      previous = next;
    }
    return false;
  }

  function objectHitsEraserSegment(object, from, to, radius) {
    if (object.deleted || isBoardFillingObject(object)) return false;
    if (!segmentHitsRect(from, to, expandBounds(eraserBounds(object), radius))) return false;
    if (object.type === "stroke" || object.type === "highlighter") {
      return strokeHitsEraserSegment(object, from, to, radius);
    }
    return true;
  }

  function eraseAlongSegment(from, to) {
    const erasedIds = state.interaction?.erasedIds;
    const radius = Math.max(4, ((currentToolRecord("object-eraser")?.width || state.eraserSize || 16)) / 2);
    const minX = Math.min(from.x, to.x) - radius;
    const minY = Math.min(from.y, to.y) - radius;
    const segmentBox = {
      x: minX, y: minY,
      width: Math.abs(to.x - from.x) + radius * 2,
      height: Math.abs(to.y - from.y) + radius * 2
    };
    const hits = [];
    querySpatial(segmentBox, radius).forEach(item => {
      if (erasedIds?.has(item.id)) return;
      const object = findObject(item.id);
      if (!object) return;
      if (objectHitsEraserSegment(object, from, to, radius)) hits.push(object);
    });
    hits.forEach(object => eraseWholeObject(object.id));
  }

  function markObjectErased(id) {
    const interaction = state.interaction;
    if (interaction?.kind !== "object-erase") return;
    interaction.erasedIds.add(id);
    interaction.erased = true;
  }

  function rememberEraseUndo() {
    const interaction = state.interaction;
    if (interaction?.kind === "object-erase" && !interaction.before) {
      interaction.before = snapshot();
    }
  }

  function eraseWholeObject(id) {
    if (!id) return false;
    const interaction = state.interaction;
    if (interaction?.kind === "object-erase" && interaction.erasedIds.has(id)) return false;
    const imported = state.importedObjects.find(object => object.id === id);
    if (imported) {
      if (isBoardFillingObject(imported) || imported.deleted) return false;
      rememberEraseUndo();
      imported.deleted = true;
      promoteImported(imported);
      imported.node?.setAttribute("display", "none");
      state.spatial?.remove(id);
      state.selected.delete(id);
      markObjectErased(id);
      editorLog("OBJECT ERASE", { id, type: "imported" });
      return true;
    }
    const index = state.objects.findIndex(object => object.id === id);
    if (index < 0) {
      const group = state.groups.find(item => item.id === id);
      if (!group) return false;
      rememberEraseUndo();
      group.children.forEach(childId => eraseWholeObject(childId));
      state.groups = state.groups.filter(item => item.id !== id);
      state.selected.delete(id);
      markObjectErased(id);
      return true;
    }
    const object = state.objects[index];
    rememberEraseUndo();
    state.objects.splice(index, 1);
    state.selected.delete(id);
    $(`[data-object-id="${CSS.escape(id)}"]`)?.remove();
    removeHtmlOverlayItem(id);
    state.spatial?.remove(id);
    markObjectErased(id);
    editorLog("OBJECT ERASE", { id, type: object.type });
    return true;
  }

  function refreshUserObject(object) {
    const existing = $(`[data-object-id="${CSS.escape(object.id)}"]`);
    const node = object.type === "text" ? renderText(object)
      : object.type === "path" ? renderPath(object)
      : renderStroke(object);
    if (existing) existing.replaceWith(node);
    else $("#user-layer")?.append(node);
    upsertHtmlOverlayItem(object);
  }

  function finishPixelEraser(interaction) {
    if (!interaction.points.length) return [];
    const touched = [];
    const trailBounds = unionBounds([{
      type: "stroke", points: interaction.points, width: interaction.width
    }]);
    state.objects.filter(object =>
      ["stroke", "highlighter"].includes(object.type) && intersects(objectBounds(object), trailBounds)
    )
      .forEach(object => {
        const sx = object.sx || 1;
        const sy = object.sy || 1;
        const tx = object.tx || 0;
        const ty = object.ty || 0;
        let hit = !object.points?.length;
        if (object.points?.length) {
          const threshold = (object.width * Math.max(Math.abs(sx), Math.abs(sy)) + interaction.width) / 2;
          hit = object.points.some(strokePoint => interaction.points.some(erasePoint =>
            Math.hypot(strokePoint.x * sx + tx - erasePoint.x, strokePoint.y * sy + ty - erasePoint.y) <= threshold
          ));
        }
        if (hit) {
          object.erasures ||= [];
          object.erasures.push({
            id: uid("erase"),
            points: interaction.points.map(point => ({
              x: (point.x - tx) / (sx || 1),
              y: (point.y - ty) / (sy || 1)
            })),
            width: interaction.width / Math.max(Math.abs(sx), Math.abs(sy), 0.01)
          });
          object._eraseBounds = null;
          touched.push(object);
        }
      });
    return touched;
  }

  function pointerRawUpdate(event) {
    const interaction = activeInk || state.interaction;
    if (!interaction || interaction.kind !== "draw") return;
    if (interaction.pointerId !== event.pointerId) return;
    if (isStalePointerEvent(event, interaction)) return;
    interaction.usedRaw = true;
    state.penHud.moves += 1;
    ingestDrawSamples(interaction, event);
  }

  function finishPointerInteraction(event, { reason = "up", pointerId } = {}) {
    const endedId = pointerId ?? event?.pointerId;
    const interaction = state.interaction;
    if (!interaction) {
      if (endedId != null) {
        forgetPointer(endedId);
        releaseCapturedPointer(endedId);
      }
      return;
    }
    if (event && reason !== "superseded" && reason !== "tool-change" &&
      interaction.kind !== "pan" && interaction.kind !== "pinch" &&
      isStalePointerEvent(event, interaction)) {
      editorLog("PEN UP ignored", { reason: "stale-timestamp", pointerId: endedId });
      return;
    }
    if (interaction.kind === "pinch" || interaction.kind === "pan") {
      if (endedId != null) forgetPointer(endedId);
      if (interaction.pointerType === "touch" || interaction.kind === "pinch") {
        syncCameraFromTouches();
      } else {
        endCameraGesture(reason);
      }
      return;
    }
    if (endedId != null && interaction.pointerId !== endedId &&
      reason !== "superseded" && reason !== "tool-change") {
      forgetPointer(endedId);
      return;
    }
    const keepFinal = Boolean(event && interaction.pointerId === event.pointerId &&
      (reason === "up" || reason === "cancel"));
    if (keepFinal && interaction.points) {
      const camera = interaction.drawCamera || interaction.startCamera || state.camera;
      const rect = interaction.sceneRect || sceneRect();
      const last = screenToCanvas(event.clientX, event.clientY, camera, rect);
      const prev = interaction.points.at(-1);
      if (!prev || prev.x !== last.x || prev.y !== last.y) {
        interaction.points.push(last);
        if (interaction.kind === "draw" || interaction.kind === "pixel") {
          appendLivePoints(interaction, [last]);
        }
      }
      interaction.current = last;
    }
    if (keepFinal && interaction.kind === "object-erase") {
      const camera = interaction.startCamera || state.camera;
      const rect = interaction.sceneRect || sceneRect();
      const last = screenToCanvas(event.clientX, event.clientY, camera, rect);
      eraseAlongSegment(interaction.lastPoint || interaction.current || last, last);
      interaction.lastPoint = last;
      interaction.current = last;
    }
    if (interaction.kind === "draw") {
      activeInk = null;
      setPaletteDrawingLock(false);
    }
    if (interaction.kind === "draw" || interaction.kind === "pan" || interaction.kind === "pinch") {
      noteToolbarIdle();
    }
    state.interaction = null;
    forgetPointer(interaction.pointerId);
    releaseCapturedPointer(interaction.pointerId);
    let needsScene = false;
    if (interaction.kind === "draw") {
      if (state.liveInkRaf) {
        cancelAnimationFrame(state.liveInkRaf);
        state.liveInkRaf = 0;
      }
      flushLiveStroke(interaction);
      state.penHud.ups += 1;
      editorLog("PEN UP", {
        pointerId: interaction.pointerId,
        pointerType: interaction.pointerType,
        points: interaction.points.length,
        duration: event ? Math.max(0, event.timeStamp - (interaction.startedAt || event.timeStamp)) : 0,
        finalized: true,
        reason
      });
      commitLiveStroke(interaction, reason);
    } else if (interaction.kind === "pixel") {
      const previousObjects = state.objects;
      const erasureCounts = new Map(previousObjects.map(object =>
        [object.id, (object.erasures || []).length]));
      finishPixelEraser(interaction).forEach(refreshUserObject);
      queueHistoryCommit(() => {
        const snap = {
          objects: clone(previousObjects),
          groups: clone(state.groups),
          importedTransforms: Object.fromEntries(state.importedObjects.map(item => [item.id, {
            x: item.tx || 0, y: item.ty || 0,
            scaleX: item.sx || 1, scaleY: item.sy || 1,
            deleted: Boolean(item.deleted)
          }]))
        };
        snap.objects.forEach(object => {
          const count = erasureCounts.get(object.id) ?? 0;
          if (object.erasures) object.erasures = object.erasures.slice(0, count);
        });
        return snap;
      });
    } else if (interaction.kind === "object-erase") {
      if (interaction.erased && interaction.before) queueHistoryCommit(interaction.before);
    } else if (interaction.kind === "move" || interaction.kind === "resize") {
      if (interaction.moved) {
        if (interaction.kind === "resize") {
          selectedItems().forEach(item => {
            if (item.type === "text") fitTextObject(item);
          });
        }
        selectedItems().forEach(indexObject);
        commitLogicalAction(interaction.before);
        editorLog("OBJECT TRANSFORM", {
          action: interaction.kind,
          ids: [...state.selected],
          startScreen: interaction.startScreen,
          currentScreen: event ? { x: event.clientX, y: event.clientY } : null,
          zoom: cameraZoom(),
          canvasDelta: interaction.startCanvas && interaction.current ? {
            x: interaction.current.x - interaction.startCanvas.x,
            y: interaction.current.y - interaction.startCanvas.y
          } : null,
          transforms: selectedItems().map(item => ({
            id: item.id,
            x: item.tx ?? item.transform?.x ?? item.x,
            y: item.ty ?? item.transform?.y ?? item.y,
            scaleX: item.sx ?? item.transform?.scaleX ?? 1,
            scaleY: item.sy ?? item.transform?.scaleY ?? 1
          }))
        });
      }
      needsScene = true;
    } else if (interaction.kind === "lasso") {
      const lassoBounds = unionBounds([{ type: "stroke", points: interaction.points, width: 0 }]);
      const candidateIds = new Set(querySpatial(lassoBounds, 12).map(item => item.id));
      const ids = topLevelItems()
        .filter(object => candidateIds.has(object.id) && lassoSelectsObject(object, interaction.points, lassoBounds))
        .map(object => object.id);
      ids.forEach(id => state.selected.add(id));
      editorLog("SELECTION END", { count: ids.length, ids });
      needsScene = true;
    }
    $("#world-scene").classList.remove("is-panning");
    editorLog("POINTER UP", {
      reason, kind: interaction.kind, pointerId: interaction.pointerId, type: interaction.pointerType,
      points: interaction.points?.length || 0
    });
    if (needsScene) renderScene();
    else if (interaction.kind !== "draw") {
      removeLiveOverlay();
      updateHistoryButtons();
      updateSelectionActions();
    }
  }

  function pointerUp(event) {
    if (eventFromStudyUi(event) && !state.pointers.has(event.pointerId) &&
        state.interaction?.pointerId !== event.pointerId) {
      return;
    }
    if (state.interaction || state.pointers.has(event.pointerId)) event.preventDefault();
    const interaction = state.interaction;
    if (interaction && ["pan", "pinch"].includes(interaction.kind)) {
      logCamera("UP", {
        pointerId: event.pointerId, pointerType: event.pointerType, reason: "up"
      });
    }
    finishPointerInteraction(event, { reason: "up" });
  }

  function pointerCancel(event) {
    if (eventFromStudyUi(event) && !state.pointers.has(event.pointerId) &&
        state.interaction?.pointerId !== event.pointerId) {
      return;
    }
    const interaction = state.interaction;
    editorLog("POINTER CANCEL", {
      pointerId: event.pointerId,
      type: event.pointerType,
      kind: interaction?.kind || null,
      points: interaction?.points?.length || 0,
      buttons: event.buttons
    });
    if (interaction && ["pan", "pinch"].includes(interaction.kind)) {
      logCamera("CANCEL", {
        pointerId: event.pointerId, pointerType: event.pointerType
      });
      finishPointerInteraction(event, { reason: "cancel" });
      return;
    }
    if (isStalePointerEvent(event, interaction)) {
      editorLog("POINTER CANCEL ignored", { reason: "stale-timestamp", pointerId: event.pointerId });
      return;
    }
    /* iPad Safari often fires pointercancel after setPointerCapture while the
       Pencil is still writing. Ending the stroke here drops the rest of the letter. */
    if (interaction?.kind === "draw" && interaction.pointerId === event.pointerId) {
      editorLog("POINTER CANCEL ignored", { reason: "keep-ink-alive", pointerId: event.pointerId });
      recaptureIfNeeded(event);
      return;
    }
    const ink = interaction &&
      ["pixel", "object-erase", "lasso"].includes(interaction.kind);
    if (ink && interaction.pointerId === event.pointerId && event.buttons) {
      editorLog("POINTER CANCEL ignored", { reason: "pen-still-down", pointerId: event.pointerId });
      return;
    }
    finishPointerInteraction(event, { reason: "cancel" });
  }

  function pointerLeave(event) {
    if (event.pointerType === "pen" && !inkIsActive()) hideHoverCursor();
    if (state.interaction?.pointerId !== event.pointerId) return;
    editorLog("POINTER LEAVE", {
      pointerId: event.pointerId,
      kind: state.interaction.kind,
      points: state.interaction.points?.length || 0
    });
  }

  function lostPointerCapture(event) {
    editorLog("POINTER CAPTURE", {
      action: "lost", pointerId: event.pointerId, releasing: state.releasingCapture,
      kind: state.interaction?.kind || null, buttons: event.buttons
    });
    if (state.releasingCapture) return;
    if (state.interaction?.pointerId !== event.pointerId) return;
    if (event.buttons) recaptureIfNeeded(event);
  }

  function deleteSelection() {
    if (!state.selected.size) return;
    const before = snapshot();
    const ids = new Set(state.selected);
    state.objects = state.objects.filter(object => !ids.has(object.id));
    state.importedObjects.forEach(object => {
      if (ids.has(object.id)) {
        object.deleted = true;
        object.node?.setAttribute("display", "none");
      }
    });
    state.groups = state.groups.filter(group => !ids.has(group.id));
    state.selected.clear();
    commitLogicalAction(before);
    renderScene();
  }

  function isTextEntryTarget(target) {
    if (!target || typeof target.closest !== "function") return false;
    return Boolean(target.closest("input, textarea, select, [contenteditable='true'], [contenteditable='']"));
  }

  function cloneSelectable(object) {
    if (!object || object.deleted) return null;
    if (object.type === "imported") {
      const d = object.sourceD || object.path?.getAttribute("d") || "";
      if (!d) return null;
      return {
        id: uid("path"),
        type: "path",
        d,
        sourceD: d,
        sourceRevision: 1,
        color: object.color || "#183153",
        fill: object.color || "#183153",
        width: 0,
        opacity: 1,
        tx: object.tx || 0,
        ty: object.ty || 0,
        sx: object.sx || 1,
        sy: object.sy || 1,
        bbox: object.bbox ? { ...object.bbox } : null,
        origin: "student",
        folderId: state.lecture.folderId || "",
        createdAt: Date.now() / 1000
      };
    }
    if (object.type === "group") return null;
    return clone(object);
  }

  function copySelection() {
    const items = selectedItems().filter(item => !item.deleted && !isBoardFillingObject(item));
    if (!items.length) return;
    state.clipboard = items.map(cloneSelectable).filter(Boolean).map(object => {
      object.id = uid(object.type === "text" ? "text" : object.type === "path" ? "path" : "stroke");
      return object;
    });
    editorLog("COPY", { count: state.clipboard.length });
  }

  function pasteClipboard({ offset = true } = {}) {
    if (!state.clipboard?.length) return;
    const before = snapshot();
    const zoom = Math.max(0.01, cameraZoom());
    const dx = offset ? 18 / zoom : 0;
    const dy = offset ? 18 / zoom : 0;
    const created = state.clipboard.map(item => {
      const object = clone(item);
      object.id = uid(object.type === "text" ? "text" : object.type === "path" ? "path" : "stroke");
      if (object.type === "text") {
        object.x += dx;
        object.y += dy;
      } else {
        object.tx = (object.tx || 0) + dx;
        object.ty = (object.ty || 0) + dy;
      }
      return object;
    });
    created.forEach(object => {
      state.objects.push(object);
      appendUserObject(object);
      indexObject(object);
    });
    state.selected = new Set(created.map(object => object.id));
    commitLogicalAction(before);
    renderScene();
    editorLog("PASTE", { count: created.length });
  }

  function duplicateSelection() {
    copySelection();
    pasteClipboard({ offset: true });
  }

  function selectAllObjects() {
    state.selected = new Set(
      topLevelItems()
        .filter(object => !object.deleted && !isBoardFillingObject(object))
        .map(object => object.id)
    );
    invalidateSelectionUnion();
    renderScene();
  }

  function handleKeyDown(event) {
    if (isTextEntryTarget(event.target)) return;
    if (event.code === "Space") {
      state.spaceDown = true;
      event.preventDefault();
    }
    const meta = event.ctrlKey || event.metaKey;
    const key = String(event.key || "").toLowerCase();
    const code = event.code || "";
    if (meta && (key === "z" || code === "KeyZ")) {
      event.preventDefault();
      event.stopPropagation();
      event.shiftKey ? redo() : undo();
    } else if (meta && (key === "y" || code === "KeyY")) {
      event.preventDefault();
      redo();
    } else if (meta && (key === "c" || code === "KeyC")) {
      event.preventDefault();
      copySelection();
    } else if (meta && (key === "v" || code === "KeyV")) {
      event.preventDefault();
      pasteClipboard();
    } else if (meta && (key === "d" || code === "KeyD")) {
      event.preventDefault();
      duplicateSelection();
    } else if (meta && (key === "a" || code === "KeyA")) {
      event.preventDefault();
      selectAllObjects();
    } else if ((event.key === "Delete" || event.key === "Backspace") && state.selected.size) {
      event.preventDefault();
      deleteSelection();
    } else if (event.key === "Enter" && state.selected.size === 1) {
      const object = findObject([...state.selected][0]);
      if (object?.type === "text") {
        event.preventDefault();
        editTextObject(object.id);
      }
    } else if ((key === "t" || code === "KeyT") && !meta) {
      event.preventDefault();
      togglePencilPalette(lastPaletteAnchor());
    } else if (event.key === "Escape") {
      if (state.paletteMode !== "closed") {
        event.preventDefault();
        closePencilPalette();
        return;
      }
      if (state.interaction) cancelTransientInteraction("escape");
      state.selected.clear();
      invalidateSelectionUnion();
      renderScene();
    }
  }

  function studyApi(path) {
    return `/api/boards/${encodeURIComponent(boardId)}${path}`;
  }

  async function requestStudy(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: { Accept: "application/json", ...(options.headers || {}) }
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(payload.error || payload.message || "Couldn't explain this right now. Your board is still saved.");
    }
    return payload;
  }

  function newStudyRequestId() {
    const bytes = new Uint8Array(8);
    (globalThis.crypto || window.crypto).getRandomValues(bytes);
    return [...bytes].map(value => value.toString(16).padStart(2, "0")).join("");
  }

  function followUpsOf(interaction) {
    return interaction?.followUps || interaction?.follow_ups || [];
  }

  function renderMarkdownInto(target, source) {
    if (!target) return;
    const paint = () => {
      target.replaceChildren();
      const renderer = globalThis.renderStudyMarkdown;
      if (typeof renderer === "function") {
        target.append(renderer(source));
        return;
      }
      const p = document.createElement("p");
      p.textContent = source || "";
      target.append(p);
    };
    paint();
    if (!globalThis.katex?.renderToString && globalThis.hasMathMarkup?.(source)) {
      const started = Date.now();
      const timer = window.setInterval(() => {
        if (globalThis.katex?.renderToString || Date.now() - started > 4000) {
          window.clearInterval(timer);
          if (globalThis.katex?.renderToString) paint();
        }
      }, 80);
    }
  }

  function setStudyHeading(source) {
    const title = $("#study-title");
    if (!title) return;
    const text = source || "Explanation";
    title.setAttribute("aria-label", String(text).replace(/\$\$?|\\[()[\]]/g, "").replace(/\s+/g, " ").trim() || text);
    const fill = globalThis.fillStudyRichText;
    if (typeof fill === "function") fill(title, text);
    else title.textContent = text;
  }

  function actionLabel(kind) {
    return {
      go_deeper: "Go Deeper",
      practice_examples: "Practice examples",
      practice_problems: "Practice Problems",
      followup: "Follow-up"
    }[kind] || "Follow-up";
  }

  function appendUserTurn(parent, text) {
    const question = document.createElement("p");
    question.className = "study-user-q";
    question.textContent = `You: ${text}`;
    parent.append(question);
  }

  function appendAssistantTurn(parent, source) {
    const wrap = document.createElement("div");
    wrap.className = "study-ai-turn";
    renderMarkdownInto(wrap, source || "");
    parent.append(wrap);
  }

  function appendGenerating(parent) {
    const status = document.createElement("p");
    status.className = "study-generating";
    status.textContent = "Generating...";
    parent.append(status);
  }

  function upsertStudyInteraction(interaction) {
    if (!interaction?.id) return null;
    const next = [];
    let found = false;
    state.studyInteractions.forEach(item => {
      if (item.id === interaction.id) {
        next.push(interaction);
        found = true;
      } else next.push(item);
    });
    if (!found) next.unshift(interaction);
    state.studyInteractions = next;
    return interaction;
  }

  function setStudyStatus(message, isError = false) {
    const status = $("#study-status");
    if (!status) return;
    status.hidden = !message;
    status.textContent = message || "";
    status.classList.toggle("is-error", Boolean(isError));
  }

  function setStudyBusy(busy) {
    state.explaining = Boolean(busy);
    const button = $("#explain-button");
    if (button) button.disabled = state.explaining;
    $$("#study-actions .study-action, #selection-actions button").forEach(node => { node.disabled = state.explaining; });
    const ask = $("#study-followup button");
    if (ask) ask.disabled = state.explaining;
  }

  function renderStudyList() {
    const list = $("#study-note-list");
    if (!list) return;
    list.replaceChildren();
    if (!state.studyInteractions.length) {
      const empty = document.createElement("p");
      empty.className = "library-message";
      empty.textContent = "Lasso something confusing, then tap Explain.";
      list.append(empty);
      return;
    }
    state.studyInteractions.forEach(item => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "study-note-item";
      button.dataset.studyId = item.id;
      if (item.id === state.activeStudyId) button.classList.add("is-active");
      const title = document.createElement("strong");
      const fill = globalThis.fillStudyRichText;
      if (typeof fill === "function") fill(title, item.title || "Explanation");
      else title.textContent = item.title || "Explanation";
      const preview = document.createElement("span");
      const previewSource = String(item.answer || "")
        .split(/\r?\n/)
        .map(line => line.trim())
        .find(line => line && !/^#{1,6}\s/.test(line) && !/^(?:\$\$|\\\[|\\\])$/.test(line))
        || item.answer
        || "";
      if (typeof fill === "function") fill(preview, previewSource);
      else preview.textContent = previewSource;
      button.append(title, preview);
      button.addEventListener("click", () => openStudyInteraction(item.id));
      list.append(button);
    });
  }

  function appendPracticeCanvasButton(parent, follow) {
    const problems = Array.isArray(follow.problems) && follow.problems.length
      ? follow.problems.map(item => item.problem || item.text || item).filter(Boolean)
      : [follow.problem || (follow.kind === "practice_problems" ? follow.answer : "")].filter(Boolean);
    if (!problems.length) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "study-canvas-action";
    button.textContent = problems.length > 1 ? "Add to Canvas" : "Add to Canvas";
    button.addEventListener("click", () => addPracticeProblemsToCanvas(problems, follow));
    parent.append(button);
  }

  function renderStudyConversation(interaction, { scrollToLatest = false } = {}) {
    const body = $("#study-body");
    if (!body || !interaction) return;
    body.replaceChildren();
    const originalQuestion = interaction.question || "Explain this";
    appendUserTurn(body, originalQuestion);
    if (interaction.answer) appendAssistantTurn(body, interaction.answer);
    followUpsOf(interaction).forEach(follow => {
      const block = document.createElement("div");
      block.className = "study-follow-block";
      block.dataset.followId = follow.id || "";
      const asked = follow.kind === "followup"
        ? follow.question
        : actionLabel(follow.kind);
      appendUserTurn(block, asked || actionLabel(follow.kind));
      if (follow.answer || follow.problem) {
        appendAssistantTurn(block, follow.answer || follow.problem || "");
      }
      appendPracticeCanvasButton(block, follow);
      body.append(block);
    });
    if (state.explaining && state.pendingStudyQuestion) {
      const pending = document.createElement("div");
      pending.className = "study-follow-block is-pending";
      appendUserTurn(pending, state.pendingStudyQuestion);
      appendGenerating(pending);
      body.append(pending);
    } else if (state.explaining && !interaction.answer) {
      appendGenerating(body);
    }
    if (scrollToLatest) {
      const latest = body.lastElementChild;
      latest?.scrollIntoView({ block: "nearest" });
    }
  }

  function openStudySheet() {
    resetGestureState("study-open");
    hidePencilUiForStudy();
    $("#study-sheet").hidden = false;
    $("#study-drawer").hidden = true;
    studyLog("PANEL", { action: "open", ...cameraPanZoom(), gesture: state.cameraGesture });
  }

  function closeStudySheet() {
    blurStudyUi();
    resetGestureState("study-close");
    $("#study-sheet").hidden = true;
    $("#study-sheet")?.classList.remove("is-fresh");
    setStudyStatus("");
    setStudyProgress(false);
    restorePencilUiAfterStudy();
    studyLog("PANEL", { action: "close", ...cameraPanZoom(), gesture: state.cameraGesture });
  }

  function showStudyActions(visible) {
    const actions = $("#study-actions");
    const form = $("#study-followup");
    if (actions) actions.hidden = !visible;
    if (form) form.hidden = !visible;
  }

  function openStudyInteraction(id, { fresh = false, scrollToLatest = false } = {}) {
    const interaction = state.studyInteractions.find(item => item.id === id);
    if (!interaction) return;
    state.activeStudyId = id;
    $("#study-kicker").textContent = fresh ? "New explanation" : "Saved explanation";
    setStudyHeading(interaction.title || "Explanation");
    $("#study-sheet")?.classList.toggle("is-fresh", Boolean(fresh));
    renderStudyConversation(interaction, { scrollToLatest: scrollToLatest || fresh });
    showStudyActions(true);
    setStudyStatus("");
    setStudyGuideMode(false);
    setStudyProgress(false);
    openStudySheet();
    renderStudyList();
  }

  function selectionHasPracticeWork() {
    const items = [...state.selected].map(findObject).filter(object => object && !object.deleted);
    const hasProblem = items.some(item => item.role === "ai_practice_problem");
    const hasWork = items.some(item => item.role !== "ai_practice_problem");
    return hasProblem && hasWork;
  }

  function lectureHasMultipleBoards() {
    return lectureBoardsFromData().length > 1;
  }

  function positionExplainButton({ cheap = false } = {}) {
    const cluster = $("#selection-actions");
    const button = $("#explain-button");
    if (!cluster || !button) return;
    const union = selectedUnionBounds();
    if (!union || !state.selected.size || inkIsActive()) {
      cluster.hidden = true;
      return;
    }
    const frame = $("#primary-frame");
    const rect = sceneRect();
    if (!frame || !rect.width) {
      cluster.hidden = true;
      return;
    }
    if (!cheap) {
      const check = selectionHasPracticeWork();
      const multi = lectureHasMultipleBoards();
      $("#explain-across-button").hidden = check || !multi;
      $("#where-from-button").hidden = check || !multi;
      $("#check-work-button").hidden = !check;
      button.hidden = false;
    }
    const frameBox = frame.getBoundingClientRect();
    const left = canvasToScreen(union.x, union.y, state.camera, rect);
    const right = canvasToScreen(union.x + union.width, union.y, state.camera, rect);
    const x = (left.x + right.x) / 2 - frameBox.left;
    const y = left.y - frameBox.top - 56;
    cluster.hidden = false;
    cluster.style.left = `${Math.max(12, Math.min(frameBox.width - 12, x))}px`;
    cluster.style.top = `${Math.max(8, y)}px`;
  }

  function selectionCanvasBox(ids = [...state.selected]) {
    const items = ids.map(findObject).filter(object => object && !object.deleted);
    if (!items.length) return null;
    const bounds = items.map(objectBounds);
    const left = Math.min(...bounds.map(box => box.x));
    const top = Math.min(...bounds.map(box => box.y));
    const right = Math.max(...bounds.map(box => box.x + box.width));
    const bottom = Math.max(...bounds.map(box => box.y + box.height));
    return {
      x: left, y: top,
      width: Math.max(1, right - left),
      height: Math.max(1, bottom - top)
    };
  }

  function unionCanvasBoxes(boxes) {
    const items = boxes.filter(box => box && box.width > 0 && box.height > 0);
    if (!items.length) return null;
    const left = Math.min(...items.map(box => box.x));
    const top = Math.min(...items.map(box => box.y));
    const right = Math.max(...items.map(box => box.x + box.width));
    const bottom = Math.max(...items.map(box => box.y + box.height));
    return {
      x: left, y: top,
      width: Math.max(1, right - left),
      height: Math.max(1, bottom - top)
    };
  }

  function studyAnchorFor(item) {
    const ids = item.selectedObjectIds || item.selected_object_ids || [];
    const live = unionCanvasBoxes(ids.map(id => {
      const object = findObject(id);
      return object && !object.deleted ? objectBounds(object) : null;
    }));
    const box = live;
    if (box) {
      const scale = studyMarkerScale();
      const pad = 10 * scale;
      return { x: box.x + box.width + pad, y: box.y };
    }
    const anchorX = Number(item.anchorX ?? item.anchor_x);
    const anchorY = Number(item.anchorY ?? item.anchor_y);
    if (Number.isFinite(anchorX) && Number.isFinite(anchorY)) {
      return { x: anchorX, y: anchorY };
    }
    const stored = item.selectionBBox || item.selection_bbox;
    if (stored && Number.isFinite(Number(stored.x)) && Number.isFinite(Number(stored.y))) {
      return { x: Number(stored.x) + Number(stored.width || 0), y: Number(stored.y) };
    }
    return null;
  }

  function studyMarkerScale() {
    const rect = sceneRect();
    return rect.width > 0 ? state.camera.width / rect.width : 1;
  }

  function setStudyMarkerAnchor(node, x, y) {
    const scale = studyMarkerScale();
    node.setAttribute("data-anchor-x", String(x));
    node.setAttribute("data-anchor-y", String(y));
    node.setAttribute("transform", `translate(${x} ${y}) scale(${scale})`);
  }

  function syncStudyMarkerScale() {
    const layer = $("#study-layer");
    if (!layer) return;
    const scale = studyMarkerScale();
    [...layer.children].forEach(node => {
      const x = node.getAttribute("data-anchor-x");
      const y = node.getAttribute("data-anchor-y");
      if (x == null || y == null) return;
      node.setAttribute("transform", `translate(${x} ${y}) scale(${scale})`);
    });
  }

  function syncStudyMarkerAnchors() {
    const layer = $("#study-layer");
    if (!layer) return;
    state.studyInteractions.forEach(item => {
      const node = layer.querySelector(`[data-study-marker="${CSS.escape(item.id)}"]`);
      if (!node) return;
      const anchor = studyAnchorFor(item);
      if (!anchor) return;
      setStudyMarkerAnchor(node, anchor.x, anchor.y);
    });
  }

  function renderStudyMarkers() {
    const layer = $("#study-layer");
    if (!layer) return;
    layer.replaceChildren();
    $("#primary-frame")?.querySelectorAll("[data-study-marker]").forEach(node => {
      if (node.namespaceURI !== NS) node.remove();
    });
    state.studyInteractions.forEach(item => {
      const anchor = studyAnchorFor(item);
      if (!anchor) return;
      const group = svgEl("g", {
        class: "study-marker",
        "data-study-marker": item.id,
        "data-anchor-x": String(anchor.x),
        "data-anchor-y": String(anchor.y),
        role: "button",
        "aria-label": item.title || "Open explanation",
        transform: `translate(${anchor.x} ${anchor.y}) scale(${studyMarkerScale()})`
      });
      const hit = svgEl("circle", {
        class: "study-marker-hit",
        cx: 0, cy: 0, r: 14,
        fill: "transparent", stroke: "none",
        "pointer-events": "all"
      });
      const icon = svgEl("g", {
        class: "study-marker-icon",
        "pointer-events": "none"
      });
      icon.append(svgEl("circle", {
        cx: 0, cy: 0, r: 8, fill: "#ffffff", stroke: "#183153", "stroke-width": 1.6
      }));
      const label = svgEl("text", {
        x: 0, y: 3.5, "text-anchor": "middle", "font-size": 10,
        "font-family": "system-ui, sans-serif", "font-weight": 700,
        fill: "#183153", "pointer-events": "none"
      });
      label.textContent = "i";
      icon.append(label);
      group.append(hit, icon);
      let press = null;
      group.addEventListener("pointerdown", event => {
        event.stopPropagation();
        event.preventDefault();
        press = { x: event.clientX, y: event.clientY, id: event.pointerId };
      });
      group.addEventListener("pointerup", event => {
        event.stopPropagation();
        if (!press || press.id !== event.pointerId) return;
        if (Math.hypot(event.clientX - press.x, event.clientY - press.y) < 14) {
          openStudyInteraction(item.id);
        }
        press = null;
      });
      group.addEventListener("pointercancel", () => { press = null; });
      layer.append(group);
    });
  }

  async function loadStudyInteractions() {
    if (!boardId) return;
    try {
      const payload = await requestStudy(studyApi("/study"));
      state.studyInteractions = Array.isArray(payload.interactions) ? payload.interactions : [];
      renderStudyList();
      renderStudyMarkers();
    } catch (_) {
      state.studyInteractions = [];
    }
  }

  function ensureBoardContext() {
    if (!boardId) return;
    requestStudy(studyApi("/study/analyze"), { method: "POST" }).catch(() => {});
    if (state.lecture.folderId && lectureHasMultipleBoards() && !state.lecture.studyGuide) {
      fetch(`/api/folders/${encodeURIComponent(state.lecture.folderId)}/analyze`, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        body: "{}"
      }).catch(() => {});
    }
  }

  function selectedTextPayload(ids = [...state.selected]) {
    return ids.map(findObject).filter(object => object?.type === "text" && !object.deleted).map(object => ({
      id: object.id,
      type: "text",
      role: object.role || "text",
      text: object.text,
      fontSize: object.fontSize,
      x: object.x,
      y: object.y,
      width: object.width,
      height: object.height,
      practiceProblemId: object.practiceProblemId || undefined,
      sourceStudyInteractionId: object.sourceStudyInteractionId || undefined
    }));
  }

  function boxesOverlap(a, b) {
    return a.x <= b.x + b.width && a.x + a.width >= b.x &&
      a.y <= b.y + b.height && a.y + a.height >= b.y;
  }

  function originalBoardBox() {
    return { x: 0, y: 0, width: state.width, height: state.height };
  }

  async function explainSelection(action = "explain") {
    if (state.explaining || !boardId || !state.selected.size) return;
    const ids = [...state.selected];
    const bbox = selectionCanvasBox(ids) || selectedUnionBounds();
    const board = originalBoardBox();
    studyLog("AI_SELECTION", {
      objects: ids.length,
      ids,
      bbox: bbox ? [bbox.x, bbox.y, bbox.width, bbox.height] : null,
      insideOriginalBoard: Boolean(bbox && boxesOverlap(bbox, board)),
      contentFound: ids.length > 0,
      objectCoords: ids.map(id => {
        const object = findObject(id);
        const box = object ? objectBounds(object) : null;
        return {
          id,
          type: object?.type,
          box,
          insideOriginalBoard: Boolean(box && boxesOverlap(box, board))
        };
      })
    });
    await flushEditorSave();
    const scale = studyMarkerScale();
    const pad = bbox ? 10 * scale : 12;
    const anchor = bbox
      ? { x: bbox.x + bbox.width + pad, y: bbox.y }
      : studyAnchorFor({ selectedObjectIds: ids, selectionBBox: bbox });
    const offsets = bbox && bbox.width && bbox.height && anchor
      ? { nx: (anchor.x - bbox.x) / bbox.width, ny: (anchor.y - bbox.y) / bbox.height }
      : { nx: 1, ny: 0 };
    const requestId = newStudyRequestId();
    const token = ++state.studyRequestToken;
    const question = {
      explain: "Explain this",
      explain_across_boards: "How does this relate to the previous board?",
      where_from: "Where did this come from?",
      check_my_work: "Check my work"
    }[action] || "Explain this";
    state.pendingStudyId = requestId;
    state.pendingStudyQuestion = question;
    state.pendingStudyAction = action;
    setStudyBusy(true);
    $("#study-kicker").textContent = action === "check_my_work" ? "Checking work" : "Explaining selection";
    setStudyHeading({
      explain: "Explain",
      explain_across_boards: "Across boards",
      where_from: "Where this came from",
      check_my_work: "Check my work"
    }[action] || "Explain");
    showStudyActions(false);
    setStudyGuideMode(false);
    $("#study-sheet")?.classList.add("is-fresh");
    setStudyStatus("");
    setStudyProgress(false);
    openStudySheet();
    const body = $("#study-body");
    if (body) {
      body.replaceChildren();
      appendUserTurn(body, question);
      appendGenerating(body);
    }
    try {
      const payload = await requestStudy(studyApi("/study/explain"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          selectedObjectIds: ids,
          selectedTextObjects: selectedTextPayload(ids),
          selectionBBox: bbox,
          anchorX: anchor?.x,
          anchorY: anchor?.y,
          anchorOffsetNx: offsets.nx,
          anchorOffsetNy: offsets.ny,
          studyInteractionId: requestId,
          requestId,
          question,
          action
        })
      });
      const interaction = payload.interaction || payload;
      if (!interaction?.id) throw new Error("Couldn't explain this right now. Your board is still saved.");
      interaction.anchorOffsetNx = interaction.anchorOffsetNx ?? offsets.nx;
      interaction.anchorOffsetNy = interaction.anchorOffsetNy ?? offsets.ny;
      upsertStudyInteraction(interaction);
      if (token !== state.studyRequestToken) return;
      const openId = payload.studyInteractionId || interaction.id;
      state.pendingStudyId = null;
      state.pendingStudyQuestion = "";
      state.pendingStudyAction = "";
      state.activeStudyId = openId;
      openStudyInteraction(openId, { fresh: true, scrollToLatest: true });
      renderStudyMarkers();
    } catch (error) {
      if (token !== state.studyRequestToken) return;
      setStudyHeading("Couldn't explain this");
      setStudyStatus(error.message || "Couldn't explain this right now. Your board is still saved.", true);
      showStudyActions(false);
    } finally {
      if (token === state.studyRequestToken) {
        state.pendingStudyId = null;
        state.pendingStudyQuestion = "";
        state.pendingStudyAction = "";
        setStudyBusy(false);
      }
    }
  }

  async function sendStudyAction({ action = "followup", question = "" } = {}) {
    const interactionId = state.activeStudyId;
    if (state.explaining || !interactionId) return;
    const requestId = newStudyRequestId();
    const token = ++state.studyRequestToken;
    const displayQuestion = action === "followup" ? question : actionLabel(action);
    state.pendingStudyQuestion = displayQuestion;
    state.pendingStudyAction = action;
    setStudyBusy(true);
    setStudyStatus("");
    const current = state.studyInteractions.find(item => item.id === interactionId);
    if (current) renderStudyConversation(current, { scrollToLatest: true });
    try {
      const payload = await requestStudy(
        studyApi(`/study/${encodeURIComponent(interactionId)}/followup`),
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action,
            question,
            requestId,
            studyInteractionId: interactionId
          })
        }
      );
      const interaction = payload.interaction || payload;
      if (!interaction?.id) throw new Error("Couldn't explain this right now. Your board is still saved.");
      upsertStudyInteraction(interaction);
      if (payload.studyInteractionId && payload.studyInteractionId !== interactionId &&
          payload.studyInteractionId !== interaction.id) {
        return;
      }
      if (state.activeStudyId !== interactionId) return;
      state.pendingStudyQuestion = "";
      openStudyInteraction(interaction.id, { scrollToLatest: true });
      if (action === "practice_problems" && (payload.problems || payload.problem || interaction.problem)) {
        setStudyStatus("Practice problems ready. Add them to the canvas if you want to solve them here.");
      } else {
        setStudyStatus("");
      }
      renderStudyList();
    } catch (error) {
      if (token !== state.studyRequestToken && state.activeStudyId !== interactionId) return;
      setStudyStatus(error.message || "Couldn't explain this right now. Your board is still saved.", true);
    } finally {
      state.pendingStudyQuestion = "";
      state.pendingStudyAction = "";
      setStudyBusy(false);
      const latest = state.studyInteractions.find(item => item.id === interactionId);
      if (latest && state.activeStudyId === interactionId) {
        renderStudyConversation(latest, { scrollToLatest: true });
      }
    }
  }

  async function sendFollowUp(event) {
    event.preventDefault();
    const input = $("#followup-input");
    const question = input.value.trim();
    if (!question) return;
    input.value = "";
    await sendStudyAction({ action: "followup", question });
  }

  function addPracticeProblemsToCanvas(problems, follow = {}) {
    const statements = (Array.isArray(problems) ? problems : [problems])
      .map(item => {
        if (item && typeof item === "object") return String(item.problem || item.text || "").trim();
        return String(item || "").trim();
      })
      .filter(Boolean);
    if (!statements.length) return;
    const interaction = state.studyInteractions.find(item => item.id === state.activeStudyId);
    const ids = interaction?.selectedObjectIds || [...state.selected];
    const live = unionCanvasBoxes(ids.map(id => {
      const object = findObject(id);
      return object && !object.deleted ? objectBounds(object) : null;
    }));
    const fontSize = 24;
    let x = live ? live.x : (Number(interaction?.anchorX) || state.camera.x + 40);
    let y = live ? live.y + live.height + Math.max(28, fontSize) : (Number(interaction?.anchorY) || state.camera.y + 40);
    const created = [];
    const metaProblems = Array.isArray(follow.problems) ? follow.problems : [];
    statements.forEach((text, index) => {
      const object = {
        id: uid("text"),
        type: "text",
        x,
        y,
        width: 40,
        height: 20,
        text,
        color: "#183153",
        fontSize,
        wrapWidth: Math.max(live?.width || 0, fontSize * 22),
        role: "ai_practice_problem",
        practiceProblemId: metaProblems[index]?.id || uid("prob").slice(0, 20),
        sourceStudyInteractionId: interaction?.id || "",
        generatedAt: Date.now() / 1000,
        origin: "ai_practice",
        folderId: state.lecture.folderId || "",
        createdAt: Date.now() / 1000
      };
      fitTextObject(object);
      created.push(object);
      y += object.height + Math.max(18, fontSize * 0.75);
    });
    const before = snapshot();
    created.forEach(object => state.objects.push(object));
    state.selected = new Set(created.map(object => object.id));
    commitLogicalAction(before);
    renderScene();
    toast(created.length > 1 ? "Practice problems added to the canvas." : "Practice problem added to the canvas.");
  }

  function closeTextEditor(save = true) {
    const editor = $("#text-editor-overlay");
    if (!editor) return;
    const object = findObject(editor.dataset.objectId);
    const nextText = editor.value;
    editor.remove();
    if (object) {
      const overlay = $("#canvas-html-world")?.querySelector(`[data-object-id="${CSS.escape(object.id)}"]`);
      if (overlay) overlay.hidden = false;
    }
    if (!save || !object || object.type !== "text") return;
    if (object.text === nextText) return;
    const before = snapshot();
    object.text = nextText;
    fitTextObject(object);
    commitLogicalAction(before);
    renderScene();
  }

  function editTextObject(id) {
    const object = findObject(id);
    if (!object || object.type !== "text") return;
    closeTextEditor(true);
    const frame = $("#primary-frame");
    const rect = sceneRect();
    if (!frame || !rect.width) return;
    const frameBox = frame.getBoundingClientRect();
    const topLeft = canvasToScreen(object.x, object.y, state.camera, rect);
    const bottomRight = canvasToScreen(object.x + object.width, object.y + object.height, state.camera, rect);
    const editor = document.createElement("textarea");
    editor.id = "text-editor-overlay";
    editor.className = "text-editor-overlay";
    editor.dataset.objectId = object.id;
    editor.value = object.text;
    editor.style.left = `${Math.max(8, topLeft.x - frameBox.left)}px`;
    editor.style.top = `${Math.max(8, topLeft.y - frameBox.top)}px`;
    editor.style.width = `${Math.max(120, bottomRight.x - topLeft.x)}px`;
    editor.style.height = `${Math.max(48, bottomRight.y - topLeft.y)}px`;
    editor.addEventListener("pointerdown", event => event.stopPropagation());
    editor.addEventListener("keydown", event => {
      if (event.key === "Escape") {
        event.preventDefault();
        closeTextEditor(false);
      } else if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        closeTextEditor(true);
      }
    });
    editor.addEventListener("blur", () => closeTextEditor(true));
    frame.append(editor);
    const overlay = $("#canvas-html-world")?.querySelector(`[data-object-id="${CSS.escape(id)}"]`);
    if (overlay) overlay.hidden = true;
    editor.focus();
    editor.select();
  }

  async function renameCurrentBoard() {
    const current = $("#board-name")?.textContent || "";
    const name = window.prompt(state.lecture.folderId ? "Lecture name" : "Board name", current);
    if (!name || name.trim() === current) return;
    try {
      if (state.lecture.folderId) {
        const payload = await requestJSON(`/api/folders/${encodeURIComponent(state.lecture.folderId)}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name: name.trim() })
        });
        const saved = payload.folder?.name || name.trim();
        state.lecture.folderName = saved;
        $("#board-name").textContent = saved;
        document.title = `${saved} · Digital Whiteboard`;
        toast("Lecture renamed.");
        return;
      }
      const payload = await requestJSON(`/api/boards/${encodeURIComponent(boardId)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim() })
      });
      const saved = payload.board?.name || name.trim();
      $("#board-name").textContent = saved;
      document.title = `${saved} · Digital Whiteboard`;
      toast("Board renamed.");
    } catch (error) {
      toast(error.message || "Could not rename this lecture.", true);
    }
  }

  function studyGuideContent(guide = state.lecture.studyGuide) {
    return String(guide?.content || guide?.answer || "").trim();
  }

  function syncStudyGuideButton() {
    const button = $("#study-guide-button");
    if (!button) return;
    if (studyGuideBusy) {
      button.textContent = "Generating…";
      button.disabled = true;
      return;
    }
    button.disabled = false;
    button.textContent = studyGuideContent() ? "Study Guide" : "Generate Study Guide";
  }

  function setStudyGuideMode(active) {
    const regen = $("#regenerate-study-guide-sheet");
    if (regen) regen.hidden = !active;
  }

  function setStudyProgress(visible, label = "", percent = null) {
    const progress = $("#study-progress");
    const bar = $("#study-progress-bar");
    const caption = $("#study-progress-label");
    if (progress) progress.hidden = !visible;
    if (caption) caption.textContent = label || "Generating study guide…";
    if (progress) progress.classList.toggle("is-determinate", percent != null);
    if (bar && percent != null) {
      const value = Math.max(4, Math.min(100, Number(percent) || 0));
      progress?.style.setProperty("--study-progress", `${value}%`);
      bar.setAttribute("aria-valuenow", String(Math.round(value)));
    } else {
      bar?.removeAttribute("aria-valuenow");
    }
    if (!visible && studyGuideProgressTimer) {
      window.clearInterval(studyGuideProgressTimer);
      studyGuideProgressTimer = 0;
    }
  }

  function startStudyGuideProgress() {
    const steps = [
      "Reading lecture notes…",
      "Organizing concepts…",
      "Writing the study guide…",
      "Formatting math…"
    ];
    let step = 0;
    setStudyProgress(true, steps[0], 12);
    if (studyGuideProgressTimer) window.clearInterval(studyGuideProgressTimer);
    studyGuideProgressTimer = window.setInterval(() => {
      step = Math.min(steps.length - 1, step + 1);
      setStudyProgress(true, steps[step], 18 + step * 22);
    }, 4500);
  }

  function applyStudySheetSize(width, height) {
    const sheet = $("#study-sheet");
    if (!sheet) return;
    const maxWidth = Math.max(280, window.innerWidth - 24);
    const maxHeight = Math.max(220, window.innerHeight - 72);
    const nextWidth = Math.max(280, Math.min(maxWidth, width));
    const nextHeight = Math.max(240, Math.min(maxHeight, height));
    sheet.classList.add("is-resized");
    sheet.style.width = `${Math.round(nextWidth)}px`;
    sheet.style.height = `${Math.round(nextHeight)}px`;
    sheet.style.maxHeight = "calc(100vh - 72px)";
  }

  function persistStudySheetSize() {
    const sheet = $("#study-sheet");
    if (!sheet) return;
    try {
      localStorage.setItem("boardlift-study-sheet-size", JSON.stringify({
        width: Math.round(sheet.getBoundingClientRect().width),
        height: Math.round(sheet.getBoundingClientRect().height)
      }));
    } catch (_) { /* ignore quota / private mode */ }
  }

  function restoreStudySheetSize() {
    try {
      const stored = JSON.parse(localStorage.getItem("boardlift-study-sheet-size") || "null");
      if (stored?.width && stored?.height) applyStudySheetSize(stored.width, stored.height);
    } catch (_) { /* keep default size */ }
  }

  function bindStudySheetResize() {
    const handle = $("#study-sheet-resize");
    const sheet = $("#study-sheet");
    if (!handle || !sheet) return;
    let drag = null;
    handle.addEventListener("pointerdown", event => {
      event.preventDefault();
      event.stopPropagation();
      const rect = sheet.getBoundingClientRect();
      drag = { id: event.pointerId, x: event.clientX, y: event.clientY, width: rect.width, height: rect.height };
      handle.setPointerCapture(event.pointerId);
    });
    handle.addEventListener("pointermove", event => {
      if (!drag || drag.id !== event.pointerId) return;
      event.preventDefault();
      applyStudySheetSize(
        drag.width + (drag.x - event.clientX),
        drag.height + (drag.y - event.clientY)
      );
    });
    const endDrag = event => {
      if (!drag || drag.id !== event.pointerId) return;
      persistStudySheetSize();
      drag = null;
    };
    handle.addEventListener("pointerup", endDrag);
    handle.addEventListener("pointercancel", endDrag);
    restoreStudySheetSize();
  }

  function renderStudyGuidePanel() {
    const panel = $("#study-guide-panel");
    const body = $("#study-guide-body");
    const stale = $("#study-guide-stale");
    if (!panel || !body) return;
    const guide = state.lecture.studyGuide;
    if (!state.lecture.folderId) {
      panel.hidden = true;
      return;
    }
    panel.hidden = false;
    if (stale) stale.hidden = !state.lecture.stale;
    body.replaceChildren();
    const content = studyGuideContent(guide);
    if (!content) {
      const empty = document.createElement("p");
      empty.className = "library-message";
      empty.textContent = "Generate a study guide for this lecture.";
      body.append(empty);
      return;
    }
    renderMarkdownInto(body, content);
  }

  function openStudyGuideSheet() {
    const guide = state.lecture.studyGuide;
    const content = studyGuideContent(guide);
    $("#study-kicker").textContent = "Lecture study guide";
    setStudyHeading(guide?.title || "Study guide");
    showStudyActions(false);
    setStudyGuideMode(Boolean(content));
    const body = $("#study-body");
    if (body) {
      if (content) renderMarkdownInto(body, content);
      else body.replaceChildren();
    }
    setStudyStatus(state.lecture.stale ? "Study guide may be outdated" : "");
    setStudyProgress(false);
    openStudySheet();
  }

  function onStudyGuideButton() {
    if (studyGuideBusy) return;
    if (studyGuideContent()) {
      openStudyGuideSheet();
      return;
    }
    generateStudyGuide();
  }

  async function generateStudyGuide() {
    if (!state.lecture.folderId) {
      toast("Open or create a lecture folder first.", true);
      return;
    }
    if (studyGuideBusy) return;
    studyGuideBusy = true;
    syncStudyGuideButton();
    $("#study-kicker").textContent = "Lecture study guide";
    setStudyHeading(state.lecture.studyGuide?.title || "Study guide");
    showStudyActions(false);
    setStudyGuideMode(false);
    const body = $("#study-body");
    if (body) body.replaceChildren();
    setStudyStatus("");
    startStudyGuideProgress();
    openStudySheet();
    try {
      const payload = await requestStudy(
        `/api/folders/${encodeURIComponent(state.lecture.folderId)}/study-guide`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }
      );
      state.lecture.studyGuide = payload.study_guide || payload.studyGuide;
      state.lecture.stale = Boolean(payload.study_guide_stale);
      renderStudyGuidePanel();
      setStudyProgress(true, "Finishing…", 96);
      openStudyGuideSheet();
    } catch (error) {
      setStudyProgress(false);
      setStudyStatus(error.message || "Couldn't generate a study guide right now.", true);
      openStudySheet();
    } finally {
      studyGuideBusy = false;
      syncStudyGuideButton();
    }
  }

  function viewBoard(boardIdToView) {
    const board = lectureBoardsFromData().find(item => item.boardId === boardIdToView)
      || state.sourceBoards.find(item => item.boardId === boardIdToView);
    if (!board) return;
    const rect = sceneRect();
    const aspect = sceneAspect(rect);
    const pad = Math.max(board.width, board.height) * 0.08;
    let width = board.width + pad * 2;
    let height = width / aspect;
    if (height < board.height + pad * 2) {
      height = board.height + pad * 2;
      width = height * aspect;
    }
    state.camera = {
      x: board.x + board.width / 2 - width / 2,
      y: board.y + board.height / 2 - height / 2,
      width,
      height
    };
    applyCamera();
  }

  async function startImportWhiteboard() {
    try {
      if (!state.lecture.folderId) {
        const created = await requestJSON(`/api/boards/${encodeURIComponent(boardId)}/lecture/ensure-folder`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}"
        });
        state.lecture.folderId = created.folder?.id || "";
        state.lecture.folderName = created.folder?.name || state.lecture.folderName;
        state.lecture.workspaceId = created.workspace_board_id || boardId;
        state.lecture.isLecture = true;
        applyLectureData({
          ...state.data,
          folder_id: state.lecture.folderId,
          folder_name: state.lecture.folderName,
          workspace_board_id: state.lecture.workspaceId,
          is_lecture: true
        });
      }
    } catch (error) {
      toast(error.message || "Could not create a lecture workspace.", true);
      return;
    }
    const folderField = $("#import-folder-id");
    const workspaceField = $("#import-workspace-id");
    if (folderField) folderField.value = state.lecture.folderId || "";
    if (workspaceField) workspaceField.value = state.lecture.workspaceId || boardId;
    const camera = $("#import-camera");
    const picker = $("#import-image");
    if (window.matchMedia?.("(pointer: coarse)").matches && camera) camera.click();
    else picker?.click();
  }

  function bindImport() {
    const form = $("#import-form");
    const picker = $("#import-image");
    const camera = $("#import-camera");
    const submitFile = input => {
      if (!input?.files?.[0]) return;
      picker.name = input === picker ? "image" : "";
      if (camera) camera.name = input === camera ? "image" : "";
      toast("Processing whiteboard…");
      form?.submit();
    };
    picker?.addEventListener("change", () => submitFile(picker));
    camera?.addEventListener("change", () => submitFile(camera));
    $("#import-whiteboard")?.addEventListener("click", startImportWhiteboard);
  }

  function bindStudy() {
    $("#explain-button")?.addEventListener("click", () => explainSelection("explain"));
    $("#explain-across-button")?.addEventListener("click", () => explainSelection("explain_across_boards"));
    $("#where-from-button")?.addEventListener("click", () => explainSelection("where_from"));
    $("#check-work-button")?.addEventListener("click", () => explainSelection("check_my_work"));
    $("#study-guide-button")?.addEventListener("click", onStudyGuideButton);
    $("#regenerate-study-guide")?.addEventListener("click", generateStudyGuide);
    $("#regenerate-study-guide-sheet")?.addEventListener("click", generateStudyGuide);
    bindStudySheetResize();
    $("#view-new-board")?.addEventListener("click", () => {
      if (state.pendingImportedId) viewBoard(state.pendingImportedId);
      const chip = $("#view-new-board");
      if (chip) chip.hidden = true;
    });
    $("#close-study")?.addEventListener("click", closeStudySheet);
    $("#study-followup")?.addEventListener("submit", sendFollowUp);
    $("#study-actions")?.addEventListener("click", event => {
      const action = event.target?.closest?.("[data-study-action]")?.dataset?.studyAction;
      if (!action) return;
      sendStudyAction({ action });
    });
    $("#study-notes-button")?.addEventListener("click", () => {
      const drawer = $("#study-drawer");
      const opening = drawer.hidden;
      drawer.hidden = !drawer.hidden;
      if (!drawer.hidden) {
        closeStudySheet();
        hidePencilUiForStudy();
        renderStudyGuidePanel();
        renderStudyList();
      } else {
        restorePencilUiAfterStudy();
      }
      resetGestureState(opening ? "study-drawer-open" : "study-drawer-close");
      if (!opening) blurStudyUi();
    });
    $("#close-study-drawer")?.addEventListener("click", () => {
      $("#study-drawer").hidden = true;
      blurStudyUi();
      restorePencilUiAfterStudy();
      resetGestureState("study-drawer-close");
    });
    $("#rename-board")?.addEventListener("click", renameCurrentBoard);
  }

  function bindPencilPalette() {
    if (!Pencil) return;
    const host = paletteHost();
    const chip = toolChipHost();
    Pencil.buildPalette(host);
    Pencil.buildToolChip(chip);
    state.pencilAdapter = new Pencil.PencilInteractionAdapter();
    state.pencilCapabilities = state.pencilAdapter.capabilities;
    state.pencilAdapter.bindHost({
      openPalette: position => openPencilPalette(position),
      closePalette: () => closePencilPalette()
    });
    state.pencilAdapter.onSqueeze(detail => {
      const position = detail?.position || lastPaletteAnchor();
      const action = state.pencilAdapter.getPreferredAction();
      if (action === "switchPreviousTool") {
        setTool(state.lastTool || "select");
        return;
      }
      openPencilPalette(position);
    });
    state.pencilAdapter.onDoubleTap(() => {
      setTool(state.lastTool || "select");
    });
    window.addEventListener("message", event => {
      const data = event.data;
      if (!data || data.channel !== "pencil-native-bridge") return;
      state.pencilAdapter.ingestNativeEvent(data.kind, data.detail || {});
    });
    globalThis.PencilNative = {
      capabilities: () => state.pencilCapabilities,
      ingest: (kind, detail) => state.pencilAdapter?.ingestNativeEvent(kind, detail)
    };
    const stopPaletteLeak = event => {
      event.stopPropagation();
    };
    host?.addEventListener("pointerdown", stopPaletteLeak);
    host?.addEventListener("pointermove", stopPaletteLeak);
    host?.addEventListener("pointerup", stopPaletteLeak);
    host?.addEventListener("touchstart", stopPaletteLeak);
    chip?.addEventListener("pointerdown", stopPaletteLeak);
    if (host) host.inert = true;
    host?.addEventListener("click", event => {
      const toolButton = event.target.closest?.("[data-tool]");
      if (toolButton) {
        setTool(toolButton.dataset.tool);
        return;
      }
      const colorButton = event.target.closest?.("[data-color]");
      if (colorButton) {
        setInkColor(colorButton.dataset.color, { applySelection: true });
        return;
      }
      const widthButton = event.target.closest?.("[data-width-preset]");
      if (widthButton) {
        const presets = Pencil.WIDTH_PRESETS[canonicalTool()];
        const width = presets?.[widthButton.dataset.widthPreset];
        if (width) setInkWidth(width);
        return;
      }
      const history = event.target.closest?.("[data-history]");
      if (history?.dataset.history === "undo") undo();
      if (history?.dataset.history === "redo") redo();
    });
    host?.querySelector("#palette-custom-color")?.addEventListener("input", event => {
      setInkColor(event.target.value);
    });
    host?.querySelector("#palette-custom-color")?.addEventListener("change", event => {
      setInkColor(event.target.value, { applySelection: true });
    });
    host?.querySelector("#palette-width-slider")?.addEventListener("input", event => {
      setInkWidth(event.target.value);
    });
    host?.querySelector("#palette-opacity-slider")?.addEventListener("input", event => {
      setInkOpacity(event.target.value);
    });
    chip?.addEventListener("click", () => openPencilPalette(lastPaletteAnchor()));
    $("#pencil-palette-button")?.addEventListener("click", () => {
      togglePencilPalette(lastPaletteAnchor());
    });
    $("#focus-mode-button")?.addEventListener("click", () => {
      setToolbarVisible(!state.toolbarVisible);
    });
    document.addEventListener("pointerdown", event => {
      if (state.paletteMode !== "temporary") return;
      if (event.target?.closest?.("#pencil-palette, #pencil-palette-button, #pencil-tool-chip")) return;
      closePencilPalette();
    }, true);
    window.addEventListener("resize", () => {
      if (state.paletteMode !== "closed") positionPencilPalette();
    });
    window.visualViewport?.addEventListener("resize", () => {
      if (state.paletteMode !== "closed") positionPencilPalette();
    });
    syncPencilPalette();
  }

  function bindChromeMenu() {
    const button = $("#chrome-menu-button");
    const menu = $("#chrome-menu");
    if (!button || !menu) return;
    const close = () => {
      menu.hidden = true;
      button.setAttribute("aria-expanded", "false");
    };
    button.addEventListener("click", () => {
      const opening = menu.hidden;
      menu.hidden = !opening;
      button.setAttribute("aria-expanded", String(opening));
    });
    document.addEventListener("pointerdown", event => {
      if (menu.hidden) return;
      if (event.target?.closest?.("#chrome-menu, #chrome-menu-button")) return;
      close();
    });
    $("#menu-import")?.addEventListener("click", () => {
      close();
      $("#import-whiteboard")?.click();
    });
    $("#menu-study-guide")?.addEventListener("click", () => {
      close();
      $("#study-guide-button")?.click();
    });
    $("#menu-export")?.addEventListener("click", () => {
      close();
      $("#export-button")?.click();
    });
    $("#menu-gestures")?.addEventListener("click", () => {
      close();
      $("#gestures-help-button")?.click();
    });
    $("#auto-hide-toolbar")?.addEventListener("change", event => {
      state.autoHideToolbar = Boolean(event.target.checked);
      persistPencilPrefs();
      if (state.autoHideToolbar) noteToolbarIdle();
    });
  }

  function bindEditor() {
    $$(".tool-button").forEach(button =>
      button.addEventListener("click", () => setTool(button.dataset.tool)));
    $$(".color-chip").forEach(button => button.addEventListener("click", () => {
      setInkColor(button.dataset.color, { applySelection: true });
    }));
    $("#custom-color")?.addEventListener("input", event => {
      setInkColor(event.target.value);
    });
    $("#custom-color")?.addEventListener("change", event => {
      setInkColor(event.target.value, { applySelection: true });
    });
    $("#stroke-size")?.addEventListener("input", event => {
      setInkWidth(event.target.value);
    });
    $("#text-size")?.addEventListener("pointerdown", () => {
      $("#text-size").dataset.history = "1";
      $("#text-size")._before = snapshot();
    });
    $("#text-size")?.addEventListener("input", event => {
      if (inkIsActive()) return;
      if (!$("#text-size")._before) $("#text-size")._before = snapshot();
      const next = clamp(Number(event.target.value), 8, 240);
      selectedTextObjects().forEach(object => {
        object.fontSize = next;
        fitTextObject(object);
      });
      renderScene();
    });
    $("#text-size")?.addEventListener("change", () => {
      const before = $("#text-size")?._before;
      if (before) commitLogicalAction(before);
      if ($("#text-size")) $("#text-size")._before = null;
    });
    $("#master-layer-toggle")?.addEventListener("change", event => {
      $("#master-layer").style.display = event.target.checked ? "" : "none";
    });
    $("#professor-layer-toggle")?.addEventListener("change", event => {
      $("#imported-layer").style.display = event.target.checked ? "" : "none";
    });
    $("#user-layer-toggle")?.addEventListener("change", event => {
      $("#user-layer").style.display = event.target.checked ? "" : "none";
      $("#interaction-layer").style.display = event.target.checked ? "" : "none";
      const overlay = $("#canvas-html-overlay");
      if (overlay) overlay.style.display = event.target.checked ? "" : "none";
    });
    $("#undo-button")?.addEventListener("click", undo);
    $("#redo-button")?.addEventListener("click", redo);
    $("#group-button")?.addEventListener("click", groupSelection);
    $("#ungroup-button")?.addEventListener("click", ungroupSelection);
    $("#save-button")?.addEventListener("click", () => saveEditor(true));
    $("#header-save-button")?.addEventListener("click", () => saveEditor(true));
    $("#clear-button")?.addEventListener("click", () => {
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
      markChanged();
    });
    $("#zoom-out").addEventListener("click", () => {
      const rect = $("#world-scene").getBoundingClientRect();
      zoomAt(.8, rect.left + rect.width / 2, rect.top + rect.height / 2);
      markChanged();
    });
    $("#home-button")?.addEventListener("click", resetView);
    $("#toolbar-study-notes")?.addEventListener("click", () => $("#study-notes-button")?.click());
    $("#toolbar-new-board")?.addEventListener("click", () => $("#import-whiteboard")?.click());
    bindPencilPalette();
    bindChromeMenu();
    bindGesturesHelp();
    $(".drawing-toolbar")?.addEventListener("pointerdown", () => {
      clearTimeout(noteToolbarIdle.timer);
    });
    if (typeof ResizeObserver === "function") {
      const observer = new ResizeObserver(() => syncCameraAspect());
      observer.observe($("#world-scene"));
    }
    window.addEventListener("resize", syncCameraAspect);
    $("#export-button").addEventListener("click", () => exportBoard("svg"));
    $("#export-png")?.addEventListener("click", () => exportBoard("png"));
    const svg = $("#world-scene");
    svg.style.touchAction = "none";
    svg.addEventListener("pointerdown", pointerDown, { passive: false });
    svg.addEventListener("dblclick", event => {
      if (state.tool !== "select") return;
      const hit = hitObject(event);
      const object = hit ? findObject(hit) : null;
      if (object?.type === "text") {
        event.preventDefault();
        editTextObject(object.id);
      }
    });
    window.addEventListener("pointermove", pointerMove, { passive: false, capture: true });
    window.addEventListener("pointerup", pointerUp, { passive: false, capture: true });
    window.addEventListener("pointercancel", pointerCancel, { passive: false, capture: true });
    window.addEventListener("pointerrawupdate", pointerRawUpdate, { passive: true, capture: true });
    svg.addEventListener("pointerrawupdate", pointerRawUpdate, { passive: true });
    svg.addEventListener("touchstart", event => {
      event.preventDefault();
    }, { passive: false });
    svg.addEventListener("touchmove", event => {
      event.preventDefault();
    }, { passive: false });
    const clearTouches = event => {
      if (event.touches && event.touches.length > 0) return;
      forgetTouchPointers();
      if (state.interaction && ["pan", "pinch"].includes(state.interaction.kind)) {
        endCameraGesture("touch-empty");
      }
    };
    window.addEventListener("touchend", clearTouches, { capture: true });
    window.addEventListener("touchcancel", clearTouches, { capture: true });
    svg.addEventListener("pointerleave", pointerLeave);
    svg.addEventListener("lostpointercapture", lostPointerCapture);
    svg.addEventListener("gotpointercapture", event => {
      editorLog("POINTER CAPTURE", { action: "got", pointerId: event.pointerId, type: event.pointerType });
    });
    svg.addEventListener("gesturestart", event => event.preventDefault());
    svg.addEventListener("gesturechange", event => event.preventDefault());
    svg.addEventListener("wheel", event => {
      event.preventDefault();
      zoomAt(Math.exp(-event.deltaY * .0015), event.clientX, event.clientY);
      markChanged();
    }, { passive: false });
    window.addEventListener("keydown", handleKeyDown, { capture: true });
    window.addEventListener("keyup", event => {
      if (event.code === "Space") state.spaceDown = false;
    });
    window.addEventListener("pagehide", unloadSave);
    bindStudy();
    bindImport();
  }

  function bindGesturesHelp() {
    const dialog = $("#gestures-help");
    const button = $("#gestures-help-button");
    if (!dialog || !button) return;
    button.addEventListener("click", () => {
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
      button.setAttribute("aria-expanded", "true");
    });
    dialog.addEventListener("close", () => button.setAttribute("aria-expanded", "false"));
  }

  function initPerfOverlay() {
    if (!DEBUG_PERF || !Engine.PerfMonitor) return;
    state.perf = new Engine.PerfMonitor();
    state.perf.enable(true);
    globalThis.__boardPerf = {
      snapshot: () => state.perf.snapshot(),
      measure: options => Engine.measureTransformLoop(options),
      reset: () => state.perf.resetWorst(),
      stats: () => ({
        imported: state.importedObjects.length,
        user: state.objects.length,
        commands: state.commandTotal,
        visible: state.visibleCount,
        culled: state.culledCount
      })
    };
  }

  function mountStressScene() {
    const params = new URLSearchParams(location.search);
    const count = Number(params.get("stress") || 0);
    if (!count) return;
    const layer = $("#imported-layer");
    if (!layer) return;
    const objects = [];
    for (let index = 0; index < count; index++) {
      const x = 40 + (index * 47) % Math.max(200, state.width - 80);
      const y = 40 + (index * 31) % Math.max(200, state.height - 80);
      const d = `M ${x} ${y} c 12 0 18 16 32 2 c 14 -12 28 6 40 -2 c 10 -6 22 10 28 0`;
      const id = `stress-${String(index).padStart(4, "0")}`;
      const wrapper = svgEl("g", {
        class: "imported-object",
        "data-object-id": id,
        transform: "translate(0 0)"
      });
      const path = svgEl("path", {
        id, d, fill: index % 2 ? "#183153" : "#2563eb",
        "data-object-id": id
      });
      wrapper.append(path);
      layer.append(wrapper);
      objects.push({
        id, type: "imported",
        bbox: { x, y, width: 100, height: 36 },
        color: path.getAttribute("fill"),
        color_class: "",
        tx: 0, ty: 0, sx: 1, sy: 1, deleted: false,
        node: wrapper, path,
        sourceD: d, sourceRevision: 1,
        commandCount: 3, displayLevel: LOD.FULL,
        boardId, originX: 0, originY: 0,
        map: { x: 0, y: 0, scaleX: 1, scaleY: 1 }
      });
    }
    state.importedObjects = state.importedObjects.concat(objects);
    state.commandTotal += objects.length * 3;
    rebuildSpatialIndex();
    buildImportedDisplay();
    prepareDerivedGeometry();
    editorLog("STRESS SCENE", { count });
  }

  function escapeXML(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function exportObject(object) {
    if (object.type === "path") {
      const transform = (object.tx || object.ty || (object.sx || 1) !== 1 || (object.sy || 1) !== 1)
        ? ` transform="${objectTransformValue(object.tx, object.ty, object.sx, object.sy)}"` : "";
      return `<path id="${escapeXML(object.id)}" d="${escapeXML(object.d || object.sourceD || "")}" fill="${escapeXML(object.fill || object.color)}" fill-opacity="${Number(object.opacity ?? 1)}"${transform}/>`;
    }
    if (object.type === "text") {
      const wrapped = wrapPlainLines(object.text, object.fontSize, intendedWrapWidth(object));
      const tspans = wrapped.lines.map((line, index) =>
        `<tspan x="${object.x + 5}" dy="${index ? object.fontSize * 1.2 : 0}">${escapeXML(line)}</tspan>`
      ).join("");
      return `<text id="${escapeXML(object.id)}" x="${object.x + 5}" y="${object.y + object.fontSize}" fill="${escapeXML(object.color)}" font-size="${object.fontSize}" font-family="system-ui, sans-serif">${tspans}</text>`;
    }
    const id = `export-mask-${object.id.replace(/[^a-zA-Z0-9_-]/g, "")}`;
    const erasures = object.erasures || [];
    const mask = erasures.length ? `<mask id="${id}" maskUnits="userSpaceOnUse" x="${-state.width}" y="${-state.height}" width="${state.width * 3}" height="${state.height * 3}"><rect x="${-state.width}" y="${-state.height}" width="${state.width * 3}" height="${state.height * 3}" fill="white"/>${erasures.map(erasure => `<path d="${escapeXML(erasure.d || pathFromPoints(erasure.points))}" fill="none" stroke="black" stroke-width="${Number(erasure.width)}" stroke-linecap="round" stroke-linejoin="round"/>`).join("")}</mask>` : "";
    const transform = (object.tx || object.ty || (object.sx || 1) !== 1 || (object.sy || 1) !== 1)
      ? ` transform="${objectTransformValue(object.tx, object.ty, object.sx, object.sy)}"` : "";
    const path = `<path d="${escapeXML(strokePath(object))}" fill="none" stroke="${escapeXML(object.color)}" stroke-width="${Number(object.width)}" stroke-opacity="${Number(object.opacity)}" stroke-linecap="round" stroke-linejoin="round"${transform}${erasures.length ? ` mask="url(#${id})"` : ""}/>`;
    return `${mask}${path}`;
  }

  function exportNode(id) {
    const group = state.groups.find(item => item.id === id);
    if (group) {
      const transform = group.transform || {};
      return `<g id="${escapeXML(group.id)}" transform="translate(${Number(transform.x) || 0} ${Number(transform.y) || 0}) scale(${Number(transform.scaleX) || 1} ${Number(transform.scaleY) || 1}) rotate(${Number(transform.rotation) || 0})">${group.children.map(exportNode).join("")}</g>`;
    }
    const object = state.objects.find(item => item.id === id);
    return object ? exportObject(object) : "";
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

  function exportImported() {
    return state.importedObjects.map(object => {
      if (object.deleted) return "";
      const path = object.path;
      if (!path) return "";
      const clone = path.cloneNode(true);
      clone.removeAttribute("style");
      clone.removeAttribute("data-object-id");
      const source = object.sourceD || path.dataset.sourceD;
      if (source) clone.setAttribute("d", source);
      return `<g id="${escapeXML(object.id)}-object" transform="${objectTransformValue(object.tx, object.ty, object.sx, object.sy)}">${clone.outerHTML}</g>`;
    }).join("");
  }

  function exportBounds(scope) {
    const board = { x: 0, y: 0, width: state.width, height: state.height };
    const items = [...state.objects, ...state.importedObjects.filter(item => !item.deleted && !isBoardFillingObject(item))];
    if (!items.length) return board;
    const content = unionBounds(items);
    if (scope === "content") return content;
    const left = Math.min(board.x, content.x);
    const top = Math.min(board.y, content.y);
    const right = Math.max(board.x + board.width, content.x + content.width);
    const bottom = Math.max(board.y + board.height, content.y + content.height);
    return { x: left, y: top, width: right - left, height: bottom - top };
  }

  async function buildExportSVG() {
    const scope = $("#export-scope")?.value || "content";
    const bounds = exportBounds(scope);
    const imported = exportImported();
    const nested = new Set(state.groups.flatMap(group => group.children));
    const objects = state.objects.filter(object => !nested.has(object.id)).map(object => exportNode(object.id)).join("") +
      state.groups.filter(group => !nested.has(group.id)).map(group => exportNode(group.id)).join("");
    return `<svg xmlns="${NS}" viewBox="${bounds.x} ${bounds.y} ${bounds.width} ${bounds.height}" width="${Math.ceil(bounds.width)}" height="${Math.ceil(bounds.height)}"><rect x="${bounds.x}" y="${bounds.y}" width="${bounds.width}" height="${bounds.height}" fill="#f7f6f2"/><g id="imported-vectors">${imported}</g><g id="user-objects">${objects}</g></svg>`;
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

  function applyLoadedPencilPrefs() {
    if (!Pencil) return;
    const prefs = Pencil.loadPrefs();
    state.toolConfig = prefs;
    state.toolbarVisible = prefs.toolbarVisible;
    state.autoHideToolbar = prefs.autoHideToolbar;
    syncToolMirrors();
  }

  async function initEditor() {
    applyLoadedPencilPrefs();
    $("#corner-workspace").hidden = true;
    $("#editor-workspace").hidden = false;
    applyLectureData(state.data);
    const title = state.lecture.folderName || state.data.title || state.data.name || `Board ${boardId || ""}`.trim();
    $("#board-name").textContent = title;
    document.title = `${title} · Digital Whiteboard`;
    state.masterUrl = findAsset("enhanced") || findAsset("corrected");
    const paper = $("#board-paper");
    const edge = $("#board-paper-edge");
    if (paper) {
      paper.setAttribute("width", state.width);
      paper.setAttribute("height", state.height);
    }
    if (edge) {
      edge.setAttribute("width", state.width);
      edge.setAttribute("height", state.height);
      edge.setAttribute("stroke-width", Math.max(1, state.width / 900));
    }
    const bounds = $("#board-bounds");
    if (bounds) {
      bounds.setAttribute("width", state.width);
      bounds.setAttribute("height", state.height);
      bounds.setAttribute("stroke-width", Math.max(1, state.width / 900));
    }
    const master = $("#master-image");
    if (master) {
      master.removeAttribute("href");
      master.setAttribute("width", state.width);
      master.setAttribute("height", state.height);
    }
    if ($("#master-layer")) $("#master-layer").setAttribute("hidden", "");
    if ($("#canvas-empty")) $("#canvas-empty").hidden = true;
    if ($("#pen-debug")) $("#pen-debug").hidden = !DEBUG_EDITOR;
    const caption = $("#canvas-dimensions");
    if (caption) caption.textContent = "Study canvas";
    $("#world-scene").setAttribute("preserveAspectRatio", "none");
    refreshSceneRect();
    syncViewportBox();
    bindEditor();
    initPerfOverlay();
    await loadEditor();
    state.objects.forEach(object => {
      if (object.type === "text") fitTextObject(object);
    });
    await loadImportedSVG();
    mountStressScene();
    await loadStudyInteractions();
    renderStudyGuidePanel();
    ensureBoardContext();
    state.selected.clear();
    syncCameraAspect();
    const viewPreset = new URLSearchParams(location.search).get("view");
    if (viewPreset === "out") {
      state.camera = cameraWithAspect({
        ...state.camera,
        width: state.camera.width / 0.42,
        height: state.camera.height / 0.42
      });
    } else if (viewPreset === "in") {
      const cx = state.camera.x + state.camera.width * 0.35;
      const cy = state.camera.y + state.camera.height * 0.38;
      const width = state.camera.width / 2.4;
      const height = state.camera.height / 2.4;
      state.camera = cameraWithAspect({
        x: cx - width * 0.35, y: cy - height * 0.38, width, height
      });
    } else if (viewPreset === "extreme") {
      const cx = state.camera.x + state.camera.width * 0.4;
      const cy = state.camera.y + state.camera.height * 0.4;
      const width = state.camera.width / 12;
      const height = state.camera.height / 12;
      state.camera = cameraWithAspect({
        x: cx - width * 0.4, y: cy - height * 0.4, width, height
      });
    }
    applyCamera();
    renderScene();
    refreshSceneRect();
    const imported = new URLSearchParams(location.search).get("imported");
    if (imported) {
      state.pendingImportedId = imported;
      const chip = $("#view-new-board");
      if (chip) chip.hidden = false;
    }
    if (new URLSearchParams(location.search).get("studyGuide") === "1" && studyGuideContent()) {
      openStudyGuideSheet();
    }
    applyPencilChrome();
    setTool(state.toolConfig?.tool || "pen");
    updatePenHud();
    if (state.pencilCapabilities) {
      editorLog("PENCIL CAPABILITIES", state.pencilCapabilities);
    }
    setSaveStatus(state.dirty ? "Unsaved changes" : "Saved");
    editorLog("EDITOR READY", {
      imported: state.importedObjects.length,
      user: state.objects.length,
      selected: [...state.selected]
    });
    if (new URLSearchParams(location.search).get("bench") === "1") {
      requestAnimationFrame(() => setTimeout(() => runCameraBench(), 400));
    }
  }

  async function runCameraBench(frames = 90) {
    const start = { ...state.camera };
    const samples = [];
    let last = nowMs();
    let index = 0;
    await new Promise(resolve => {
      const tick = () => {
        const t = nowMs();
        samples.push(t - last);
        last = t;
        state.camera.x = start.x + Math.sin(index / 7) * 120;
        state.camera.y = start.y + Math.cos(index / 9) * 80;
        applyCamera({ hud: false, overlays: false });
        index += 1;
        if (index >= frames) resolve();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    Object.assign(state.camera, start);
    applyCamera({ hud: true, overlays: true });
    const sorted = samples.slice(1).sort((a, b) => a - b);
    const avg = sorted.reduce((a, b) => a + b, 0) / Math.max(1, sorted.length);
    const result = {
      frames: sorted.length,
      avgMs: avg,
      fps: 1000 / avg,
      p95Ms: sorted[Math.floor(sorted.length * 0.95)] || avg,
      worstMs: sorted[sorted.length - 1] || avg,
      imported: state.importedObjects.length,
      user: state.objects.length,
      commands: state.commandTotal
    };
    console.info("[bench] camera", result);
    const node = document.createElement("pre");
    node.id = "bench-result";
    node.textContent = JSON.stringify(result);
    node.hidden = true;
    document.body.append(node);
    document.title = `bench ${Math.round(result.fps)}fps ${result.imported}obj`;
    return result;
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
