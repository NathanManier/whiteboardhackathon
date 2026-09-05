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
    if (!value) return "No recent activity";
    const date = new Date(typeof value === "number" && value < 1e12 ? value * 1000 : value);
    return Number.isNaN(date.valueOf())
      ? "Saved board"
      : `Updated ${new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(date)}`;
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
    card.className = "library-card folder-card";
    const icon = document.createElement("span");
    icon.className = "card-icon";
    icon.textContent = "▰";
    icon.setAttribute("aria-hidden", "true");
    const title = document.createElement("h3");
    title.textContent = itemName(folder, "Untitled folder");
    const count = state.boards.filter(board => itemFolderId(board) === folder.id).length;
    const detail = document.createElement("p");
    detail.textContent = `${count} board${count === 1 ? "" : "s"}`;
    const spacer = document.createElement("span");
    spacer.className = "card-spacer";
    const actions = document.createElement("div");
    actions.className = "card-actions";
    actions.append(
      button("Open", "open-folder", folder.id, "open-action"),
      button("Rename", "rename-folder", folder.id),
      button("Delete", "delete-folder", folder.id, "danger-action"),
    );
    card.append(icon, title, detail, spacer, actions);
    return card;
  }

  function boardCard(board) {
    const card = document.createElement("article");
    card.className = "library-card";
    const icon = document.createElement("span");
    icon.className = "card-icon";
    icon.textContent = "▤";
    icon.setAttribute("aria-hidden", "true");
    const title = document.createElement("h3");
    title.textContent = itemName(board, "Untitled board");
    const detail = document.createElement("p");
    detail.textContent = formatDate(board.updated_at || board.created_at);
    const spacer = document.createElement("span");
    spacer.className = "card-spacer";
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
    card.append(icon, title, detail, spacer, actions);
    return card;
  }

  function renderFolderOptions() {
    const selects = [$("#upload-folder"), $("#move-folder")];
    selects.forEach(select => {
      const current = select.value;
      select.replaceChildren(new Option("Root", ""));
      [...state.folders]
        .sort((a, b) => itemName(a, "").localeCompare(itemName(b, "")))
        .forEach(folder => select.add(new Option(itemName(folder, "Untitled folder"), folder.id)));
      if ([...select.options].some(option => option.value === current)) select.value = current;
    });
    $("#upload-folder").value = state.folderId || "";
  }

  function render() {
    renderFolderOptions();
    const grid = $("#library-grid");
    const status = $("#library-status");
    const path = $("#library-path");
    const activeFolder = state.folders.find(folder => folder.id === state.folderId);
    const rootButton = document.createElement("button");
    rootButton.type = "button";
    rootButton.className = "path-button";
    rootButton.dataset.action = "open-root";
    rootButton.textContent = "All boards";
    path.replaceChildren(rootButton);
    if (activeFolder) {
      path.append("›");
      const current = document.createElement("strong");
      current.textContent = itemName(activeFolder, "Untitled folder");
      path.append(current);
    }

    grid.replaceChildren();
    if (!state.folderId) {
      [...state.folders]
        .sort((a, b) => itemName(a, "").localeCompare(itemName(b, "")))
        .forEach(folder => grid.append(folderCard(folder)));
    }
    [...state.boards]
      .filter(board => itemFolderId(board) === state.folderId)
      .sort((a, b) => Number(b.updated_at || 0) - Number(a.updated_at || 0))
      .forEach(board => grid.append(boardCard(board)));

    const isEmpty = !grid.childElementCount;
    status.className = "library-message";
    status.removeAttribute("role");
    status.setAttribute("role", "status");
    status.textContent = activeFolder
      ? "This folder is empty. Choose it above when uploading a board."
      : "No boards or folders yet. Upload a photo to create your first board.";
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
      if (!confirm(`“${name}” is not empty (${count || "one or more"} boards). Delete the folder and every board inside it? This cannot be undone.`)) return;
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

  async function handleLibraryAction(event) {
    const target = event.target.closest("[data-action]");
    if (!target) return;
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
        openNameDialog("Rename folder", "Use a short, recognizable name.", itemName(folder, ""), name =>
          request(`/api/folders/${encodeURIComponent(folder.id)}`, { method: "PATCH", body: JSON.stringify({ name }) }));
      } else if (action === "rename-board" && board) {
        openNameDialog("Rename board", "The board URL and saved work will stay the same.", itemName(board, ""), name =>
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

  function showFile(file) {
    if (!isAcceptedImage(file)) {
      toast("Choose a PNG, JPEG, or WebP image.", true);
      return;
    }
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = URL.createObjectURL(file);
    $("#file-title").textContent = file.name;
    $("#file-detail").textContent = `${(file.size / 1048576).toFixed(1)} MB · Ready to process`;
    $("#upload-preview").src = previewUrl;
    $("#upload-preview").hidden = false;
    $("#drop-zone").classList.add("has-file");
    if (!$("#upload-name").value.trim()) {
      $("#upload-name").value = file.name.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ").trim();
    }
  }

  function bindUpload() {
    const form = $("#upload-form");
    const input = $("#board-image");
    const zone = $("#drop-zone");
    input.addEventListener("change", () => showFile(input.files[0]));
    ["dragenter", "dragover"].forEach(type => zone.addEventListener(type, event => {
      event.preventDefault();
      zone.classList.add("is-dragging");
    }));
    ["dragleave", "drop"].forEach(type => zone.addEventListener(type, event => {
      event.preventDefault();
      zone.classList.remove("is-dragging");
    }));
    zone.addEventListener("drop", event => {
      const file = event.dataTransfer.files[0];
      if (!isAcceptedImage(file)) {
        toast("Choose a PNG, JPEG, or WebP image.", true);
        return;
      }
      const transfer = new DataTransfer();
      transfer.items.add(file);
      input.files = transfer.files;
      showFile(file);
    });
    form.addEventListener("submit", event => {
      if (!isAcceptedImage(input.files[0])) {
        event.preventDefault();
        toast("Choose a board photo before continuing.", true);
        return;
      }
      $("#processing").hidden = false;
      $("#upload-submit").disabled = true;
      $("#upload-submit span").textContent = "Processing…";
      zone.setAttribute("aria-busy", "true");
    });
  }

  function bindLibrary() {
    $("#library-grid").addEventListener("click", handleLibraryAction);
    $("#library-path").addEventListener("click", handleLibraryAction);
    $("#refresh-library").addEventListener("click", loadLibrary);
    $("#create-folder").addEventListener("click", () => {
      openNameDialog("Create folder", "Folders keep related boards together.", "", name =>
        request("/api/folders", { method: "POST", body: JSON.stringify({ name }) }));
    });
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
})();
