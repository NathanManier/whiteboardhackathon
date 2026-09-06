(() => {
  "use strict";

  /* Visual levels describe geometric density, never presence.
     FULL: source commands
     PERCEPTUAL: < ~1 screen pixel of change, topology kept
     LIGHT: < ~2 screen pixels of change, topology kept
     INTERACTION / NAVIGATION are aliases so older callers cannot request blobs. */
  const LEVEL = {
    FULL: "full",
    PERCEPTUAL: "perceptual",
    LIGHT: "light",
    INTERACTION: "perceptual",
    NAVIGATION: "light"
  };

  const MIN_ZOOM = 0.04;
  const MAX_ZOOM = 64;
  const MAX_TRANSLATE = 1e6;

  function now() {
    return performance.now();
  }

  function parsePathCommands(d) {
    if (!d) return [];
    const source = String(d);
    const commands = [];
    const re = /([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)/g;
    let match;
    while ((match = re.exec(source))) {
      const letter = match[1];
      const nums = match[2].trim()
        ? match[2].trim().split(/[\s,]+/).map(Number).filter(Number.isFinite)
        : [];
      commands.push({ letter, nums });
    }
    return commands;
  }

  function commandCount(d) {
    if (!d) return 0;
    const found = String(d).match(/[MmLlHhVvCcSsQqTtAaZz]/g);
    return found ? found.length : 0;
  }

  function subpathCount(d) {
    if (!d) return 0;
    const found = String(d).match(/[Mm]/g);
    return found ? found.length : 0;
  }

  function splitSubpathCommands(commands) {
    const subpaths = [];
    let current = [];
    commands.forEach(command => {
      const type = command.letter.toUpperCase();
      if (type === "M" && current.length) {
        subpaths.push(current);
        current = [command];
        return;
      }
      current.push(command);
    });
    if (current.length) subpaths.push(current);
    return subpaths;
  }

  function flattenCommands(commands) {
    const paths = [];
    let current = [];
    let x = 0;
    let y = 0;
    let startX = 0;
    let startY = 0;
    const pushPoint = (px, py, kind) => {
      current.push({ x: px, y: py, kind });
      x = px;
      y = py;
    };
    commands.forEach(command => {
      const letter = command.letter;
      const nums = command.nums;
      const abs = letter === letter.toUpperCase();
      const type = letter.toUpperCase();
      if (type === "Z") {
        if (current.length) {
          current.push({ x: startX, y: startY, kind: "Z" });
          paths.push(current);
          current = [];
        }
        x = startX;
        y = startY;
        return;
      }
      if (type === "M") {
        if (current.length) paths.push(current);
        current = [];
        for (let i = 0; i + 1 < nums.length; i += 2) {
          const nx = abs ? nums[i] : x + nums[i];
          const ny = abs ? nums[i + 1] : y + nums[i + 1];
          if (i === 0) {
            startX = nx;
            startY = ny;
            pushPoint(nx, ny, "M");
          } else pushPoint(nx, ny, "L");
        }
        return;
      }
      if (type === "L") {
        for (let i = 0; i + 1 < nums.length; i += 2) {
          pushPoint(abs ? nums[i] : x + nums[i], abs ? nums[i + 1] : y + nums[i + 1], "L");
        }
        return;
      }
      if (type === "H") {
        nums.forEach(value => pushPoint(abs ? value : x + value, y, "L"));
        return;
      }
      if (type === "V") {
        nums.forEach(value => pushPoint(x, abs ? value : y + value, "L"));
        return;
      }
      if (type === "C") {
        for (let i = 0; i + 5 < nums.length; i += 6) {
          const x1 = abs ? nums[i] : x + nums[i];
          const y1 = abs ? nums[i + 1] : y + nums[i + 1];
          const x2 = abs ? nums[i + 2] : x + nums[i + 2];
          const y2 = abs ? nums[i + 3] : y + nums[i + 3];
          const nx = abs ? nums[i + 4] : x + nums[i + 4];
          const ny = abs ? nums[i + 5] : y + nums[i + 5];
          current.push({ x: x1, y: y1, kind: "C1" });
          current.push({ x: x2, y: y2, kind: "C2" });
          pushPoint(nx, ny, "C");
        }
        return;
      }
      if (type === "Q") {
        for (let i = 0; i + 3 < nums.length; i += 4) {
          const x1 = abs ? nums[i] : x + nums[i];
          const y1 = abs ? nums[i + 1] : y + nums[i + 1];
          const nx = abs ? nums[i + 2] : x + nums[i + 2];
          const ny = abs ? nums[i + 3] : y + nums[i + 3];
          current.push({ x: x1, y: y1, kind: "Q1" });
          pushPoint(nx, ny, "Q");
        }
        return;
      }
      if (type === "S" || type === "T" || type === "A") {
        const step = type === "A" ? 7 : type === "S" ? 4 : 2;
        for (let i = 0; i + step - 1 < nums.length; i += step) {
          const nx = abs ? nums[i + step - 2] : x + nums[i + step - 2];
          const ny = abs ? nums[i + step - 1] : y + nums[i + step - 1];
          pushPoint(nx, ny, type);
        }
      }
    });
    if (current.length) paths.push(current);
    return paths;
  }

  function perpendicularDistance(point, start, end) {
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const length = Math.hypot(dx, dy);
    if (length < 1e-9) return Math.hypot(point.x - start.x, point.y - start.y);
    return Math.abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x) / length;
  }

  function rdp(points, epsilon) {
    if (points.length < 3) return points.slice();
    let maxDist = 0;
    let index = 0;
    const end = points.length - 1;
    for (let i = 1; i < end; i++) {
      const dist = perpendicularDistance(points[i], points[0], points[end]);
      if (dist > maxDist) {
        index = i;
        maxDist = dist;
      }
    }
    if (maxDist > epsilon) {
      const left = rdp(points.slice(0, index + 1), epsilon);
      const right = rdp(points.slice(index), epsilon);
      return left.slice(0, -1).concat(right);
    }
    return [points[0], points[end]];
  }

  function rdpPreserveTopology(points, epsilon, closed) {
    if (points.length <= 3) return points.slice();
    let result = rdp(points, Math.max(epsilon, 1e-4));
    const minKeep = closed
      ? Math.max(4, Math.min(12, Math.ceil(points.length * 0.08)))
      : 2;
    if (result.length >= minKeep) return result;
    for (let scale = 0.5; scale >= 0.04 && result.length < minKeep; scale *= 0.5) {
      result = rdp(points, Math.max(epsilon * scale, 1e-4));
    }
    if (result.length < minKeep) {
      const step = Math.max(1, Math.floor(points.length / minKeep));
      result = points.filter((_, index) => index % step === 0 || index === points.length - 1);
    }
    return result;
  }

  function formatNumber(value, digits) {
    const factor = 10 ** digits;
    const rounded = Math.round(value * factor) / factor;
    return String(rounded);
  }

  function serializeSubpath(points, digits) {
    if (!points.length) return "";
    let d = `M ${formatNumber(points[0].x, digits)} ${formatNumber(points[0].y, digits)}`;
    for (let i = 1; i < points.length; i++) {
      const point = points[i];
      if (point.kind === "Z") {
        d += " Z";
        continue;
      }
      d += ` L ${formatNumber(point.x, digits)} ${formatNumber(point.y, digits)}`;
    }
    return d;
  }

  function serializeCommands(commands, digits) {
    return commands.map(command => {
      if (!command.nums.length) return command.letter;
      const nums = command.nums.map(value => formatNumber(value, digits)).join(" ");
      return `${command.letter} ${nums}`;
    }).join(" ");
  }

  function subpathHasCurves(commands) {
    return commands.some(command => /[CcSsQqTtAa]/.test(command.letter));
  }

  function simplifyLineSubpath(commands, epsilon, digits) {
    const points = flattenCommands(commands)[0] || [];
    if (!points.length) return serializeCommands(commands, digits);
    const closed = points.length > 1 && points[points.length - 1].kind === "Z";
    const body = closed ? points.slice(0, -1) : points;
    if (body.length <= 3) return serializeCommands(commands, digits);
    const simplified = rdpPreserveTopology(body, epsilon, closed);
    if (closed && simplified.length) simplified.push({ ...simplified[0], kind: "Z" });
    return serializeSubpath(simplified, digits);
  }

  function simplifyPath(d, epsilon, digits = 3) {
    const commands = parsePathCommands(d);
    if (!commands.length) return d || "";
    if (!Number.isFinite(epsilon) || epsilon <= 0) return d;
    if (commands.length <= 6) return d;
    const subpaths = splitSubpathCommands(commands);
    return subpaths.map(sub => {
      if (!sub.length) return "";
      if (subpathHasCurves(sub) || sub.length <= 3) return serializeCommands(sub, digits);
      return simplifyLineSubpath(sub, epsilon, digits);
    }).filter(Boolean).join(" ");
  }

  function boxMinSide(box) {
    if (!box) return 8;
    return Math.max(0.5, Math.min(box.width || 8, box.height || 8));
  }

  function screenSpaceEpsilon(object, zoom, pixelBudget = 1) {
    const box = object?.bbox || object?._worldBounds;
    const width = Math.max(0.5, (box?.width || 8) * Math.abs(object?.sx || 1));
    const height = Math.max(0.5, (box?.height || 8) * Math.abs(object?.sy || 1));
    const safeZoom = Math.max(zoom, MIN_ZOOM);
    const screen = Math.max(width, height) * safeZoom;
    const minSide = Math.min(width, height);
    /* Small marks stay intact. Epsilon shrinks with the object, never grows. */
    if (screen < 14 || minSide < 7) return Math.min(0.12, 0.35 / safeZoom);
    const pixel = Math.max(0.15, pixelBudget / safeZoom);
    const relative = minSide * 0.012;
    return Math.min(pixel, relative, 2.4);
  }

  function chooseLevel({
    zoom = 1,
    screenSize = 100,
    cameraMoving = false,
    selected = false,
    editing = false,
    commandCount: commands = 0,
    nearViewport = true
  } = {}) {
    if (editing || selected) return LEVEL.FULL;
    if (!nearViewport) return LEVEL.PERCEPTUAL;
    if (screenSize < 16 || commands <= 28) return LEVEL.FULL;
    if (zoom >= 1.1) return LEVEL.FULL;
    if (cameraMoving && commands > 500 && zoom < 0.4) return LEVEL.LIGHT;
    if (commands > 220 && zoom < 0.55) return LEVEL.PERCEPTUAL;
    return LEVEL.FULL;
  }

  function quantizeColor(value) {
    const raw = String(value || "");
    const hex = raw.match(/^#([0-9a-f]{3,8})$/i);
    if (!hex) return raw || "none";
    let digits = hex[1];
    if (digits.length === 3 || digits.length === 4) {
      digits = digits.split("").map(ch => ch + ch).join("");
    }
    const r = Math.round(parseInt(digits.slice(0, 2), 16) / 32) * 32;
    const g = Math.round(parseInt(digits.slice(2, 4), 16) / 32) * 32;
    const b = Math.round(parseInt(digits.slice(4, 6), 16) / 32) * 32;
    const toHex = channel => Math.max(0, Math.min(255, channel)).toString(16).padStart(2, "0");
    return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
  }

  function visualStyleKey(path) {
    const ink = path.getAttribute?.("data-ink") || path.color_class || path.ink || "";
    const fill = path.getAttribute?.("fill") || path.fill || "none";
    const stroke = path.getAttribute?.("stroke") || path.stroke || "none";
    const rule = path.getAttribute?.("fill-rule") || path.fillRule || "nonzero";
    const opacity = path.getAttribute?.("fill-opacity") || path.opacity || "1";
    const width = path.getAttribute?.("stroke-width") || path.strokeWidth || "0";
    const family = ink || `${quantizeColor(fill)}:${quantizeColor(stroke)}`;
    return `${family}|${rule}|${opacity}|${width}`;
  }

  function packNonOverlapping(items, pad = 0.75) {
    const bins = [];
    items.forEach(item => {
      const box = item.bbox || item.box;
      if (!box) {
        bins.push([item]);
        return;
      }
      const padded = expand(box, pad);
      let placed = false;
      for (const bin of bins) {
        const overlaps = bin.some(other => intersects(padded, other.bbox || other.box));
        if (!overlaps) {
          bin.push(item);
          placed = true;
          break;
        }
      }
      if (!placed) bins.push([item]);
    });
    return bins;
  }

  function combinePathData(items) {
    return items.map(item => item.sourceD || item.d || "").filter(Boolean).join(" ");
  }

  class GeometryCache {
    constructor() {
      this.items = new Map();
    }

    key(objectId, level) {
      return `${objectId}|${level}`;
    }

    get(objectId, level) {
      return this.items.get(this.key(objectId, level)) || null;
    }

    set(entry) {
      this.items.set(this.key(entry.objectId, entry.level), entry);
      return entry;
    }

    invalidateObject(objectId) {
      [...this.items.keys()].forEach(key => {
        if (key.startsWith(`${objectId}|`)) this.items.delete(key);
      });
    }

    ensure(object, level, zoom) {
      const existing = this.get(object.id, level);
      if (existing && existing.sourceRevision === object.sourceRevision) return existing;
      const source = object.sourceD || object.path?.getAttribute?.("d") || object.d || "";
      if (!source) return null;
      const commands = object.commandCount || commandCount(source);
      const keepSource = level === LEVEL.FULL ||
        commands <= 8 ||
        (Math.min(object.bbox?.width || 8, object.bbox?.height || 8) < 7 && commands < 80);
      if (keepSource) {
        return this.set({
          objectId: object.id,
          sourceRevision: object.sourceRevision || 1,
          level,
          simplifiedPath: source,
          bbox: object.bbox || null,
          commands,
          subpaths: subpathCount(source)
        });
      }
      const epsilon = screenSpaceEpsilon(object, zoom, level === LEVEL.LIGHT ? 1.8 : 0.9);
      const simplifiedPath = simplifyPath(source, epsilon, 3);
      const nextSubpaths = subpathCount(simplifiedPath);
      const sourceSubpaths = subpathCount(source);
      const safePath = nextSubpaths === sourceSubpaths && simplifiedPath ? simplifiedPath : source;
      return this.set({
        objectId: object.id,
        sourceRevision: object.sourceRevision || 1,
        level,
        simplifiedPath: safePath,
        bbox: object.bbox || null,
        commands: commandCount(safePath),
        subpaths: nextSubpaths
      });
    }
  }

  class SpatialHash {
    constructor(cellSize = 256) {
      this.cellSize = cellSize;
      this.cells = new Map();
      this.items = new Map();
    }

    cellKey(cx, cy) {
      return `${cx}:${cy}`;
    }

    cellsFor(box) {
      if (!box || !(box.width >= 0) || !(box.height >= 0)) return [];
      const size = this.cellSize;
      const x0 = Math.floor(box.x / size);
      const y0 = Math.floor(box.y / size);
      const x1 = Math.floor((box.x + box.width) / size);
      const y1 = Math.floor((box.y + box.height) / size);
      const keys = [];
      for (let x = x0; x <= x1; x++) {
        for (let y = y0; y <= y1; y++) keys.push(this.cellKey(x, y));
      }
      return keys;
    }

    remove(id) {
      const item = this.items.get(id);
      if (!item) return;
      item.cells.forEach(key => {
        const bucket = this.cells.get(key);
        if (!bucket) return;
        bucket.delete(id);
        if (!bucket.size) this.cells.delete(key);
      });
      this.items.delete(id);
    }

    upsert(id, box) {
      const prev = this.items.get(id);
      if (prev && prev.box &&
        prev.box.x === box.x && prev.box.y === box.y &&
        prev.box.width === box.width && prev.box.height === box.height) {
        return;
      }
      this.remove(id);
      const keys = this.cellsFor(box);
      keys.forEach(key => {
        let bucket = this.cells.get(key);
        if (!bucket) {
          bucket = new Set();
          this.cells.set(key, bucket);
        }
        bucket.add(id);
      });
      this.items.set(id, { box, cells: keys });
    }

    query(box) {
      const seen = new Set();
      const out = [];
      this.cellsFor(box).forEach(key => {
        const bucket = this.cells.get(key);
        if (!bucket) return;
        bucket.forEach(id => {
          if (seen.has(id)) return;
          seen.add(id);
          const item = this.items.get(id);
          if (item) out.push({ id, box: item.box });
        });
      });
      return out;
    }

    clear() {
      this.cells.clear();
      this.items.clear();
    }
  }

  function intersects(a, b) {
    return a && b &&
      a.x <= b.x + b.width && a.x + a.width >= b.x &&
      a.y <= b.y + b.height && a.y + a.height >= b.y;
  }

  function expand(box, pad) {
    return {
      x: box.x - pad,
      y: box.y - pad,
      width: box.width + pad * 2,
      height: box.height + pad * 2
    };
  }

  function practiceCardMetrics(board = {}) {
    const boardWidth = Math.max(1, finiteNumber(board.width, 1200));
    const boardHeight = Math.max(1, finiteNumber(board.height, 800));
    const width = Math.min(700, Math.max(500, boardWidth * 0.42));
    const height = Math.min(450, Math.max(300, boardHeight * 0.36));
    return {
      width,
      height,
      fontSize: Math.min(34, Math.max(26, width / 21)),
      gap: Math.min(250, Math.max(100, width * 0.2)),
      sourceGap: Math.min(250, Math.max(100, Math.min(boardWidth, boardHeight) * 0.14))
    };
  }

  function placePracticeCards({
    count = 2,
    anchor,
    board,
    card,
    obstacles = []
  } = {}) {
    const amount = Math.max(1, Math.min(2, Math.floor(finiteNumber(count, 2))));
    const metrics = { ...practiceCardMetrics(board), ...(card || {}) };
    const source = anchor || board || { x: 0, y: 0, width: 1, height: 1 };
    const boardBox = board && board.width > 0 && board.height > 0 ? board : null;
    const gap = Math.max(1, finiteNumber(metrics.gap, 120));
    const sourceGap = Math.max(1, finiteNumber(metrics.sourceGap, gap));
    const pairWidth = metrics.width * amount + gap * (amount - 1);
    const pairHeight = metrics.height * amount + gap * (amount - 1);
    const baseX = finiteNumber(source.x) + finiteNumber(source.width) / 2 - pairWidth / 2;
    const belowY = (boardBox
      ? Math.max(finiteNumber(source.y) + finiteNumber(source.height), boardBox.y + boardBox.height)
      : finiteNumber(source.y) + finiteNumber(source.height)) + sourceGap;
    const rightX = (boardBox
      ? Math.max(finiteNumber(source.x) + finiteNumber(source.width), boardBox.x + boardBox.width)
      : finiteNumber(source.x) + finiteNumber(source.width)) + sourceGap;
    const candidates = [
      { x: baseX, y: belowY, vertical: false },
      { x: rightX, y: finiteNumber(source.y), vertical: true },
      {
        x: boardBox ? boardBox.x : finiteNumber(source.x),
        y: belowY,
        vertical: true
      },
      {
        x: rightX,
        y: finiteNumber(source.y) + finiteNumber(source.height) / 2 - pairHeight / 2,
        vertical: true
      }
    ];
    const occupied = obstacles.filter(item => item && item.width > 0 && item.height > 0);
    const boxesFor = candidate => Array.from({ length: amount }, (_, index) => ({
      x: candidate.x + (candidate.vertical ? 0 : index * (metrics.width + gap)),
      y: candidate.y + (candidate.vertical ? index * (metrics.height + gap) : 0),
      width: metrics.width,
      height: metrics.height
    }));
    for (const candidate of candidates) {
      const boxes = boxesFor(candidate);
      if (!boxes.some(box => occupied.some(obstacle => intersects(box, obstacle)))) return boxes;
    }
    const fallback = candidates[0];
    let boxes = boxesFor(fallback);
    let guard = 0;
    while (boxes.some(box => occupied.some(obstacle => intersects(box, obstacle))) && guard < 40) {
      fallback.y += metrics.height + gap;
      boxes = boxesFor(fallback);
      guard += 1;
    }
    return boxes;
  }

  function finiteNumber(value, fallback = 0) {
    const next = Number(value);
    return Number.isFinite(next) ? next : fallback;
  }

  function cameraZoom(camera, rect) {
    const width = finiteNumber(camera?.width, 0);
    if (!(width > 0)) return 1;
    return rect?.width > 0 ? rect.width / width : 1;
  }

  function cameraAsPanZoom(camera, rect) {
    const zoom = cameraZoom(camera, rect);
    return {
      zoom,
      panX: (rect?.left || 0) - finiteNumber(camera?.x) * zoom,
      panY: (rect?.top || 0) - finiteNumber(camera?.y) * zoom
    };
  }

  function screenToCanvas(clientX, clientY, camera, rect) {
    const { zoom, panX, panY } = cameraAsPanZoom(camera, rect);
    const safeZoom = zoom === 0 ? 1 : zoom;
    return {
      x: (clientX - panX) / safeZoom,
      y: (clientY - panY) / safeZoom
    };
  }

  function canvasToScreen(x, y, camera, rect) {
    const { zoom, panX, panY } = cameraAsPanZoom(camera, rect);
    return {
      x: x * zoom + panX,
      y: y * zoom + panY
    };
  }

  function sanitizeCamera(camera, rect, { minZoom = MIN_ZOOM, maxZoom = MAX_ZOOM, basis = 1600 } = {}) {
    const aspect = rect?.width > 0 && rect?.height > 0
      ? rect.width / rect.height
      : (finiteNumber(camera?.width, 1) / Math.max(finiteNumber(camera?.height, 1), 1e-6));
    let width = finiteNumber(camera?.width, basis);
    if (!(width > 0)) width = basis;
    const minWidth = basis / maxZoom;
    const maxWidth = basis / minZoom;
    width = Math.min(maxWidth, Math.max(minWidth, width));
    const height = width / (aspect || 1);
    let x = finiteNumber(camera?.x, 0);
    let y = finiteNumber(camera?.y, 0);
    if (!Number.isFinite(x)) x = 0;
    if (!Number.isFinite(y)) y = 0;
    return { x, y, width, height };
  }

  function pinchCamera({
    startCamera,
    startDistance,
    startMidpoint,
    currentDistance,
    currentMidpoint,
    rect,
    zoomLatched = true,
    minZoom,
    maxZoom,
    basis
  }) {
    const oldDistance = Math.max(1, finiteNumber(startDistance, 1));
    const newDistance = Math.max(1, finiteNumber(currentDistance, oldDistance));
    const factor = zoomLatched ? newDistance / oldDistance : 1;
    const width = sanitizeCamera({
      ...startCamera,
      width: startCamera.width / factor
    }, rect, { minZoom, maxZoom, basis }).width;
    const height = width / ((rect?.width > 0 && rect?.height > 0) ? rect.width / rect.height : 1);
    const focus = screenToCanvas(startMidpoint.x, startMidpoint.y, startCamera, rect);
    const next = {
      x: focus.x - (currentMidpoint.x - rect.left) * width / rect.width,
      y: focus.y - (currentMidpoint.y - rect.top) * height / rect.height,
      width,
      height
    };
    return sanitizeCamera(next, rect, { minZoom, maxZoom, basis });
  }

  function cameraCss(camera, rect) {
    const zoom = cameraZoom(camera, rect);
    let tx = -finiteNumber(camera?.x) * zoom;
    let ty = -finiteNumber(camera?.y) * zoom;
    tx = Math.max(-MAX_TRANSLATE, Math.min(MAX_TRANSLATE, tx));
    ty = Math.max(-MAX_TRANSLATE, Math.min(MAX_TRANSLATE, ty));
    const safeZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM * 1.25, zoom));
    return {
      zoom: safeZoom,
      tx,
      ty,
      css: `translate3d(${tx}px, ${ty}px, 0) scale(${safeZoom})`,
      svg: `translate(${tx} ${ty}) scale(${safeZoom})`
    };
  }

  function applySceneTransform(world, html, camera, rect) {
    const mapped = cameraCss(camera, rect);
    if (world) {
      world.style.transform = "none";
      world.style.webkitTransform = "none";
      world.style.willChange = "auto";
      world.setAttribute("transform", mapped.svg);
    }
    if (html) {
      html.style.transform = `scale(${mapped.zoom}) translate(${-finiteNumber(camera.x)}px, ${-finiteNumber(camera.y)}px)`;
      html.style.transformOrigin = "0 0";
    }
    return mapped;
  }

  function displayCellKey(box, cellSize = 240) {
    const cx = Math.floor((box.x + box.width / 2) / cellSize);
    const cy = Math.floor((box.y + box.height / 2) / cellSize);
    return `${cx}:${cy}`;
  }

  function cellBounds(key, cellSize = 240) {
    const [cx, cy] = String(key).split(":").map(Number);
    return {
      x: cx * cellSize,
      y: cy * cellSize,
      width: cellSize,
      height: cellSize
    };
  }

  class PerfMonitor {
    constructor() {
      this.enabled = false;
      this.frames = [];
      this.last = now();
      this.fps = 0;
      this.frameTime = 0;
      this.worst = 0;
      this.p95 = 0;
      this.renders = 0;
      this.visible = 0;
      this.culled = 0;
      this.svgObjects = 0;
      this.pathCommands = 0;
      this.level = LEVEL.FULL;
      this.gesture = "idle";
      this.pointers = 0;
      this.zoom = 1;
      this.raf = 0;
      this.overlay = null;
      this.samples = [];
    }

    enable(flag) {
      this.enabled = Boolean(flag);
      if (this.enabled) this.ensureOverlay();
      else this.overlay?.remove();
      if (this.enabled && !this.raf) this.tick();
    }

    ensureOverlay() {
      if (this.overlay) return this.overlay;
      const node = document.createElement("div");
      node.id = "perf-overlay";
      node.setAttribute("aria-hidden", "true");
      document.body.append(node);
      this.overlay = node;
      return node;
    }

    markRender() {
      this.renders += 1;
    }

    recordFrame(dt) {
      this.samples.push(dt);
      if (this.samples.length > 180) this.samples.shift();
      this.frameTime = dt;
      this.worst = Math.max(this.worst, dt);
      const sorted = this.samples.slice().sort((a, b) => a - b);
      this.p95 = sorted[Math.floor(sorted.length * 0.95)] || dt;
      const instant = dt > 0 ? 1000 / dt : 0;
      this.fps = this.fps ? this.fps * 0.82 + instant * 0.18 : instant;
    }

    resetWorst() {
      this.worst = 0;
      this.samples = [];
    }

    tick() {
      const t = now();
      this.recordFrame(t - this.last);
      this.last = t;
      if (this.enabled) this.paint();
      this.raf = requestAnimationFrame(() => this.tick());
    }

    paint() {
      const node = this.ensureOverlay();
      node.textContent = [
        `${Math.round(this.fps)} FPS`,
        `${this.frameTime.toFixed(1)} ms`,
        `p95 ${this.p95.toFixed(1)} ms`,
        `worst ${this.worst.toFixed(1)} ms`,
        `zoom ${Math.round(this.zoom * 100)}%`,
        `vis ${this.visible} / cull ${this.culled}`,
        `svg ${this.svgObjects}`,
        `cmds ${this.pathCommands}`,
        this.level.toUpperCase(),
        this.gesture,
        `ptrs ${this.pointers}`,
        `scene ${this.renders}`
      ].join("\n");
    }

    snapshot() {
      return {
        fps: this.fps,
        frameTime: this.frameTime,
        p95: this.p95,
        worst: this.worst,
        zoom: this.zoom,
        visible: this.visible,
        culled: this.culled,
        svgObjects: this.svgObjects,
        pathCommands: this.pathCommands,
        level: this.level,
        gesture: this.gesture,
        pointers: this.pointers,
        renders: this.renders
      };
    }
  }

  async function measureTransformLoop({ frames = 90, paths = 800 } = {}) {
    const host = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    host.setAttribute("width", "800");
    host.setAttribute("height", "500");
    host.style.cssText = "position:fixed;left:-2000px;top:0;width:800px;height:500px;";
    const group = document.createElementNS("http://www.w3.org/2000/svg", "g");
    host.append(group);
    for (let i = 0; i < paths; i++) {
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      const x = (i * 17) % 700;
      const y = (i * 13) % 400;
      path.setAttribute("d", `M ${x} ${y} c 8 0 16 12 24 0 c 8 -12 16 0 24 0`);
      path.setAttribute("fill", i % 2 ? "#183153" : "#2563eb");
      group.append(path);
    }
    document.body.append(host);
    const times = { viewBox: [], transform: [] };
    const run = (label, step) => new Promise(resolve => {
      let count = 0;
      let last = now();
      const tick = () => {
        const t = now();
        times[label].push(t - last);
        last = t;
        step(count);
        count += 1;
        if (count >= frames) resolve();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    await run("viewBox", i => {
      host.setAttribute("viewBox", `${i * 3} ${i * 2} 800 500`);
    });
    host.setAttribute("viewBox", "0 0 800 500");
    await run("transform", i => {
      const zoom = 1 + (i % 20) * 0.01;
      group.setAttribute("transform", `translate(${-i * 2} ${-i}) scale(${zoom})`);
    });
    host.remove();
    const avg = list => list.reduce((a, b) => a + b, 0) / Math.max(1, list.length);
    return {
      paths,
      frames,
      viewBoxMs: avg(times.viewBox),
      transformMs: avg(times.transform),
      viewBoxFps: 1000 / avg(times.viewBox),
      transformFps: 1000 / avg(times.transform)
    };
  }

  const engine = {
    LEVEL,
    MIN_ZOOM,
    MAX_ZOOM,
    parsePathCommands,
    commandCount,
    subpathCount,
    simplifyPath,
    screenSpaceEpsilon,
    chooseLevel,
    GeometryCache,
    SpatialHash,
    intersects,
    expand,
    practiceCardMetrics,
    placePracticeCards,
    cameraCss,
    cameraZoom,
    cameraAsPanZoom,
    screenToCanvas,
    canvasToScreen,
    sanitizeCamera,
    pinchCamera,
    applySceneTransform,
    visualStyleKey,
    packNonOverlapping,
    combinePathData,
    displayCellKey,
    cellBounds,
    boxMinSide,
    PerfMonitor,
    measureTransformLoop,
    idle(work) {
      if (typeof requestIdleCallback === "function") {
        return requestIdleCallback(work, { timeout: 800 });
      }
      return setTimeout(() => work({ timeRemaining: () => 8, didTimeout: true }), 16);
    }
  };

  globalThis.BoardEngine = engine;
  if (typeof module !== "undefined" && module.exports) module.exports = engine;
})();
