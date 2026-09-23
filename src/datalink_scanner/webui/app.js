const $ = (selector) => document.querySelector(selector);
const badge = $("#connectionBadge");
const portSelect = $("#portSelect");
const questionCount = $("#questionCount");
const testName = $("#testName");
const connectButton = $("#connectButton");
const disconnectButton = $("#disconnectButton");
const activityList = $("#activityList");

let showProtocol = false;
let refreshTimer = null;
let lastPortSignature = "";
let connectionState = "disconnected";
let activeReviewId = null;
let activeRosterMatchIndex = -1;
let autoResolvingReviewId = null;

// Classes, the selected class and the test name live in the app's database,
// not in browser storage: the window's origin changes on every launch, so
// anything kept in localStorage would be gone by the next one.
let classes = [];
let selectedClassName = "";
let roster = [];
let rosterIndex = 0;
let studentMatching = "id";

function sameStudentId(left, right) {
  // The scanner writes the ID field as it was bubbled, which can carry leading
  // zeros a roster typed by hand does not. Comparing the two as plain strings
  // quietly failed to match, and the sheet fell back to roster order.
  const tidy = value => String(value ?? "").trim().replace(/^0+(?=\d)/, "");
  return Boolean(tidy(left)) && tidy(left) === tidy(right);
}

function rosterIndexForId(id) {
  return roster.findIndex(student => sameStudentId(student.id, id));
}
let editingClassName = "";
let currentView = "scan";
let currentSessionId = null;
// The loaded session, kept because correcting one answer means sending the
// whole row back: the server checks the response count against the form.
let openSessionDetail = null;
let editingCell = null;

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, character => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[character]);
}

function toast(message) {
  const node = $("#toast");
  node.textContent = message;
  node.classList.add("show");
  setTimeout(() => node.classList.remove("show"), 2800);
}

async function request(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Request failed");
  return data;
}

function post(path, body) {
  return request(path, {method: "POST", body: JSON.stringify(body)});
}

/* ------------------------------------------------------------------ views */

const VIEWS = ["scan", "paper", "classes", "sessions", "analysis", "settings"];
const ANALYSIS_PANES = ["items", "students", "review", "key", "upload"];

function showView(name) {
  if (!VIEWS.includes(name)) name = "scan";
  currentView = name;
  for (const button of document.querySelectorAll("#viewTabs button")) {
    button.classList.toggle("active", button.dataset.view === name);
  }
  for (const view of VIEWS) $(`#view-${view}`).hidden = view !== name;
  renderContextBar();
  if (name === "paper") loadPaper();
  if (name === "classes") loadClasses();
  if (name === "sessions") loadSessions();
  if (name === "analysis") loadAnalysisSessions();
  if (name === "settings") loadConnection();
}

/* --------------------------------------------------------------- routing */

// The address bar is the app's memory of where you are. Without it the back
// button did nothing, a reload dropped you on the Scan tab, and there was no
// way to point at "the review list for this test".
//
//   #/scan  #/paper  #/classes  #/settings
//   #/sessions              #/sessions/5
//   #/analysis              #/analysis/5        #/analysis/5/review
let applyingRoute = false;

function currentRoute() {
  const raw = location.hash.replace(/^#\/?/, "");
  const [view, id, pane] = raw.split("/").filter(Boolean);
  return {
    view: VIEWS.includes(view) ? view : "scan",
    id: /^\d+$/.test(id || "") ? Number(id) : null,
    pane: ANALYSIS_PANES.includes(pane) ? pane : null,
  };
}

function routeFor(view, id, pane) {
  return "#/" + [view, id ?? null, pane ?? null].filter(value => value !== null).join("/");
}

// `replace` for a redirect the user did not ask for, so Back does not land
// them on a route that immediately bounces them forward again.
function navigate(view, {id = null, pane = null, replace = false} = {}) {
  const target = routeFor(view, id, pane);
  if (location.hash === target) {
    applyRoute();
    return;
  }
  if (replace) location.replace(target);
  else location.hash = target;
}

async function applyRoute() {
  if (applyingRoute) return;
  applyingRoute = true;
  try {
    const {view, id, pane} = currentRoute();
    // A route must mean one thing however you reached it. On the two tabs that
    // own a test, no id in the address means no test selected — otherwise
    // Back to #/sessions left the previous one on screen while the address
    // said there was none, and a reload of that same URL showed something
    // different again.
    const ownsSession = view === "sessions" || view === "analysis";
    if (id !== null && id !== currentSessionId) await selectSession(id, {silent: true});
    else if (id === null && ownsSession && currentSessionId !== null) closeSession();
    showView(view);
    if (view === "sessions" && currentSessionId !== null) {
      await loadSessionDetail(currentSessionId, {reveal: false});
    }
    if (view === "analysis" && pane) showAnalysisPane(pane, {push: false});
  } finally {
    applyingRoute = false;
  }
}

window.addEventListener("hashchange", applyRoute);

/* ------------------------------------------------- the test being worked on */

let currentSessionName = "";
let currentSessionMeta = "";

// Choosing a test is one act, wherever it happens. Both tabs read this.
async function selectSession(id, {silent = false} = {}) {
  if (id === null) {
    closeSession();
    return;
  }
  currentSessionId = id;
  try {
    const summary = (await request("/api/sessions")).sessions.find(item => item.id === id);
    currentSessionName = summary?.name || "Untitled session";
    currentSessionMeta = summary
      ? [summary.class_name, `${summary.scan_count} sheets`, formatTimestamp(summary.started_at)]
          .filter(Boolean).join(" · ")
      : "";
  } catch (error) {
    currentSessionName = "Untitled session";
    currentSessionMeta = "";
  }
  renderContextBar();
  if (!silent) navigate(currentView === "analysis" ? "analysis" : "sessions", {id});
}

function renderContextBar() {
  const bar = $("#contextBar");
  const showing = currentSessionId !== null;
  bar.classList.toggle("hidden", !showing);
  if (!showing) return;
  $("#contextName").textContent = currentSessionName;
  $("#contextMeta").textContent = currentSessionMeta;
  $("#contextSheets").classList.toggle("active", currentView === "sessions");
  $("#contextAnalysis").classList.toggle("active", currentView === "analysis");
}

$("#contextSheets").addEventListener("click", () => navigate("sessions", {id: currentSessionId}));
$("#contextAnalysis").addEventListener("click", () => navigate("analysis", {id: currentSessionId}));
$("#contextClear").addEventListener("click", () => {
  closeSession();
  navigate(currentView);
});

for (const button of document.querySelectorAll("#viewTabs button")) {
  button.addEventListener("click", () => navigate(button.dataset.view, {
    // A tab that owns the selected test keeps it in the address.
    id: ["sessions", "analysis"].includes(button.dataset.view) ? currentSessionId : null,
  }));
}

/* ---------------------------------------------------------------- classes */

function selectedClass() {
  return classes.find(item => item.name === selectedClassName) || null;
}

function rosterProgress() {
  return JSON.parse(sessionStorage.getItem("datalinkRosterProgress") || "{}");
}

function saveRosterPosition() {
  const progress = rosterProgress();
  if (selectedClassName) progress[selectedClassName] = rosterIndex;
  sessionStorage.setItem("datalinkRosterProgress", JSON.stringify(progress));
}

function loadSelectedClass() {
  roster = selectedClass()?.students || [];
  rosterIndex = Number(rosterProgress()[selectedClassName] || 0);
}

function currentStudent() {
  return roster[rosterIndex] || null;
}

function advanceRoster() {
  if (rosterIndex < roster.length) rosterIndex += 1;
  saveRosterPosition();
}

function updateClassSelector() {
  const select = $("#classSelect");
  select.innerHTML = '<option value="">No roster</option>' + classes.map(item =>
    `<option value="${escapeHtml(item.name)}">${escapeHtml(item.name)}</option>`
  ).join("");
  select.value = selectedClassName;
}

function renderClassList() {
  $("#classEmptyState").classList.toggle("hidden", classes.length > 0);
  $("#classListWrap").classList.toggle("hidden", classes.length === 0);
  $("#classRows").innerHTML = classes.map(item => `
    <tr>
      <td><strong>${escapeHtml(item.name)}</strong></td>
      <td>${item.students.length}</td>
      <td>${item.name === selectedClassName ? "✓" : ""}</td>
      <td class="row-actions">
        <button class="ghost" data-select="${escapeHtml(item.name)}">Use for scanning</button>
        <button class="secondary" data-edit="${escapeHtml(item.name)}">Edit</button>
      </td>
    </tr>`).join("");

  for (const button of $("#classRows").querySelectorAll("[data-edit]")) {
    button.addEventListener("click", () => openClassEditor(button.dataset.edit));
  }
  for (const button of $("#classRows").querySelectorAll("[data-select]")) {
    button.addEventListener("click", () => selectClass(button.dataset.select));
  }
}

async function loadClasses() {
  const data = await request("/api/classes");
  classes = data.classes;
  if (!classes.some(item => item.name === selectedClassName)) selectedClassName = "";
  loadSelectedClass();
  updateClassSelector();
  renderClassList();
}

async function selectClass(name) {
  selectedClassName = name;
  await post("/api/settings", {selected_class: name});
  loadSelectedClass();
  updateClassSelector();
  renderClassList();
  updateExportName();
  toast(name ? `Scanning against ${name}` : "Roster turned off");
  refresh();
}

function openClassEditor(name) {
  const item = classes.find(entry => entry.name === name) || null;
  editingClassName = item ? item.name : "";
  $("#classEditorTitle").textContent = item ? "Edit class" : "Add a class";
  $("#classNameInput").value = item ? item.name : "";
  $("#rosterInput").value = item
    ? item.students.map(student => `${student.id}, ${student.name}`).join("\n")
    : "";
  $("#deleteClassButton").classList.toggle("hidden", !item);
  $("#classEditorCard").classList.remove("hidden");
  $("#classNameInput").focus();
}

function closeClassEditor() {
  $("#classEditorCard").classList.add("hidden");
  editingClassName = "";
}

function parseRoster(text) {
  const students = [];
  for (const line of text.split(/\r?\n/).map(entry => entry.trim()).filter(Boolean)) {
    const comma = line.indexOf(",");
    const id = (comma >= 0 ? line.slice(0, comma) : "").trim();
    const name = (comma >= 0 ? line.slice(comma + 1) : "").trim();
    if (!/^\d+$/.test(id) || !name) throw new Error(`Fix roster line: ${line}`);
    students.push({id, name});
  }
  return students;
}

$("#newClassButton").addEventListener("click", () => openClassEditor(null));
$("#cancelClassButton").addEventListener("click", closeClassEditor);

$("#classForm").addEventListener("submit", async event => {
  event.preventDefault();
  try {
    const students = parseRoster($("#rosterInput").value);
    const name = $("#classNameInput").value.trim();
    const data = await post("/api/classes/save", {
      name,
      students,
      original_name: editingClassName || null,
    });
    classes = data.classes;
    if (selectedClassName === editingClassName) selectedClassName = name;
    if (!selectedClassName) selectedClassName = name;
    await post("/api/settings", {selected_class: selectedClassName});
    loadSelectedClass();
    rosterIndex = 0;
    saveRosterPosition();
    updateClassSelector();
    renderClassList();
    updateExportName();
    closeClassEditor();
    toast(`Saved ${name} with ${students.length} students`);
    refresh();
  } catch (error) {
    toast(error.message);
  }
});

$("#deleteClassButton").addEventListener("click", async () => {
  if (!editingClassName || !confirm(`Delete the saved class “${editingClassName}”? Saved sessions are not affected.`)) return;
  const data = await post("/api/classes/delete", {name: editingClassName});
  classes = data.classes;
  if (selectedClassName === editingClassName) selectedClassName = "";
  loadSelectedClass();
  updateClassSelector();
  renderClassList();
  updateExportName();
  closeClassEditor();
  refresh();
});

$("#classSelect").addEventListener("change", event => selectClass(event.target.value));

/* --------------------------------------------------------------- sessions */

function formatTimestamp(value) {
  if (!value) return "—";
  const when = new Date(value);
  // An unparseable timestamp would otherwise render as "Invalid Date".
  if (Number.isNaN(when.getTime())) return "—";
  return when.toLocaleDateString([], {month: "short", day: "numeric"}) + " " +
    when.toLocaleTimeString([], {hour: "numeric", minute: "2-digit"});
}

function formatBytes(bytes) {
  if (!bytes) return "0 KB";
  const units = ["bytes", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

function renderStorage(report) {
  const since = report.oldest
    ? ` · oldest ${new Date(report.oldest).toLocaleDateString([], {month: "short", year: "numeric"})}`
    : "";
  $("#storageSummary").textContent =
    `${formatBytes(report.total_bytes)} in total — ${report.scans} sheets across ` +
    `${report.sessions} sessions, plus ${report.log_files} plain-text logs${since}.`;
  $("#storagePath").textContent = report.directory
    ? `Everything is kept in ${report.directory}. Deleting a session removes its scans and its log file.`
    : "";
}

async function loadStorage() {
  try { renderStorage(await request("/api/storage")); }
  catch (error) { $("#storageSummary").textContent = error.message; }
}

async function loadSessions() {
  const data = await request("/api/sessions");
  renderSessions(data.sessions);
  loadStorage();
}

$("#pruneButton").addEventListener("click", async () => {
  const days = Number($("#pruneAge").value);
  const label = $("#pruneAge").selectedOptions[0].textContent;
  const preview = await post("/api/storage/prune", {days, preview: true});
  if (!preview.count) {
    toast(`No sessions are older than ${label}`);
    return;
  }
  if (!confirm(`Delete ${preview.count} session(s) older than ${label}? Their scans and log files are removed for good.`)) return;
  const result = await post("/api/storage/prune", {days});
  renderSessions(result.sessions_list);
  renderStorage(result.storage);
  closeSession();
  toast(`Deleted ${result.sessions} session(s) and ${result.logs} log file(s)`);
});

$("#revealStorageButton").addEventListener("click", () => {
  if (window.datalinkNative) {
    window.webkit.messageHandlers.datalink.postMessage({action: "reveal"});
  } else {
    toast($("#storagePath").textContent || "No folder yet");
  }
});

function renderSessions(sessions) {
  $("#sessionEmptyState").classList.toggle("hidden", sessions.length > 0);
  $("#sessionListWrap").classList.toggle("hidden", sessions.length === 0);
  $("#sessionRows").innerHTML = sessions.map(item => `
    <tr>
      <td>${formatTimestamp(item.started_at)}</td>
      <td><strong>${escapeHtml(item.name || "Untitled")}</strong></td>
      <td>${escapeHtml(item.class_name || "—")}</td>
      <td>${item.scan_count}</td>
      <td class="row-actions">
        <button class="secondary" data-open="${item.id}">View</button>
        <button class="ghost" data-rename="${item.id}">Rename</button>
        <button class="ghost danger" data-delete="${item.id}">Delete</button>
      </td>
    </tr>`).join("");

  const rows = $("#sessionRows");
  for (const button of rows.querySelectorAll("[data-open]")) {
    button.addEventListener("click", () => openSession(Number(button.dataset.open)));
  }
  for (const button of rows.querySelectorAll("[data-rename]")) {
    button.addEventListener("click", async () => {
      const id = Number(button.dataset.rename);
      const existing = sessions.find(item => item.id === id);
      const name = prompt("Name this session", existing?.name || "");
      if (name === null) return;
      renderSessions((await post("/api/sessions/rename", {id, name})).sessions);
      if (currentSessionId === id) await loadSessionDetail(id);
    });
  }
  for (const button of rows.querySelectorAll("[data-delete]")) {
    button.addEventListener("click", async () => {
      const id = Number(button.dataset.delete);
      if (!confirm("Delete this saved session and all of its scans? This cannot be undone.")) return;
      renderSessions((await post("/api/sessions/delete", {id})).sessions);
      if (currentSessionId === id) closeSession();
      toast("Session deleted");
    });
  }
}

// Clicking a session is a navigation, so it goes through the address bar and
// Back works. loadSessionDetail() is what actually fills the card.
function openSession(id) {
  navigate("sessions", {id});
}

async function loadSessionDetail(id, {reveal = true} = {}) {
  const session = await request(`/api/sessions/${id}`);
  currentSessionId = id;
  openSessionDetail = session;
  renderContextBar();
  $("#sessionDetailCard").classList.remove("hidden");
  $("#sessionDetailTitle").textContent = session.name || "Untitled session";
  const parts = [
    formatTimestamp(session.started_at),
    session.class_name || "no class",
    `${session.scans.length} sheets`,
    `${session.question_count} questions per form`,
  ];
  $("#sessionDetailSummary").textContent = parts.join(" · ");
  const link = $("#sessionExportButton");
  link.href = `/api/sessions/${id}/export.csv`;
  link.download = `${session.name || "datalink-session"}.csv`;

  // Item analysis needs one answer key and at least one student sheet, so it
  // is not offered for a session that cannot produce it.
  const analysis = $("#sessionAnalysisButton");
  analysis.href = `/api/sessions/${id}/analysis.json`;
  analysis.download = `${session.name || "datalink-session"}.json`;
  analysis.classList.toggle("disabled", !session.analysis_available);
  analysis.title = session.analysis_available
    ? "Scores every sheet and writes the item analysis JSON for upload"
    : session.analysis_error || "";

  const columns = Math.max(session.question_count, ...session.scans.map(scan => scan.responses.length), 0);
  $("#sessionDetailHead").innerHTML =
    `<th>Scan</th><th>Student</th><th>Time</th><th>Answered</th>` +
    Array.from({length: columns}, (_, index) => `<th>Q${index + 1}</th>`).join("");
  $("#sessionDetailRows").innerHTML = session.scans.map(scan => {
    const label = scan.role === "key" ? "Key" : `Student ${scan.number - 1}`;
    const student = scan.student_name
      ? `${escapeHtml(scan.student_name)}<br><small>${escapeHtml(scan.student_id || "")}</small>`
      : escapeHtml(scan.student_id || "—");
    // Every response is clickable: the scanner is accurate but not perfect,
    // and a mark read as blank that was not needs to be fixable where it is
    // seen rather than by re-feeding the sheet.
    const cells = scan.responses.map((value, index) =>
      `<td class="response ${!value ? "blank" : value.length > 1 ? "multiple" : ""}"` +
      ` data-scan="${scan.number}" data-question="${index + 1}"` +
      ` title="Click to correct question ${index + 1}">${escapeHtml(value || "—")}</td>`
    ).join("");
    return `<tr><td>${label}</td><td>${student}</td>` +
      `<td>${formatTimestamp(scan.received_at)}</td><td>${scan.answered_count}</td>${cells}</tr>`;
  }).join("");
  // Only when the user asked for this card by clicking it. Arriving by link or
  // by Back should leave them at the top, where the navigation is.
  if (reveal) $("#sessionDetailCard").scrollIntoView({behavior: "smooth", block: "start"});
}

$("#sessionDetailRows").addEventListener("click", event => {
  const cell = event.target.closest("td.response");
  if (!cell || !openSessionDetail) return;
  const number = Number(cell.dataset.scan);
  const question = Number(cell.dataset.question);
  const scan = openSessionDetail.scans.find(item => item.number === number);
  if (!scan) return;
  editingCell = {number, question};
  const current = scan.responses[question - 1] || "";
  const who = scan.role === "key" ? "Answer key" : scan.student_name || scan.student_id || `Student ${number - 1}`;
  $("#answerTitle").textContent = `Question ${question}`;
  $("#answerIntro").textContent = current
    ? `${who} · read as ${current}. Choose what the sheet actually shows.`
    : `${who} · read as blank. Choose what the sheet actually shows, or confirm the blank.`;
  $("#answerChoices").innerHTML = ["A", "B", "C", "D", "E"].map(letter =>
    `<label class="review-choice"><input type="radio" name="answer" value="${letter}"` +
    `${letter === current ? " checked" : ""}><span>${letter}</span></label>`
  ).join("") +
    `<label class="review-choice"><input type="radio" name="answer" value=""` +
    `${current ? "" : " checked"}><span>Blank</span></label>`;
  $("#answerDialog").showModal();
});

$("#answerCancel").addEventListener("click", () => {
  editingCell = null;
  $("#answerDialog").close();
});

$("#answerForm").addEventListener("submit", async () => {
  if (!editingCell || !openSessionDetail) return;
  const {number, question} = editingCell;
  editingCell = null;
  const chosen = $("#answerChoices").querySelector("input:checked");
  const scan = openSessionDetail.scans.find(item => item.number === number);
  if (!chosen || !scan) return;
  const responses = scan.responses.slice();
  if (responses[question - 1] === chosen.value) {
    toast("That is already what is recorded");
    return;
  }
  responses[question - 1] = chosen.value;
  try {
    const result = await post("/api/sessions/correct", {
      session_id: currentSessionId,
      corrections: [{number, responses}],
    });
    toast(result.applied
      ? `Question ${question} saved as ${chosen.value || "blank"}`
      : "No change was made");
    await loadSessionDetail(currentSessionId);
  } catch (error) {
    toast(error.message);
  }
});

function closeSession() {
  currentSessionId = null;
  openSessionDetail = null;
  analysisReport = null;
  analysisReportId = null;
  for (const id of ["#reviewBadge", "#tabReviewBadge", "#contextReviewBadge"]) {
    $(id).classList.add("hidden");
  }
  $("#sessionDetailCard").classList.add("hidden");
  renderContextBar();
}

$("#sessionAnalysisButton").addEventListener("click", event => {
  if (event.currentTarget.classList.contains("disabled")) {
    event.preventDefault();
    toast(event.currentTarget.title || "Not available for this session");
  }
});

$("#closeSessionButton").addEventListener("click", closeSession);
$("#refreshSessionsButton").addEventListener("click", () => {
  loadSessions();
  toast("Sessions refreshed");
});

/* ------------------------------------------------------------- scan view */

function updateExportName() {
  const name = testName.value.trim();
  const className = selectedClassName.trim();
  const filename = [className, name].filter(Boolean).join(" - ") || "datalink-session";
  const query = new URLSearchParams({name: filename, class: className});
  $("#exportButton").href = `/api/export.csv?${query}`;
  $("#exportButton").download = `${filename}.csv`;
}

let testNameTimer = null;
testName.addEventListener("input", () => {
  updateExportName();
  clearTimeout(testNameTimer);
  testNameTimer = setTimeout(
    () => post("/api/settings", {test_name: testName.value.trim()}).catch(() => {}),
    400,
  );
});

const MIN_QUESTIONS = 1;
const MAX_QUESTIONS = 100;

function currentQuestionCount() {
  const value = Number.parseInt(questionCount.value, 10);
  if (!Number.isFinite(value)) return 50;
  return Math.min(Math.max(value, MIN_QUESTIONS), MAX_QUESTIONS);
}

// Clamp on the way out of the field rather than on every keystroke, so typing
// "100" does not fight the user after the first digit.
questionCount.addEventListener("change", () => {
  const clamped = currentQuestionCount();
  if (String(clamped) !== questionCount.value) {
    questionCount.value = clamped;
    toast(`Questions per form must be between ${MIN_QUESTIONS} and ${MAX_QUESTIONS}`);
  }
  post("/api/settings", {question_count: String(clamped)}).catch(() => {});
  refresh();
});

// Keep a bubble inside the window. Anchoring it to one edge in CSS only moves
// the problem to the other edge, so measure and nudge, then slide the arrow
// back the same distance so it still points at the button.
function placeHint(bubble) {
  const margin = 12;
  bubble.style.left = "0px";
  const rect = bubble.getBoundingClientRect();
  let shift = 0;
  if (rect.right > window.innerWidth - margin) {
    shift = window.innerWidth - margin - rect.right;
  }
  if (rect.left + shift < margin) shift = margin - rect.left;
  bubble.style.left = `${shift}px`;
  const arrow = Math.min(Math.max(12 - shift, 8), Math.max(rect.width - 14, 8));
  bubble.style.setProperty("--arrow-left", `${arrow}px`);
}

function closeHints(except) {
  for (const bubble of document.querySelectorAll(".hint-bubble.open")) {
    if (bubble === except) continue;
    bubble.classList.remove("open");
    bubble.parentElement.querySelector(".hint")?.setAttribute("aria-expanded", "false");
  }
}

for (const button of document.querySelectorAll("button.hint")) {
  const bubble = document.getElementById(button.getAttribute("aria-controls"));
  if (!bubble) continue;
  const wrap = button.closest(".hint-wrap") || button.parentElement;
  // Hover shows the bubble from CSS alone, so place it on the way in too.
  wrap.addEventListener("mouseenter", () => placeHint(bubble));
  // Leaving also drops a bubble that was opened by a click, so the hint never
  // lingers over the controls beside it.
  wrap.addEventListener("mouseleave", () => closeHints(null));
  button.addEventListener("focus", () => placeHint(bubble));
  button.addEventListener("blur", () => closeHints(null));
  button.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    const open = bubble.classList.toggle("open");
    button.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) placeHint(bubble);
    closeHints(open ? bubble : null);
  });
}

window.addEventListener("resize", () => {
  for (const bubble of document.querySelectorAll(".hint-bubble.open")) placeHint(bubble);
});

document.addEventListener("click", () => closeHints(null));
document.addEventListener("keydown", event => {
  if (event.key === "Escape") closeHints(null);
});

function updatePorts(ports) {
  const signature = JSON.stringify(ports);
  if (signature === lastPortSignature) return;
  lastPortSignature = signature;
  const selected = portSelect.value;
  portSelect.innerHTML = '<option value="">Auto-detect scanner</option>';
  for (const port of ports) {
    const option = document.createElement("option");
    option.value = port;
    option.textContent = port;
    portSelect.append(option);
  }
  if (ports.includes(selected)) portSelect.value = selected;
}

function render(state) {
  updatePorts(state.ports || []);
  connectionState = state.state;
  badge.className = `badge ${state.state}`;
  const labels = { disconnected: "Disconnected", connecting: "Connecting…", connected: state.scanning ? "Ready to scan" : "Connected · no session", error: "Needs attention" };
  badge.innerHTML = `<span></span>${labels[state.state] || state.state}`;
  const scanning = Boolean(state.scanning);
  const busy = state.state === "connecting";
  connectButton.disabled = busy || scanning;
  connectButton.textContent = state.state === "connected"
    ? "Start scanning session"
    : "Connect and start session";
  $("#endSessionButton").disabled = !scanning;
  // Clearing renumbers what is on screen, and while a session is running that
  // numbering is what gets saved. It says so rather than being dead.
  $("#clearButton").disabled = scanning;
  $("#clearButton").title = scanning
    ? "Not while a session is running — the sheets on screen are the ones being recorded"
    : "";
  $("#resetScannerButton").disabled = state.state !== "connected";
  disconnectButton.disabled = state.state === "disconnected";
  // The form length and the port belong to the session that is running, so
  // they are only locked while one is.
  portSelect.disabled = busy || state.state === "connected";
  questionCount.disabled = busy || scanning;
  $("#connectionDetail").textContent = state.error || (state.state === "connected"
    ? scanning
      ? `Session running on ${state.port}. Feed one sheet at a time.`
      : `Scanner ready on ${state.port}. No session is running.`
    : "Connect the scanner by USB, then select its serial port.");
  $("#scanCount").textContent = state.record_count;
  const latest = state.records[state.records.length - 1];
  $("#answerCount").textContent = latest ? `${latest.answered_count} / ${latest.responses.length}` : "—";
  $("#sessionFile").textContent = state.scanning
    ? (state.session_name || state.output_path?.split("/").pop() || "Running")
    : "Not started";
  const hasKey = state.records.some(record => record.role === "key");
  const next = currentStudent();
  const workflow = $("#workflowCard");
  workflow.classList.toggle("key-complete", hasKey);
  workflow.classList.toggle("key-needed", !hasKey);
  workflow.querySelector(".step-number").textContent = !scanning ? "1" : hasKey ? "✓" : "2";
  $("#workflowTitle").textContent = !scanning
    ? "Start a session"
    : hasKey
      ? next ? `Next: ${next.name}` : roster.length ? "Roster complete" : "Answer key captured"
      : "Scan the answer key first";
  $("#workflowDetail").textContent = !scanning
    ? "Name the test, pick the class, then press Start. Nothing is recorded until a session is running."
    : hasKey
      ? next ? `Roster #${next.id} · Feed ${next.name}'s sheet now.` : roster.length ? "Every student on the roster has been handled." : "The session is ready for student sheets. Feed them one at a time."
      : "After the scanner says Ready to scan, feed the marked answer key before any student sheets.";
  $("#skipStudentButton").classList.toggle("hidden", !scanning || !hasKey || !next);
  $("#rosterSummary").textContent = roster.length
    ? `${selectedClassName} · ${roster.length} students · ${Math.min(rosterIndex, roster.length)} handled · ${Math.max(roster.length - rosterIndex, 0)} remaining`
    : "No saved roster. Student IDs will be entered manually.";
  $("#resetRosterButton").classList.toggle("hidden", !roster.length || rosterIndex === 0);
  renderRecords(state.records);
  renderActivity(state.activity);
  renderReview(state.pending_review);
}

function renderReview(review) {
  const dialog = $("#reviewDialog");
  if (!review) {
    activeReviewId = null;
    activeRosterMatchIndex = -1;
    autoResolvingReviewId = null;
    if (dialog.open) dialog.close();
    return;
  }
  // "By bubbled ID" is what lets sheets be fed in any order: the ID decides who
  // the sheet belongs to and the name is filled in afterwards. Roster order
  // ignores the ID area entirely, for sheets where it was left blank.
  const useScannerId = studentMatching === "id" && Boolean(review.scanner_id);
  const detectedRosterIndex = useScannerId ? rosterIndexForId(review.scanner_id) : -1;
  const canAutoSave = studentMatching === "id"
    && review.student_id_required && review.scanner_id && review.ambiguities.length === 0
    && (!roster.length || detectedRosterIndex >= 0);
  if (canAutoSave) {
    if (autoResolvingReviewId !== review.id) {
      autoResolvingReviewId = review.id;
      saveDetectedStudent(review);
    }
    return;
  }
  if (activeReviewId === review.id && dialog.open) return;
  activeReviewId = review.id;
  const label = review.role === "key" ? "answer key" : `student sheet ${review.number - 1}`;
  activeRosterMatchIndex = useScannerId ? rosterIndexForId(review.scanner_id) : rosterIndex;
  const next = !review.student_id_required || studentMatching === "manual"
    ? null
    : useScannerId
      ? roster[activeRosterMatchIndex] || null
      : currentStudent();
  const hasAmbiguities = review.ambiguities.length > 0;
  $("#reviewDialog h2").textContent = next ? `Confirm ${next.name}` : hasAmbiguities ? "Check the scan" : "Enter the student ID";
  $("#reviewIntro").textContent = hasAmbiguities
    ? `The scanner found more than one mark on the ${label}. Please resolve each item before continuing.`
    : useScannerId
      ? roster.length && activeRosterMatchIndex < 0
        ? `ID ${review.scanner_id} is not in ${selectedClassName}. Check the sheet or save it as an unlisted student.`
        : `The scanner read ID ${review.scanner_id}. Confirm the student before continuing.`
      : `The ${label} was captured. Enter the ID bubbled on the sheet before scanning the next student.`;
  $("#studentIdField").classList.toggle("hidden", !review.student_id_required);
  $("#studentIdInput").value = (useScannerId && review.scanner_id) || (next ? next.id : "");
  $("#studentNameInput").value = next ? next.name : "";
  $("#studentIdInput").required = review.student_id_required;
  $("#reviewNote").classList.toggle("hidden", !hasAmbiguities);
  $("#reviewQuestions").innerHTML = review.ambiguities.map(item => {
    const choices = item.options.map((choice, index) =>
      `<label class="review-choice"><input type="radio" name="q${item.question}" value="${choice}" ${index === 0 ? "checked" : ""}><span>${choice}</span></label>`
    ).join("");
    return `<fieldset data-question="${item.question}"><legend>Question ${item.question} was read as <strong>${item.value}</strong></legend><div class="review-choices">${choices}<label class="review-choice"><input type="radio" name="q${item.question}" value=""><span>Blank</span></label><label class="review-choice"><input type="radio" name="q${item.question}" value="${item.value}"><span>Keep ${item.value}</span></label></div></fieldset>`;
  }).join("");
  if (!dialog.open) dialog.showModal();
  if (review.student_id_required) setTimeout(() => $("#studentIdInput").focus(), 50);
}

async function saveDetectedStudent(review) {
  const matchIndex = rosterIndexForId(review.scanner_id);
  const match = roster[matchIndex] || null;
  try {
    const state = await post("/api/resolve-review", {
      id: review.id,
      resolutions: {},
      student_id: review.scanner_id,
      student_name: match ? match.name : "",
    });
    if (matchIndex >= 0) {
      rosterIndex = matchIndex + 1;
      saveRosterPosition();
    }
    toast(match ? `Captured ${match.name} · ${review.scanner_id}` : `Captured ID ${review.scanner_id}`);
    render(state);
  } catch (error) {
    autoResolvingReviewId = null;
    toast(error.message);
  }
}

function renderRecords(records) {
  $("#emptyState").classList.toggle("hidden", records.length > 0);
  $("#tableWrap").classList.toggle("hidden", records.length === 0);
  const head = $("#tableHead");
  const columns = Math.max(currentQuestionCount(), ...records.map(record => record.responses.length));
  head.innerHTML = `<th>Scan</th><th>Student ID</th><th>Time</th>${Array.from({length: columns}, (_, i) => `<th>Q${i + 1}</th>`).join("")}`;
  $("#recordRows").innerHTML = records.slice().reverse().map(record => {
    const time = new Date(record.received_at).toLocaleTimeString([], {hour: "numeric", minute: "2-digit", second: "2-digit"});
    const cells = record.responses.map(value => `<td class="${!value ? "blank" : value.length > 1 ? "multiple" : ""}">${value || "—"}</td>`).join("");
    const label = record.role === "key" ? "Key" : `Student ${record.number - 1}`;
    const student = record.student_name ? `${escapeHtml(record.student_name)}<br><small>${escapeHtml(record.student_id || "")}</small>` : escapeHtml(record.student_id || "—");
    return `<tr><td>${label}</td><td>${student}</td><td>${time}</td>${cells}</tr>`;
  }).join("");
}

function renderActivity(activity) {
  const visible = activity.filter(item => showProtocol || item.kind !== "protocol");
  activityList.innerHTML = visible.length ? visible.map(item =>
    `<li><time>${item.time}</time><span class="${item.kind}">${escapeHtml(item.message)}</span></li>`
  ).join("") : '<li class="muted">Waiting for activity.</li>';
}

async function refresh() {
  try { render(await request("/api/status")); }
  catch (error) { $("#connectionDetail").textContent = error.message; }
}

connectButton.addEventListener("click", async () => {
  connectButton.disabled = true;
  try {
    // One press for the common case: bring the scanner up if it is not up
    // already, then open the session on top of it.
    if (connectionState !== "connected") {
      await post("/api/connect", {port: portSelect.value, question_count: currentQuestionCount(), acknowledge_writes: true});
    }
    rosterIndex = 0;
    saveRosterPosition();
    render(await post("/api/session/start", {question_count: currentQuestionCount()}));
    toast("Session started \u00b7 feed the answer key first");
  } catch (error) { toast(error.message); await refresh(); }
});

$("#endSessionButton").addEventListener("click", async () => {
  if (!confirm("End this session? The sheets already captured stay saved under Sessions.")) return;
  try {
    const state = await post("/api/session/end", {});
    render(state);
    toast(state.summary?.message || "Session ended");
  } catch (error) { toast(error.message); }
});

$("#resetScannerButton").addEventListener("click", async () => {
  try {
    render(await post("/api/scanner/reset", {}));
    toast("Scanner reset \u00b7 re-feed the sheet that jammed");
  } catch (error) { toast(error.message); }
});

disconnectButton.addEventListener("click", async () => {
  try { render(await post("/api/disconnect", {})); }
  catch (error) { toast(error.message); }
});

$("#clearButton").addEventListener("click", async () => {
  if (confirm("Clear the scans shown here? The saved session is not deleted.")) {
    render(await post("/api/clear", {}));
  }
});

$("#toggleProtocol").addEventListener("click", () => {
  showProtocol = !showProtocol;
  $("#toggleProtocol").textContent = showProtocol ? "Hide protocol details" : "Show protocol details";
  refresh();
});

$("#reviewForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const resolutions = {};
  for (const fieldset of $("#reviewQuestions").querySelectorAll("fieldset")) {
    const selected = fieldset.querySelector("input:checked");
    resolutions[fieldset.dataset.question] = selected ? selected.value : "";
  }
  $("#saveReviewButton").disabled = true;
  try {
    const wasStudent = !$("#studentIdField").classList.contains("hidden");
    const state = await post("/api/resolve-review", {id: activeReviewId, resolutions, student_id: $("#studentIdInput").value, student_name: $("#studentNameInput").value});
    if (wasStudent && roster.length && activeRosterMatchIndex >= 0) {
      rosterIndex = activeRosterMatchIndex + 1;
      saveRosterPosition();
    }
    render(state);
  } catch (error) {
    toast(error.message);
  } finally {
    $("#saveReviewButton").disabled = false;
  }
});

$("#skipStudentButton").addEventListener("click", () => {
  const skipped = currentStudent();
  if (!skipped) return;
  advanceRoster();
  toast(`Skipped ${skipped.name}`);
  refresh();
});

$("#resetRosterButton").addEventListener("click", () => {
  rosterIndex = 0;
  saveRosterPosition();
  refresh();
});

$("#quitButton").addEventListener("click", async () => {
  if (!confirm("Stop DataLink Scanner? The scanner will be disconnected and this page will stop updating. Saved sessions are not deleted.")) return;
  $("#quitButton").disabled = true;
  try {
    await post("/api/quit", {});
  } catch (error) {
    // The server can close the connection before the response lands; that
    // still means it is shutting down.
  }
  clearInterval(refreshTimer);
  document.body.classList.add("stopped");
  $("#connectionDetail").textContent = "DataLink Scanner has stopped. You can close this tab.";
  badge.className = "badge disconnected";
  badge.innerHTML = "<span></span>Stopped";
});

/* ------------------------------------------------------- native menu bar */

window.datalinkMenu = {
  connect: () => connectButton.disabled || connectButton.click(),
  endSession: () => $("#endSessionButton").disabled || $("#endSessionButton").click(),
  resetScanner: () => $("#resetScannerButton").disabled || $("#resetScannerButton").click(),
  disconnect: () => disconnectButton.disabled || disconnectButton.click(),
  clearView: () => $("#clearButton").click(),
  exportCsv: () => (currentView === "sessions" && currentSessionId !== null
    ? $("#sessionExportButton") : $("#exportButton")).click(),
  exportAnalysis: () => {
    if (currentView !== "sessions" || currentSessionId === null) {
      toast("Open a saved session first, then export its item analysis");
      return;
    }
    $("#sessionAnalysisButton").click();
  },
  newClass: () => { navigate("classes"); openClassEditor(null); },
  editClass: () => { navigate("classes"); openClassEditor(selectedClassName); },
  skipStudent: () => $("#skipStudentButton").click(),
  startAtFirst: () => $("#resetRosterButton").click(),
  toggleProtocol: () => $("#toggleProtocol").click(),
  showScan: () => navigate("scan"),
  showPaper: () => navigate("paper"),
  choosePaperPdf: () => { navigate("paper"); $("#paperChooseButton").click(); },
  showClasses: () => navigate("classes"),
  showSessions: () => navigate("sessions", {id: currentSessionId}),
  showAnalysis: () => navigate("analysis", {id: currentSessionId}),
  showSettings: () => navigate("settings"),
};

if (window.datalinkNative) {
  // Cmd-Q quits properly in the native shell, so the in-page button is both
  // redundant and misleading: it would stop the server and leave a live window
  // showing a dead page.
  $("#quitButton").remove();
  document.body.classList.add("native");
  // A WKWebView will not act on <a download>, so hand exports to the app and
  // let it put up a real Save panel.
  for (const id of ["exportButton", "sessionExportButton", "sessionAnalysisButton"]) {
    $(`#${id}`).addEventListener("click", event => {
      event.preventDefault();
      const link = $(`#${id}`);
      if (link.classList.contains("disabled")) {
        toast(link.title || "Not available for this session");
        return;
      }
      const url = new URL(link.getAttribute("href"), location.origin);
      window.webkit.messageHandlers.datalink.postMessage({
        action: "export",
        path: url.pathname,
        query: url.search.replace(/^\?/, ""),
        filename: link.download || "datalink-session.csv",
      });
    });
  }
}


/* --------------------------------------------------------------- analysis */

// The same cut points the omr_final results page uses, so an item that reads
// as Priority there reads as Priority here.
const PRIORITY_BELOW = 60;
const SECURE_AT = 70;

let analysisReport = null;
let analysisReportId = null;
let itemFilter = "all";

function itemStatus(item) {
  if (item.percent_correct < PRIORITY_BELOW) return "priority";
  if (item.percent_correct < SECURE_AT) return "developing";
  return "secure";
}

function statusLabel(status) {
  return {priority: "Priority", developing: "Developing", secure: "Secure"}[status];
}

async function loadAnalysisSessions() {
  const {sessions} = await request("/api/sessions");
  const select = $("#analysisSession");
  select.innerHTML = '<option value="">Choose a test…</option>' + sessions.map(item =>
    `<option value="${item.id}">${escapeHtml(item.name || "Untitled")} · ` +
    `${formatTimestamp(item.started_at)} · ${item.scan_count} sheets</option>`
  ).join("");
  // A test already chosen elsewhere is the one to show. Asking for it again
  // was the single most tiresome thing about moving between these two tabs.
  const wanted = String(currentSessionId ?? "");
  if (sessions.some(item => String(item.id) === wanted)) {
    select.value = wanted;
    if (analysisReportId !== wanted) {
      await loadAnalysis(wanted);
    }
  } else {
    select.value = "";
    showAnalysisPlaceholder("No test selected");
  }
}

function showAnalysisPlaceholder(message, error) {
  analysisReport = null;
  $("#analysisBody").classList.add("hidden");
  $("#analysisDownload").classList.add("hidden");
  $("#analysisEmptyState").classList.toggle("hidden", Boolean(error));
  $("#analysisEmptyState").querySelector("h3").textContent = message;
  const banner = $("#analysisError");
  banner.classList.toggle("hidden", !error);
  banner.textContent = error || "";
}

async function loadAnalysis(sessionId) {
  if (!sessionId) {
    analysisReportId = null;
    showAnalysisPlaceholder("No test selected");
    return;
  }
  try {
    analysisReport = await request(`/api/sessions/${sessionId}/analysis`);
    analysisReportId = String(sessionId);
  } catch (error) {
    analysisReportId = null;
    showAnalysisPlaceholder("This test cannot be scored", error.message);
    return;
  }
  $("#analysisError").classList.add("hidden");
  $("#analysisEmptyState").classList.add("hidden");
  $("#analysisBody").classList.remove("hidden");
  const download = $("#analysisDownload");
  download.classList.remove("hidden");
  download.href = `/api/sessions/${sessionId}/analysis.json`;
  download.download = `${analysisReport.exam.name || "analysis"}.json`;
  renderAnalysis(analysisReport);
}

function renderAnalysis(report) {
  const summary = report.summary;
  $("#statStudents").textContent = summary.student_count;
  $("#statAverage").textContent =
    summary.mean_percentage === null ? "—" : `${summary.mean_percentage}%`;
  $("#statKr20").textContent = summary.kr20 === null ? "—" : summary.kr20;
  $("#statReview").textContent = report.review_items.length;

  const counts = {priority: 0, developing: 0, secure: 0, flagged: 0};
  for (const item of report.items) {
    counts[itemStatus(item)] += 1;
    if (item.flags.length) counts.flagged += 1;
  }
  $("#countPriority").textContent = counts.priority;
  $("#countDeveloping").textContent = counts.developing;
  $("#countSecure").textContent = counts.secure;
  $("#countFlagged").textContent = counts.flagged;

  const callout = $("#priorityCallout");
  const priorityItems = report.items.filter(item => itemStatus(item) === "priority");
  callout.classList.toggle("hidden", priorityItems.length === 0);
  if (priorityItems.length) {
    const numbers = priorityItems.map(item => item.question).join(", ");
    callout.textContent =
      `Focus first on item${priorityItems.length === 1 ? "" : "s"} ${numbers}. ` +
      `Fewer than ${PRIORITY_BELOW}% of students answered ${priorityItems.length === 1 ? "it" : "each"} correctly.`;
  }

  renderItems();
  renderDiagnostics(report);
  renderStudentScores(report);
  renderAnalysisReview(report);
  renderAnswerKey(report);
  $("#uploadSuccess").classList.add("hidden");
  $("#uploadError").classList.add("hidden");
  renderUploadPicker();
  showAnalysisPane(analysisPane);
}

function renderItems() {
  const items = (analysisReport?.items || []).filter(item =>
    itemFilter === "all" ? true
      : itemFilter === "flagged" ? item.flags.length > 0
      : itemStatus(item) === itemFilter);
  $("#itemEmpty").classList.toggle("hidden", items.length > 0);
  $("#itemRows").innerHTML = items.map(item => {
    const status = itemStatus(item);
    const width = Math.max(0, Math.min(100, item.percent_correct));
    return `<tr>
      <td><strong>${item.question}</strong></td>
      <td>${escapeHtml(item.correct_answer)}</td>
      <td class="bar-cell">
        <span class="bar ${status}"><span style="width:${width}%"></span></span>
        <span class="bar-value">${item.percent_correct.toFixed(1)}%</span>
      </td>
      <td>${item.n_correct}</td>
      <td>${item.most_common_wrong ? escapeHtml(item.most_common_wrong) : "—"}</td>
      <td><span class="pill ${status}">${statusLabel(status)}</span>${item.flags.length ? ' <span class="pill flagged">Flagged</span>' : ""}</td>
    </tr>`;
  }).join("");
}

function renderDiagnostics(report) {
  const choices = ["A", "B", "C", "D", "E", "BLANK", "MULTIPLE"];
  $("#diagnosticsHead").innerHTML =
    "<th>Item</th><th>Key</th><th>% correct</th><th>Difficulty</th>" +
    "<th>Point biserial</th><th>Upper−lower</th>" +
    choices.map(choice => `<th>${choice === "MULTIPLE" ? "Mult" : choice} %</th>`).join("") +
    "<th>Flags</th>";
  const number = value => (value === null || value === undefined ? "—" : value);
  $("#diagnosticsRows").innerHTML = report.items.map(item => `
    <tr>
      <td><strong>${item.question}</strong></td>
      <td>${escapeHtml(item.correct_answer)}</td>
      <td>${item.percent_correct.toFixed(1)}</td>
      <td>${number(item.difficulty)}</td>
      <td>${number(item.point_biserial)}</td>
      <td>${number(item.upper_lower_discrimination)}</td>
      ${choices.map(choice => `<td>${item.distribution[choice].pct}</td>`).join("")}
      <td>${item.flags.length ? escapeHtml(item.flags.join(", ")) : "—"}</td>
    </tr>`).join("");
}

function renderStudentScores(report) {
  const rows = [...report.students].sort(
    (a, b) => b.score.percentage - a.score.percentage
  );
  $("#studentScoreRows").innerHTML = rows.map(row => `
    <tr>
      <td>${escapeHtml(row.student_name || "—")}</td>
      <td>${escapeHtml(row.student_id || row.student_id_read || "—")}</td>
      <td>${row.score.correct} / ${row.score.total}</td>
      <td>${row.score.percentage}%</td>
      <td>${row.score.blank}</td>
      <td>${row.score.multiple}</td>
      <td class="missed">${row.score.missed_questions.length ? row.score.missed_questions.join(", ") : "—"}</td>
    </tr>`).join("");
}

$("#analysisSession").addEventListener("change", event => {
  const value = event.target.value;
  if (value) selectSession(Number(value));
  else { closeSession(); navigate("analysis"); }
});

for (const button of document.querySelectorAll("#itemFilters button")) {
  button.addEventListener("click", () => {
    itemFilter = button.dataset.filter;
    for (const other of document.querySelectorAll("#itemFilters button")) {
      other.classList.toggle("active", other === button);
    }
    renderItems();
  });
}

$("#toggleDiagnostics").addEventListener("click", () => {
  const wrap = $("#diagnosticsWrap");
  const hidden = wrap.classList.toggle("hidden");
  $("#toggleDiagnostics").textContent = hidden ? "Show diagnostics" : "Hide diagnostics";
});

$("#analysisDownload").addEventListener("click", event => {
  if (!window.datalinkNative) return;
  event.preventDefault();
  const link = $("#analysisDownload");
  const url = new URL(link.getAttribute("href"), location.origin);
  window.webkit.messageHandlers.datalink.postMessage({
    action: "export",
    path: url.pathname,
    query: "",
    filename: link.download,
  });
});


/* ------------------------------------------------- analysis sub-sections */

let analysisPane = "items";
let editedKey = null;

function showAnalysisPane(name, {push = true} = {}) {
  analysisPane = name;
  if (push && currentSessionId !== null && !applyingRoute) {
    const target = routeFor("analysis", currentSessionId, name);
    if (location.hash !== target) location.replace(target);
  }
  for (const button of document.querySelectorAll("#analysisTabs button")) {
    button.classList.toggle("active", button.dataset.pane === name);
  }
  // Direct children only: the sub-tab buttons carry data-pane too, and a
  // descendant selector would hide every tab but the active one.
  for (const pane of document.querySelectorAll("#analysisBody > [data-pane]")) {
    pane.hidden = pane.dataset.pane !== name;
  }
}

for (const button of document.querySelectorAll("#analysisTabs button")) {
  button.addEventListener("click", () => showAnalysisPane(button.dataset.pane));
}

/* ------------------------------------------------------------------ review */

// Must match review_key() in analysis.py: page, field, question, reason.
function reviewKey(item) {
  return [item.page, item.field, item.question || 0, item.reason || ""].join(":");
}

function reviewProblems(report) {
  // One row per thing a human has to decide, keyed to the sheet it came from.
  const bySheet = new Map(report.students.map(row => [row.page, row]));
  const rows = [];
  for (const item of report.review_items) {
    const student = bySheet.get(item.page);
    if (item.field === "student_id") {
      rows.push({
        sheet: item.page,
        student,
        key: reviewKey(item),
        kind: "student_id",
        problem: "No student ID was read",
        read: student?.student_id_read || "—",
      });
    } else if (item.field === "answer") {
      const answer = student?.answers?.find(entry => entry.question === item.question);
      // A faint mark and a double mark are different problems and want
      // different words: one is "which of these did they mean", the other is
      // "is this a mark at all".
      const faint = item.reason === "faint";
      rows.push({
        sheet: item.page,
        student,
        key: reviewKey(item),
        kind: "answer",
        question: item.question,
        problem: faint
          ? `Question ${item.question} is much lighter than this student's other marks — check it is not a stray mark or an erasure`
          : `Question ${item.question} has more than one mark`,
        read: answer ? answer.response : "MULTIPLE",
      });
    } else if (item.field === "sheet") {
      // Nothing to correct: the whole sheet read faint, so the point is that
      // every answer on it is worth a glance, not that one of them is wrong.
      rows.push({
        sheet: item.page,
        student,
        key: reviewKey(item),
        kind: "note",
        problem: item.reason === "pending_review"
          ? "This sheet was saved before live review finished. Check its student ID and answers."
          : `Every mark on this sheet is light (${item.value} of them). Worth checking the sheet against the screen.`,
        read: item.reason === "pending_review" ? "Review pending" : "faint",
      });
    }
  }
  return rows.sort((a, b) => a.sheet - b.sheet || (a.question || 0) - (b.question || 0));
}

function renderAnalysisReview(report) {
  const rows = reviewProblems(report);
  for (const id of ["#reviewBadge", "#tabReviewBadge", "#contextReviewBadge"]) {
    const badge = $(id);
    badge.textContent = rows.length;
    badge.classList.toggle("hidden", rows.length === 0);
  }
  $("#reviewEmpty").classList.toggle("hidden", rows.length > 0);
  $("#reviewWrap").classList.toggle("hidden", rows.length === 0);
  $("#applyReviewButton").disabled = rows.length === 0;
  $("#dismissAllButton").disabled = rows.length === 0;

  // Settling an item hides it, so say so and offer the way back.
  const settled = Number(report.dismissed_count || 0);
  $("#reviewDismissedLine").classList.toggle("hidden", settled === 0);
  $("#reviewDismissedCount").textContent =
    `${settled} item${settled === 1 ? "" : "s"} checked off and hidden. `;

  // One sheet can raise several problems. Its ID and name are the sheet's, not
  // the problem's, so they are edited once and sent once however many rows it
  // has — otherwise two rows for the same sheet would fight over the value.
  const firstRowForSheet = new Map();
  const problemsPerSheet = new Map();
  for (const row of rows) {
    if (!firstRowForSheet.has(row.sheet)) firstRowForSheet.set(row.sheet, row);
    problemsPerSheet.set(row.sheet, (problemsPerSheet.get(row.sheet) || 0) + 1);
  }

  $("#reviewRows").innerHTML = rows.map(row => {
    // One sheet can raise several problems, and its ID and name belong to the
    // sheet rather than to any one of them. The cells span the sheet's rows
    // instead of being drawn once and leaving the rest blank, which read as a
    // dropdown that had gone missing.
    const owns = firstRowForSheet.get(row.sheet) === row;
    const span = problemsPerSheet.get(row.sheet) > 1
      ? ` rowspan="${problemsPerSheet.get(row.sheet)}"`
      : "";
    const student = row.student || {};
    const sheet = report.has_pages
      ? `<button type="button" class="link-button" data-sheet-view="${row.sheet}"
                 title="Open the page this sheet was read from">${row.sheet}</button>`
      : `<strong>${row.sheet}</strong>`;
    // The ID the reader saw, even when it was not sure enough to use it: that
    // is the likeliest starting point for a correction, not an empty box.
    const idValue = student.student_id || student.student_id_read || "";
    const who = `<input type="text" inputmode="numeric" pattern="[0-9]*" placeholder="Student ID"
                class="cell-input" data-edit="student_id" data-sheet="${row.sheet}"
                value="${escapeHtml(idValue)}">`;
    const named = nameControl(report.class_name, student, row.sheet);
    const control = row.kind === "note"
      ? "—"
      : row.kind === "student_id"
      ? "—"
      : `<select data-fix="answer" data-sheet="${row.sheet}" data-question="${row.question}">
           <option value="">Keep as read</option>
           ${[..."ABCDE"].map(letter => `<option value="${letter}">${letter}</option>`).join("")}
           <option value="BLANK">Blank</option>
         </select>`;
    const sheetCells = owns
      ? `<td${span}>${sheet}</td><td${span}>${who}</td><td${span}>${named}</td>`
      : "";
    return `<tr>
      ${sheetCells}
      <td>${escapeHtml(row.problem)}</td>
      <td><code>${escapeHtml(row.read)}</code></td>
      <td>${control}</td>
      <td><input type="checkbox" class="review-check" data-done="${escapeHtml(row.key)}"
                 aria-label="Checked — clear this from the list"></td>
    </tr>`;
  }).join("");

  for (const button of document.querySelectorAll("#reviewRows [data-sheet-view]")) {
    button.addEventListener("click", () => showSheet(Number(button.dataset.sheetView)));
  }
  for (const select of document.querySelectorAll("#reviewRows [data-pick]")) {
    select.addEventListener("change", () => chooseStudent(select, report.class_name));
  }
  for (const field of document.querySelectorAll('#reviewRows [data-edit="student_id"]')) {
    // While the digits are still going in, a half-typed ID is not yet a
    // missing one, so the name fills quietly and only says it found nothing
    // once the field is left.
    field.addEventListener("input", () => fillNameFromRoster(field, report.class_name));
    field.addEventListener("blur", () => fillNameFromRoster(field, report.class_name, true));
    // An ID the reader already got right should bring its name in without
    // anyone having to retype the ID to trigger it.
    fillNameFromRoster(field, report.class_name);
  }
}

// Typing an ID should bring its name with it. The roster is the one this test
// was scanned against, not whichever class the Scan tab is pointed at now.
function fillNameFromRoster(idField, className, announce = false) {
  const row = idField.closest("tr");
  const nameField = row?.querySelector('[data-edit="student_name"]');
  if (!nameField) return;
  const list = (classes.find(item => item.name === className) || {}).students || [];
  // Never overwrite a name the teacher typed: only a blank box, or one this
  // filled in itself and so is free to replace.
  const ours = nameField.dataset.fromRoster === "1";
  if (nameField.value.trim() && !ours) return;

  const picker = row.querySelector("[data-pick]");
  const match = list.find(student => sameStudentId(student.id, idField.value));
  if (match) {
    nameField.value = match.name;
    nameField.dataset.fromRoster = "1";
    nameField.placeholder = "Student name";
    if (picker) {
      picker.value = String(match.id);
      nameField.classList.add("hidden");
    }
    return;
  }
  if (picker) {
    picker.value = "";
    nameField.classList.remove("hidden");
  }
  if (ours) {
    nameField.value = "";
    delete nameField.dataset.fromRoster;
  }
  nameField.placeholder = announce && className && idField.value.trim()
    ? `Not on ${className} — type the name`
    : "Student name";
}

function nameControl(className, student, sheet) {
  // With a roster, the name is a choice from the class rather than something
  // to retype: an ID the reader got wrong cannot be looked up, and the
  // teacher knows who the sheet belongs to by looking at it.
  const list = (classes.find(item => item.name === className) || {}).students || [];
  const chosen = list.find(entry => entry.name === student.student_name);
  // The box is what gets saved, so it is always there — but while a roster
  // student is chosen it would only repeat the dropdown, so it is kept out of
  // the way until the answer is someone the roster does not have.
  const input = `<input type="text" placeholder="Student name"
            class="cell-input ${list.length && chosen ? "hidden" : ""}"
            data-edit="student_name" data-sheet="${sheet}"
            value="${escapeHtml(student.student_name || "")}">`;
  if (!list.length) return input;
  const options = list.map(entry =>
    `<option value="${escapeHtml(entry.id)}" ${chosen === entry ? "selected" : ""}>${escapeHtml(entry.name)}</option>`
  ).join("");
  return `<div class="name-cell"><select class="cell-input" data-pick="student" data-sheet="${sheet}">
      <option value="">${student.student_name ? escapeHtml(student.student_name) + " \u2014 not on this roster" : "Choose a student\u2026"}</option>
      ${options}
    </select>${input}</div>`;
}

// Picking a student says this sheet is theirs, so it takes their roster ID
// with it. The ID box changes in view and nothing is saved until Apply.
function chooseStudent(select, className) {
  const row = select.closest("tr");
  const nameField = row?.querySelector('[data-edit="student_name"]');
  const idField = row?.querySelector('[data-edit="student_id"]');
  if (!nameField || !idField) return;
  const list = (classes.find(item => item.name === className) || {}).students || [];
  const student = list.find(entry => String(entry.id) === select.value);
  nameField.classList.toggle("hidden", Boolean(student));
  if (!student) {
    nameField.focus();
    return;
  }
  nameField.value = student.name;
  nameField.dataset.fromRoster = "1";
  if (!sameStudentId(idField.value, student.id)) idField.value = student.id;
}

function showSheet(sheet) {
  const sessionId = $("#analysisSession").value;
  const url = `/api/sessions/${sessionId}/page/${sheet}`;
  $("#sheetDialogTitle").textContent = `Sheet ${sheet}`;
  $("#sheetDialogNote").textContent = "The page as it was scanned. Read the printed name and ID from it, then type them into the row behind this.";
  $("#sheetImage").src = url;
  $("#sheetFullLink").href = url;
  const dialog = $("#sheetDialog");
  if (!dialog.open) dialog.showModal();
}

$("#sheetDialogClose").addEventListener("click", () => $("#sheetDialog").close());
$("#sheetImage").addEventListener("error", () => {
  $("#sheetDialogNote").textContent = "That page is not in the cache any more. Read the batch again to bring the images back.";
});

$("#dismissAllButton").addEventListener("click", () => {
  const boxes = [...document.querySelectorAll("#reviewRows .review-check")];
  const turningOn = boxes.some(box => !box.checked);
  for (const box of boxes) box.checked = turningOn;
  $("#dismissAllButton").textContent = turningOn ? "Untick all" : "Mark all checked";
});

$("#restoreReviewButton").addEventListener("click", async () => {
  const sessionId = $("#analysisSession").value;
  try {
    const result = await post("/api/sessions/review/restore", {
      session_id: Number(sessionId),
    });
    toast(`Brought back ${result.restored} item(s)`);
    await loadAnalysis(sessionId);
    showAnalysisPane("review");
  } catch (error) {
    toast(error.message);
  }
});

$("#applyReviewButton").addEventListener("click", async () => {
  if (!analysisReport) return;
  const sessionId = $("#analysisSession").value;
  const bySheet = new Map();
  const sheetAnswers = new Map(
    analysisReport.students.map(row => [row.page, row.answers.map(a => a.response)])
  );

  // The ID and name boxes are prefilled with what was read, so only a box the
  // teacher actually changed counts as a correction.
  const byPage = new Map(analysisReport.students.map(row => [row.page, row]));
  for (const field of document.querySelectorAll("#reviewRows [data-edit]")) {
    const sheet = Number(field.dataset.sheet);
    const student = byPage.get(sheet) || {};
    const value = field.value.trim();
    const was = field.dataset.edit === "student_id"
      ? String(student.student_id || student.student_id_read || "")
      : String(student.student_name || "");
    if (value === was.trim()) continue;
    if (field.dataset.edit === "student_id" && value && !/^\d+$/.test(value)) {
      toast(`Student ID for sheet ${sheet} must be digits only`);
      return;
    }
    const entry = bySheet.get(sheet) || {number: sheet};
    entry[field.dataset.edit] = value;
    bySheet.set(sheet, entry);
  }

  // A row the teacher ticked is settled, and so is one whose answer they
  // actually changed — having decided what it should say, they are not
  // asking to be warned about it again.
  const dismiss = new Set(
    [...document.querySelectorAll("#reviewRows .review-check")]
      .filter(box => box.checked)
      .map(box => box.dataset.done)
  );

  for (const field of document.querySelectorAll("#reviewRows [data-fix]")) {
    const value = field.value.trim();
    if (!value) continue;
    const sheet = Number(field.dataset.sheet);
    const entry = bySheet.get(sheet) || {number: sheet};
    const responses = entry.responses || [...sheetAnswers.get(sheet)];
    // The stored sheet uses "" for a blank, not the analysis label.
    responses[Number(field.dataset.question) - 1] = value === "BLANK" ? "" : value;
    entry.responses = responses.map(r => (r === "BLANK" ? "" : r));
    bySheet.set(sheet, entry);
    const row = field.closest("tr")?.querySelector(".review-check");
    if (row?.dataset.done) dismiss.add(row.dataset.done);
  }

  if (!bySheet.size && !dismiss.size) {
    toast("Change something, or tick what you have checked");
    return;
  }
  try {
    const result = await post("/api/sessions/correct", {
      session_id: Number(sessionId),
      corrections: [...bySheet.values()],
      dismiss: [...dismiss],
    });
    const parts = [];
    if (result.applied) parts.push(`${result.applied} correction(s)`);
    if (result.dismissed) parts.push(`${result.dismissed} checked off`);
    toast(`Applied ${parts.join(" · ") || "nothing"}`);
    await loadAnalysis(sessionId);
    showAnalysisPane("review");
  } catch (error) {
    toast(error.message);
  }
});

/* ------------------------------------------------------------- answer key */

function renderAnswerKey(report) {
  editedKey = report.exam.answer_key.map(entry => entry.answer);
  drawAnswerKey(report);
}

function drawAnswerKey(report) {
  const original = report.exam.answer_key.map(entry => entry.answer);
  $("#keyGrid").innerHTML = editedKey.map((answer, index) => {
    const changed = answer !== original[index];
    return `<div class="key-row${changed ? " changed" : ""}">
      <span class="key-question">${index + 1}</span>
      ${[..."ABCDE"].map(letter => `
        <button type="button" class="key-choice${letter === answer ? " selected" : ""}"
                data-question="${index + 1}" data-answer="${letter}">${letter}</button>`).join("")}
    </div>`;
  }).join("");

  const changes = editedKey.filter((answer, index) => answer !== original[index]).length;
  $("#saveKeyButton").disabled = changes === 0;
  const note = $("#keyDirtyNote");
  note.classList.toggle("hidden", changes === 0);
  if (changes) {
    note.textContent = `${changes} answer${changes === 1 ? "" : "s"} changed. Saving rescores every sheet in this test.`;
  }

  for (const button of $("#keyGrid").querySelectorAll(".key-choice")) {
    button.addEventListener("click", () => {
      editedKey[Number(button.dataset.question) - 1] = button.dataset.answer;
      drawAnswerKey(report);
    });
  }
}

$("#resetKeyButton").addEventListener("click", () => {
  if (!analysisReport) return;
  renderAnswerKey(analysisReport);
});

$("#saveKeyButton").addEventListener("click", async () => {
  if (!analysisReport) return;
  const sessionId = $("#analysisSession").value;
  const keySheet = analysisReport.exam.key_page;
  if (!confirm("Save this answer key? Every sheet in the test is rescored against it.")) return;
  try {
    const result = await post("/api/sessions/correct", {
      session_id: Number(sessionId),
      corrections: [{number: keySheet, responses: editedKey}],
    });
    toast(result.applied ? "Answer key saved and sheets rescored" : "No change was made");
    await loadAnalysis(sessionId);
    showAnalysisPane("key");
  } catch (error) {
    toast(error.message);
  }
});


/* ----------------------------------------------------------- T-TESS upload */

let destinations = [];
let connected = false;

function renderConnection(state) {
  connected = Boolean(state.connected);
  destinations = state.destinations || [];
  $("#apiUrlLabel").textContent = state.api_url || "";
  // Only when the server sent one: renderConnection is also called with states
  // assembled in the page, which carry no site_url, and overwriting the link
  // with "" there would leave a button that goes nowhere.
  if (state.site_url) $("#ttessSiteLink").href = state.site_url;
  $("#connectForm").classList.toggle("hidden", connected);
  $("#connectedPanel").classList.toggle("hidden", !connected);
  $("#disconnectTtessButton").classList.toggle("hidden", !connected);

  if (!connected) {
    $("#connectionStatus").textContent =
      "Not connected. Paste a connection token from T-TESS → Reteaching → Connect DataLink.";
  } else {
    const courses = new Set(destinations.map(item => item.course_title));
    $("#connectionStatus").textContent = state.error
      ? state.error
      : `Connected · ${destinations.length} test${destinations.length === 1 ? "" : "s"} across ${courses.size} course${courses.size === 1 ? "" : "s"}`;
    $("#destinationSummary").textContent = destinations.length
      ? [...courses].join(" · ")
      : "No tests are available to this account yet.";
  }
  renderUploadPicker();
}

async function loadConnection() {
  try { renderConnection(await request("/api/connection")); }
  catch (error) { $("#connectionStatus").textContent = error.message; }
}

$("#connectTtessButton").addEventListener("click", async () => {
  const field = $("#tokenInput");
  const banner = $("#connectError");
  banner.classList.add("hidden");
  $("#connectTtessButton").disabled = true;
  try {
    const state = await post("/api/connection/connect", {token: field.value});
    field.value = "";                       // do not leave it sitting in the DOM
    renderConnection({connected: true, destinations: state.destinations, api_url: $("#apiUrlLabel").textContent});
    toast("Connected to T-TESS");
  } catch (error) {
    banner.textContent = error.message;
    banner.classList.remove("hidden");
  } finally {
    $("#connectTtessButton").disabled = false;
  }
});

$("#disconnectTtessButton").addEventListener("click", async () => {
  if (!confirm("Disconnect from T-TESS? The connection token is removed from this Mac's Keychain.")) return;
  renderConnection(await post("/api/connection/disconnect", {}));
  toast("Disconnected");
});

$("#refreshDestinationsButton").addEventListener("click", async () => {
  try {
    const state = await request("/api/destinations");
    destinations = state.destinations || [];
    renderConnection({connected: true, destinations, api_url: $("#apiUrlLabel").textContent});
    toast(`${destinations.length} test(s) available`);
  } catch (error) { toast(error.message); }
});

/* Course → Section → Unit → Test, each narrowing the next. */

function fillSelect(select, values, keep) {
  select.innerHTML = values.map(([value, label]) =>
    `<option value="${escapeHtml(value)}">${escapeHtml(label)}</option>`).join("");
  if (keep && values.some(([value]) => value === keep)) select.value = keep;
}

function uniqueBy(rows, key, label) {
  const seen = new Map();
  for (const row of rows) if (!seen.has(row[key])) seen.set(row[key], row[label]);
  return [...seen.entries()];
}

function renderUploadPicker() {
  const hasReport = Boolean(analysisReport);
  $("#uploadNotConnected").classList.toggle("hidden", connected);
  $("#uploadPicker").classList.toggle("hidden", !connected);
  if (!connected) {
    $("#uploadButton").disabled = true;
    return;
  }

  const courses = uniqueBy(destinations, "course_id", "course_title");
  fillSelect($("#uploadCourse"), courses, $("#uploadCourse").value);
  const course = $("#uploadCourse").value;

  const inCourse = destinations.filter(item => item.course_id === course);
  const sections = [];
  const seenSection = new Set();
  for (const item of inCourse) {
    for (const section of item.sections || []) {
      if (seenSection.has(section.section_id)) continue;
      seenSection.add(section.section_id);
      sections.push([section.section_id, section.section_name]);
    }
  }
  fillSelect($("#uploadSection"), sections, $("#uploadSection").value);
  const section = $("#uploadSection").value;

  const inSection = inCourse.filter(item =>
    (item.sections || []).some(entry => entry.section_id === section));
  const units = uniqueBy(inSection, "unit_id", "unit_title");
  fillSelect($("#uploadUnit"), units, $("#uploadUnit").value);
  const unit = $("#uploadUnit").value;

  const tests = inSection
    .filter(item => item.unit_id === unit)
    .map(item => [item.exam_id, `${item.exam_title} (${item.test_code})`]);
  fillSelect($("#uploadTest"), tests, $("#uploadTest").value);

  const chosen = selectedDestination();
  $("#uploadDetail").textContent = chosen
    ? `Uploads to ${chosen.course_title} · ${chosen.unit_title} · ${chosen.exam_title} · code ${chosen.test_code}` +
      (chosen.grade_cap ? ` · grade cap ${chosen.grade_cap}` : "")
    : "No test matches this combination.";
  $("#uploadButton").disabled = !chosen || !hasReport;
}

function selectedDestination() {
  return destinations.find(item => item.exam_id === $("#uploadTest").value) || null;
}

for (const id of ["uploadCourse", "uploadSection", "uploadUnit", "uploadTest"]) {
  $(`#${id}`).addEventListener("change", () => {
    // Clear the narrower choices so a stale pick cannot survive.
    if (id === "uploadCourse") { $("#uploadSection").value = ""; $("#uploadUnit").value = ""; $("#uploadTest").value = ""; }
    if (id === "uploadSection") { $("#uploadUnit").value = ""; $("#uploadTest").value = ""; }
    if (id === "uploadUnit") { $("#uploadTest").value = ""; }
    renderUploadPicker();
  });
}

$("#uploadButton").addEventListener("click", async () => {
  const destination = selectedDestination();
  const sessionId = $("#analysisSession").value;
  if (!destination || !sessionId) return;
  const error = $("#uploadError");
  const success = $("#uploadSuccess");
  error.textContent = "";
  error.classList.add("hidden");
  success.classList.add("hidden");
  $("#uploadButton").disabled = true;
  $("#uploadButton").textContent = "Uploading…";
  try {
    const result = await post("/api/sessions/upload", {
      session_id: Number(sessionId),
      exam_id: destination.exam_id,
    });
    $("#uploadRunId").textContent = result.run_id || "—";
    $("#uploadReviewLink").href = result.review_url;
    success.classList.remove("hidden");
    toast("Uploaded to T-TESS");
  } catch (failure) {
    error.textContent = failure.message;
    error.classList.remove("hidden");
    // An invalid token is cleared server side; reflect that here.
    if (/reconnect/i.test(failure.message)) loadConnection();
  } finally {
    $("#uploadButton").disabled = false;
    $("#uploadButton").textContent = "Upload to T-TESS";
  }
});

$("#uploadReviewLink").addEventListener("click", event => {
  if (!window.datalinkNative) return;   // the shell opens external links itself
  event.preventDefault();
  window.open($("#uploadReviewLink").href, "_blank");
});

/* --------------------------------------------------------------- start-up */

async function migrateBrowserStorage() {
  // Rosters saved by earlier browser-only builds still sit in localStorage on
  // the fixed port they used. Adopt them once, then stop reading them.
  let stored;
  try {
    stored = JSON.parse(localStorage.getItem("datalinkClasses") || "[]");
  } catch (error) {
    return;
  }
  if (!Array.isArray(stored) || !stored.length) return;
  try {
    const data = await post("/api/classes/import", {classes: stored});
    localStorage.removeItem("datalinkClasses");
    localStorage.removeItem("datalinkRoster");
    if (data.imported.length) {
      toast(`Imported ${data.imported.length} saved class(es) from this browser`);
    }
  } catch (error) {
    /* Leave localStorage untouched so the next launch can try again. */
  }
}

/* ---------------------------------------------------------------- paper */

let paperPath = "";
let paperPollTimer = null;
let paperWarnedOverLimit = false;

function readableSize(bytes) {
  const mb = (bytes || 0) / 1048576;
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${mb.toFixed(0)} MB`;
}

function renderPaperSupport(support) {
  const ready = support.ready;
  $("#paperSupportStatus").textContent = ready
    ? `Ready · OpenCV ${support.opencv_version}`
    : "Not installed yet";
  $("#paperInstallButton").classList.toggle("hidden", ready || !support.can_install_packages);
  $("#paperChooseButton").disabled = !ready;

  const parts = [];
  if (ready) {
    parts.push(`${support.packages.join(", ")} are installed in ${support.support_dir}.`);
  } else {
    if (support.missing.includes("packages")) {
      parts.push(
        `Reading paper sheets needs ${support.packages.join(", ")} — about ` +
        `${support.download_mb} MB to download and ${support.installed_mb} MB on disk. ` +
        "They are kept outside the app so an update does not download them again."
      );
      if (!support.can_install_packages) {
        parts.push("This build cannot install them itself; install DataLink Scanner with Homebrew instead.");
      }
    }
    if (support.missing.includes("poppler")) {
      parts.push("poppler is also missing. Install it with: brew install poppler");
    }
  }
  $("#paperSupportDetail").textContent = parts.join(" ");
}

function renderPaperStorage(storage) {
  const summary =
    `${readableSize(storage.cache_bytes)} of rendered pages` +
    (storage.batches ? ` from ${storage.batches} batch${storage.batches === 1 ? "" : "es"}` : "");
  $("#paperStorageSummary").textContent = storage.cache_bytes
    ? summary
    : "Nothing cached yet.";
  $("#paperPurgeButton").disabled = !storage.cache_bytes;
  if (!storage.over_limit) paperWarnedOverLimit = false;
  return storage;
}

// The reader will not score anything against a key it could not read, which
// is right, but refusing without a way forward left the batch stranded. This
// asks for the answers it could not settle and runs it again.
let keyFixState = null;

function renderKeyFix(review) {
  keyFixState = review || null;
  const panel = $("#paperKeyFix");
  panel.classList.toggle("hidden", !review);
  if (!review) return;

  const questions = Object.keys(review.unresolved);
  $("#paperKeyFixIntro").textContent =
    `Nothing can be scored until the key is settled. The key was read from page ` +
    `${review.key_page}; ${questions.length === 1 ? "one question" : `${questions.length} questions`} ` +
    `could not be made out. Look at the sheet and say what each should be.`;

  $("#paperKeyQuestions").innerHTML = questions.map(question => {
    // What the reader saw: "MULTIPLE" for an erasure or a second mark, an
    // empty value for a question it found nothing on.
    const read = review.unresolved[question];
    const saw = !read || read === "BLANK"
      ? "nothing marked on the key"
      : read === "MULTIPLE"
        ? "two or more marks on the key"
        : `read as <strong>${escapeHtml(read)}</strong>`;
    const choices = [..."ABCDE"].map(letter =>
      `<label class="key-fix-choice"><input type="radio" name="key-${escapeHtml(question)}"
        value="${letter}" data-key-question="${escapeHtml(question)}"><span>${letter}</span></label>`
    ).join("");
    return `<div class="key-fix-row">
      <span class="key-fix-what"><strong>Question ${escapeHtml(question)}</strong>
        <span class="key-fix-read">${saw}</span></span>
      ${choices}
    </div>`;
  }).join("");

  // Nothing can be sent until every one of them has an answer; a partial set
  // would simply be refused again by the reader.
  const answered = () => new Set(
    [...document.querySelectorAll("#paperKeyQuestions input:checked")]
      .map(input => input.dataset.keyQuestion)
  ).size === questions.length;
  const retry = $("#paperKeyRetry");
  retry.disabled = true;
  for (const input of document.querySelectorAll("#paperKeyQuestions input")) {
    input.addEventListener("change", () => { retry.disabled = !answered(); });
  }
}

function renderPaperJob(job) {
  const running = job.state === "installing" || job.state === "reading";
  $("#paperProgressWrap").classList.toggle("hidden", !running);
  $("#paperProgressMessage").textContent = job.message || "Working…";
  $("#paperProgressBar").style.width = `${Math.round((job.progress || 0) * 100)}%`;
  $("#paperRunButton").disabled = running;
  $("#paperChooseButton").disabled = running;
  $("#paperInstallButton").disabled = running;

  const failed = job.state === "failed";
  const fixable = Boolean(failed && job.key_review);
  // The fix panel restates the problem and offers the way out, so the bare
  // red line above it would only say the same thing twice.
  $("#paperError").classList.toggle("hidden", !failed || fixable);
  if (failed && !fixable) $("#paperError").textContent = job.message;
  renderKeyFix(fixable ? job.key_review : null);

  const finished = job.state === "done" && job.session_id;
  $("#paperDone").classList.toggle("hidden", !finished);
  $("#paperSetup").classList.toggle("hidden", !paperPath || running || finished);
  if (finished) {
    $("#paperDoneMessage").textContent =
      `${job.message}. They are saved as a session, ready to review and send to T-TESS.`;
    $("#paperOpenAnalysis").dataset.session = job.session_id;
  }
}

async function loadPaper() {
  try {
    const data = await request("/api/paper");
    renderPaperSupport(data.support);
    renderPaperStorage(data.storage);
    renderPaperJob(data.job);
    $("#paperQuestions").max = data.max_questions;
    await loadClasses();
    const select = $("#paperClass");
    const chosen = select.value;
    select.innerHTML = '<option value="">No roster</option>' + classes.map(item =>
      `<option value="${escapeHtml(item.name)}">${escapeHtml(item.name)}</option>`
    ).join("");
    select.value = chosen || selectedClassName || "";
    if (data.job.busy) startPaperPolling();
  } catch (error) {
    $("#paperSupportStatus").textContent = error.message;
  }
}

function startPaperPolling() {
  if (paperPollTimer !== null) return;
  paperPollTimer = setInterval(async () => {
    let data;
    try {
      data = await request("/api/paper/job");
    } catch (error) {
      return;
    }
    renderPaperJob(data.job);
    const storage = renderPaperStorage(data.storage);
    if (!data.job.busy) {
      clearInterval(paperPollTimer);
      paperPollTimer = null;
      if (data.job.state === "done") {
        loadSessions().catch(() => {});
        offerPurgeIfLarge(storage);
      }
    }
  }, 1000);
}

async function offerPurgeIfLarge(storage) {
  // Asked once per run, and only when the cache has actually grown past the
  // limit: a prompt on every batch would be trained away in a week.
  if (!storage.over_limit || paperWarnedOverLimit) return;
  paperWarnedOverLimit = true;
  const answer = confirm(
    `The scanned page cache is now ${readableSize(storage.cache_bytes)}, over the ` +
    `${readableSize(storage.warn_bytes)} mark.\n\n` +
    "Empty it? Only the page images go — your sessions, scores and item analyses are kept."
  );
  if (answer) await purgePaperCache();
}

async function purgePaperCache() {
  const result = await post("/api/paper/purge", {});
  renderPaperStorage(result);
  toast(`Freed ${readableSize(result.freed_bytes)}`);
}

$("#paperChooseButton").addEventListener("click", async () => {
  if (window.datalinkNative) {
    // A WKWebView file input gives the page no path, and the pipeline needs
    // one, so the app puts up a real Open panel and calls back.
    window.webkit.messageHandlers.datalink.postMessage({action: "choosePdf"});
    return;
  }
  const typed = prompt("Full path to the scanned PDF:", paperPath || "");
  if (typed) setPaperPdf(typed.trim());
});

async function setPaperPdf(path) {
  if (!path) return;
  paperPath = path;
  $("#paperError").classList.add("hidden");
  $("#paperDone").classList.add("hidden");
  try {
    const {pages} = await post("/api/paper/pages", {path});
    const name = path.split("/").pop();
    $("#paperFileLine").textContent = `${name} · ${pages} page${pages === 1 ? "" : "s"}`;
    $("#paperKeyPage").max = pages;
    $("#paperSetup").classList.remove("hidden");
    if (!$("#paperName").value) $("#paperName").value = name.replace(/\.pdf$/i, "");
  } catch (error) {
    paperPath = "";
    $("#paperSetup").classList.add("hidden");
    $("#paperError").classList.remove("hidden");
    $("#paperError").textContent = error.message;
  }
}

window.datalinkPaper = {chosen: setPaperPdf};

async function runPaperBatch(keyOverrides = null) {
  $("#paperError").classList.add("hidden");
  try {
    const {job} = await post("/api/paper/run", {
      path: paperPath,
      key_page: Number($("#paperKeyPage").value),
      question_count: Number($("#paperQuestions").value),
      name: $("#paperName").value.trim(),
      class_name: $("#paperClass").value,
      key_overrides: keyOverrides || {},
    });
    renderPaperJob(job);
    startPaperPolling();
  } catch (error) {
    $("#paperError").classList.remove("hidden");
    $("#paperError").textContent = error.message;
  }
}

$("#paperRunButton").addEventListener("click", () => runPaperBatch());

$("#paperKeyRetry").addEventListener("click", () => {
  const chosen = {};
  for (const input of document.querySelectorAll("#paperKeyQuestions input:checked")) {
    chosen[input.dataset.keyQuestion] = input.value;
  }
  renderKeyFix(null);
  // The pages are already rendered and cached, so reading again is quick.
  runPaperBatch(chosen);
});

$("#paperKeyCancel").addEventListener("click", () => {
  renderKeyFix(null);
  $("#paperError").classList.add("hidden");
});

$("#paperKeyView").addEventListener("click", () => {
  if (!keyFixState) return;
  const url = `/api/paper/page?path=${encodeURIComponent(paperPath)}` +
              `&page=${keyFixState.key_page}`;
  $("#sheetDialogTitle").textContent = `Answer key — page ${keyFixState.key_page}`;
  $("#sheetDialogNote").textContent =
    "The key sheet as it was scanned. Read off the answers it could not settle, " +
    "then choose them behind this.";
  $("#sheetImage").src = url;
  $("#sheetFullLink").href = url;
  const dialog = $("#sheetDialog");
  if (!dialog.open) dialog.showModal();
});

$("#paperInstallButton").addEventListener("click", async () => {
  $("#paperError").classList.add("hidden");
  try {
    const {job} = await post("/api/paper/install", {});
    renderPaperJob(job);
    startPaperPolling();
    const finished = setInterval(async () => {
      const data = await request("/api/paper/job").catch(() => null);
      if (data && !data.job.busy) {
        clearInterval(finished);
        loadPaper();
      }
    }, 1500);
  } catch (error) {
    $("#paperError").classList.remove("hidden");
    $("#paperError").textContent = error.message;
  }
});

$("#paperPurgeButton").addEventListener("click", async () => {
  if (!confirm("Empty the scanned page cache? Sessions, scores and item analyses are kept.")) return;
  await purgePaperCache();
});

$("#paperAgainButton").addEventListener("click", async () => {
  paperPath = "";
  await post("/api/paper/dismiss", {});
  $("#paperDone").classList.add("hidden");
  $("#paperFileLine").textContent = "";
  $("#paperName").value = "";
  loadPaper();
});

$("#paperOpenAnalysis").addEventListener("click", async () => {
  const sessionId = Number($("#paperOpenAnalysis").dataset.session);
  await selectSession(sessionId, {silent: true});
  navigate("analysis", {id: sessionId});
});

function renderUpdateSettings(settings) {
  $("#autoUpdateCheck").checked = settings.auto_update_check !== false;
  const version = `Running version ${settings.app_version || "—"}`;
  $("#updateVersionLine").textContent = settings.last_update_check
    ? `${version} · last checked ${formatTimestamp(settings.last_update_check)}`
    : `${version} · not checked yet`;
}

$("#studentMatching").addEventListener("change", async event => {
  studentMatching = event.target.value;
  await post("/api/settings", {student_matching: studentMatching}).catch(() => {});
  toast({
    id: "Sheets can be fed in any order",
    roster: "Sheets are taken in roster order",
    manual: "Every sheet will ask",
  }[studentMatching]);
  refresh();
});

$("#autoUpdateCheck").addEventListener("change", async event => {
  const wanted = event.target.checked;
  try {
    await post("/api/settings", {auto_update_check: wanted});
    toast(wanted ? "Automatic update checks on" : "Automatic update checks off");
  } catch (error) {
    // Leave the box showing what is actually stored, not what was clicked.
    event.target.checked = !wanted;
    toast("That setting could not be saved");
  }
});

async function start() {
  await migrateBrowserStorage();
  const settings = await request("/api/settings");
  renderUpdateSettings(settings);
  studentMatching = settings.student_matching || "id";
  $("#studentMatching").value = studentMatching;
  testName.value = settings.test_name || "";
  if (settings.question_count) questionCount.value = settings.question_count;
  selectedClassName = settings.selected_class || "";
  await loadClasses();
  updateExportName();
  await refresh();
  refreshTimer = setInterval(refresh, 750);
  loadConnection().catch(() => {});
  // A reload, a bookmark, or the back button all land here.
  if (!location.hash) location.replace(routeFor("scan"));
  await applyRoute();
}

start();
