const rows = document.getElementById("containerRows");
const statusLine = document.getElementById("statusLine");
const logBox = document.getElementById("logBox");
const jobLine = document.getElementById("jobLine");
const form = document.getElementById("containerForm");
const refreshBtn = document.getElementById("refreshBtn");
const resetFormBtn = document.getElementById("resetFormBtn");
const repairNvidiaBtn = document.getElementById("repairNvidiaBtn");
const themeToggleBtn = document.getElementById("themeToggleBtn");

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
  document.getElementById("image").value = item.image || defaults[item.profile || "nvidia"];
  document.getElementById("model").value = item.model || "Qwen/Qwen3-0.6B";
  document.getElementById("port").value = item.port || 18000;
  document.getElementById("hfToken").value = "";
  document.getElementById("extraArgs").value = item.extra_args || "";
  document.getElementById("dockerExtraArgs").value = item.docker_extra_args || "";
  document.getElementById("autostart").checked = !!item.autostart;
  selectedName = item.name || null;
}

function formData() {
  return {
    old_name: document.getElementById("oldName").value,
    name: document.getElementById("name").value.trim(),
    profile: document.getElementById("profile").value,
    image: document.getElementById("image").value.trim(),
    model: document.getElementById("model").value.trim(),
    port: Number(document.getElementById("port").value),
    hf_token: document.getElementById("hfToken").value,
    extra_args: document.getElementById("extraArgs").value,
    docker_extra_args: document.getElementById("dockerExtraArgs").value,
    autostart: document.getElementById("autostart").checked,
  };
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
    rows.innerHTML = `<tr><td colspan="8">Noch keine Container konfiguriert.</td></tr>`;
    return;
  }
  rows.innerHTML = containers.map((c) => `
    <tr>
      <td><strong>${escapeHtml(c.name)}</strong></td>
      <td>${badge(c.status, c.status)}${c.config_current ? "" : "<br><small>Config geaendert</small>"}</td>
      <td>
        ${badge(c.api_ready ? "API bereit" : "API nicht bereit", c.api_ready ? "running" : "missing")}
        ${c.api_ready ? `<br><a class="api-link" href="${escapeHtml(c.api_models_url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(c.api_models_url)}</a>` : ""}
      </td>
      <td>${escapeHtml(c.profile)}</td>
      <td>${escapeHtml(c.model)}</td>
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
  `).join("");
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
