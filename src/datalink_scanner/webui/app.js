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
  for (const view of ["scan", "classes", "sessions"]) {
    $(`#view-${view}`).hidden = view !== name;
  }
  if (name === "classes") loadClasses();
  if (name === "sessions") loadSessions();
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
$("#manageClassesButton").addEventListener("click", () => showView("classes"));

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
  showClasses: () => showView("classes"),
  showSessions: () => showView("sessions"),
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

async function start() {
  await migrateBrowserStorage();
  const settings = await request("/api/settings");
  testName.value = settings.test_name || "";
  if (settings.question_count) questionCount.value = settings.question_count;
  selectedClassName = settings.selected_class || "";
  await loadClasses();
  updateExportName();
  await refresh();
  refreshTimer = setInterval(refresh, 750);
}

start();
