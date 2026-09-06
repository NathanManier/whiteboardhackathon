(() => {
  "use strict";

  const $ = selector => document.querySelector(selector);
  const state = { folders: [], boards: [], folderId: null, dialogAction: null, moveBoardId: null };
  let previewUrl = null;
  let toastTimer = null;

  function apiError(payload, response) {
    return payload?.error || payload?.message || `${response.status} ${response.statusText}`.trim();
  }

  async function request(url, options = {}) {
    const response = await fetch(url, {
      headers: options.body ? { "Content-Type": "application/json", ...options.headers } : options.headers,
      ...options,
    });
    const type = response.headers.get("content-type") || "";
    const payload = type.includes("json") ? await response.json() : await response.text();
    if (!response.ok) {
      const error = new Error(typeof payload === "string" ? payload : apiError(payload, response));
      error.status = response.status;
      error.payload = payload;
      throw error;
    }
    return payload;
  }

  function toast(message, isError = false) {
    const element = $("#toast");
    if (!element) return;
    clearTimeout(toastTimer);
    element.textContent = message;
    element.style.background = isError ? "#9b321f" : "";
    element.hidden = false;
    toastTimer = setTimeout(() => { element.hidden = true; }, 3500);
  }

  function normalizeLibrary(payload) {
    const library = payload?.library && typeof payload.library === "object" ? payload.library : payload;
    state.folders = Array.isArray(library?.folders) ? library.folders : [];
    state.boards = Array.isArray(library?.boards) ? library.boards : [];
    if (state.folderId && !state.folders.some(folder => folder.id === state.folderId)) {
      state.folderId = null;
    }
  }

  function itemName(item, fallback) {
    return String(item.name || item.title || item.display_name || fallback);
  }

  function itemFolderId(item) {
    return item.folder_id || item.folderId || null;
  }

  function formatDate(value) {
    if (!value) return "";
    const date = new Date(typeof value === "number" && value < 1e12 ? value * 1000 : value);
    return Number.isNaN(date.valueOf())
      ? ""
      : new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(date);
  }

  function button(label, action, itemId, className = "") {
    const element = document.createElement("button");
    element.type = "button";
    element.textContent = label;
    element.dataset.action = action;
    element.dataset.id = itemId;
    if (className) element.className = className;
    return element;
  }

  function folderCard(folder) {
    const card = document.createElement("article");
    card.className = "folder-chip";
    const open = document.createElement("button");
    open.type = "button";
    open.className = "folder-open";
    open.dataset.action = "open-folder";
    open.dataset.id = folder.id;
    const count = state.boards.filter(board => itemFolderId(board) === folder.id).length;
    open.innerHTML = `<strong></strong><span></span>`;
    open.querySelector("strong").textContent = itemName(folder, "Untitled folder");
    const stale = folder.study_guide_stale ? " · study guide may be outdated" : "";
    open.querySelector("span").textContent = `${count} whiteboard${count === 1 ? "" : "s"}${stale}`;
    const actions = document.createElement("div");
    actions.className = "chip-actions";
    actions.append(
      button("Rename", "rename-folder", folder.id),
      button("Delete", "delete-folder", folder.id, "danger-action"),
    );
    card.append(open, actions);
    return card;
  }

  function boardCard(board) {
    const card = document.createElement("article");
    card.className = "board-card";
    const thumb = document.createElement("a");
    thumb.className = "board-thumb";
    thumb.href = board.url || `/board/${encodeURIComponent(board.id)}`;
    thumb.setAttribute("aria-label", `Open ${itemName(board, "board")}`);
    if (board.thumbnail_url) {
      const img = document.createElement("img");
      img.src = board.thumbnail_url;
      img.alt = "";
      img.loading = "lazy";
      thumb.append(img);
    } else {
      const placeholder = document.createElement("span");
      placeholder.className = "thumb-placeholder";
      placeholder.textContent = "Whiteboard";
      thumb.append(placeholder);
    }
    const body = document.createElement("div");
    body.className = "board-card-body";
    const title = document.createElement("h3");
    const order = whiteboardOrder(board);
    title.textContent = order
      ? `${order} — ${itemName(board, "Whiteboard")}`
      : itemName(board, "Untitled whiteboard");
    const detail = document.createElement("p");
    detail.textContent = formatDate(board.updated_at || board.created_at);
    const actions = document.createElement("div");
    actions.className = "card-actions";
    const open = document.createElement("a");
    open.className = "open-action";
    open.href = board.url || `/board/${encodeURIComponent(board.id)}`;
    open.textContent = "Open";
    actions.append(
      open,
      button("Rename", "rename-board", board.id),
      button("Move", "move-board", board.id),
      button("Delete", "delete-board", board.id, "danger-action"),
    );
    body.append(title, detail, actions);
    card.append(thumb, body);
    return card;
  }

  function renderFolderOptions() {
    const select = $("#move-folder");
    if (!select) return;
    const current = select.value;
    select.replaceChildren(new Option("No folder", ""));
    [...state.folders]
      .sort((a, b) => itemName(a, "").localeCompare(itemName(b, "")))
      .forEach(folder => select.add(new Option(itemName(folder, "Untitled folder"), folder.id)));
    if ([...select.options].some(option => option.value === current)) select.value = current;
  }

  function whiteboardOrder(board) {
    const folder = state.folders.find(item => item.id === itemFolderId(board));
    const order = folder?.board_order || folder?.boardOrder || [];
    const index = order.indexOf(board.id);
    return index >= 0 ? index + 1 : null;
  }

  function visibleBoards() {
    if (state.folderId) {
      return state.boards.filter(board => itemFolderId(board) === state.folderId);
    }
    return [...state.boards].sort((a, b) => Number(b.updated_at || 0) - Number(a.updated_at || 0));
  }

  function render() {
    renderFolderOptions();
    const grid = $("#library-grid");
    const status = $("#library-status");
    const path = $("#library-path");
    const folderRow = $("#folder-row");
    const foldersSection = $("#folders-section");
    const activeFolder = state.folders.find(folder => folder.id === state.folderId);
    const folderField = $("#upload-folder-id");
    if (folderField) folderField.value = state.folderId || "";
    const workspaceField = $("#upload-workspace-id");
    if (workspaceField) {
      workspaceField.value = activeFolder?.workspace_board_id || activeFolder?.workspaceBoardId || "";
    }
    const newBoard = $("#new-board-button");
    if (newBoard) newBoard.textContent = state.folderId ? "+ Import Whiteboard" : "New Board";

    const rootButton = document.createElement("button");
    rootButton.type = "button";
    rootButton.className = "path-button";
    rootButton.dataset.action = "open-root";
    rootButton.textContent = "My Lectures";
    path.replaceChildren(rootButton);
    if (activeFolder) {
      path.append(" › ");
      const current = document.createElement("strong");
      current.textContent = itemName(activeFolder, "Untitled folder");
      path.append(current);
    }

    folderRow.replaceChildren();
    if (!state.folderId) {
      [...state.folders]
        .sort((a, b) => itemName(a, "").localeCompare(itemName(b, "")))
        .forEach(folder => folderRow.append(folderCard(folder)));
      foldersSection.hidden = false;
    } else {
      foldersSection.hidden = true;
    }
    if (!state.folderId && !state.folders.length) foldersSection.hidden = true;

    const boards = visibleBoards();
    grid.replaceChildren();
    boards.forEach(board => grid.append(boardCard(board)));
    $("#boards-title").textContent = activeFolder
      ? "Whiteboards"
      : "Recent whiteboards";

    const actions = $("#lecture-actions");
    const stale = $("#folder-guide-stale");
    const openLecture = $("#open-lecture");
    if (actions) {
      actions.hidden = !activeFolder;
      if (stale) stale.hidden = !(activeFolder?.study_guide_stale || activeFolder?.studyGuideStale);
      if (openLecture) {
        const workspace = activeFolder?.workspace_board_id || activeFolder?.url;
        openLecture.hidden = !boards.length;
        openLecture.dataset.url = activeFolder?.url || (boards[0]?.url || "");
      }
    }

    const isEmpty = !boards.length;
    status.className = "library-message";
    status.setAttribute("role", "status");
    status.textContent = activeFolder
      ? "This lecture has no whiteboards yet. Import a photographed board to start."
      : "No lectures yet. Create a lecture, then import photographed whiteboards.";
    status.hidden = !isEmpty;
    grid.hidden = isEmpty;
  }

  async function loadLibrary() {
    const status = $("#library-status");
    $("#library-grid").hidden = true;
    status.hidden = false;
    status.className = "library-message";
    status.setAttribute("role", "status");
    status.textContent = "Loading your boards…";
    try {
      normalizeLibrary(await request("/api/library"));
      render();
    } catch (error) {
      status.setAttribute("role", "alert");
      status.textContent = `Could not load the board library. ${error.message}`;
    }
  }

  function openNameDialog(title, help, value, action) {
    state.dialogAction = action;
    $("#name-dialog-title").textContent = title;
    $("#name-dialog-help").textContent = help;
    $("#name-dialog-input").value = value || "";
    $("#name-dialog").showModal();
    $("#name-dialog-input").focus();
    $("#name-dialog-input").select();
  }

  async function submitName(event) {
    event.preventDefault();
    if (event.submitter?.value === "cancel") {
      $("#name-dialog").close();
      return;
    }
    const name = $("#name-dialog-input").value.trim();
    if (!name || !state.dialogAction) return;
    const submit = $("#name-dialog-submit");
    submit.disabled = true;
    try {
      await state.dialogAction(name);
      $("#name-dialog").close();
      await loadLibrary();
    } catch (error) {
      toast(error.message, true);
    } finally {
      submit.disabled = false;
    }
  }

  async function deleteFolder(folder) {
    const name = itemName(folder, "this folder");
    if (!confirm(`Delete “${name}”? Empty folders are removed immediately.`)) return;
    try {
      await request(`/api/folders/${encodeURIComponent(folder.id)}`, { method: "DELETE" });
    } catch (error) {
      if (error.status !== 409) throw error;
      const count = state.boards.filter(board => itemFolderId(board) === folder.id).length;
      if (!confirm(`“${name}” still contains ${count || "one or more"} boards. Delete the folder and every board inside it? This cannot be undone.`)) return;
      await request(`/api/folders/${encodeURIComponent(folder.id)}?recursive=1`, { method: "DELETE" });
    }
    toast(`Deleted ${name}.`);
    await loadLibrary();
  }

  async function deleteBoard(board) {
    const name = itemName(board, "this board");
    if (!confirm(`Permanently delete “${name}”? This cannot be undone.`)) return;
    await request(`/api/boards/${encodeURIComponent(board.id)}`, { method: "DELETE" });
    toast(`Deleted ${name}.`);
    await loadLibrary();
  }

  function openMoveDialog(board) {
    state.moveBoardId = board.id;
    renderFolderOptions();
    $("#move-folder").value = itemFolderId(board) || "";
    $("#move-dialog").showModal();
  }

  function openCapture() {
    $("#capture-dialog").showModal();
  }

  function closeCapture() {
    if ($("#processing")?.hidden === false) return;
    $("#capture-dialog").close();
    clearSelection();
  }

  async function handleLibraryAction(event) {
    const target = event.target.closest("[data-action]");
    if (!target) return;
    event.preventDefault();
    event.stopPropagation();
    const { action, id } = target.dataset;
    const folder = state.folders.find(item => item.id === id);
    const board = state.boards.find(item => item.id === id);
    try {
      if (action === "open-root") {
        state.folderId = null;
        render();
      } else if (action === "open-folder" && folder) {
        state.folderId = folder.id;
        render();
      } else if (action === "rename-folder" && folder) {
        openNameDialog("Rename lecture", "Use a short course or lecture name.", itemName(folder, ""), name =>
          request(`/api/folders/${encodeURIComponent(folder.id)}`, { method: "PATCH", body: JSON.stringify({ name }) }));
      } else if (action === "rename-board" && board) {
        openNameDialog("Rename board", "The saved canvas stays the same.", itemName(board, ""), name =>
          request(`/api/boards/${encodeURIComponent(board.id)}`, { method: "PATCH", body: JSON.stringify({ name }) }));
      } else if (action === "move-board" && board) {
        openMoveDialog(board);
      } else if (action === "delete-folder" && folder) {
        await deleteFolder(folder);
      } else if (action === "delete-board" && board) {
        await deleteBoard(board);
      }
    } catch (error) {
      toast(error.message, true);
    }
  }

  function isAcceptedImage(file) {
    return file && ["image/png", "image/jpeg", "image/webp"].includes(file.type);
  }

  function setInputSource(input) {
    const standardInput = $("#board-image");
    const cameraInput = $("#camera-image");
    standardInput.name = input === standardInput ? "image" : "";
    cameraInput.name = input === cameraInput ? "image" : "";
    standardInput.required = input === standardInput;
    cameraInput.required = input === cameraInput;
  }

  function showSelection(file, input) {
    if (!isAcceptedImage(file)) {
      toast("Choose a PNG, JPEG, or WebP image.", true);
      return;
    }
    setInputSource(input);
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = URL.createObjectURL(file);
    $("#file-title").textContent = file.name;
    $("#file-detail").textContent = `${(file.size / 1048576).toFixed(1)} MB`;
    $("#selection-image").src = previewUrl;
    $("#selection-image").alt = `Selected whiteboard photo: ${file.name}`;
    $("#upload-idle").hidden = true;
    $("#upload-selected").hidden = false;
    $("#processing").hidden = true;
  }

  function clearSelection() {
    const standardInput = $("#board-image");
    const cameraInput = $("#camera-image");
    standardInput.value = "";
    cameraInput.value = "";
    standardInput.name = "image";
    cameraInput.removeAttribute("name");
    standardInput.required = true;
    cameraInput.required = false;
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = undefined;
    $("#selection-image").removeAttribute("src");
    $("#upload-selected").hidden = true;
    $("#upload-idle").hidden = false;
    $("#processing").hidden = true;
  }

  function bindUpload() {
    const form = $("#upload-form");
    const standardInput = $("#board-image");
    const cameraInput = $("#camera-image");
    const dropZone = $("#drop-zone");
    standardInput.addEventListener("change", () => showSelection(standardInput.files[0], standardInput));
    cameraInput.addEventListener("change", () => showSelection(cameraInput.files[0], cameraInput));
    $("#cancel-selection").addEventListener("click", clearSelection);
    $("#replace-selection").addEventListener("click", () => standardInput.click());
    ["dragenter", "dragover"].forEach(type => dropZone.addEventListener(type, event => {
      event.preventDefault();
      dropZone.classList.add("is-dragging");
    }));
    ["dragleave", "drop"].forEach(type => dropZone.addEventListener(type, event => {
      event.preventDefault();
      dropZone.classList.remove("is-dragging");
    }));
    dropZone.addEventListener("drop", event => {
      const file = event.dataTransfer.files[0];
      if (!isAcceptedImage(file)) return;
      const transfer = new DataTransfer();
      transfer.items.add(file);
      standardInput.files = transfer.files;
      showSelection(file, standardInput);
    });
    form.addEventListener("submit", event => {
      const activeInput = standardInput.name ? standardInput : cameraInput;
      if (!isAcceptedImage(activeInput.files[0])) {
        event.preventDefault();
        toast("Choose a board photo before continuing.", true);
        return;
      }
      $("#upload-selected").hidden = true;
      $("#processing").hidden = false;
      form.setAttribute("aria-busy", "true");
      const started = Date.now();
      const timer = $("#processing-time");
      window.setInterval(() => {
        const seconds = Math.floor((Date.now() - started) / 1000);
        timer.textContent = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
      }, 250);
    });
  }

  function bindLibrary() {
    $("#library-grid").addEventListener("click", handleLibraryAction);
    $("#folder-row").addEventListener("click", handleLibraryAction);
    $("#library-path").addEventListener("click", handleLibraryAction);
    $("#refresh-library").addEventListener("click", loadLibrary);
    $("#create-folder").addEventListener("click", () => {
      openNameDialog("Create lecture", "A lecture holds every whiteboard from one class session.", "", name =>
        request("/api/folders", { method: "POST", body: JSON.stringify({ name }) }));
    });
    $("#new-board-button").addEventListener("click", openCapture);
    $("#import-lecture-board")?.addEventListener("click", openCapture);
    $("#open-lecture")?.addEventListener("click", () => {
      const url = $("#open-lecture")?.dataset.url;
      if (url) location.assign(url);
    });
    $("#generate-folder-guide")?.addEventListener("click", async () => {
      if (!state.folderId) return;
      try {
        toast("Generating study guide…");
        const payload = await request(`/api/folders/${encodeURIComponent(state.folderId)}/study-guide`, {
          method: "POST",
          body: "{}",
        });
        const guide = payload.study_guide || payload.studyGuide;
        if (guide?.content) {
          const preview = guide.content.replace(/\s+/g, " ").slice(0, 180);
          toast(payload.study_guide_stale ? "Study guide may be outdated." : `Study guide ready. ${preview}`);
        } else {
          toast("Study guide generated.");
        }
        await loadLibrary();
      } catch (error) {
        toast(error.message || "Couldn't generate a study guide right now.", true);
      }
    });
    $("#close-capture").addEventListener("click", closeCapture);
    $("#name-form").addEventListener("submit", submitName);
    $("#move-form").addEventListener("submit", async event => {
      event.preventDefault();
      if (event.submitter?.value === "cancel") {
        $("#move-dialog").close();
        return;
      }
      try {
        await request(`/api/boards/${encodeURIComponent(state.moveBoardId)}`, {
          method: "PATCH",
          body: JSON.stringify({ folder_id: $("#move-folder").value || null }),
        });
        $("#move-dialog").close();
        toast("Board moved.");
        await loadLibrary();
      } catch (error) {
        toast(error.message, true);
      }
    });
  }

  bindUpload();
  bindLibrary();
  loadLibrary();
  if (new URLSearchParams(location.search).has("new")) openCapture();
})();
