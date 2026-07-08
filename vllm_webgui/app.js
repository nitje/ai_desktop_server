const rows = document.getElementById("containerRows");
const statusLine = document.getElementById("statusLine");
const logBox = document.getElementById("logBox");
const jobLine = document.getElementById("jobLine");
const form = document.getElementById("containerForm");
const refreshBtn = document.getElementById("refreshBtn");
const resetFormBtn = document.getElementById("resetFormBtn");
const repairNvidiaBtn = document.getElementById("repairNvidiaBtn");
const themeToggleBtn = document.getElementById("themeToggleBtn");
const modelFormat = document.getElementById("modelFormat");
const ggufFields = document.getElementById("ggufFields");
const modelLabel = document.getElementById("modelLabel");
const modelHint = document.getElementById("modelHint");

let state = null;
let selectedName = null;
let selectedJob = null;

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

function renderGgufSource(c) {
  if (c.gguf_url) {
    const label = shortText(fileNameFromUrl(c.gguf_url), 44);
    const href = escapeHtml(c.gguf_url);
    return `<a class="model-link" href="${href}" title="${href}" target="_blank" rel="noopener noreferrer">${escapeHtml(label)}</a>`;
  }
  const source = c.gguf_repo && c.gguf_file ? `${c.gguf_repo}:${c.gguf_file}` : c.gguf_file;
  return escapeHtml(shortText(source || "unvollstaendig", 58));
}

function badge(status, kind = "") {
  return `<span class="badge ${escapeHtml(kind)}">${escapeHtml(status)}</span>`;
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
  document.getElementById("port").value = item.port || 18000;
  document.getElementById("hfToken").value = "";
  document.getElementById("extraArgs").value = item.extra_args || "";
  document.getElementById("dockerExtraArgs").value = item.docker_extra_args || "";
  document.getElementById("autostart").checked = !!item.autostart;
  selectedName = item.name || null;
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
    port: Number(document.getElementById("port").value),
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
  const containers = state.containers || [];
  if (!containers.length) {
    rows.innerHTML = `<tr><td colspan="9">Noch keine Container konfiguriert.</td></tr>`;
    return;
  }
  rows.innerHTML = containers.map((c) => {
    const modelCell = c.model_format === "gguf"
      ? `${escapeHtml(c.model)}<br><small>GGUF: ${renderGgufSource(c)}</small>`
      : escapeHtml(c.model);
    return `
    <tr>
      <td><strong>${escapeHtml(c.name)}</strong></td>
      <td>${badge(c.status, c.status)}${c.config_current ? "" : "<br><small>Config geaendert</small>"}</td>
      <td>
        ${badge(c.api_ready ? "API bereit" : "API nicht bereit", c.api_ready ? "running" : "missing")}
        ${c.api_ready ? `<br><a class="api-link" href="${escapeHtml(c.api_models_url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(c.api_models_url)}</a>` : ""}
      </td>
      <td>${progressBar(c.download_progress)}</td>
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
          <button data-act="remove" data-name="${escapeHtml(c.name)}" class="danger">Deinstallieren</button>
        </div>
      </td>
    </tr>
  `}).join("");
}

function progressBar(progress = {}) {
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
    logBox.textContent = data.logs || "";
    logBox.scrollTop = logBox.scrollHeight;
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await api("/api/containers", {method: "POST", body: JSON.stringify(formData())});
    document.getElementById("hfToken").value = "";
    await refresh();
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
  try {
    if (action === "edit") fillForm(item);
    if (action === "start") await startJob("start", name);
    if (action === "stop") await startJob("stop", name);
    if (action === "unload") await startJob("unload", name);
    if (action === "logs") {
      selectedName = name;
      selectedJob = null;
      await loadLogs(name);
    }
    if (action === "remove") {
      const removeCache = confirm("Container deinstallieren? OK = inklusive HF-Cache, Abbrechen = nur Container/Config.");
      const data = await api(`/api/containers/${encodeURIComponent(name)}?remove_cache=${removeCache ? "1" : "0"}`, {method: "DELETE"});
      selectedJob = data.job_id;
      selectedName = null;
      await refreshJob();
    }
    await refresh();
  } catch (error) {
    alert(error.message);
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
themeToggleBtn.addEventListener("click", () => {
  applyTheme(document.documentElement.dataset.theme === "dark" ? "day" : "dark");
});
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
