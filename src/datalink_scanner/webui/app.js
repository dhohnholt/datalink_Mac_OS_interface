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
let classes = JSON.parse(localStorage.getItem("datalinkClasses") || "[]");
const legacyRoster = JSON.parse(localStorage.getItem("datalinkRoster") || "[]");
if (!classes.length && legacyRoster.length) {
  classes = [{name: "My Class", students: legacyRoster}];
  localStorage.setItem("datalinkClasses", JSON.stringify(classes));
  localStorage.removeItem("datalinkRoster");
}
let selectedClassName = localStorage.getItem("datalinkSelectedClass") || (classes[0]?.name || "");
if (!classes.some(item => item.name === selectedClassName)) selectedClassName = classes[0]?.name || "";
let roster = [];
let rosterIndex = 0;
let editingClassName = "";
testName.value = localStorage.getItem("datalinkTestName") || "";

function selectedClass() {
  return classes.find(item => item.name === selectedClassName) || null;
}

function rosterProgress() {
  return JSON.parse(sessionStorage.getItem("datalinkRosterProgress") || "{}");
}

function loadSelectedClass() {
  roster = selectedClass()?.students || [];
  rosterIndex = Number(rosterProgress()[selectedClassName] || 0);
  localStorage.setItem("datalinkSelectedClass", selectedClassName);
}

function saveClasses() {
  localStorage.setItem("datalinkClasses", JSON.stringify(classes));
}

function updateClassSelector() {
  const select = $("#classSelect");
  select.innerHTML = '<option value="">No roster</option>' + classes.map(item =>
    `<option value="${escapeHtml(item.name)}">${escapeHtml(item.name)}</option>`
  ).join("");
  select.value = selectedClassName;
}

function updateExportName() {
  const name = testName.value.trim();
  localStorage.setItem("datalinkTestName", name);
  const className = selectedClassName.trim();
  const filename = [className, name].filter(Boolean).join(" - ") || "datalink-session";
  const query = new URLSearchParams({name: filename, class: className});
  $("#exportButton").href = `/api/export.csv?${query}`;
  $("#exportButton").download = `${filename}.csv`;
}

testName.addEventListener("input", updateExportName);
updateExportName();

function currentStudent() {
  return roster[rosterIndex] || null;
}

function saveRosterPosition() {
  const progress = rosterProgress();
  if (selectedClassName) progress[selectedClassName] = rosterIndex;
  sessionStorage.setItem("datalinkRosterProgress", JSON.stringify(progress));
}

function advanceRoster() {
  if (rosterIndex < roster.length) rosterIndex += 1;
  saveRosterPosition();
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, character => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[character]);
}

loadSelectedClass();
updateClassSelector();

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
    const state = await request("/api/resolve-review", {
      method: "POST",
      body: JSON.stringify({
        id: review.id,
        resolutions: {},
        student_id: review.scanner_id,
        student_name: match ? match.name : "",
      }),
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
  const columns = Math.max(Number(questionCount.value), ...records.map(record => record.responses.length));
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
    `<li><time>${item.time}</time><span class="${item.kind}">${item.message}</span></li>`
  ).join("") : '<li class="muted">Waiting for activity.</li>';
}

async function refresh() {
  try { render(await request("/api/status")); }
  catch (error) { $("#connectionDetail").textContent = error.message; }
}

connectButton.addEventListener("click", async () => {
  connectButton.disabled = true;
  try {
    render(await request("/api/connect", {method: "POST", body: JSON.stringify({port: portSelect.value, question_count: Number(questionCount.value), acknowledge_writes: true})}));
  } catch (error) { toast(error.message); await refresh(); }
});
disconnectButton.addEventListener("click", async () => {
  try { render(await request("/api/disconnect", {method: "POST", body: "{}"})); }
  catch (error) { toast(error.message); }
});
$("#demoButton").addEventListener("click", async () => render(await request("/api/demo", {method: "POST", body: JSON.stringify({question_count: Number(questionCount.value)})})));
$("#clearButton").addEventListener("click", async () => {
  if (confirm("Clear the scans shown here? The saved session file on disk is not deleted.")) {
    render(await request("/api/clear", {method: "POST", body: "{}"}));
  }
});
$("#quitButton").addEventListener("click", async () => {
  if (!confirm("Stop DataLink Scanner? The scanner will be disconnected and this page will stop updating. Saved sessions are not deleted.")) return;
  $("#quitButton").disabled = true;
  try {
    await request("/api/quit", {method: "POST", body: "{}"});
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
    const state = await request("/api/resolve-review", {method: "POST", body: JSON.stringify({id: activeReviewId, resolutions, student_id: $("#studentIdInput").value, student_name: $("#studentNameInput").value})});
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

$("#editRosterButton").addEventListener("click", () => {
  if (!selectedClass()) {
    $("#newClassButton").click();
    return;
  }
  editingClassName = selectedClassName;
  $("#rosterDialogTitle").textContent = "Edit class roster";
  $("#classNameInput").value = selectedClassName;
  $("#rosterInput").value = roster.map(student => `${student.id}, ${student.name}`).join("\n");
  $("#deleteClassButton").classList.remove("hidden");
  $("#rosterDialog").showModal();
});
$("#newClassButton").addEventListener("click", () => {
  editingClassName = "";
  $("#rosterDialogTitle").textContent = "Add a class";
  $("#classNameInput").value = "";
  $("#rosterInput").value = "";
  $("#deleteClassButton").classList.add("hidden");
  $("#rosterDialog").showModal();
  setTimeout(() => $("#classNameInput").focus(), 50);
});
$("#cancelRosterButton").addEventListener("click", () => $("#rosterDialog").close());
$("#deleteClassButton").addEventListener("click", () => {
  if (!editingClassName || !confirm(`Delete the saved class “${editingClassName}”?`)) return;
  classes = classes.filter(item => item.name !== editingClassName);
  selectedClassName = classes[0]?.name || "";
  saveClasses();
  loadSelectedClass();
  updateClassSelector();
  updateExportName();
  $("#rosterDialog").close();
  refresh();
});
$("#classSelect").addEventListener("change", event => {
  selectedClassName = event.target.value;
  loadSelectedClass();
  updateExportName();
  refresh();
});
$("#resetRosterButton").addEventListener("click", () => {
  rosterIndex = 0;
  saveRosterPosition();
  refresh();
});
$("#rosterForm").addEventListener("submit", event => {
  event.preventDefault();
  const className = $("#classNameInput").value.trim();
  if (!className) {
    toast("Enter a class name");
    return;
  }
  if (classes.some(item => item.name.toLowerCase() === className.toLowerCase() && item.name !== editingClassName)) {
    toast("A class with that name already exists");
    return;
  }
  const lines = $("#rosterInput").value.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  const parsed = [];
  const ids = new Set();
  for (const line of lines) {
    const comma = line.indexOf(",");
    const id = (comma >= 0 ? line.slice(0, comma) : "").trim();
    const name = (comma >= 0 ? line.slice(comma + 1) : "").trim();
    if (!/^\d+$/.test(id) || !name) {
      toast(`Fix roster line: ${line}`);
      return;
    }
    if (ids.has(id)) {
      toast(`Student ID ${id} appears more than once`);
      return;
    }
    ids.add(id);
    parsed.push({id, name});
  }
  const editedIndex = classes.findIndex(item => item.name === editingClassName);
  const savedClass = {name: className, students: parsed};
  if (editedIndex >= 0) classes[editedIndex] = savedClass;
  else classes.push(savedClass);
  selectedClassName = className;
  saveClasses();
  loadSelectedClass();
  rosterIndex = 0;
  saveRosterPosition();
  updateClassSelector();
  updateExportName();
  $("#rosterDialog").close();
  toast(`Saved ${className} with ${parsed.length} students`);
  refresh();
});

// Bridge for the native menu bar. Each entry drives the same code path as
// the on-screen control, so menu and button behave identically.
window.datalinkMenu = {
  connect: () => connectButton.disabled || connectButton.click(),
  disconnect: () => disconnectButton.disabled || disconnectButton.click(),
  addDemo: () => $("#demoButton").click(),
  clearView: () => $("#clearButton").click(),
  exportCsv: () => $("#exportButton").click(),
  newClass: () => $("#newClassButton").click(),
  editClass: () => $("#editRosterButton").click(),
  skipStudent: () => $("#skipStudentButton").click(),
  startAtFirst: () => $("#resetRosterButton").click(),
  toggleProtocol: () => $("#toggleProtocol").click(),
};

if (window.datalinkNative) {
  // Cmd-Q quits properly in the native shell, so the in-page button is both
  // redundant and misleading: it would stop the server and leave a live window
  // showing a dead page.
  $("#quitButton").remove();
  document.body.classList.add("native");
  // The export control is an <a download>, which a WKWebView will not save on
  // its own. Hand the request to the app so the user gets a real Save panel.
  $("#exportButton").addEventListener("click", event => {
    event.preventDefault();
    const link = $("#exportButton");
    window.webkit.messageHandlers.datalink.postMessage({
      action: "export",
      query: new URL(link.href, location.origin).search.replace(/^\?/, ""),
      filename: link.download || "datalink-session.csv",
    });
  });
}

refresh();
refreshTimer = setInterval(refresh, 750);
