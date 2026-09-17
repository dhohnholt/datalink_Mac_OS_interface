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
let editingClassName = "";
let currentView = "scan";
let openSessionId = null;

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

function showView(name) {
  currentView = name;
  for (const button of document.querySelectorAll("#viewTabs button")) {
    button.classList.toggle("active", button.dataset.view === name);
  }
  for (const view of ["scan", "paper", "classes", "sessions", "analysis", "settings"]) {
    $(`#view-${view}`).hidden = view !== name;
  }
  if (name === "paper") loadPaper();
  if (name === "classes") loadClasses();
  if (name === "sessions") loadSessions();
  if (name === "analysis") loadAnalysisSessions();
  if (name === "settings") loadConnection();
}

for (const button of document.querySelectorAll("#viewTabs button")) {
  button.addEventListener("click", () => showView(button.dataset.view));
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
      if (openSessionId === id) openSession(id);
    });
  }
  for (const button of rows.querySelectorAll("[data-delete]")) {
    button.addEventListener("click", async () => {
      const id = Number(button.dataset.delete);
      if (!confirm("Delete this saved session and all of its scans? This cannot be undone.")) return;
      renderSessions((await post("/api/sessions/delete", {id})).sessions);
      if (openSessionId === id) closeSession();
      toast("Session deleted");
    });
  }
}

async function openSession(id) {
  const session = await request(`/api/sessions/${id}`);
  openSessionId = id;
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
    const cells = scan.responses.map(value =>
      `<td class="${!value ? "blank" : value.length > 1 ? "multiple" : ""}">${escapeHtml(value || "—")}</td>`
    ).join("");
    return `<tr><td>${label}${scan.demo ? " · demo" : ""}</td><td>${student}</td>` +
      `<td>${formatTimestamp(scan.received_at)}</td><td>${scan.answered_count}</td>${cells}</tr>`;
  }).join("");
  $("#sessionDetailCard").scrollIntoView({behavior: "smooth", block: "start"});
}

function closeSession() {
  openSessionId = null;
  $("#sessionDetailCard").classList.add("hidden");
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
  badge.className = `badge ${state.state}`;
  const labels = { disconnected: "Disconnected", connecting: "Connecting…", connected: "Ready to scan", error: "Needs attention" };
  badge.innerHTML = `<span></span>${labels[state.state] || state.state}`;
  connectButton.disabled = state.state === "connecting" || state.state === "connected";
  disconnectButton.disabled = state.state === "disconnected";
  portSelect.disabled = state.state === "connecting" || state.state === "connected";
  questionCount.disabled = state.state === "connecting" || state.state === "connected";
  $("#connectionDetail").textContent = state.error || (state.state === "connected"
    ? `Data Collection active on ${state.port}. Feed one sheet at a time.`
    : "Connect the scanner by USB, then select its serial port.");
  $("#scanCount").textContent = state.record_count;
  const latest = state.records[state.records.length - 1];
  $("#answerCount").textContent = latest ? `${latest.answered_count} / ${latest.responses.length}` : "—";
  $("#sessionFile").textContent = state.output_path ? state.output_path.split("/").pop() : "Not started";
  const hasKey = state.records.some(record => record.role === "key");
  const next = currentStudent();
  const workflow = $("#workflowCard");
  workflow.classList.toggle("key-complete", hasKey);
  workflow.classList.toggle("key-needed", !hasKey);
  workflow.querySelector(".step-number").textContent = hasKey ? "✓" : "1";
  $("#workflowTitle").textContent = hasKey
    ? next ? `Next: ${next.name}` : roster.length ? "Roster complete" : "Answer key captured"
    : "Scan the answer key first";
  $("#workflowDetail").textContent = hasKey
    ? next ? `Roster #${next.id} · Feed ${next.name}'s sheet now.` : roster.length ? "Every student on the roster has been handled." : "The session is ready for student sheets. Feed them one at a time."
    : "After the scanner says Ready to scan, feed the marked answer key before any student sheets.";
  $("#skipStudentButton").classList.toggle("hidden", !hasKey || !next);
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
  const detectedRosterIndex = review.scanner_id
    ? roster.findIndex(student => student.id === review.scanner_id)
    : -1;
  const canAutoSave = review.student_id_required && review.scanner_id && review.ambiguities.length === 0
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
  activeRosterMatchIndex = review.scanner_id
    ? roster.findIndex(student => student.id === review.scanner_id)
    : rosterIndex;
  const next = review.student_id_required
    ? review.scanner_id
      ? roster[activeRosterMatchIndex] || null
      : currentStudent()
    : null;
  const hasAmbiguities = review.ambiguities.length > 0;
  $("#reviewDialog h2").textContent = next ? `Confirm ${next.name}` : hasAmbiguities ? "Check the scan" : "Enter the student ID";
  $("#reviewIntro").textContent = hasAmbiguities
    ? `The scanner found more than one mark on the ${label}. Please resolve each item before continuing.`
    : review.scanner_id
      ? roster.length && activeRosterMatchIndex < 0
        ? `ID ${review.scanner_id} is not in ${selectedClassName}. Check the sheet or save it as an unlisted student.`
        : `The scanner read ID ${review.scanner_id}. Confirm the student before continuing.`
      : `The ${label} was captured. Enter the ID bubbled on the sheet before scanning the next student.`;
  $("#studentIdField").classList.toggle("hidden", !review.student_id_required);
  $("#studentIdInput").value = review.scanner_id || (next ? next.id : "");
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
  const matchIndex = roster.findIndex(student => student.id === review.scanner_id);
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
    return `<tr><td>${label}${record.demo ? " · demo" : ""}</td><td>${student}</td><td>${time}</td>${cells}</tr>`;
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
    render(await post("/api/connect", {port: portSelect.value, question_count: currentQuestionCount(), acknowledge_writes: true}));
  } catch (error) { toast(error.message); await refresh(); }
});

disconnectButton.addEventListener("click", async () => {
  try { render(await post("/api/disconnect", {})); }
  catch (error) { toast(error.message); }
});

$("#demoButton").addEventListener("click", async () =>
  render(await post("/api/demo", {question_count: currentQuestionCount()})));

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
  disconnect: () => disconnectButton.disabled || disconnectButton.click(),
  addDemo: () => $("#demoButton").click(),
  clearView: () => $("#clearButton").click(),
  exportCsv: () => (currentView === "sessions" && openSessionId !== null
    ? $("#sessionExportButton") : $("#exportButton")).click(),
  exportAnalysis: () => {
    if (currentView !== "sessions" || openSessionId === null) {
      toast("Open a saved session first, then export its item analysis");
      return;
    }
    $("#sessionAnalysisButton").click();
  },
  newClass: () => { showView("classes"); openClassEditor(null); },
  editClass: () => { showView("classes"); openClassEditor(selectedClassName); },
  skipStudent: () => $("#skipStudentButton").click(),
  startAtFirst: () => $("#resetRosterButton").click(),
  toggleProtocol: () => $("#toggleProtocol").click(),
  showScan: () => showView("scan"),
  showPaper: () => showView("paper"),
  choosePaperPdf: () => { showView("paper"); $("#paperChooseButton").click(); },
  showClasses: () => showView("classes"),
  showSessions: () => showView("sessions"),
  showAnalysis: () => showView("analysis"),
  showSettings: () => showView("settings"),
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
  const previous = select.value;
  select.innerHTML = '<option value="">Choose a test…</option>' + sessions.map(item =>
    `<option value="${item.id}">${escapeHtml(item.name || "Untitled")} · ` +
    `${formatTimestamp(item.started_at)} · ${item.scan_count} sheets</option>`
  ).join("");
  if (sessions.some(item => String(item.id) === previous)) select.value = previous;
  if (!select.value) showAnalysisPlaceholder("No test selected");
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
    showAnalysisPlaceholder("No test selected");
    return;
  }
  try {
    analysisReport = await request(`/api/sessions/${sessionId}/analysis`);
  } catch (error) {
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

$("#analysisSession").addEventListener("change", event => loadAnalysis(event.target.value));

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

function showAnalysisPane(name) {
  analysisPane = name;
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
        kind: "student_id",
        problem: "No student ID was read",
        read: student?.student_id_read || "—",
      });
    } else if (item.field === "answer") {
      const answer = student?.answers?.find(entry => entry.question === item.question);
      rows.push({
        sheet: item.page,
        student,
        kind: "answer",
        question: item.question,
        problem: `Question ${item.question} has more than one mark`,
        read: answer ? answer.response : "MULTIPLE",
      });
    }
  }
  return rows.sort((a, b) => a.sheet - b.sheet || (a.question || 0) - (b.question || 0));
}

function renderAnalysisReview(report) {
  const rows = reviewProblems(report);
  const badge = $("#reviewBadge");
  badge.textContent = rows.length;
  badge.classList.toggle("hidden", rows.length === 0);
  $("#reviewEmpty").classList.toggle("hidden", rows.length > 0);
  $("#reviewWrap").classList.toggle("hidden", rows.length === 0);
  $("#applyReviewButton").disabled = rows.length === 0;

  $("#reviewRows").innerHTML = rows.map(row => {
    const who = row.student?.student_name
      ? escapeHtml(row.student.student_name)
      : row.student?.student_id
        ? escapeHtml(row.student.student_id)
        : "—";
    const control = row.kind === "student_id"
      ? `<input type="text" inputmode="numeric" pattern="[0-9]*" placeholder="Student ID"
                data-fix="student_id" data-sheet="${row.sheet}">`
      : `<select data-fix="answer" data-sheet="${row.sheet}" data-question="${row.question}">
           <option value="">Keep as read</option>
           ${[..."ABCDE"].map(letter => `<option value="${letter}">${letter}</option>`).join("")}
           <option value="BLANK">Blank</option>
         </select>`;
    return `<tr>
      <td><strong>${row.sheet}</strong></td>
      <td>${who}</td>
      <td>${escapeHtml(row.problem)}</td>
      <td><code>${escapeHtml(row.read)}</code></td>
      <td>${control}</td>
    </tr>`;
  }).join("");
}

$("#applyReviewButton").addEventListener("click", async () => {
  if (!analysisReport) return;
  const sessionId = $("#analysisSession").value;
  const bySheet = new Map();
  const sheetAnswers = new Map(
    analysisReport.students.map(row => [row.page, row.answers.map(a => a.response)])
  );

  for (const field of document.querySelectorAll("#reviewRows [data-fix]")) {
    const value = field.value.trim();
    if (!value) continue;
    const sheet = Number(field.dataset.sheet);
    const entry = bySheet.get(sheet) || {number: sheet};
    if (field.dataset.fix === "student_id") {
      if (!/^\d+$/.test(value)) {
        toast(`Student ID for sheet ${sheet} must be digits only`);
        return;
      }
      entry.student_id = value;
    } else {
      const responses = entry.responses || [...sheetAnswers.get(sheet)];
      // The stored sheet uses "" for a blank, not the analysis label.
      responses[Number(field.dataset.question) - 1] = value === "BLANK" ? "" : value;
      entry.responses = responses.map(r => (r === "BLANK" ? "" : r));
    }
    bySheet.set(sheet, entry);
  }

  if (!bySheet.size) {
    toast("Enter at least one correction first");
    return;
  }
  try {
    const result = await post("/api/sessions/correct", {
      session_id: Number(sessionId),
      corrections: [...bySheet.values()],
    });
    toast(`Applied ${result.applied} correction(s)`);
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

function renderPaperJob(job) {
  const running = job.state === "installing" || job.state === "reading";
  $("#paperProgressWrap").classList.toggle("hidden", !running);
  $("#paperProgressMessage").textContent = job.message || "Working…";
  $("#paperProgressBar").style.width = `${Math.round((job.progress || 0) * 100)}%`;
  $("#paperRunButton").disabled = running;
  $("#paperChooseButton").disabled = running;
  $("#paperInstallButton").disabled = running;

  const failed = job.state === "failed";
  $("#paperError").classList.toggle("hidden", !failed);
  if (failed) $("#paperError").textContent = job.message;

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

$("#paperRunButton").addEventListener("click", async () => {
  $("#paperError").classList.add("hidden");
  try {
    const {job} = await post("/api/paper/run", {
      path: paperPath,
      key_page: Number($("#paperKeyPage").value),
      question_count: Number($("#paperQuestions").value),
      name: $("#paperName").value.trim(),
      class_name: $("#paperClass").value,
    });
    renderPaperJob(job);
    startPaperPolling();
  } catch (error) {
    $("#paperError").classList.remove("hidden");
    $("#paperError").textContent = error.message;
  }
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
  const sessionId = $("#paperOpenAnalysis").dataset.session;
  showView("analysis");
  await loadAnalysisSessions();
  $("#analysisSession").value = sessionId;
  $("#analysisSession").dispatchEvent(new Event("change"));
});

function renderUpdateSettings(settings) {
  $("#autoUpdateCheck").checked = settings.auto_update_check !== false;
  const version = `Running version ${settings.app_version || "—"}`;
  $("#updateVersionLine").textContent = settings.last_update_check
    ? `${version} · last checked ${formatTimestamp(settings.last_update_check)}`
    : `${version} · not checked yet`;
}

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
  testName.value = settings.test_name || "";
  if (settings.question_count) questionCount.value = settings.question_count;
  selectedClassName = settings.selected_class || "";
  await loadClasses();
  updateExportName();
  await refresh();
  refreshTimer = setInterval(refresh, 750);
  loadConnection().catch(() => {});
}

start();
