const rows = document.getElementById("containerRows");
const statusLine = document.getElementById("statusLine");
const logBox = document.getElementById("logBox");
const jobLine = document.getElementById("jobLine");
const form = document.getElementById("containerForm");
const refreshBtn = document.getElementById("refreshBtn");
const resetFormBtn = document.getElementById("resetFormBtn");
const repairNvidiaBtn = document.getElementById("repairNvidiaBtn");
const themeToggleBtn = document.getElementById("themeToggleBtn");
const downloadLogBtn = document.getElementById("downloadLogBtn");
const clearLogBtn = document.getElementById("clearLogBtn");
const modelFormat = document.getElementById("modelFormat");
const ggufFields = document.getElementById("ggufFields");
const modelLabel = document.getElementById("modelLabel");
const modelHint = document.getElementById("modelHint");
const portInput = document.getElementById("port");

let state = null;
let selectedName = null;
let selectedJob = null;
let currentLogTitle = "vllm-log";
let portManuallyEdited = false;

const defaults = {
  nvidia: "vllm/vllm-openai:latest",
  rocm: "vllm/vllm-openai-rocm:latest",
  xpu: "vllm/vllm-openai-xpu:latest",
  cpu: "vllm/vllm-openai-cpu:latest-x86_64",
};

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: {"Content-Type": "application/json"},
    ...options,
  });
  const data = await res.json();
  if (!res.ok || data.error) throw new Error(data.error || res.statusText);
  return data;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#039;",
  }[ch]));
}

function shortText(value, max = 48) {
  const text = String(value || "");
  if (text.length <= max) return text;
  const keep = Math.max(8, Math.floor((max - 3) / 2));
  return `${text.slice(0, keep)}...${text.slice(-keep)}`;
}

function fileNameFromUrl(value) {
  try {
    const url = new URL(value);
    const name = decodeURIComponent(url.pathname.split("/").filter(Boolean).pop() || "");
    return name || "GGUF Download-Link";
  } catch {
    return "GGUF Download-Link";
  }
}

function huggingFaceRepoFromUrl(value) {
  try {
    const url = new URL(value);
    if (url.hostname !== "huggingface.co") return "";
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length < 2) return "";
    return `${parts[0]}/${parts[1]}`;
  } catch {
    return "";
  }
}

function huggingFaceRepoUrl(repo) {
  const clean = String(repo || "").trim().split(":", 1)[0];
  if (!clean || clean.startsWith("/") || clean.includes("://") || !clean.includes("/")) return "";
  return `https://huggingface.co/${clean}/tree/main`;
}

function quantLabelFromGguf(filename, repo) {
  const stem = String(filename || "").replace(/\.gguf$/i, "");
  const repoName = String(repo || "").split("/").pop() || "";
  const baseName = repoName.replace(/-GGUF$/i, "");
  if (baseName && stem.startsWith(`${baseName}-`)) return stem.slice(baseName.length + 1);
  return stem || filename || "";
}

function modelLink(repo, label, max = 58) {
  const href = huggingFaceRepoUrl(repo);
  const text = shortText(label || repo || "unvollstaendig", max);
  if (!href) return escapeHtml(text);
  return `<a class="model-link" href="${escapeHtml(href)}" title="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer">${escapeHtml(text)}</a>`;
}

function hfLink(repo) {
  const href = huggingFaceRepoUrl(repo);
  if (!href) return "";
  return `<br><small>HF: <a class="model-link" href="${escapeHtml(href)}" title="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer">Link</a></small>`;
}

function safeFilePart(value) {
  return String(value || "vllm-log").replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^-+|-+$/g, "") || "vllm-log";
}

function portUsedByCurrentEdit(port, exceptName = "") {
  return !!exceptName && (state?.containers || []).some((c) => c.name === exceptName && Number(c.port) === Number(port));
}

function isPortUsed(port, exceptName = "") {
  const numericPort = Number(port);
  if (!Number.isInteger(numericPort) || numericPort < 1 || numericPort > 65535) return true;
  const configured = (state?.containers || []).some((c) => c.name !== exceptName && Number(c.port) === numericPort);
  if (configured) return true;
  const hostUsed = (state?.ports_in_use || []).some((p) => Number(p) === numericPort);
  return hostUsed && !portUsedByCurrentEdit(numericPort, exceptName);
}

function nextFreePort(start = 18000, exceptName = "") {
  const first = Math.max(1, Math.min(65535, Number(start) || 18000));
  for (let port = first; port <= 65535; port += 1) {
    if (!isPortUsed(port, exceptName)) return port;
  }
  for (let port = 1; port < first; port += 1) {
    if (!isPortUsed(port, exceptName)) return port;
  }
  return first;
}

function updateCreateFormPort() {
  if (!state || selectedName || document.getElementById("oldName").value || portManuallyEdited) return;
  const current = Number(portInput.value || 18000);
  if (!current || isPortUsed(current)) portInput.value = nextFreePort(current || 18000);
}

function downloadCurrentLog() {
  const text = logBox.textContent || "";
  if (!text.trim()) {
    alert("Kein Log zum Herunterladen vorhanden.");
    return;
  }
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const blob = new Blob([`${jobLine.textContent}\n\n${text}\n`], {type: "text/plain;charset=utf-8"});
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `${safeFilePart(currentLogTitle)}-${timestamp}.txt`;
  document.body.appendChild(link);
  link.click();
  URL.revokeObjectURL(link.href);
  link.remove();
}

function clearVisibleLog() {
  selectedJob = null;
  selectedName = null;
  currentLogTitle = "vllm-log";
  jobLine.textContent = "Log-Anzeige geleert.";
  logBox.textContent = "";
}

function renderGgufSource(c) {
  if (c.gguf_url) {
    const repo = c.gguf_repo || huggingFaceRepoFromUrl(c.gguf_url);
    const filename = fileNameFromUrl(c.gguf_url);
    const label = repo ? `${repo}:${quantLabelFromGguf(filename, repo)}` : filename;
    return modelLink(repo, label, 58);
  }
  const source = c.gguf_repo && c.gguf_file ? `${c.gguf_repo}:${c.gguf_file}` : c.gguf_file;
  return modelLink(c.gguf_repo, source, 58);
}

function badge(status, kind = "") {
  return `<span class="badge ${escapeHtml(kind)}">${escapeHtml(status)}</span>`;
}

function startupLine(status = {}) {
  if (!status.text) return "";
  return `<div class="startup-line" title="${escapeHtml(status.title || status.text)}">${escapeHtml(status.text)}</div>`;
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("vllm-theme", theme);
  themeToggleBtn.textContent = theme === "dark" ? "Day" : "Dark";
}

function initTheme() {
  applyTheme(localStorage.getItem("vllm-theme") || "dark");
}

function fillForm(item = {}) {
  const editing = !!item.name;
  document.getElementById("oldName").value = item.name || "";
  document.getElementById("name").value = item.name || "";
  document.getElementById("profile").value = item.profile || "nvidia";
  modelFormat.value = item.model_format || "hf";
  document.getElementById("image").value = item.image || defaults[item.profile || "nvidia"];
  document.getElementById("model").value = item.model || "Qwen/Qwen3-0.6B";
  document.getElementById("ggufRepo").value = item.gguf_repo || "";
  document.getElementById("ggufFile").value = item.gguf_file || "";
  document.getElementById("ggufUrl").value = item.gguf_url || "";
  document.getElementById("tokenizer").value = item.tokenizer || "";
  document.getElementById("hfConfigPath").value = item.hf_config_path || "";
  portInput.value = editing ? item.port : nextFreePort(18000);
  document.getElementById("hfToken").value = "";
  document.getElementById("extraArgs").value = item.extra_args || "";
  document.getElementById("dockerExtraArgs").value = item.docker_extra_args || "";
  document.getElementById("autostart").checked = !!item.autostart;
  selectedName = item.name || null;
  portManuallyEdited = false;
  toggleModelFormat();
}

function formData() {
  return {
    old_name: document.getElementById("oldName").value,
    name: document.getElementById("name").value.trim(),
    profile: document.getElementById("profile").value,
    model_format: modelFormat.value,
    image: document.getElementById("image").value.trim(),
    model: document.getElementById("model").value.trim(),
    gguf_repo: document.getElementById("ggufRepo").value.trim(),
    gguf_file: document.getElementById("ggufFile").value.trim(),
    gguf_url: document.getElementById("ggufUrl").value.trim(),
    tokenizer: document.getElementById("tokenizer").value.trim(),
    hf_config_path: document.getElementById("hfConfigPath").value.trim(),
    port: Number(portInput.value),
    hf_token: document.getElementById("hfToken").value,
    extra_args: document.getElementById("extraArgs").value,
    docker_extra_args: document.getElementById("dockerExtraArgs").value,
    autostart: document.getElementById("autostart").checked,
  };
}

function toggleModelFormat() {
  const isGguf = modelFormat.value === "gguf";
  ggufFields.classList.toggle("hidden", !isGguf);
  modelLabel.childNodes[0].nodeValue = isGguf ? "Served Model Name" : "Hugging Face Modell";
  modelHint.textContent = isGguf
    ? "Name, der in /v1/models angezeigt wird. Die echte GGUF-Quelle steht unten."
    : "Normale Hugging-Face-Repo-ID, z.B. Qwen/Qwen3-0.6B.";
}

async function refresh() {
  state = await api("/api/status");
  statusLine.textContent = `Docker: ${state.docker ? "ok" : "fehlt"} | NVIDIA SMI: ${state.nvidia_smi ? "aktiv" : "fehlt"} | Web: http://${state.ip}:${state.web_port}/`;
  renderNvidiaStatus();
  renderRows();
  updateCreateFormPort();
  await refreshJob();
  if (selectedName) await loadLogs(selectedName);
}

function renderNvidiaStatus() {
  const nvidiaStatus = document.getElementById("nvidiaStatus");
  nvidiaStatus.innerHTML = `
    <div class="status-pills">
      ${badge(state.nvidia_smi ? "NVIDIA SMI aktiv" : "NVIDIA SMI fehlt", state.nvidia_smi ? "running" : "missing")}
      ${badge(state.nvidia_container_toolkit ? "Toolkit installiert" : "Toolkit fehlt", state.nvidia_container_toolkit ? "running" : "missing")}
      ${badge(state.docker_nvidia_runtime ? "Docker Runtime aktiv" : "Docker Runtime fehlt", state.docker_nvidia_runtime ? "running" : "missing")}
    </div>
  `;
}

function renderRows() {
  const containers = [...(state.containers || [])].sort((a, b) => {
    const portA = Number(a.port || 0);
    const portB = Number(b.port || 0);
    return portA - portB || String(a.name || "").localeCompare(String(b.name || ""));
  });
  if (!containers.length) {
    rows.innerHTML = `<tr><td colspan="9">Noch keine Container konfiguriert.</td></tr>`;
    return;
  }
  rows.innerHTML = containers.map((c) => {
    const modelCell = c.model_format === "gguf"
      ? `${escapeHtml(c.model)}<br><small>GGUF: ${renderGgufSource(c)}</small>`
      : `${escapeHtml(c.model)}${hfLink(c.model)}`;
    return `
    <tr>
      <td><strong>${escapeHtml(c.name)}</strong></td>
      <td>${badge(c.status, c.status)}${c.config_current ? "" : "<br><small>Config geaendert</small>"}</td>
      <td class="api-status-cell">
        <div class="api-status-block">
          ${badge(c.api_ready ? "API bereit" : "API nicht bereit", c.api_ready ? "running" : "missing")}
          <div class="api-detail-line">
            ${c.api_ready ? `<a class="api-link" href="${escapeHtml(c.api_models_url)}" title="${escapeHtml(c.api_models_url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(c.api_models_url)}</a>` : (c.diagnostic ? `<small class="diagnostic" title="${escapeHtml(c.diagnostic)}">${escapeHtml(c.diagnostic)}</small>` : `<span class="api-placeholder">&nbsp;</span>`)}
          </div>
        </div>
      </td>
      <td>${progressBar(c.download_progress, c.startup_status)}</td>
      <td>${escapeHtml(c.profile)}</td>
      <td>${modelCell}</td>
      <td>${escapeHtml(c.port)}</td>
      <td>${c.autostart ? "ja" : "nein"}</td>
      <td>
        <div class="actions">
          <button data-act="edit" data-name="${escapeHtml(c.name)}" class="secondary">Bearbeiten</button>
          <button data-act="start" data-name="${escapeHtml(c.name)}">Start</button>
          <button data-act="stop" data-name="${escapeHtml(c.name)}" class="secondary">Stop</button>
          <button data-act="unload" data-name="${escapeHtml(c.name)}" class="secondary">Unload VRAM</button>
          <button data-act="logs" data-name="${escapeHtml(c.name)}" class="secondary">Logs</button>
          <button data-act="cache" data-name="${escapeHtml(c.name)}" class="danger">HF Cache</button>
          <button data-act="remove" data-name="${escapeHtml(c.name)}" class="danger">Deinstallieren</button>
        </div>
      </td>
    </tr>
  `}).join("");
}

function progressBar(progress = {}, startupStatus = {}) {
  const percent = Number.isFinite(progress.percent) ? Math.max(0, Math.min(100, progress.percent)) : null;
  const active = !!progress.active;
  const label = progress.label || (percent === null ? "wartet" : `${percent}%`);
  const style = percent === null ? "" : `style="width:${percent}%"`;
  return `
    <div class="progress-wrap">
      <div class="progress-track ${active && percent === null ? "indeterminate" : ""}">
        <div class="progress-fill ${active ? "active" : ""}" ${style}></div>
      </div>
      <small>${escapeHtml(label)}</small>
      ${startupLine(startupStatus)}
    </div>
  `;
}

async function startJob(action, name) {
  const data = await api(`/api/containers/${encodeURIComponent(name)}/${action}`, {method: "POST", body: "{}"});
  selectedJob = data.job_id;
  selectedName = name;
  await refreshJob();
}

async function refreshJob() {
  if (!selectedJob) return;
  const job = await api(`/api/jobs/${selectedJob}`);
  jobLine.textContent = `${job.label || "Job"}: ${job.status}`;
  currentLogTitle = job.label || "vllm-job";
  logBox.textContent = (job.log || []).join("\n");
  logBox.scrollTop = logBox.scrollHeight;
  if (job.status === "done" || job.status === "error") {
    selectedJob = null;
  }
}

async function loadLogs(name) {
  const data = await api(`/api/containers/${encodeURIComponent(name)}/logs`);
  if (!selectedJob) {
    jobLine.textContent = `Logs: ${name}`;
    currentLogTitle = name;
    logBox.textContent = data.logs || "";
    logBox.scrollTop = logBox.scrollHeight;
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    const data = formData();
    if (state && isPortUsed(data.port, data.old_name)) {
      data.port = nextFreePort(data.port || 18000, data.old_name);
      portInput.value = data.port;
    }
    const result = await api("/api/containers", {method: "POST", body: JSON.stringify(data)});
    fillForm();
    selectedName = null;
    selectedJob = null;
    await refresh();
    if (result.removed_cache && result.removed_cache.length) {
      selectedJob = null;
      selectedName = null;
      jobLine.textContent = "Alter Hugging-Face-Cache geloescht";
      logBox.textContent = result.removed_cache.map((name) => `geloescht: ${name}`).join("\n");
      logBox.scrollTop = logBox.scrollHeight;
    }
  } catch (error) {
    alert(error.message);
  }
});

rows.addEventListener("click", async (event) => {
  const button = event.target.closest("button");
  if (!button) return;
  const name = button.dataset.name;
  const action = button.dataset.act;
  const item = (state.containers || []).find((c) => c.name === name);
  button.disabled = true;
  try {
    if (action === "edit") {
      fillForm(item);
      return;
    } else if (action === "start") {
      await startJob("start", name);
    } else if (action === "stop") {
      await startJob("stop", name);
    } else if (action === "unload") {
      await startJob("unload", name);
    } else if (action === "logs") {
      selectedName = name;
      selectedJob = null;
      await loadLogs(name);
    } else if (action === "cache") {
      if (!confirm(`Hugging-Face-Modellcache fuer ${name} loeschen? Der Container wird dabei gestoppt.`)) return;
      const data = await api(`/api/containers/${encodeURIComponent(name)}/clear-cache`, {method: "POST", body: "{}"});
      selectedJob = data.job_id;
      selectedName = name;
      await refreshJob();
    } else if (action === "remove") {
      const removeCache = confirm("Container deinstallieren? OK = inklusive HF-Cache, Abbrechen = nur Container/Config.");
      const data = await api(`/api/containers/${encodeURIComponent(name)}?remove_cache=${removeCache ? "1" : "0"}`, {method: "DELETE"});
      selectedJob = data.job_id;
      selectedName = null;
      await refreshJob();
    }
    await refresh();
  } catch (error) {
    alert(error.message);
  } finally {
    button.disabled = false;
  }
});

document.getElementById("profile").addEventListener("change", () => {
  const profile = document.getElementById("profile").value;
  const image = document.getElementById("image");
  if (!image.value || Object.values(defaults).includes(image.value)) image.value = defaults[profile];
});
modelFormat.addEventListener("change", toggleModelFormat);

refreshBtn.addEventListener("click", refresh);
resetFormBtn.addEventListener("click", () => fillForm());
portInput.addEventListener("input", () => {
  portManuallyEdited = true;
});
portInput.addEventListener("blur", () => {
  const oldName = document.getElementById("oldName").value;
  const current = Number(portInput.value || 18000);
  if (state && isPortUsed(current, oldName)) {
    portInput.value = nextFreePort(current || 18000, oldName);
  }
});
themeToggleBtn.addEventListener("click", () => {
  applyTheme(document.documentElement.dataset.theme === "dark" ? "day" : "dark");
});
downloadLogBtn.addEventListener("click", downloadCurrentLog);
clearLogBtn.addEventListener("click", clearVisibleLog);
repairNvidiaBtn.addEventListener("click", async () => {
  try {
    const data = await api("/api/nvidia/repair", {method: "POST", body: "{}"});
    selectedJob = data.job_id;
    await refreshJob();
  } catch (error) {
    alert(error.message);
  }
});

initTheme();
fillForm();
refresh();
setInterval(refresh, 5000);
