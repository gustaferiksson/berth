const MODES = ["flat", "folders", "project"]
const MODE_KEY = "berth-review-files"
const DECLARATION_KEYWORDS = "func|let|var|struct|class|enum|protocol|actor|typealias|case|const|function|interface|type|export"
const REPLY_TIMEOUT = 2000
const SNIPPET_LINES = 20
const HEURISTIC_FILE_LIMIT = 40
const DEFAULT_PALETTE = ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf", "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]
const ENTITIES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }
const COMMENT_ICON = '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" style="vertical-align:-1px"><path d="M2.5 3h11v7.5h-6l-3 2.5v-2.5h-2z"/></svg>'

const el = Object.fromEntries(["compare", "prTab", "base", "totals", "error", "fetched", "refresh", "modes", "tree", "cpanel", "ccount", "clist", "send", "fh", "diffHost", "viewHost", "notice"].map(id => [id, document.getElementById(id)]))

const state = {
  load: null,
  files: new Map(),
  changedFolders: new Set(),
  mode: "folders",
  expanded: new Map(),
  comments: [],
  selected: null,
  shown: null,
  reveal: null,
  composer: null,
  zones: [],
  savedVersions: new Map(),
  savingVersions: new Map(),
  savedFlash: null,
  replies: new Map(),
  fileWaiters: new Map(),
  seq: 0,
}

let diffEditor = null
let viewer = null

const escapeHTML = text => String(text).replace(/[&<>"']/g, c => ENTITIES[c])

function hex(value, fallback) {
  const match = /^#?([0-9a-f]{6})$/i.exec(String(value ?? ""))
  return match ? `#${match[1].toLowerCase()}` : fallback
}

function mixHex(from, to, amount) {
  const channels = [1, 3, 5].map(i => Math.round(parseInt(from.slice(i, i + 2), 16) * (1 - amount) + parseInt(to.slice(i, i + 2), 16) * amount))
  return `#${channels.map(c => c.toString(16).padStart(2, "0")).join("")}`
}

function applyTheme(theme = {}) {
  const palette = DEFAULT_PALETTE.map((fallback, i) => hex(theme.palette?.[i], fallback))
  const background = hex(theme.background, DEFAULT_PALETTE[0])
  const foreground = hex(theme.foreground, DEFAULT_PALETTE[7])
  const selection = hex(theme.selection, mixHex(background, foreground, 0.2))
  const [r, g, b] = [1, 3, 5].map(i => parseInt(background.slice(i, i + 2), 16) / 255)
  const isLight = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
  const contrast = isLight ? "#000000" : "#ffffff"
  const fontFamily = `"${String(theme.fontFamily ?? "SF Mono").replace(/["\\;{}]/g, "")}", "SF Mono", ui-monospace, Menlo, monospace`
  const fontSize = Number(theme.fontSize) > 0 ? Number(theme.fontSize) : 13
  const [red, green, yellow, blue, magenta, cyan] = palette.slice(1, 7)
  const recessed = mixHex(background, contrast === "#ffffff" ? "#000000" : "#ffffff", 0.18)
  const raised = mixHex(background, foreground, 0.06)

  const root = document.documentElement.style
  Object.entries({ bg: background, fg: foreground, contrast, sel: selection, red, green, yellow, blue, mag: magenta, cyan, mono: fontFamily }).forEach(([name, value]) => root.setProperty(`--${name}`, value))
  root.colorScheme = isLight ? "light" : "dark"

  monaco.editor.defineTheme("berth", {
    base: isLight ? "vs" : "vs-dark",
    inherit: true,
    rules: [
      { token: "", foreground: foreground.slice(1) },
      { token: "comment", foreground: palette[8].slice(1), fontStyle: "italic" },
      { token: "keyword", foreground: magenta.slice(1) },
      { token: "string", foreground: green.slice(1) },
      { token: "number", foreground: yellow.slice(1) },
      { token: "type", foreground: yellow.slice(1) },
      { token: "type.identifier", foreground: yellow.slice(1) },
      { token: "attribute", foreground: cyan.slice(1) },
      { token: "tag", foreground: red.slice(1) },
      { token: "regexp", foreground: red.slice(1) },
      { token: "variable.predefined", foreground: cyan.slice(1) },
    ],
    colors: {
      "editor.background": background,
      "editor.foreground": foreground,
      "editor.selectionBackground": selection,
      "editor.inactiveSelectionBackground": `${selection}99`,
      "editor.lineHighlightBackground": `${foreground}0a`,
      "editor.lineHighlightBorder": "#00000000",
      "editorCursor.foreground": foreground,
      "editorLineNumber.foreground": mixHex(background, foreground, 0.38),
      "editorLineNumber.activeForeground": foreground,
      "editorGutter.background": background,
      "editorWidget.background": raised,
      "editorWidget.border": mixHex(background, foreground, 0.16),
      "editorHoverWidget.background": raised,
      "editorHoverWidget.border": mixHex(background, foreground, 0.16),
      "editorSuggestWidget.background": raised,
      "input.background": recessed,
      "focusBorder": `${blue}99`,
      "scrollbarSlider.background": `${foreground}22`,
      "scrollbarSlider.hoverBackground": `${foreground}33`,
      "scrollbarSlider.activeBackground": `${foreground}44`,
      "list.hoverBackground": `${foreground}12`,
      "list.activeSelectionBackground": `${blue}33`,
      "list.activeSelectionForeground": foreground,
      "list.inactiveSelectionBackground": `${foreground}18`,
      "list.focusBackground": `${blue}33`,
      "diffEditor.insertedLineBackground": `${green}1f`,
      "diffEditor.insertedTextBackground": `${green}38`,
      "diffEditor.removedLineBackground": `${red}21`,
      "diffEditor.removedTextBackground": `${red}3d`,
      "diffEditorGutter.insertedLineBackground": `${green}2a`,
      "diffEditorGutter.removedLineBackground": `${red}2c`,
      "diffEditor.diagonalFill": `${foreground}14`,
      "diffEditor.border": `${foreground}21`,
      "diffEditor.unchangedRegionBackground": raised,
      "diffEditor.unchangedRegionForeground": mixHex(background, foreground, 0.62),
      "diffEditor.unchangedCodeBackground": `${foreground}08`,
      "peekView.border": blue,
      "peekViewTitle.background": mixHex(background, blue, 0.12),
      "peekViewTitleLabel.foreground": foreground,
      "peekViewTitleDescription.foreground": mixHex(background, foreground, 0.62),
      "peekViewEditor.background": recessed,
      "peekViewEditorGutter.background": recessed,
      "peekViewEditor.matchHighlightBackground": `${blue}33`,
      "peekViewResult.background": raised,
      "peekViewResult.fileForeground": foreground,
      "peekViewResult.lineForeground": mixHex(background, foreground, 0.75),
      "peekViewResult.selectionBackground": `${blue}33`,
      "peekViewResult.selectionForeground": foreground,
      "peekViewResult.matchHighlightBackground": `${yellow}40`,
    },
  })
  monaco.editor.setTheme("berth")
  diffEditor.updateOptions({ fontFamily, fontSize })
  viewer.updateOptions({ fontFamily, fontSize })
}

const fileURI = path => monaco.Uri.from({ scheme: "berth", path: `/${path}` })

function languageFor(path) {
  const languages = monaco.languages.getLanguages()
  const name = path.split("/").pop().toLowerCase()
  const extension = name.includes(".") ? name.slice(name.lastIndexOf(".")) : ""
  return languages.find(language => language.filenames?.some(f => f.toLowerCase() === name) || (extension && language.extensions?.includes(extension)))?.id ?? (extension === ".toml" ? "ini" : "plaintext")
}

function isDirty(path) {
  const model = monaco.editor.getModel(fileURI(path))
  return model != null && state.savedVersions.has(path) && state.savedVersions.get(path) !== model.getAlternativeVersionId()
}

function syncModel(uri, text, language) {
  const existing = monaco.editor.getModel(uri)
  if (existing == null) return monaco.editor.createModel(text, language, uri)

  if (existing.getLanguageId() !== language) monaco.editor.setModelLanguage(existing, language)
  if (existing.getValue() !== text) existing.setValue(text)
  return existing
}

function storeModels(message) {
  const path = message.path
  const language = languageFor(path)
  const changed = state.files.has(path)
  if (changed) syncModel(monaco.Uri.from({ scheme: "berth-original", path: `/${path}` }), message.original ?? "", language)
  if (isDirty(path)) return

  const isNew = monaco.editor.getModel(fileURI(path)) == null
  const model = syncModel(fileURI(path), message.modified ?? (changed ? "" : message.original ?? ""), language)
  state.savedVersions.set(path, model.getAlternativeVersionId())
  if (isNew) model.onDidChangeContent(() => renderDirtyState(path))
  window.webkit.messageHandlers.berth.postMessage({ type: "dirty", paths: [...state.savedVersions.keys()].filter(isDirty) })
}

function receiveFile(message) {
  if (typeof message.path !== "string") return

  if (!message.binary && !message.tooLarge) storeModels(message)
  state.fileWaiters.get(message.path)?.forEach(resolve => resolve())
  state.fileWaiters.delete(message.path)
  if (message.path === state.selected) show(message)
}

function show(message) {
  const path = message.path
  const changed = state.files.has(path)
  const hasText = !message.binary && !message.tooLarge
  state.shown = { path, changed, binary: message.binary, tooLarge: message.tooLarge, editable: changed && hasText && message.editable === true && state.load?.editable !== false && message.modified != null }
  clearZones()

  el.diffHost.hidden = !(hasText && changed)
  el.viewHost.hidden = !(hasText && !changed)
  el.notice.hidden = hasText
  el.notice.textContent = message.binary ? "Binary file, not shown" : message.tooLarge ? "File too large to show" : ""
  renderFileHeader()
  if (!hasText) return

  const modified = monaco.editor.getModel(fileURI(path))
  if (!changed) {
    if (viewer.getModel() !== modified) viewer.setModel(modified)
    revealPending(viewer)
    return
  }

  const original = monaco.editor.getModel(monaco.Uri.from({ scheme: "berth-original", path: `/${path}` }))
  const current = diffEditor.getModel()
  if (current?.original !== original || current?.modified !== modified) diffEditor.setModel({ original, modified })
  diffEditor.updateOptions({ readOnly: !state.shown.editable })
  renderZones()
  if (diffEditor.getLineChanges() != null) return revealPending(diffEditor.getModifiedEditor())

  const pendingDiff = diffEditor.onDidUpdateDiff(() => {
    pendingDiff.dispose()
    revealPending(diffEditor.getModifiedEditor())
  })
}

function revealPending(editor) {
  const reveal = state.reveal
  if (reveal == null || reveal.path !== state.shown?.path) return

  state.reveal = null
  editor.setPosition({ lineNumber: reveal.line, column: reveal.column ?? 1 })
  editor.revealLineInCenter(reveal.line)
  editor.focus()
}

function openPath(path, reveal = null) {
  state.reveal = reveal ? { path, ...reveal } : null
  state.selected = path
  path.split("/").slice(0, -1).forEach((_, i, parts) => state.expanded.set(`${state.mode}:${parts.slice(0, i + 1).join("/")}`, true))
  renderTree()
  if (path === state.shown?.path) return revealPending(state.shown.changed ? diffEditor.getModifiedEditor() : viewer)

  window.webkit.messageHandlers.berth.postMessage({ type: "openFile", path })
}

function renderFileHeader() {
  const shown = state.shown
  el.fh.hidden = shown == null
  if (shown == null) return

  const file = state.files.get(shown.path)
  const slash = shown.path.lastIndexOf("/")
  const dirty = shown.editable && isDirty(shown.path)
  const saved = !dirty && state.savedFlash === shown.path
  el.fh.innerHTML = [
    file ? `<span class="st ${file.letter}">${file.letter}</span>` : "",
    `<span class="dirn">${escapeHTML(shown.path.slice(0, slash + 1))}</span><b>${escapeHTML(shown.path.slice(slash + 1))}</b>`,
    file?.oldPath ? `<span class="meta">from ${escapeHTML(file.oldPath)}</span>` : "",
    file?.additions != null ? `<span class="meta"><span class="add">+${file.additions}</span><span class="del">−${file.deletions ?? 0}</span></span>` : "",
    file ? "" : '<span class="meta">unchanged</span>',
    '<span class="sp"></span>',
    dirty ? '<span class="edited">● Edited, ⌘S saves</span>' : "",
    saved ? '<span class="saved">Saved</span>' : "",
    file && !shown.editable && !shown.binary && !shown.tooLarge ? '<span class="meta">read only</span>' : "",
  ].join("")
}

function renderDirtyState(path) {
  if (state.shown?.path === path) renderFileHeader()
  renderTree()
  window.webkit.messageHandlers.berth.postMessage({ type: "dirty", paths: [...state.savedVersions.keys()].filter(isDirty) })
}

function save() {
  const shown = state.shown
  if (!shown?.editable) return

  const model = monaco.editor.getModel(fileURI(shown.path))
  state.savingVersions.set(shown.path, model.getAlternativeVersionId())
  window.webkit.messageHandlers.berth.postMessage({ type: "save", path: shown.path, text: model.getValue() })
}

function receiveSaved(path) {
  if (!state.savingVersions.has(path)) return

  state.savedVersions.set(path, state.savingVersions.get(path))
  state.savingVersions.delete(path)
  state.savedFlash = path
  renderDirtyState(path)
  setTimeout(() => {
    if (state.savedFlash !== path) return
    state.savedFlash = null
    renderFileHeader()
  }, 2000)
}

function receiveLoad(message) {
  const files = Array.isArray(message.files) ? message.files.filter(file => typeof file?.path === "string") : []
  state.load = { ...message, allFiles: Array.isArray(message.allFiles) ? message.allFiles : [] }
  state.files = new Map(files.map(file => {
    const letter = String(file.status ?? "").charAt(0).toUpperCase()
    return [file.path, { ...file, letter: /^[AMDR]$/.test(letter) ? letter : "M" }]
  }))
  state.changedFolders = new Set(files.flatMap(file => file.path.split("/").slice(0, -1).map((_, i, parts) => parts.slice(0, i + 1).join("/"))))
  state.comments = Array.isArray(message.comments) ? message.comments : []
  applyTheme(message.theme)
  renderHeader()
  renderComments()

  const known = path => path != null && (state.files.has(path) || state.load.allFiles.includes(path))
  const target = [message.selectedPath, state.selected, files[0]?.path].find(known)
  state.selected = null
  state.shown = null
  if (target != null) return openPath(target)

  renderTree()
  renderFileHeader()
  el.diffHost.hidden = true
  el.viewHost.hidden = true
  el.notice.hidden = false
  el.notice.textContent = "No changes"
}

function renderHeader() {
  const load = state.load
  const files = [...state.files.values()]
  el.compare.querySelectorAll("button[data-compare]").forEach(button => button.classList.toggle("on", button.dataset.compare === load.compare))
  el.prTab.hidden = load.prNumber == null
  el.prTab.textContent = `PR #${load.prNumber}`
  el.base.innerHTML = load.base ? `vs <code>${escapeHTML(load.base)}</code>` : ""
  el.base.title = load.mergeBase ? `merge base ${load.mergeBase}` : ""
  el.totals.innerHTML = `${files.length} ${files.length === 1 ? "file" : "files"} <span class="add">+${files.reduce((sum, file) => sum + (file.additions ?? 0), 0)}</span><span class="del">−${files.reduce((sum, file) => sum + (file.deletions ?? 0), 0)}</span>`
  el.error.hidden = !load.fetchError
  el.error.textContent = "offline, using local refs"
  el.error.title = load.fetchError ?? ""
  renderFetched()
}

function renderFetched() {
  const fetchedAt = state.load?.fetchedAt ? new Date(state.load.fetchedAt) : null
  if (fetchedAt == null || isNaN(fetchedAt) || state.load.fetchError) {
    el.fetched.textContent = ""
    return
  }

  const seconds = Math.max(0, Math.round((Date.now() - fetchedAt) / 1000))
  el.fetched.textContent = seconds < 60 ? `fetched ${seconds} s ago` : seconds < 3600 ? `fetched ${Math.floor(seconds / 60)} min ago` : `fetched ${Math.floor(seconds / 3600)} h ago`
}

function treeRows(paths, isOpen) {
  const root = { name: "", path: "", folders: new Map(), files: [] }
  for (const path of paths) {
    let node = root
    for (const name of path.split("/").slice(0, -1)) {
      const child = node.folders.get(name) ?? { name, path: node.path ? `${node.path}/${name}` : name, folders: new Map(), files: [] }
      node.folders.set(name, child)
      node = child
    }
    node.files.push(path)
  }
  return folderRows(root, 0, isOpen)
}

function folderRows(node, depth, isOpen) {
  const folders = [...node.folders.values()].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true })).flatMap(folder => {
    let deepest = folder
    let label = folder.name
    while (deepest.files.length === 0 && deepest.folders.size === 1) {
      deepest = deepest.folders.values().next().value
      label += `/${deepest.name}`
    }
    const open = isOpen(deepest.path)
    return [{ kind: "folder", label, path: deepest.path, depth, open }, ...(open ? folderRows(deepest, depth + 1, isOpen) : [])]
  })
  const files = node.files
    .map(path => ({ kind: "file", path, depth, name: path.split("/").pop() }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }))
  return [...folders, ...files]
}

function flatRows() {
  return [...state.files.keys()]
    .map(path => ({ kind: "file", path, depth: 0, name: path.split("/").pop(), dir: path.split("/").slice(0, -1).join("/") }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }) || a.dir.localeCompare(b.dir))
}

function rowsFor(isOpen) {
  if (state.mode === "flat") return flatRows()

  const changed = [...state.files.keys()]
  return treeRows(state.mode === "project" ? [...new Set([...(state.load?.allFiles ?? []), ...changed])] : changed, isOpen)
}

function rowHTML(row, counts) {
  const indent = 8 + row.depth * 12
  if (row.kind === "folder") {
    const marked = state.mode === "project" && state.changedFolders.has(row.path)
    return `<div class="sf fold${state.mode === "project" && !marked ? " dimf" : ""}" data-folder="${escapeHTML(row.path)}" style="padding-left:${indent}px"><span class="chev">${row.open ? "▼" : "▶"}</span><span class="nm">${escapeHTML(row.label)}</span>${marked ? '<i class="chg"></i>' : ""}</div>`
  }

  const on = row.path === state.selected ? " on" : ""
  const file = state.files.get(row.path)
  if (file == null) return `<div class="sf dimf${on}" data-path="${escapeHTML(row.path)}" style="padding-left:${indent + 16}px"><span class="nm">${escapeHTML(row.name)}</span></div>`

  const count = counts.get(row.path) ?? 0
  return `<div class="sf ${file.letter}${on}" data-path="${escapeHTML(row.path)}" style="padding-left:${state.mode === "flat" ? indent : indent + 16}px"${file.oldPath ? ` title="Renamed from ${escapeHTML(file.oldPath)}"` : ""}>`
    + `<span class="st ${file.letter}">${file.letter}</span><span class="nm">${escapeHTML(row.name)}</span>`
    + (row.dir ? `<span class="dir">${escapeHTML(row.dir)}</span>` : "")
    + (isDirty(row.path) ? '<span class="dirty" title="Unsaved edits">●</span>' : "")
    + (count ? `<span class="cb">${COMMENT_ICON} ${count}</span>` : "")
    + (file.additions != null ? `<span class="cnt"><span class="add">+${file.additions}</span><span class="del">−${file.deletions ?? 0}</span></span>` : "")
    + "</div>"
}

function isFolderOpen(path) {
  return state.expanded.get(`${state.mode}:${path}`) ?? (state.mode === "folders" || state.changedFolders.has(path))
}

function renderTree() {
  const counts = state.comments.reduce((map, comment) => map.set(comment.path, (map.get(comment.path) ?? 0) + 1), new Map())
  const rows = rowsFor(isFolderOpen)
  el.modes.querySelectorAll("button").forEach(button => button.classList.toggle("on", button.dataset.mode === state.mode))
  el.tree.innerHTML = rows.length ? rows.map(row => rowHTML(row, counts)).join("") : '<div class="sf dimf">No changes</div>'
  el.tree.querySelector(".sf.on")?.scrollIntoView({ block: "nearest" })
}

function moveSelection(step) {
  const order = rowsFor(() => true).filter(row => row.kind === "file" && state.files.has(row.path)).map(row => row.path)
  if (order.length === 0) return

  const index = order.indexOf(state.selected)
  const next = index === -1 ? order[0] : order[Math.min(order.length - 1, Math.max(0, index + step))]
  if (next !== state.selected) openPath(next)
}

function setComments(comments) {
  state.comments = comments
  window.webkit.messageHandlers.berth.postMessage({ type: "commentsChanged", comments })
  renderComments()
  renderZones()
}

function renderComments() {
  const comments = state.comments
  el.cpanel.hidden = comments.length === 0
  el.ccount.textContent = comments.length
  el.clist.innerHTML = comments.map(comment => `<div class="ci" data-id="${escapeHTML(comment.id)}"><code>${escapeHTML(comment.path)}:${comment.line}${comment.endLine > comment.line ? `–${comment.endLine}` : ""}</code><span>${escapeHTML(comment.text)}</span></div>`).join("")
  el.send.innerHTML = `Send ${comments.length} to Claude`
  renderTree()
}

function snippet(model, line, endLine) {
  const last = Math.min(endLine, line + SNIPPET_LINES - 1, model.getLineCount())
  return Array.from({ length: Math.max(0, last - line + 1) }, (_, i) => model.getLineContent(line + i)).join("\n")
}

function openComposer(line, endLine, existing = null) {
  if (!state.shown?.changed || state.shown.binary || state.shown.tooLarge) return

  state.composer = { path: state.shown.path, line, endLine, id: existing?.id ?? null, text: existing?.text ?? "" }
  renderZones()
}

function submitComposer(text) {
  const composer = state.composer
  const model = monaco.editor.getModel(fileURI(composer.path))
  if (text.trim() === "" || model == null) return

  state.composer = null
  const comment = { id: composer.id ?? `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`, path: composer.path, line: composer.line, endLine: composer.endLine, text: text.trim(), snippet: snippet(model, composer.line, composer.endLine) }
  setComments(composer.id ? state.comments.map(c => (c.id === composer.id ? comment : c)) : [...state.comments, comment])
}

function selectedLines(editor) {
  const selection = editor.getSelection()
  if (selection == null) return null

  const end = selection.endColumn === 1 && selection.endLineNumber > selection.startLineNumber ? selection.endLineNumber - 1 : selection.endLineNumber
  return [selection.startLineNumber, end]
}

function clearZones() {
  const editor = diffEditor.getModifiedEditor()
  const zones = state.zones
  state.zones = []
  editor.changeViewZones(accessor => zones.forEach(zone => accessor.removeZone(zone.zoneId)))
  zones.forEach(zone => {
    zone.observer.disconnect()
    editor.removeOverlayWidget(zone.widget)
  })
}

function mountZone(afterLineNumber, node) {
  const editor = diffEditor.getModifiedEditor()
  const id = `berth.zone.${++state.seq}`
  const widget = { getId: () => id, getDomNode: () => node, getPosition: () => null }
  const layout = editor.getLayoutInfo()
  node.style.left = `${layout.contentLeft}px`
  node.style.width = `${layout.contentWidth}px`
  node.addEventListener("mousedown", event => event.stopPropagation())
  editor.addOverlayWidget(widget)

  const zone = {
    afterLineNumber,
    afterColumn: 1,
    heightInPx: node.offsetHeight || 80,
    domNode: document.createElement("div"),
    onDomNodeTop: top => { node.style.top = `${top}px` },
  }
  let zoneId = null
  editor.changeViewZones(accessor => { zoneId = accessor.addZone(zone) })
  const observer = new ResizeObserver(() => {
    if (node.offsetHeight === 0 || node.offsetHeight === zone.heightInPx) return
    zone.heightInPx = node.offsetHeight
    editor.changeViewZones(accessor => accessor.layoutZone(zoneId))
  })
  observer.observe(node)
  state.zones.push({ zoneId, widget, node, observer })
}

function threadNode(comment) {
  const node = document.createElement("div")
  node.className = "thread"
  node.innerHTML = `<div><header>${COMMENT_ICON} You on ${escapeHTML(comment.path)}:${comment.line}${comment.endLine > comment.line ? `–${comment.endLine}` : ""}<span class="sp"></span><button type="button" class="link" data-act="edit">Edit</button><button type="button" class="link" data-act="delete">Delete</button></header><p>${escapeHTML(comment.text)}</p></div>`
  node.addEventListener("click", event => {
    const act = event.target.closest("button")?.dataset.act
    if (act === "edit") openComposer(comment.line, comment.endLine, comment)
    if (act === "delete") setComments(state.comments.filter(c => c.id !== comment.id))
  })
  return node
}

function composerNode(composer) {
  const node = document.createElement("div")
  node.className = "thread compose"
  node.innerHTML = `<div><header>${COMMENT_ICON} Comment on ${escapeHTML(composer.path)}:${composer.line}${composer.endLine > composer.line ? `–${composer.endLine}` : ""}</header><textarea placeholder="Ask Claude to change something here"></textarea><footer><span class="meta">Goes to Claude with the lines</span><button type="button" class="btn ghost" data-act="cancel">Cancel</button><button type="button" class="btn pri" data-act="submit">Add comment <span class="kbd">⌘↩</span></button></footer></div>`
  const textarea = node.querySelector("textarea")
  textarea.value = composer.text
  textarea.addEventListener("input", () => { composer.text = textarea.value })
  textarea.addEventListener("keydown", event => {
    event.stopPropagation()
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) submitComposer(textarea.value)
    if (event.key === "Escape") cancelComposer()
  })
  node.addEventListener("click", event => {
    const act = event.target.closest("button")?.dataset.act
    if (act === "cancel") cancelComposer()
    if (act === "submit") submitComposer(textarea.value)
  })
  return node
}

function cancelComposer() {
  state.composer = null
  renderZones()
  diffEditor.getModifiedEditor().focus()
}

function renderZones() {
  clearZones()
  const shown = state.shown
  if (!shown?.changed || el.diffHost.hidden) return

  const composer = state.composer?.path === shown.path ? state.composer : null
  state.comments
    .filter(comment => comment.path === shown.path && comment.id !== composer?.id)
    .forEach(comment => mountZone(comment.endLine ?? comment.line, threadNode(comment)))
  if (composer == null) return

  const node = composerNode(composer)
  mountZone(composer.endLine, node)
  diffEditor.getModifiedEditor().revealLineInCenterIfOutsideViewport(composer.endLine)
  requestAnimationFrame(() => node.querySelector("textarea").focus())
}

function revealComment(id) {
  const comment = state.comments.find(c => c.id === id)
  if (comment == null) return

  openPath(comment.path, { line: comment.line, column: 1 })
}

function askSwift(message) {
  const reply = new Promise(resolve => {
    state.replies.set(message.id, resolve)
    setTimeout(() => resolve(null), REPLY_TIMEOUT)
  })
  window.webkit.messageHandlers.berth.postMessage(message)
  return reply.finally(() => state.replies.delete(message.id))
}

function fileArrival(path) {
  return new Promise(resolve => {
    state.fileWaiters.set(path, [...(state.fileWaiters.get(path) ?? []), resolve])
    setTimeout(resolve, REPLY_TIMEOUT)
    window.webkit.messageHandlers.berth.postMessage({ type: "readFile", path })
  })
}

async function ensureModels(paths) {
  const missing = [...new Set(paths)].filter(path => monaco.editor.getModel(fileURI(path)) == null)
  await Promise.all(missing.map(fileArrival))
}

async function guessLocations(kind, word) {
  const unread = [...state.files.values()].filter(file => file.letter !== "D" && file.additions != null).map(file => file.path)
  await ensureModels(unread.slice(0, HEURISTIC_FILE_LIMIT))

  const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const pattern = kind === "definition" ? `\\b(?:${DECLARATION_KEYWORDS})\\s+${escaped}\\b` : `(?<![\\w$])${escaped}(?![\\w$])`
  return monaco.editor.getModels()
    .filter(model => model.uri.scheme === "berth")
    .flatMap(model => model.findMatches(pattern, false, true, true, null, false, 200).map(match => ({
      uri: model.uri,
      range: new monaco.Range(match.range.endLineNumber, match.range.endColumn - word.length, match.range.endLineNumber, match.range.endColumn),
    })))
}

async function locate(kind, model, position) {
  const word = model.getWordAtPosition(position)
  if (word == null) return null

  const id = ++state.seq
  const answer = await askSwift({ type: kind, id, path: model.uri.path.slice(1), line: position.lineNumber, column: position.column, word: word.word })
  if (!Array.isArray(answer)) {
    const guesses = await guessLocations(kind, word.word)
    return guesses.length ? guesses : null
  }

  const located = answer.filter(location => typeof location?.path === "string" && location.line > 0)
  await ensureModels(located.map(location => location.path))
  return located
    .filter(location => monaco.editor.getModel(fileURI(location.path)) != null)
    .map(location => ({
      uri: fileURI(location.path),
      range: new monaco.Range(location.line, location.column ?? 1, location.endLine ?? location.line, location.endColumn ?? location.column ?? 1),
    }))
}

function openFromMonaco(source, resource, selectionOrPosition) {
  if (resource.scheme !== "berth" || source.getModel()?.uri.toString() === resource.toString()) return false

  const line = selectionOrPosition?.startLineNumber ?? selectionOrPosition?.lineNumber ?? 1
  const column = selectionOrPosition?.startColumn ?? selectionOrPosition?.column ?? 1
  openPath(resource.path.slice(1), { line, column })
  return true
}

function receive(message) {
  if (message?.type === "load") return receiveLoad(message)
  if (message?.type === "file") return receiveFile(message)
  if (message?.type === "theme") return applyTheme(message.theme)
  if (message?.type === "saved") return receiveSaved(message.path)
  if (message?.type === "reply") return state.replies.get(message.id)?.(message.locations ?? null)
  if (message?.type !== "error") return

  el.error.hidden = false
  el.error.textContent = String(message.message ?? "Something went wrong")
  el.error.title = el.error.textContent
}

function wireChrome() {
  el.compare.addEventListener("click", event => {
    const compare = event.target.closest("button[data-compare]")?.dataset.compare
    if (compare && compare !== state.load?.compare) window.webkit.messageHandlers.berth.postMessage({ type: "selectCompare", compare })
  })
  el.refresh.addEventListener("click", () => window.webkit.messageHandlers.berth.postMessage({ type: "refresh" }))
  el.modes.addEventListener("click", event => {
    const mode = event.target.closest("button[data-mode]")?.dataset.mode
    if (mode == null) return
    state.mode = mode
    try { localStorage.setItem(MODE_KEY, mode) } catch {}
    renderTree()
  })
  el.tree.addEventListener("click", event => {
    const row = event.target.closest(".sf")
    if (row?.dataset.folder != null) {
      state.expanded.set(`${state.mode}:${row.dataset.folder}`, !isFolderOpen(row.dataset.folder))
      return renderTree()
    }
    if (row?.dataset.path != null) openPath(row.dataset.path)
  })
  el.tree.addEventListener("keydown", event => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return
    event.preventDefault()
    moveSelection(event.key === "ArrowDown" ? 1 : -1)
  })
  el.clist.addEventListener("click", event => {
    const id = event.target.closest(".ci")?.dataset.id
    if (id != null) revealComment(id)
  })
  el.send.addEventListener("click", () => {
    window.webkit.messageHandlers.berth.postMessage({ type: "sendComments", comments: state.comments })
  })
  setInterval(renderFetched, 5000)
}

function wireEditors() {
  const shared = { automaticLayout: true, minimap: { enabled: false }, scrollBeyondLastLine: false, definitionLinkOpensInPeek: true, fixedOverflowWidgets: true, renderLineHighlight: "line" }
  diffEditor = monaco.editor.createDiffEditor(el.diffHost, {
    ...shared,
    theme: "berth",
    renderSideBySide: true,
    useInlineViewWhenSpaceIsLimited: false,
    originalEditable: false,
    readOnly: true,
    glyphMargin: true,
    renderMarginRevertIcon: false,
    renderGutterMenu: false,
    hideUnchangedRegions: { enabled: true, contextLineCount: 3, minimumLineCount: 3, revealLineCount: 20 },
  })
  viewer = monaco.editor.create(el.viewHost, { ...shared, readOnly: true, theme: "berth" })

  const modified = diffEditor.getModifiedEditor()
  const hoverGlyph = modified.createDecorationsCollection()
  modified.onMouseMove(event => {
    const line = event.target.position?.lineNumber
    const commentable = line != null && state.shown?.changed && state.composer == null
    hoverGlyph.set(commentable ? [{ range: new monaco.Range(line, 1, line, 1), options: { glyphMarginClassName: "add-comment-glyph" } }] : [])
  })
  modified.onMouseLeave(() => hoverGlyph.clear())
  modified.onMouseDown(event => {
    if (event.target.type !== monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN || event.target.position == null) return
    const line = event.target.position.lineNumber
    const [start, end] = selectedLines(modified) ?? [line, line]
    const inSelection = start <= line && line <= end && !modified.getSelection().isEmpty()
    openComposer(inSelection ? start : line, inSelection ? end : line)
  })
  modified.addAction({
    id: "berth.addComment",
    label: "Add Comment",
    keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyM],
    contextMenuGroupId: "navigation",
    run: editor => {
      const [start, end] = selectedLines(editor) ?? [1, 1]
      openComposer(start, end)
    },
  })
  modified.addAction({ id: "berth.save", label: "Save", keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS], run: save })
  modified.onDidLayoutChange(layout => state.zones.forEach(zone => {
    zone.node.style.left = `${layout.contentLeft}px`
    zone.node.style.width = `${layout.contentWidth}px`
  }))

  monaco.languages.typescript.typescriptDefaults.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: true })
  monaco.languages.typescript.javascriptDefaults.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: true })
  monaco.languages.registerDefinitionProvider("*", { provideDefinition: (model, position) => locate("definition", model, position) })
  monaco.languages.registerReferenceProvider("*", { provideReferences: (model, position) => locate("references", model, position) })
  monaco.editor.registerEditorOpener({ openCodeEditor: openFromMonaco })
}

function start() {
  try {
    state.mode = MODES.includes(localStorage.getItem(MODE_KEY)) ? localStorage.getItem(MODE_KEY) : state.mode
  } catch {}
  wireEditors()
  wireChrome()
  applyTheme()
  window.berth = { receive }
  window.webkit.messageHandlers.berth.postMessage({ type: "ready" })
}

const devHarness = new URLSearchParams(location.search).has("dev")
  ? new Promise(resolve => document.head.append(Object.assign(document.createElement("script"), { src: "dev.js", onload: resolve })))
  : Promise.resolve()

require.config({ paths: { vs: "vs" } })
devHarness.then(() => require(["vs/editor/editor.main"], start))
