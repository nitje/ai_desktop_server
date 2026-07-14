const rows = document.getElementById("containerRows");
const statusLine = document.getElementById("statusLine");
const logBox = document.getElementById("logBox");
const jobLine = document.getElementById("jobLine");
const overviewCard = document.getElementById("overviewCard");
const systemCard = document.getElementById("systemCard");
const form = document.getElementById("containerForm");
const logsCard = document.getElementById("logsCard");
const refreshBtn = document.getElementById("refreshBtn");
const resetFormBtn = document.getElementById("resetFormBtn");
const repairNvidiaBtn = document.getElementById("repairNvidiaBtn");
const themeToggleBtn = document.getElementById("themeToggleBtn");
const settingsBtn = document.getElementById("settingsBtn");
const downloadLogBtn = document.getElementById("downloadLogBtn");
const clearLogBtn = document.getElementById("clearLogBtn");
const systemMetrics = document.getElementById("systemMetrics");
const addDiskBtn = document.getElementById("addDiskBtn");
const diskModal = document.getElementById("diskModal");
const diskModalList = document.getElementById("diskModalList");
const diskModalCloseBtn = document.getElementById("diskModalCloseBtn");
const diskModalSaveBtn = document.getElementById("diskModalSaveBtn");
const diskModalCancelBtn = document.getElementById("diskModalCancelBtn");
const settingsModal = document.getElementById("settingsModal");
const settingsModalCloseBtn = document.getElementById("settingsModalCloseBtn");
const settingsModalSaveBtn = document.getElementById("settingsModalSaveBtn");
const settingsModalResetBtn = document.getElementById("settingsModalResetBtn");
const settingsModalCancelBtn = document.getElementById("settingsModalCancelBtn");
const overviewIntervalInput = document.getElementById("overviewIntervalInput");
const systemIntervalInput = document.getElementById("systemIntervalInput");
const containersIntervalInput = document.getElementById("containersIntervalInput");
const logsIntervalInput = document.getElementById("logsIntervalInput");
const designSelect = document.getElementById("designSelect");
const containerLimitInput = document.getElementById("containerLimitInput");
const modelSizeWarnReserveInput = document.getElementById("modelSizeWarnReserveInput");
const containerSortInput = document.getElementById("containerSortInput");
const containerSortDirectionInput = document.getElementById("containerSortDirectionInput");
const showThroughputInput = document.getElementById("showThroughputInput");
const showOverviewCard = document.getElementById("showOverviewCard");
const showSystemCard = document.getElementById("showSystemCard");
const showFormCard = document.getElementById("showFormCard");
const showLogsCard = document.getElementById("showLogsCard");
const ntfyEnabledInput = document.getElementById("ntfyEnabledInput");
const ntfyServerInput = document.getElementById("ntfyServerInput");
const ntfyTopicInput = document.getElementById("ntfyTopicInput");
const ntfyTokenInput = document.getElementById("ntfyTokenInput");
const ntfyTestBtn = document.getElementById("ntfyTestBtn");
const telegramEnabledInput = document.getElementById("telegramEnabledInput");
const telegramBotTokenInput = document.getElementById("telegramBotTokenInput");
const telegramChatIdInput = document.getElementById("telegramChatIdInput");
const telegramTestBtn = document.getElementById("telegramTestBtn");
const emailEnabledInput = document.getElementById("emailEnabledInput");
const emailSmtpHostInput = document.getElementById("emailSmtpHostInput");
const emailSmtpPortInput = document.getElementById("emailSmtpPortInput");
const emailUsernameInput = document.getElementById("emailUsernameInput");
const emailPasswordInput = document.getElementById("emailPasswordInput");
const emailFromInput = document.getElementById("emailFromInput");
const emailToInput = document.getElementById("emailToInput");
const emailTlsInput = document.getElementById("emailTlsInput");
const emailSslInput = document.getElementById("emailSslInput");
const emailTestBtn = document.getElementById("emailTestBtn");
const containerLimitControls = document.getElementById("containerLimitControls");
const containerLimitSummary = document.getElementById("containerLimitSummary");
const containerLimitToggleBtn = document.getElementById("containerLimitToggleBtn");
const containerSearch = document.getElementById("containerSearch");
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
let selectedDiskKeys = null;
let pollTimers = {};
let pollBusy = {overview: false, system: false, containers: false, logs: false};
let showAllContainers = false;
let runtimeEditMode = false;
let runtimeEditDrafts = {};
let settingsSecretBuffer = "";

const defaultPollSettings = {
  overview: 5000,
  system: 2000,
  containers: 3000,
  logs: 1500,
};

const defaultCardSettings = {
  overview: true,
  system: true,
  form: true,
  logs: true,
};

const defaultViewSettings = {
  containerLimit: 5,
  modelSizeWarnReserveGb: 8,
  containerSort: "port",
  containerSortDirection: "asc",
  ramSizeUnit: "GB",
  vramSizeUnit: "GB",
  diskSizeUnit: "GB",
  systemTempUnit: "C",
  showThroughput: true,
};

const defaultNotificationSettings = {
  ntfy: {enabled: false, server: "https://ntfy.sh", topic: "", token: "", monitors: defaultMonitorSettings()},
  email: {enabled: false, smtp_host: "", smtp_port: 587, username: "", password: "", from_addr: "", to_addr: "", use_tls: true, use_ssl: false, monitors: defaultMonitorSettings()},
  telegram: {enabled: false, bot_token: "", chat_id: "", monitors: defaultMonitorSettings()},
};

const defaultUiSettings = {
  theme: "dark",
  design: "default",
  poll: defaultPollSettings,
  cards: defaultCardSettings,
  view: defaultViewSettings,
  notifications: defaultNotificationSettings,
  selected_disks: null,
};

const availableDesigns = new Set(["default", "neonsys-cyberpunk", "aurora-mesh-gradient", "aura-glassmorphism"]);

let uiSettings = normalizeUiSettings(defaultUiSettings);

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

function modelSizeLine(container) {
  const modelSize = Number(container.model_size_bytes || 0);
  const vramTotal = Number(state?.system?.gpu?.vram_total || 0);
  const label = modelSize > 0 ? formatModelSize(modelSize) : "";
  const modelSizeGb = modelSize > 0 ? Math.round(modelSize / (1000 ** 3)) : 0;
  const vramTotalGb = vramTotal > 0 ? Math.round(vramTotal / (1024 ** 3)) : 0;
  const reserveGb = Number(readViewSettings().modelSizeWarnReserveGb || 0);
  const tooLarge = modelSizeGb > 0 && vramTotalGb > 0 && modelSizeGb > Math.max(0, vramTotalGb - reserveGb);
  const className = tooLarge ? ` class="model-size-warning"` : "";
  return `<br><small${className}>Size: ${label ? escapeHtml(label) : "-"}</small>`;
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

function secondsToHms(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds || 0)));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
}

function hmsToSeconds(value) {
  const text = String(value || "").trim();
  if (!text) return null;
  if (/^\d+$/.test(text)) return Number(text);
  const parts = text.split(":");
  if (parts.length < 2 || parts.length > 3) return null;
  if (!parts.every((part) => /^\d+$/.test(part))) return null;
  const values = parts.map(Number);
  if (parts.length === 2) {
    return values[0] * 60 + values[1];
  }
  return values[0] * 3600 + values[1] * 60 + values[2];
}

function runtimeLine(name, status = {}) {
  const text = status.text || "Laufzeit 0s";
  const title = status.active ? "Zaehlt, solange die API bereit ist." : "Gespeicherte gesamte API-Laufzeit.";
  if (runtimeEditMode) {
    const value = Object.prototype.hasOwnProperty.call(runtimeEditDrafts, name)
      ? runtimeEditDrafts[name]
      : secondsToHms(status.total_seconds || 0);
    return `
      <span class="runtime-edit">
        <input class="runtime-input" data-runtime-input data-name="${escapeHtml(name)}" type="text" inputmode="numeric" value="${escapeHtml(value)}" placeholder="h:m:s">
        <button type="button" class="runtime-save secondary" data-act="runtime-save" data-name="${escapeHtml(name)}" title="Laufzeit uebernehmen">v</button>
      </span>
    `;
  }
  return `<small class="runtime-line" title="${escapeHtml(title)}">${escapeHtml(text)}</small>`;
}

function throughputLine(status = {}) {
  const viewSettings = readViewSettings();
  if (!viewSettings.showThroughput || !status.label) return "";
  const title = status.title || "Avg prompt throughput / Avg generation throughput";
  return `<small class="throughput-line" title="${escapeHtml(title)}">${escapeHtml(status.label)}</small>`;
}

function formatNumber(value, digits = 0) {
  return Number(value || 0).toLocaleString("de-DE", {
    maximumFractionDigits: digits,
    minimumFractionDigits: digits,
  });
}

function formatBytesUnit(value, unit = "GB") {
  const divisor = unit === "TB" ? 1024 ** 4 : 1024 ** 3;
  const amount = Number(value || 0) / divisor;
  if (unit === "TB") return `${formatNumber(amount, amount < 10 ? 2 : 1)}TB`;
  return `${formatNumber(amount, amount < 10 ? 1 : 0)}GB`;
}

function formatModelSize(value) {
  const bytes = Number(value || 0);
  if (bytes >= 1000 ** 4) {
    const amount = bytes / (1000 ** 4);
    return `${formatNumber(amount, amount < 10 ? 2 : 1)}TB`;
  }
  const amount = bytes / (1000 ** 3);
  return `${formatNumber(amount, amount < 10 ? 1 : 0)}GB`;
}

function formatUsage(used, total, unit = "GB") {
  return `${formatBytesUnit(used, unit)}/${formatBytesUnit(total, unit)}`;
}

function formatPercent(value, missing = false) {
  if (missing) return "-";
  const percent = Math.max(0, Math.min(100, Number(value || 0)));
  return `${formatNumber(percent, percent % 1 ? 1 : 0)}%`;
}

function formatTemp(value, unit = "C", missing = false) {
  if (missing || value === null || value === undefined) return "-";
  const celsius = Number(value);
  const display = unit === "F" ? (celsius * 9 / 5) + 32 : celsius;
  return `${formatNumber(display, 0)}${unit}`;
}

function diskKey(disk) {
  return `${disk.source || ""}|${disk.mount || ""}`;
}

function diskLabel(disk) {
  return `${disk.source || "Disk"} ${disk.mount || ""}`.trim();
}

function defaultMonitorSettings() {
  return {
    error: {enabled: true},
    start: {enabled: false},
    stop: {enabled: false},
    notify_toggle: {enabled: false},
    temp: {enabled: false, limit: 90},
    vram: {enabled: false, limit: 97},
    ram: {enabled: false, limit: 90},
    disks: {},
  };
}

function normalizeLimit(value, fallback, min = 1, max = 100) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(min, Math.min(max, Math.round(number)));
}

function normalizeMonitorSettings(settings = {}) {
  const defaults = defaultMonitorSettings();
  const disks = settings.disks || {};
  const normalizedDisks = {};
  Object.entries(disks).forEach(([key, value]) => {
    normalizedDisks[key] = {
      enabled: !!value?.enabled,
      limit: normalizeLimit(value?.limit, 90, 1, 100),
    };
  });
  return {
    error: {enabled: settings.error?.enabled !== false},
    start: {enabled: !!settings.start?.enabled},
    stop: {enabled: !!settings.stop?.enabled},
    notify_toggle: {enabled: !!settings.notify_toggle?.enabled},
    temp: {
      enabled: !!settings.temp?.enabled,
      limit: normalizeLimit(settings.temp?.limit, defaults.temp.limit, 1, 120),
    },
    vram: {
      enabled: !!settings.vram?.enabled,
      limit: normalizeLimit(settings.vram?.limit, defaults.vram.limit, 1, 100),
    },
    ram: {
      enabled: !!settings.ram?.enabled,
      limit: normalizeLimit(settings.ram?.limit, defaults.ram.limit, 1, 100),
    },
    disks: normalizedDisks,
  };
}

function normalizeNotificationSettings(settings = {}) {
  const ntfy = settings.ntfy || {};
  const email = settings.email || {};
  const telegram = settings.telegram || {};
  return {
    ntfy: {
      enabled: !!ntfy.enabled,
      server: String(ntfy.server || defaultNotificationSettings.ntfy.server),
      topic: String(ntfy.topic || ""),
      token: String(ntfy.token || ""),
      monitors: normalizeMonitorSettings(ntfy.monitors || {}),
    },
    email: {
      enabled: !!email.enabled,
      smtp_host: String(email.smtp_host || ""),
      smtp_port: Math.max(1, Number(email.smtp_port) || defaultNotificationSettings.email.smtp_port),
      username: String(email.username || ""),
      password: String(email.password || ""),
      from_addr: String(email.from_addr || ""),
      to_addr: String(email.to_addr || ""),
      use_tls: !!email.use_tls && !email.use_ssl,
      use_ssl: !!email.use_ssl,
      monitors: normalizeMonitorSettings(email.monitors || {}),
    },
    telegram: {
      enabled: !!telegram.enabled,
      bot_token: String(telegram.bot_token || ""),
      chat_id: String(telegram.chat_id || ""),
      monitors: normalizeMonitorSettings(telegram.monitors || {}),
    },
  };
}

function normalizeUiSettings(settings = {}) {
  const poll = settings.poll || {};
  const cards = settings.cards || {};
  const view = settings.view || {};
  const sortFields = new Set(["port", "name", "startup", "status", "api_ready"]);
  const sortDirections = new Set(["asc", "desc"]);
  const sizeUnits = new Set(["GB", "TB"]);
  const tempUnits = new Set(["C", "F"]);
  const rawContainerSort = view.containerSort === "running" ? "status" : view.containerSort;
  const containerSort = sortFields.has(rawContainerSort) ? rawContainerSort : defaultViewSettings.containerSort;
  const containerSortDirection = sortDirections.has(view.containerSortDirection) ? view.containerSortDirection : defaultViewSettings.containerSortDirection;
  const warnReserve = Number(view.modelSizeWarnReserveGb);
  const legacySizeUnit = sizeUnits.has(view.systemSizeUnit) ? view.systemSizeUnit : null;
  const ramSizeUnit = sizeUnits.has(view.ramSizeUnit) ? view.ramSizeUnit : (legacySizeUnit || defaultViewSettings.ramSizeUnit);
  const vramSizeUnit = sizeUnits.has(view.vramSizeUnit) ? view.vramSizeUnit : (legacySizeUnit || defaultViewSettings.vramSizeUnit);
  const diskSizeUnit = sizeUnits.has(view.diskSizeUnit) ? view.diskSizeUnit : (legacySizeUnit || defaultViewSettings.diskSizeUnit);
  const systemTempUnit = tempUnits.has(view.systemTempUnit) ? view.systemTempUnit : defaultViewSettings.systemTempUnit;
  const design = availableDesigns.has(settings.design) ? settings.design : "default";
  return {
    theme: settings.theme === "day" ? "day" : "dark",
    design,
    poll: {
      overview: Math.max(1000, Number(poll.overview) || defaultPollSettings.overview),
      system: Math.max(500, Number(poll.system) || defaultPollSettings.system),
      containers: Math.max(1000, Number(poll.containers) || defaultPollSettings.containers),
      logs: Math.max(500, Number(poll.logs) || defaultPollSettings.logs),
    },
    cards: {
      overview: cards.overview !== false,
      system: cards.system !== false,
      form: cards.form !== false,
      logs: cards.logs !== false,
    },
    view: {
      containerLimit: Math.max(1, Number(view.containerLimit) || defaultViewSettings.containerLimit),
      modelSizeWarnReserveGb: Number.isFinite(warnReserve) ? Math.max(0, warnReserve) : defaultViewSettings.modelSizeWarnReserveGb,
      containerSort,
      containerSortDirection,
      ramSizeUnit,
      vramSizeUnit,
      diskSizeUnit,
      systemTempUnit,
      showThroughput: view.showThroughput !== false,
    },
    notifications: normalizeNotificationSettings(settings.notifications || {}),
    selected_disks: Array.isArray(settings.selected_disks) ? [...new Set(settings.selected_disks)] : null,
  };
}

async function loadUiSettings() {
  try {
    const data = await api("/api/ui-settings");
    uiSettings = normalizeUiSettings(data.settings || {});
  } catch (error) {
    console.warn("UI-Einstellungen konnten nicht geladen werden:", error);
    uiSettings = normalizeUiSettings(defaultUiSettings);
  }
  selectedDiskKeys = Array.isArray(uiSettings.selected_disks) ? [...uiSettings.selected_disks] : null;
}

async function persistUiSettings() {
  try {
    const data = await api("/api/ui-settings", {method: "POST", body: JSON.stringify(uiSettings)});
    uiSettings = normalizeUiSettings(data.settings || uiSettings);
    selectedDiskKeys = Array.isArray(uiSettings.selected_disks) ? [...uiSettings.selected_disks] : null;
  } catch (error) {
    console.warn("UI-Einstellungen konnten nicht gespeichert werden:", error);
  }
}

async function saveSelectedDisks(keys) {
  selectedDiskKeys = [...new Set(keys)];
  uiSettings.selected_disks = selectedDiskKeys;
  await persistUiSettings();
}

function readPollSettings() {
  return {...defaultPollSettings, ...uiSettings.poll};
}

function savePollSettings(settings) {
  const cleaned = {
    overview: Math.max(1000, Number(settings.overview) || defaultPollSettings.overview),
    system: Math.max(500, Number(settings.system) || defaultPollSettings.system),
    containers: Math.max(1000, Number(settings.containers) || defaultPollSettings.containers),
    logs: Math.max(500, Number(settings.logs) || defaultPollSettings.logs),
  };
  uiSettings.poll = cleaned;
  return cleaned;
}

function readCardSettings() {
  return {...defaultCardSettings, ...uiSettings.cards};
}

function saveCardSettings(settings) {
  const cleaned = {
    overview: !!settings.overview,
    system: !!settings.system,
    form: !!settings.form,
    logs: !!settings.logs,
  };
  uiSettings.cards = cleaned;
  return cleaned;
}

function readViewSettings() {
  return {...defaultViewSettings, ...uiSettings.view};
}

function saveViewSettings(settings) {
  const sortFields = new Set(["port", "name", "startup", "status", "api_ready"]);
  const sortDirections = new Set(["asc", "desc"]);
  const sizeUnits = new Set(["GB", "TB"]);
  const tempUnits = new Set(["C", "F"]);
  const current = readViewSettings();
  const warnReserve = Number(settings.modelSizeWarnReserveGb);
  const cleaned = {
    containerLimit: Math.max(1, Number(settings.containerLimit) || defaultViewSettings.containerLimit),
    modelSizeWarnReserveGb: Number.isFinite(warnReserve) ? Math.max(0, warnReserve) : current.modelSizeWarnReserveGb,
    containerSort: sortFields.has(settings.containerSort) ? settings.containerSort : defaultViewSettings.containerSort,
    containerSortDirection: sortDirections.has(settings.containerSortDirection) ? settings.containerSortDirection : defaultViewSettings.containerSortDirection,
    ramSizeUnit: sizeUnits.has(settings.ramSizeUnit) ? settings.ramSizeUnit : current.ramSizeUnit,
    vramSizeUnit: sizeUnits.has(settings.vramSizeUnit) ? settings.vramSizeUnit : current.vramSizeUnit,
    diskSizeUnit: sizeUnits.has(settings.diskSizeUnit) ? settings.diskSizeUnit : current.diskSizeUnit,
    systemTempUnit: tempUnits.has(settings.systemTempUnit) ? settings.systemTempUnit : current.systemTempUnit,
    showThroughput: settings.showThroughput !== false,
  };
  uiSettings.view = cleaned;
  return cleaned;
}

function readNotificationSettings() {
  return normalizeNotificationSettings(uiSettings.notifications || defaultNotificationSettings);
}

function notificationSettingsFromForm() {
  return normalizeNotificationSettings({
    ntfy: {
      enabled: ntfyEnabledInput.checked,
      server: ntfyServerInput.value,
      topic: ntfyTopicInput.value,
      token: ntfyTokenInput.value,
      monitors: collectMonitorSettings("ntfy"),
    },
    email: {
      enabled: emailEnabledInput.checked,
      smtp_host: emailSmtpHostInput.value,
      smtp_port: emailSmtpPortInput.value,
      username: emailUsernameInput.value,
      password: emailPasswordInput.value,
      from_addr: emailFromInput.value,
      to_addr: emailToInput.value,
      use_tls: emailTlsInput.checked,
      use_ssl: emailSslInput.checked,
      monitors: collectMonitorSettings("email"),
    },
    telegram: {
      enabled: telegramEnabledInput.checked,
      bot_token: telegramBotTokenInput.value,
      chat_id: telegramChatIdInput.value,
      monitors: collectMonitorSettings("telegram"),
    },
  });
}

function saveNotificationSettings(settings) {
  const cleaned = normalizeNotificationSettings(settings);
  uiSettings.notifications = cleaned;
  return cleaned;
}

function activeDisplayedDisks() {
  const disks = state?.system?.disks || [];
  const availableKeys = disks.map(diskKey);
  let activeKeys = Array.isArray(selectedDiskKeys) ? selectedDiskKeys.filter((key) => availableKeys.includes(key)) : [];
  if (selectedDiskKeys === null && disks.length) activeKeys = [diskKey(disks[0])];
  return disks.filter((disk) => activeKeys.includes(diskKey(disk)));
}

function monitorElement(type, attr, name) {
  return document.querySelector(`[data-monitor-type="${type}"][${attr}="${name}"]`);
}

function fillMonitorSettings(type, monitors = defaultMonitorSettings()) {
  ["error", "start", "stop", "notify_toggle", "temp", "vram", "ram"].forEach((name) => {
    const enabled = monitorElement(type, "data-monitor-enabled", name);
    if (enabled) enabled.checked = !!monitors[name]?.enabled;
    const limit = monitorElement(type, "data-monitor-limit", name);
    if (limit) limit.value = monitors[name]?.limit ?? defaultMonitorSettings()[name]?.limit ?? 90;
  });
}

function collectMonitorSettings(type) {
  const current = defaultMonitorSettings();
  ["error", "start", "stop", "notify_toggle", "temp", "vram", "ram"].forEach((name) => {
    const enabled = monitorElement(type, "data-monitor-enabled", name);
    const limit = monitorElement(type, "data-monitor-limit", name);
    current[name] = {
      enabled: !!enabled?.checked,
      ...(limit ? {limit: limit.value} : {}),
    };
  });
  current.disks = {};
  document.querySelectorAll(`[data-monitor-type="${type}"][data-monitor-disk-enabled]`).forEach((checkbox) => {
    const key = checkbox.dataset.diskKey || "";
    const limit = [...document.querySelectorAll(`[data-monitor-type="${type}"][data-monitor-disk-limit]`)]
      .find((input) => input.dataset.diskKey === key);
    current.disks[key] = {
      enabled: checkbox.checked,
      limit: limit?.value || 90,
    };
  });
  return normalizeMonitorSettings(current);
}

function renderNotificationDiskLimits(notificationSettings = readNotificationSettings()) {
  const disks = activeDisplayedDisks();
  ["ntfy", "telegram", "email"].forEach((type) => {
    const target = document.getElementById(`${type}DiskLimits`);
    if (!target) return;
    const monitors = notificationSettings[type]?.monitors || defaultMonitorSettings();
    if (!disks.length) {
      target.innerHTML = `<small>Keine HDD auf der Hauptseite angezeigt.</small>`;
      return;
    }
    target.innerHTML = disks.map((disk, index) => {
      const key = diskKey(disk);
      const cfg = monitors.disks?.[key] || {enabled: false, limit: 90};
      const label = `HDD${index + 1}`;
      return `
        <label class="monitor-row">
          <span><input data-monitor-type="${type}" data-monitor-disk-enabled data-disk-key="${escapeHtml(key)}" type="checkbox" ${cfg.enabled ? "checked" : ""}> ${label} &gt;</span>
          <input data-monitor-type="${type}" data-monitor-disk-limit data-disk-key="${escapeHtml(key)}" type="number" min="1" max="100" step="1" value="${escapeHtml(cfg.limit ?? 90)}">
          <span>%</span>
        </label>
      `;
    }).join("");
  });
}

function applyCardVisibility(settings = readCardSettings()) {
  overviewCard.classList.toggle("hidden", !settings.overview);
  systemCard.classList.toggle("hidden", !settings.system);
  form.classList.toggle("hidden", !settings.form);
  logsCard.classList.toggle("hidden", !settings.logs);
}

async function guardedPoll(key, fn) {
  if (pollBusy[key]) return;
  pollBusy[key] = true;
  try {
    await fn();
  } catch (error) {
    console.warn(`Refresh ${key} fehlgeschlagen:`, error);
  } finally {
    pollBusy[key] = false;
  }
}

function restartPolling() {
  Object.values(pollTimers).forEach((timer) => clearInterval(timer));
  const settings = readPollSettings();
  pollTimers = {
    overview: setInterval(() => guardedPoll("overview", refreshOverview), settings.overview),
    system: setInterval(() => guardedPoll("system", refreshSystem), settings.system),
    containers: setInterval(() => guardedPoll("containers", refreshContainers), settings.containers),
    logs: setInterval(() => guardedPoll("logs", refreshLogsArea), settings.logs),
  };
}

function metricBar(label, value, options = {}) {
  const missing = options.missing;
  const percent = Math.max(0, Math.min(100, Number(value || 0)));
  const fill = missing ? 0 : percent;
  const center = missing ? "-" : (options.center || "");
  const right = missing ? "-" : (Object.prototype.hasOwnProperty.call(options, "right") ? options.right : formatPercent(percent));
  const classes = ["metric-item"];
  if (options.toggle) classes.push("clickable");
  const attrs = options.toggle ? ` role="button" tabindex="0" data-metric-toggle="${escapeHtml(options.toggle)}"` : "";
  return `
    <div class="${classes.join(" ")}"${attrs}>
      <div class="metric-label">
        <span>${escapeHtml(label)}</span>
        <strong class="metric-center">${escapeHtml(center)}</strong>
        <strong class="metric-right">${escapeHtml(right)}</strong>
      </div>
      <div class="metric-track"><div class="metric-fill" style="width:${fill}%"></div></div>
    </div>
  `;
}

function renderSystemMetrics() {
  const system = state?.system || {};
  const gpu = system.gpu || {};
  const disks = system.disks || [];
  const viewSettings = readViewSettings();
  const ramSizeUnit = viewSettings.ramSizeUnit || "GB";
  const vramSizeUnit = viewSettings.vramSizeUnit || "GB";
  const diskSizeUnit = viewSettings.diskSizeUnit || "GB";
  const tempUnit = viewSettings.systemTempUnit || "C";
  const availableKeys = disks.map(diskKey);
  let activeKeys = Array.isArray(selectedDiskKeys) ? selectedDiskKeys.filter((key) => availableKeys.includes(key)) : [];
  if (selectedDiskKeys === null && disks.length) {
    activeKeys = [diskKey(disks[0])];
    saveSelectedDisks(activeKeys);
  } else if (Array.isArray(selectedDiskKeys) && activeKeys.join("|") !== selectedDiskKeys.join("|")) {
    saveSelectedDisks(activeKeys);
  }
  const diskItems = disks.filter((disk) => activeKeys.includes(diskKey(disk))).map((disk, index) => {
    const label = `HDD${index + 1}`;
    return metricBar(label, disk.percent, {
      center: formatUsage(disk.used, disk.total, diskSizeUnit),
      right: formatPercent(disk.percent),
      toggle: "disk-size",
    });
  });
  systemMetrics.innerHTML = [
    metricBar("CPU", system.cpu?.percent || 0, {right: formatPercent(system.cpu?.percent || 0)}),
    metricBar("RAM", system.ram?.percent || 0, {
      center: formatUsage(system.ram?.used, system.ram?.total, ramSizeUnit),
      right: formatPercent(system.ram?.percent || 0),
      toggle: "ram-size",
    }),
    metricBar("GPU", gpu.gpu_percent || 0, {missing: !gpu.available, right: formatPercent(gpu.gpu_percent || 0, !gpu.available)}),
    metricBar("VRAM", gpu.vram_percent || 0, {
      missing: !gpu.available,
      center: formatUsage(gpu.vram_used, gpu.vram_total, vramSizeUnit),
      right: formatPercent(gpu.vram_percent || 0, !gpu.available),
      toggle: "vram-size",
    }),
    metricBar("Temp", gpu.temp ?? 0, {
      missing: !gpu.available,
      center: formatTemp(gpu.temp, tempUnit, !gpu.available),
      right: "",
      toggle: "temp",
    }),
    ...diskItems,
  ].join("");
  addDiskBtn.disabled = !disks.length;
}

function renderDiskModal() {
  const disks = state?.system?.disks || [];
  if (!disks.length) {
    diskModalList.innerHTML = `<p>Keine HDDs gefunden.</p>`;
    return;
  }
  const selected = new Set(Array.isArray(selectedDiskKeys) ? selectedDiskKeys : []);
  diskModalList.innerHTML = disks.map((disk) => {
    const key = diskKey(disk);
    const detail = `${formatUsage(disk.used, disk.total, readViewSettings().diskSizeUnit)} | ${formatPercent(disk.percent)} belegt`;
    return `
      <label class="disk-option">
        <input type="checkbox" value="${escapeHtml(key)}" ${selected.has(key) ? "checked" : ""}>
        <span>
          <strong>${escapeHtml(diskLabel(disk))}</strong>
          <small>${escapeHtml(detail)}</small>
        </span>
      </label>
    `;
  }).join("");
}

function openDiskModal() {
  renderDiskModal();
  diskModal.classList.remove("hidden");
}

function closeDiskModal() {
  diskModal.classList.add("hidden");
}

async function applyDiskSelection() {
  const keys = [...diskModalList.querySelectorAll("input[type='checkbox']:checked")].map((input) => input.value);
  await saveSelectedDisks(keys);
  renderSystemMetrics();
  closeDiskModal();
}

async function toggleSystemMetric(kind) {
  const viewSettings = readViewSettings();
  if (kind === "temp") {
    saveViewSettings({...viewSettings, systemTempUnit: viewSettings.systemTempUnit === "C" ? "F" : "C"});
  } else if (kind === "ram-size") {
    saveViewSettings({...viewSettings, ramSizeUnit: viewSettings.ramSizeUnit === "GB" ? "TB" : "GB"});
  } else if (kind === "vram-size") {
    saveViewSettings({...viewSettings, vramSizeUnit: viewSettings.vramSizeUnit === "GB" ? "TB" : "GB"});
  } else if (kind === "disk-size") {
    saveViewSettings({...viewSettings, diskSizeUnit: viewSettings.diskSizeUnit === "GB" ? "TB" : "GB"});
  } else {
    return;
  }
  renderSystemMetrics();
  await persistUiSettings();
}

function fillSettingsForm(settings = readPollSettings()) {
  const cardSettings = readCardSettings();
  const viewSettings = readViewSettings();
  const notificationSettings = readNotificationSettings();
  designSelect.value = uiSettings.design || defaultUiSettings.design;
  overviewIntervalInput.value = settings.overview;
  systemIntervalInput.value = settings.system;
  containersIntervalInput.value = settings.containers;
  logsIntervalInput.value = settings.logs;
  containerLimitInput.value = viewSettings.containerLimit;
  modelSizeWarnReserveInput.value = viewSettings.modelSizeWarnReserveGb;
  containerSortInput.value = viewSettings.containerSort;
  containerSortDirectionInput.value = viewSettings.containerSortDirection;
  showThroughputInput.checked = viewSettings.showThroughput !== false;
  showOverviewCard.checked = cardSettings.overview;
  showSystemCard.checked = cardSettings.system;
  showFormCard.checked = cardSettings.form;
  showLogsCard.checked = cardSettings.logs;
  renderNotificationDiskLimits(notificationSettings);
  fillMonitorSettings("ntfy", notificationSettings.ntfy.monitors);
  fillMonitorSettings("telegram", notificationSettings.telegram.monitors);
  fillMonitorSettings("email", notificationSettings.email.monitors);
  ntfyEnabledInput.checked = notificationSettings.ntfy.enabled;
  ntfyServerInput.value = notificationSettings.ntfy.server;
  ntfyTopicInput.value = notificationSettings.ntfy.topic;
  ntfyTokenInput.value = notificationSettings.ntfy.token;
  telegramEnabledInput.checked = notificationSettings.telegram.enabled;
  telegramBotTokenInput.value = notificationSettings.telegram.bot_token;
  telegramChatIdInput.value = notificationSettings.telegram.chat_id;
  emailEnabledInput.checked = notificationSettings.email.enabled;
  emailSmtpHostInput.value = notificationSettings.email.smtp_host;
  emailSmtpPortInput.value = notificationSettings.email.smtp_port;
  emailUsernameInput.value = notificationSettings.email.username;
  emailPasswordInput.value = notificationSettings.email.password;
  emailFromInput.value = notificationSettings.email.from_addr;
  emailToInput.value = notificationSettings.email.to_addr;
  emailTlsInput.checked = notificationSettings.email.use_tls;
  emailSslInput.checked = notificationSettings.email.use_ssl;
}

function setEmailSecurityMode(mode) {
  if (mode === "ssl") {
    emailSslInput.checked = true;
    emailTlsInput.checked = false;
    emailSmtpPortInput.value = 465;
    return;
  }
  if (mode === "starttls") {
    emailTlsInput.checked = true;
    emailSslInput.checked = false;
    emailSmtpPortInput.value = 587;
    return;
  }
  emailTlsInput.checked = false;
  emailSslInput.checked = false;
}

function openSettingsModal() {
  fillSettingsForm();
  settingsModal.classList.remove("hidden");
}

function closeSettingsModal() {
  settingsModal.classList.add("hidden");
}

async function applySettings() {
  applyDesign(designSelect.value);
  savePollSettings({
    overview: overviewIntervalInput.value,
    system: systemIntervalInput.value,
    containers: containersIntervalInput.value,
    logs: logsIntervalInput.value,
  });
  applyCardVisibility(saveCardSettings({
    overview: showOverviewCard.checked,
    system: showSystemCard.checked,
    form: showFormCard.checked,
    logs: showLogsCard.checked,
  }));
  saveViewSettings({
    containerLimit: containerLimitInput.value,
    modelSizeWarnReserveGb: modelSizeWarnReserveInput.value,
    containerSort: containerSortInput.value,
    containerSortDirection: containerSortDirectionInput.value,
    showThroughput: showThroughputInput.checked,
  });
  saveNotificationSettings(notificationSettingsFromForm());
  showAllContainers = false;
  renderRows();
  await persistUiSettings();
  restartPolling();
  closeSettingsModal();
}

async function testNotification(type, button) {
  const oldText = button.textContent;
  button.disabled = true;
  button.textContent = "Teste...";
  try {
    await api("/api/notifications/test", {
      method: "POST",
      body: JSON.stringify({type, notifications: notificationSettingsFromForm()}),
    });
    button.textContent = "OK";
    window.setTimeout(() => {
      button.textContent = oldText;
      button.disabled = false;
    }, 1200);
  } catch (error) {
    alert(error.message);
    button.textContent = oldText;
    button.disabled = false;
  }
}

async function resetSettings() {
  const settings = savePollSettings(defaultPollSettings);
  applyDesign(defaultUiSettings.design);
  applyCardVisibility(saveCardSettings(defaultCardSettings));
  saveViewSettings(defaultViewSettings);
  saveNotificationSettings(defaultNotificationSettings);
  showAllContainers = false;
  renderRows();
  await persistUiSettings();
  fillSettingsForm(settings);
  restartPolling();
}

function applyTheme(theme, persist = false) {
  const normalized = theme === "day" ? "day" : "dark";
  uiSettings.theme = normalized;
  document.documentElement.dataset.theme = normalized;
  themeToggleBtn.textContent = normalized === "dark" ? "Day" : "Dark";
  if (persist) persistUiSettings();
}

function applyDesign(design, persist = false) {
  const normalized = availableDesigns.has(design) ? design : "default";
  uiSettings.design = normalized;
  document.documentElement.dataset.design = normalized;
  themeToggleBtn.classList.toggle("hidden", normalized !== "default");
  if (designSelect) designSelect.value = normalized;
  if (persist) persistUiSettings();
}

function initTheme() {
  applyTheme(uiSettings.theme || "dark");
  applyDesign(uiSettings.design || "default");
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

async function refreshOverview() {
  const data = await api("/api/overview");
  state = {...(state || {}), ...data};
  const version = escapeHtml(state.runner_version || "local");
  statusLine.innerHTML = `Version 0.56 - Hotfix: ${version} | &copy; 2026 <a href="https://interceptor.marconitschke.de/thread-157.html" target="_blank" rel="noopener noreferrer">Marco Nitschke</a> | <a href="https://hub.docker.com/u/nitje" target="_blank" rel="noopener noreferrer">DockerHub</a> | <a href="https://github.com/nitje" target="_blank" rel="noopener noreferrer">GitHub</a> | <a href="https://github.com/vllm-project/vllm" target="_blank" rel="noopener noreferrer">vLLM Projekt</a>`;
  renderNvidiaStatus();
}

async function refreshSystem() {
  const data = await api("/api/system");
  state = {...(state || {}), system: data.system};
  renderSystemMetrics();
}

async function refreshContainers() {
  const data = await api("/api/containers");
  state = {...(state || {}), containers: data.containers || [], ports_in_use: data.ports_in_use || []};
  renderRows();
  updateCreateFormPort();
}

async function refreshLogsArea() {
  await refreshJob();
  if (selectedName) await loadLogs(selectedName);
}

async function refresh() {
  await Promise.all([
    guardedPoll("overview", refreshOverview),
    guardedPoll("system", refreshSystem),
    guardedPoll("containers", refreshContainers),
  ]);
  await guardedPoll("logs", refreshLogsArea);
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

function containerSortValue(container, field) {
  if (field === "name") return String(container.name || "").toLowerCase();
  if (field === "startup") {
    const value = Number(container.startup_status?.sort_seconds);
    return Number.isFinite(value) && value > 0 ? value : null;
  }
  if (field === "status") {
    const ranks = {missing: 0, stopped: 1, running: 2};
    return Object.prototype.hasOwnProperty.call(ranks, container.status) ? ranks[container.status] : 1;
  }
  if (field === "api_ready") return container.api_ready ? 1 : 0;
  return Number(container.port || 0);
}

function compareContainerValues(aValue, bValue, direction) {
  const aMissing = aValue === null || aValue === undefined || aValue === "";
  const bMissing = bValue === null || bValue === undefined || bValue === "";
  if (aMissing && bMissing) return 0;
  if (aMissing) return 1;
  if (bMissing) return -1;
  if (typeof aValue === "string" || typeof bValue === "string") {
    return String(aValue).localeCompare(String(bValue)) * direction;
  }
  return (Number(aValue) - Number(bValue)) * direction;
}

function sortContainers(containers) {
  const viewSettings = readViewSettings();
  const field = viewSettings.containerSort;
  const direction = viewSettings.containerSortDirection === "desc" ? -1 : 1;
  return [...containers].sort((a, b) => {
    const primary = compareContainerValues(
      containerSortValue(a, field),
      containerSortValue(b, field),
      direction,
    );
    if (primary !== 0) return primary;
    const portTie = Number(a.port || 0) - Number(b.port || 0);
    if (portTie !== 0) return portTie;
    return String(a.name || "").localeCompare(String(b.name || ""));
  });
}

function normalizeSearch(value) {
  return String(value ?? "").trim().toLowerCase().replace(/\s+/g, " ");
}

function containerSearchText(container) {
  const apiStatus = container.api_ready ? "api_ready ready" : "api_not_ready not_ready";
  const autostart = container.autostart ? "autostart ja yes an aktiv" : "autostart nein no aus inaktiv";
  const configStatus = container.config_current ? "config aktuell" : "config geaendert geändert";
  return [
    container.name,
    container.status,
    apiStatus,
    container.profile,
    container.model_format,
    container.model,
    container.gguf_repo,
    container.gguf_file,
    container.gguf_url,
    container.tokenizer,
    container.hf_config_path,
    container.port,
    autostart,
    configStatus,
    container.api_url,
    container.api_models_url,
    container.download_progress?.label,
    container.startup_status?.text,
    container.runtime_status?.text,
    container.runtime_total_text,
    container.throughput_status?.label,
    container.throughput_status?.title,
    container.diagnostic,
  ].map((value) => String(value ?? "").toLowerCase()).join(" ");
}

function applyApiSearchRule(container, query) {
  let remaining = ` ${normalizeSearch(query)} `;
  const notReadyPhrases = ["api nicht bereit", "api not ready", "api_not_ready", "api-not-ready"];
  const readyPhrases = ["api bereit", "api ready", "api_ready", "api-ready"];
  if (notReadyPhrases.some((phrase) => remaining.includes(` ${phrase} `))) {
    if (container.api_ready) return null;
    notReadyPhrases.forEach((phrase) => {
      remaining = remaining.replaceAll(` ${phrase} `, " ");
    });
  } else if (readyPhrases.some((phrase) => remaining.includes(` ${phrase} `))) {
    if (!container.api_ready) return null;
    readyPhrases.forEach((phrase) => {
      remaining = remaining.replaceAll(` ${phrase} `, " ");
    });
  }
  return remaining.trim();
}

function matchesContainerSearch(container, query) {
  const remainingQuery = applyApiSearchRule(container, query);
  if (remainingQuery === null) return false;
  const terms = remainingQuery.split(/\s+/).filter(Boolean);
  if (!terms.length) return true;
  const haystack = containerSearchText(container);
  return terms.every((term) => haystack.includes(term));
}

function renderRows() {
  const allContainers = sortContainers(state?.containers || []);
  const searchQuery = normalizeSearch(containerSearch?.value);
  const containers = searchQuery
    ? allContainers.filter((container) => matchesContainerSearch(container, searchQuery))
    : allContainers;
  if (!containers.length) {
    rows.innerHTML = `<tr><td colspan="9">${searchQuery ? "Keine Container fuer diese Suche." : "Noch keine Container konfiguriert."}</td></tr>`;
    containerLimitControls.classList.add("hidden");
    return;
  }
  const limit = readViewSettings().containerLimit;
  const visibleContainers = searchQuery || showAllContainers ? containers : containers.slice(0, limit);
  const hasHiddenContainers = !searchQuery && containers.length > limit;
  containerLimitControls.classList.toggle("hidden", !hasHiddenContainers);
  containerLimitToggleBtn.classList.remove("hidden");
  if (searchQuery) {
    containerLimitControls.classList.remove("hidden");
    containerLimitSummary.textContent = `Suche: ${containers.length} von ${allContainers.length} Containern`;
    containerLimitToggleBtn.classList.add("hidden");
  }
  if (hasHiddenContainers) {
    containerLimitSummary.textContent = showAllContainers
      ? `Zeige alle ${containers.length} Container`
      : `Zeige ${visibleContainers.length} von ${containers.length} Containern`;
    containerLimitToggleBtn.textContent = showAllContainers ? "Weniger anzeigen" : "Alle anzeigen";
  }
  rows.innerHTML = visibleContainers.map((c) => {
    const modelCell = c.model_format === "gguf"
      ? `${escapeHtml(c.model)}<br><small>GGUF: ${renderGgufSource(c)}</small>${modelSizeLine(c)}`
      : `${escapeHtml(c.model)}${hfLink(c.model)}${modelSizeLine(c)}`;
    const startStopAction = c.status === "running" ? "stop" : "start";
    const startStopLabel = c.status === "running" ? "Stop" : "Start";
    const startStopClass = c.status === "running" ? "secondary" : "";
    const notifyEnabled = !!c.notify;
    const notifyDisabled = !c.notifications_available;
    const notifyClass = notifyEnabled ? "notify-enabled" : "secondary";
    const notifyTitle = notifyDisabled ? "Erst Benachrichtigungen in den Einstellungen einrichten" : (notifyEnabled ? "Benachrichtigung deaktivieren" : "Benachrichtigung aktivieren");
    return `
    <tr>
      <td><strong>${escapeHtml(c.name)}</strong><br>${runtimeLine(c.name, c.runtime_status)}${throughputLine(c.throughput_status)}</td>
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
          <button data-act="${startStopAction}" data-name="${escapeHtml(c.name)}" class="${startStopClass}">${startStopLabel}</button>
          <button data-act="notify" data-name="${escapeHtml(c.name)}" class="${notifyClass}" title="${escapeHtml(notifyTitle)}" ${notifyDisabled ? "disabled" : ""}>NTFY</button>
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
    } else if (action === "runtime-save") {
      const input = button.closest(".runtime-edit")?.querySelector("[data-runtime-input]");
      const seconds = hmsToSeconds(input?.value);
      if (seconds === null) {
        alert("Bitte Laufzeit als h:m:s eingeben, z.B. 1:23:45.");
        return;
      }
      await api(`/api/containers/${encodeURIComponent(name)}/runtime`, {method: "POST", body: JSON.stringify({seconds})});
      runtimeEditMode = false;
      runtimeEditDrafts = {};
      await refreshContainers();
      return;
    } else if (action === "start") {
      await startJob("start", name);
    } else if (action === "stop") {
      await startJob("stop", name);
    } else if (action === "notify") {
      const data = await api(`/api/containers/${encodeURIComponent(name)}/notify`, {
        method: "POST",
        body: JSON.stringify({enabled: !(item?.notify)}),
      });
      if (item) item.notify = data.notify;
      await refreshContainers();
      return;
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
    await Promise.all([refreshContainers(), refreshLogsArea()]);
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
settingsBtn.addEventListener("click", openSettingsModal);
addDiskBtn.addEventListener("click", openDiskModal);
systemMetrics.addEventListener("click", (event) => {
  const item = event.target.closest("[data-metric-toggle]");
  if (item) toggleSystemMetric(item.dataset.metricToggle);
});
systemMetrics.addEventListener("keydown", (event) => {
  if (event.key !== "Enter" && event.key !== " ") return;
  const item = event.target.closest("[data-metric-toggle]");
  if (!item) return;
  event.preventDefault();
  toggleSystemMetric(item.dataset.metricToggle);
});
diskModalSaveBtn.addEventListener("click", applyDiskSelection);
diskModalCancelBtn.addEventListener("click", closeDiskModal);
diskModalCloseBtn.addEventListener("click", closeDiskModal);
diskModal.addEventListener("click", (event) => {
  if (event.target.dataset.closeModal === "disk") closeDiskModal();
});
settingsModalSaveBtn.addEventListener("click", applySettings);
settingsModalResetBtn.addEventListener("click", resetSettings);
settingsModalCancelBtn.addEventListener("click", closeSettingsModal);
settingsModalCloseBtn.addEventListener("click", closeSettingsModal);
ntfyTestBtn.addEventListener("click", () => testNotification("ntfy", ntfyTestBtn));
emailTestBtn.addEventListener("click", () => testNotification("email", emailTestBtn));
telegramTestBtn.addEventListener("click", () => testNotification("telegram", telegramTestBtn));
emailTlsInput.addEventListener("change", () => setEmailSecurityMode(emailTlsInput.checked ? "starttls" : "none"));
emailSslInput.addEventListener("change", () => setEmailSecurityMode(emailSslInput.checked ? "ssl" : "none"));
settingsModal.addEventListener("click", (event) => {
  if (event.target.dataset.closeModal === "settings") closeSettingsModal();
});
document.addEventListener("keydown", (event) => {
  if (settingsModal.classList.contains("hidden")) {
    settingsSecretBuffer = "";
    return;
  }
  if (event.ctrlKey || event.altKey || event.metaKey || event.key.length !== 1) return;
  settingsSecretBuffer = `${settingsSecretBuffer}${event.key.toLowerCase()}`.slice(-3);
  if (settingsSecretBuffer === "css") {
    runtimeEditMode = true;
    runtimeEditDrafts = {};
    settingsSecretBuffer = "";
    renderRows();
  }
});
containerLimitToggleBtn.addEventListener("click", () => {
  showAllContainers = !showAllContainers;
  renderRows();
});
containerSearch.addEventListener("input", () => {
  renderRows();
});
rows.addEventListener("input", (event) => {
  const input = event.target.closest("[data-runtime-input]");
  if (!input) return;
  runtimeEditDrafts[input.dataset.name || ""] = input.value;
});
rows.addEventListener("keydown", async (event) => {
  if (event.key !== "Enter") return;
  const input = event.target.closest("[data-runtime-input]");
  if (!input) return;
  event.preventDefault();
  input.closest(".runtime-edit")?.querySelector("[data-act='runtime-save']")?.click();
});
document.querySelectorAll("[data-stepper-target]").forEach((button) => {
  button.addEventListener("click", () => {
    const input = document.getElementById(button.dataset.stepperTarget);
    if (!input) return;
    const delta = Number(button.dataset.stepperDelta || 0);
    const step = Number(input.step || 1);
    const min = input.min === "" ? -Infinity : Number(input.min);
    const max = input.max === "" ? Infinity : Number(input.max);
    const current = Number(input.value || 0);
    const next = Math.min(max, Math.max(min, current + delta * step));
    input.value = Number.isInteger(next) ? String(next) : String(Number(next.toFixed(2)));
  });
});
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
  applyTheme(document.documentElement.dataset.theme === "dark" ? "day" : "dark", true);
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

async function initApp() {
  await loadUiSettings();
  initTheme();
  applyCardVisibility();
  fillForm();
  await refresh();
  restartPolling();
}

initApp();
