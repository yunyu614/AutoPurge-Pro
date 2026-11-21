/**
 * AutoPurge Pro WebUI Frontend Controller (v4.4.2)
 * Author: liancan
 * Supports KernelSU / KernelSU Next / APatch / MMRL / WebUI X Bridge + Preview Sandbox
 */

const MODULE_ID = "Clear_Rubbish";
let MODDIR = "/data/adb/modules/Clear_Rubbish";
const CONFIG_DIR = "/data/media/0/Android/Clear/清理垃圾";
const SHELL = "/system/bin/sh";
// 部分管理器的 exec 环境 PATH 不完整，统一补上系统与应用管理器的可执行目录，
// 避免 `sh: not found` 被误报成“模块读取失败”。
const CMD_PREFIX = "export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH; ";
let CTL_SCRIPT = `${MODDIR}/bin/autopurge_ctl.sh`;

const FILE_PATHS = {
  blacklist: `${CONFIG_DIR}/名单配置/黑名单.conf`,
  whitelist: `${CONFIG_DIR}/名单配置/白名单.conf`,
  mtlist: `${CONFIG_DIR}/名单配置/MT.conf`,
  main_conf: `${CONFIG_DIR}/配置.conf`,
  timing_conf: `${CONFIG_DIR}/自定义定时设置/定时设置.conf`,
  timing_sh: `${CONFIG_DIR}/自定义定时设置/Timing_Settings.sh`,
  clear_log: `${CONFIG_DIR}/Clear.log`,
  history_log: `${CONFIG_DIR}/History_Files.log`,
  file_paths: `${CONFIG_DIR}/FilePaths.conf`
};

const SWITCH_LABELS = {
  master_switch: "模块总开关",
  timed_cleaning: "定时清理",
  mt_cleaning: "MT 残留清理",
  log_cleaning: "日志自动维护",
  apk_cleaning: "APK 自动清理",
  module_residue_cleaning: "模块残留清理",
  file_organize: "文件整理",
  blacklist_cleaning: "黑名单清理"
};

// State
let currentRuleType = "blacklist";
let isRawEditMode = false;
let currentRuleLines = [];
let rawRuleContentCache = {
  blacklist: "# 应用缓存\n/data/data/*/cache/*\n/data/media/0/Android/data/*/cache/*\n# 2345残留垃圾目录\n/data/media/0/2345*\n/data/media/0/Android/data/com.market2345/cache/*",
  whitelist: "# 白名单保护路径\n/sdcard/*\n/data/adb/*\n/data/media/0/DCIM/\n/data/media/0/Pictures/\n/data/media/0/Download/",
  mtlist: "/data/media/0/.*\n/data/media/0/QQBrowser/\n/data/media/0/MT2/.recycle/\n/data/media/0/ramdump/"
};

// ---------------------------------------------------------------- Root 桥接层
// 兼容 KernelSU / KernelSU Next / APatch（window.ksu）与 MMRL / WebUI X。
// 首次进入先做一次探测，把“没有桥接 / 未授权 Shell / 模块文件缺失 / 命令超时”
// 分开提示，避免把所有环境问题都显示成一句“模块读取失败”。

const Bridge = {
  obj: null,
  name: "",
  ready: false,
  probing: false,
  probeResult: null,
  mmrl: false,
  mmrlShell: null,
  reason: "",
  lastCommand: "",
  lastError: ""
};

function detectBridge() {
  const candidates = [
    { name: "KernelSU / APatch", obj: window.ksu },
    { name: "MMRL / WebUI X", obj: window.mmrl },
    { name: "APatch", obj: window.apatch }
  ];
  for (const c of candidates) {
    if (c.obj && typeof c.obj.exec === "function") {
      Bridge.obj = c.obj;
      Bridge.name = c.name;
      return true;
    }
  }
  Bridge.obj = null;
  Bridge.name = "";
  return false;
}
function hasBridge() { return !!Bridge.obj; }
// 旧调用点继续用 isKsuEnv()：只有探测通过后才执行真实命令。
function isKsuEnv() { return Bridge.ready; }

function isMmrl() {
  try { return typeof window.ksu?.mmrl === "function" && window.ksu.mmrl() === true; } catch (_) { return false; }
}
function mmrlShellAllowed() {
  try {
    // MMRL / WebUI X 把模块接口挂在 `$模块ID` 上，部分版本也保留无前缀别名。
    const api = window[`$${MODULE_ID}`] || window[MODULE_ID];
    if (api && typeof api.getHasAccessToAdvancedKernelSuAPI === "function") {
      return api.getHasAccessToAdvancedKernelSuAPI() === true;
    }
  } catch (_) {}
  return null;
}
function resolveModuleDir() {
  try {
    if (window.ksu && typeof window.ksu.moduleInfo === "function") {
      const info = JSON.parse(window.ksu.moduleInfo());
      if (info && typeof info.moduleDir === "string" && info.moduleDir.startsWith("/")) {
        MODDIR = info.moduleDir.replace(/\/+$/, "");
        CTL_SCRIPT = `${MODDIR}/bin/autopurge_ctl.sh`;
      }
    }
  } catch (_) {}
}

let cbCounter = 0;
let rootExecQueue = Promise.resolve();

function execRootCmdDirect(command, timeoutMs = 20000) {
  return new Promise((resolve) => {
    if (!Bridge.obj) {
      resolve({ errno: 127, stdout: "", stderr: "当前页面没有可用的 Root 桥接", noBridge: true });
      return;
    }
    const cbName = `ksu_cb_${Date.now()}_${++cbCounter}`;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { delete window[cbName]; } catch (_) {}
      if (result.errno !== 0 && result.stderr) Bridge.lastError = result.stderr;
      resolve(result);
    };
    const timer = setTimeout(() => finish({
      errno: 124,
      stdout: "",
      stderr: `Root 命令等待超时（${Math.round(timeoutMs / 1000)} 秒）：${String(command).slice(0, 80)}`
    }), timeoutMs);
    window[cbName] = (errno, stdout, stderr) => {
      // 少数管理器回传的是单个结果对象而不是三个参数
      if (errno && typeof errno === "object") {
        const o = errno;
        finish({ errno: Number(o.errno ?? o.code ?? 1), stdout: o.stdout || "", stderr: o.stderr || "" });
        return;
      }
      finish({ errno: Number(errno), stdout: stdout || "", stderr: stderr || "" });
    };
    Bridge.lastCommand = String(command);
    try {
      const ret = Bridge.obj.exec(`${CMD_PREFIX}${command}`, JSON.stringify({ cwd: "/" }), cbName);
      // 少数管理器的 exec 只实现同步返回，回调不会触发；这里一并兼容。
      if (typeof ret === "string" && !settled) {
        finish({ errno: 0, stdout: ret, stderr: "" });
      }
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      finish({ errno: 1, stdout: "", stderr: msg || "Root 桥接调用异常" });
    }
  });
}
// Serialize bridge calls: some Root WebView bridges become unstable when several
// shell commands are dispatched concurrently during page changes or fast taps.
function execRootCmd(command, timeoutMs = 20000) {
  const run = () => execRootCmdDirect(command, timeoutMs);
  const result = rootExecQueue.then(run, run);
  rootExecQueue = result.then(() => undefined, () => undefined);
  return result;
}

function showToast(msg) {
  if (Bridge.ready && Bridge.obj && typeof Bridge.obj.toast === "function") {
    try { Bridge.obj.toast(msg); } catch (_) {}
  }
  const box = document.getElementById("toastBox");
  if (!box) return;
  box.textContent = msg;
  box.classList.add("show");
  clearTimeout(window._toastTimer);
  window._toastTimer = setTimeout(() => box.classList.remove("show"), 2400);
}

// ---------------------------------------------------------------- 桥接状态横幅

function showBridgeBanner(tone, title, detail) {
  const box = document.getElementById("bridgeBanner");
  if (!box) return;
  box.hidden = false;
  box.className = `bridge-banner ${tone || "warn"}`;
  const t = document.getElementById("bridgeTitle");
  const d = document.getElementById("bridgeDetail");
  if (t) t.textContent = title || "";
  if (d) d.textContent = detail || "";
}
function hideBridgeBanner() {
  const box = document.getElementById("bridgeBanner");
  if (box) box.hidden = true;
}
function bridgeDiagnosticsText() {
  const r = Bridge.probeResult || {};
  return [
    "AutoPurge Pro WebUI 诊断",
    `时间: ${new Date().toLocaleString()}`,
    `桥接: ${Bridge.name || "无"} / ready=${Bridge.ready}`,
    `MMRL: ${Bridge.mmrl} / Shell权限=${Bridge.mmrlShell}`,
    `errno: ${r.errno ?? "?"}`,
    `stdout: ${String(r.stdout || "").slice(0, 800)}`,
    `stderr: ${String(r.stderr || "").slice(0, 800)}`,
    `模块目录: ${MODDIR}`,
    `控制脚本: ${CTL_SCRIPT}`,
    `UA: ${navigator.userAgent}`
  ].join("\n");
}
async function copyBridgeDiagnostics() {
  const text = bridgeDiagnosticsText();
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
      showToast("诊断信息已复制");
      return;
    }
  } catch (_) {}
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); showToast("诊断信息已复制"); }
  catch (_) { showToast("复制失败，请截图页面顶部提示"); }
  document.body.removeChild(ta);
}

async function probeRootBridge() {
  if (Bridge.probing) return Bridge.ready;
  Bridge.probing = true;
  try {
    detectBridge();
    resolveModuleDir();
    Bridge.mmrl = isMmrl();
    Bridge.mmrlShell = Bridge.mmrl ? mmrlShellAllowed() : null;

    if (!hasBridge()) {
      Bridge.ready = false;
      Bridge.reason = "no-bridge";
      // 有些 MMRL 版本会注入 ksu 对象但把 exec 收起来，需要区分于真正没有桥接。
      if (window.ksu && typeof window.ksu.exec !== "function" && Bridge.mmrl) {
        Bridge.reason = "mmrl-permission";
        showBridgeBanner("bad", "MMRL 未开启 Shell 接口",
          "检测到 MMRL 环境，但 ksu.exec 不可用。请在 MMRL 的模块设置中开启“高级 KernelSU API / Shell 权限”，然后点“重试”。");
        return false;
      }
      showBridgeBanner("warn", "预览模式：未检测到 Root 桥接",
        "当前页面不在 KernelSU / APatch / MMRL 的 WebUI 中，数据仅作展示，操作不会写入设备。请在模块管理器里打开本模块的 WebUI。");
      return false;
    }
    if (Bridge.mmrlShell === false) {
      Bridge.ready = false;
      Bridge.reason = "mmrl-permission";
      showBridgeBanner("bad", "MMRL 未授予 Shell 权限",
        "在 MMRL 中打开本模块页面 → 模块设置 → 开启“高级 KernelSU API / Shell 权限”，然后点“重试”。");
      return false;
    }

    const probeCmd = [
      "echo __AP_BRIDGE__",
      "echo \"uid=$(id -u 2>/dev/null)\"",
      "AP_CTL=\"\"",
      `for p in "${CTL_SCRIPT}" "/data/adb/modules/Clear_Rubbish/bin/autopurge_ctl.sh" "/data/adb/ksu/modules/Clear_Rubbish/bin/autopurge_ctl.sh"; do [ -f "$p" ] && { AP_CTL="$p"; break; }; done`,
      "if [ -n \"$AP_CTL\" ]; then echo \"__AP_CTL__ $AP_CTL\"; else echo __AP_CTL_MISSING__; fi"
    ].join("; ");
    const res = await execRootCmdDirect(probeCmd, 15000);
    Bridge.probeResult = res;
    const out = res.stdout || "";
    const err = (res.stderr || "").trim();

    if (!out.includes("__AP_BRIDGE__")) {
      Bridge.ready = false;
      Bridge.reason = res.errno === 124 ? "timeout" : "exec-failed";
      let hint = "桥接存在但命令没有执行成功，请尝试在管理器中重新打开 WebUI。";
      if (res.errno === 124) hint = "命令 15 秒内没有返回。请确认 Root 管理器在前台运行，或重启管理器后再试。";
      else if (/permission|denied|not allowed|权限/i.test(err)) hint = "Root 管理器拒绝了命令，请在管理器中给本模块 WebUI 授予 Shell / Root 权限。";
      showBridgeBanner("bad", "Root 命令执行失败", `${hint}${err ? "\n错误：" + err.slice(0, 200) : ""}\n可点“复制诊断”反馈。`);
      return false;
    }

    if (!/(^|\n)uid=0(\n|$)/.test(out)) {
      Bridge.ready = false;
      Bridge.reason = "no-root";
      const uid = (out.match(/uid=(\d+)/) || [])[1] || "未知";
      showBridgeBanner("bad", "Root 权限不可用",
        `桥接已连接，但命令以 uid=${uid} 运行，未获得 root。请确认设备已 Root，并在管理器中允许本模块执行 Shell。`);
      return false;
    }

    const ctlMatch = out.match(/__AP_CTL__\s+(\S+)/);
    if (ctlMatch) {
      CTL_SCRIPT = ctlMatch[1];
      MODDIR = ctlMatch[1].replace(/\/bin\/autopurge_ctl\.sh$/, "");
    } else if (out.includes("__AP_CTL_MISSING__")) {
      Bridge.ready = false;
      Bridge.reason = "module-missing";
      showBridgeBanner("bad", "模块文件缺失",
        `没有找到控制脚本：${CTL_SCRIPT}。安装可能不完整，请重新刷入模块 ZIP（升级会保留配置与统计）。`);
      return false;
    }

    Bridge.ready = true;
    Bridge.reason = "";
    hideBridgeBanner();
    return true;
  } catch (e) {
    Bridge.ready = false;
    Bridge.reason = "exception";
    showBridgeBanner("bad", "Root 桥接初始化异常", String(e && e.message ? e.message : e).slice(0, 240));
    return false;
  } finally {
    Bridge.probing = false;
  }
}

async function retryBridge() {
  showBridgeBanner("info", "正在重新检测 Root 桥接…", "请稍候");
  const ok = await probeRootBridge();
  if (ok) {
    await loadSimpleSchedule();
    await loadVersionInfo();
    await refreshDashboard();
    showToast("Root 桥接已连接");
  } else {
    showToast("仍未连接，请按页面顶部提示检查");
  }
}

function parseJsonLoose(text) {
  const raw = String(text || "").trim();
  if (!raw) return null;
  const lines = raw.split(/\r?\n/).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (line.startsWith("{")) {
      try { return JSON.parse(line); } catch (_) {}
    }
  }
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start >= 0 && end > start) {
    try { return JSON.parse(raw.slice(start, end + 1)); } catch (_) {}
  }
  return null;
}

// Base64 UTF-8 safe helpers for writing config files via shell without escaping issues
function utf8ToB64(str) {
  return window.btoa(unescape(encodeURIComponent(str)));
}

const RULE_FILE_KEYS = ["blacklist", "whitelist", "mtlist"];
async function readRootFile(path) {
  if (!isKsuEnv()) {
    // 预览模式仅缓存名单文件内容，其余路径返回空串
    const key = Object.keys(FILE_PATHS).find((k) => FILE_PATHS[k] === path);
    return RULE_FILE_KEYS.includes(key) ? (rawRuleContentCache[key] || "") : "";
  }
  const { errno, stdout } = await execRootCmd(`cat "${path}" 2>/dev/null`, 15000);
  return errno === 0 ? stdout : "";
}

async function writeRootFile(path, content, mode = "644") {
  if (!isKsuEnv()) {
    const key = Object.keys(FILE_PATHS).find((k) => FILE_PATHS[k] === path);
    if (RULE_FILE_KEYS.includes(key)) rawRuleContentCache[key] = content;
    return true;
  }
  const b64 = utf8ToB64(content);
  const cmd = `echo "${b64}" | base64 -d > "${path}.tmp" && chmod ${mode} "${path}.tmp" && mv -f "${path}.tmp" "${path}"`;
  const { errno } = await execRootCmd(cmd, 15000);
  return errno === 0;
}

function formatSizeFromKB(kb) {
  const num = Number(kb) || 0;
  if (num >= 1048576) return (num / 1048576).toFixed(2) + " GB";
  if (num >= 1024) return (num / 1024).toFixed(1) + " MB";
  return num + " KB";
}

// Tab Navigation
let tabLoadToken = 0;
function switchTab(tabId) {
  if (tabId === "files") tabId = "clean"; // legacy links now open the unified page
  document.querySelectorAll(".tab-pane").forEach((el) => el.classList.remove("active"));
  document.querySelectorAll(".nav-item").forEach((el) => el.classList.remove("active"));
  const targetPane = document.getElementById(`tab-${tabId}`);
  const targetNav = document.getElementById(`nav-${tabId}`);
  if (targetPane) targetPane.classList.add("active");
  if (targetNav) targetNav.classList.add("active");
  const token = ++tabLoadToken;
  const tasks = tabId === "dashboard" || tabId === "clean" ? [refreshDashboard()] :
    tabId === "rules" ? [reloadCurrentRuleFile(), loadFilePaths()] : tabId === "settings" ? [loadSimpleSchedule()] : tabId === "logs" ? [loadFeatureLogs()] : [];
  if (tasks.length) Promise.allSettled(tasks).then((results) => {
    if (token !== tabLoadToken) return;
    const failed = results.some((x) => x.status === "rejected");
    if (failed) showToast("页面数据读取未完成，可稍后点击刷新；界面仍可继续操作");
  });
}

// 定时计划：每天固定时间 / 每 N 分钟·小时·天
let scheduleMode = "daily";

function pad2(v) { return String(v).padStart(2, "0"); }
function unitLabel(unit) { return unit === "minute" ? "分钟" : unit === "day" ? "天" : "小时"; }
function intervalLimits(unit) {
  if (unit === "minute") return { min: 10, max: 1440, def: 30 };
  if (unit === "day") return { min: 1, max: 30, def: 1 };
  return { min: 1, max: 720, def: 6 };
}
function formatEpoch(epoch) {
  const n = Number(epoch);
  if (!Number.isFinite(n) || n <= 0) return "尚未排期";
  const d = new Date(n * 1000);
  if (Number.isNaN(d.getTime())) return "尚未排期";
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  return sameDay
    ? `今天 ${pad2(d.getHours())}:${pad2(d.getMinutes())}`
    : `${String(d.getMonth() + 1).padStart(2, "0")}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function initScheduleSelects() {
  const h = document.getElementById("dailyHour");
  const m = document.getElementById("dailyMinute");
  if (h) h.innerHTML = Array.from({ length: 24 }, (_, i) => `<option value="${i}">${pad2(i)}</option>`).join("");
  if (m) m.innerHTML = Array.from({ length: 60 }, (_, i) => `<option value="${i}">${pad2(i)}</option>`).join("");
  if (h) h.value = "3";
  if (m) m.value = "0";
  const iv = document.getElementById("intervalValue");
  if (iv) iv.value = "6";
  const iu = document.getElementById("intervalUnit");
  if (iu) iu.value = "hour";
  if (h) h.addEventListener("change", updateSimpleSchedulePreview);
  if (m) m.addEventListener("change", updateSimpleSchedulePreview);
  setScheduleMode("daily", false);
  if (isKsuEnv()) loadSimpleSchedule();
}

function setScheduleMode(mode, showTip = true) {
  scheduleMode = mode === "interval" ? "interval" : "daily";
  const dailyBox = document.getElementById("dailyScheduleBox");
  const intervalBox = document.getElementById("intervalScheduleBox");
  if (dailyBox) dailyBox.hidden = scheduleMode !== "daily";
  if (intervalBox) intervalBox.hidden = scheduleMode !== "interval";
  const bd = document.getElementById("schedModeDaily");
  const bi = document.getElementById("schedModeInterval");
  if (bd) bd.classList.toggle("active", scheduleMode === "daily");
  if (bi) bi.classList.toggle("active", scheduleMode === "interval");
  updateSimpleSchedulePreview();
  if (showTip) showToast(scheduleMode === "daily" ? "已切换：每天固定时间" : "已切换：按间隔执行");
}

function currentIntervalValue() {
  const iv = document.getElementById("intervalValue");
  const iu = document.getElementById("intervalUnit");
  const unit = iu ? iu.value : "hour";
  const limits = intervalLimits(unit);
  let n = parseInt(iv ? iv.value : "", 10);
  if (!Number.isInteger(n)) n = limits.def;
  return { n: Math.min(limits.max, Math.max(limits.min, n)), unit, limits };
}

function updateSimpleSchedulePreview() {
  const out = document.getElementById("scheduleSummary");
  if (!out) return;
  if (scheduleMode === "interval") {
    const { n, unit } = currentIntervalValue();
    const mins = unit === "minute" ? n : unit === "hour" ? n * 60 : n * 1440;
    const perDay = mins > 0 ? Math.floor(1440 / mins) : 0;
    out.textContent = `每 ${n} ${unitLabel(unit)}自动清理${perDay >= 1 ? `（约 ${perDay} 次/天）` : ""}，保存后从现在开始计时`;
  } else {
    const h = document.getElementById("dailyHour");
    const m = document.getElementById("dailyMinute");
    out.textContent = `每天 ${pad2(h ? h.value : 3)}:${pad2(m ? m.value : 0)} 自动清理`;
  }
}

function onIntervalUnitChange() {
  const iv = document.getElementById("intervalValue");
  const iu = document.getElementById("intervalUnit");
  if (!iv || !iu) return;
  const limits = intervalLimits(iu.value);
  const cur = parseInt(iv.value, 10);
  if (!Number.isInteger(cur) || cur < limits.min || cur > limits.max) iv.value = String(limits.def);
  iv.min = String(limits.min);
  iv.max = String(limits.max);
  updateSimpleSchedulePreview();
}

function setIntervalPreset(value, unit) {
  setScheduleMode("interval", false);
  const iv = document.getElementById("intervalValue");
  const iu = document.getElementById("intervalUnit");
  if (iu) iu.value = unit;
  if (iv) iv.value = String(value);
  onIntervalUnitChange();
  showToast(`已选择：每 ${value} ${unitLabel(unit)}`);
}

async function loadSimpleSchedule() {
  if (!isKsuEnv()) return;
  const content = await readRootFile(FILE_PATHS.timing_conf);
  if (!content) return;
  const get = (key) => {
    const m = content.match(new RegExp(`^${key}=(.*)$`, "m"));
    return m ? m[1].trim() : "";
  };
  const hour = get("Set_Time1") || "3";
  const minute = get("Set_minute1") || "0";
  const mode = get("Set_Mode") === "interval" ? "interval" : "daily";
  const unitRaw = get("Set_Interval_Unit");
  const unit = ["minute", "hour", "day"].includes(unitRaw) ? unitRaw : "hour";
  const limits = intervalLimits(unit);
  let n = parseInt(get("Set_Interval"), 10);
  if (!Number.isInteger(n)) n = limits.def;
  n = Math.min(limits.max, Math.max(limits.min, n));

  const h = document.getElementById("dailyHour");
  const m = document.getElementById("dailyMinute");
  if (h) h.value = /^(?:[0-9]|1[0-9]|2[0-3])$/.test(hour) ? String(Number(hour)) : "3";
  if (m) m.value = /^(?:[0-9]|[1-5][0-9])$/.test(minute) ? String(Number(minute)) : "0";
  const iv = document.getElementById("intervalValue");
  const iu = document.getElementById("intervalUnit");
  if (iu) iu.value = unit;
  if (iv) { iv.value = String(n); iv.min = String(limits.min); iv.max = String(limits.max); }
  setScheduleMode(mode, false);
}

async function saveSimpleSchedule() {
  const hourEl = document.getElementById("dailyHour");
  const minuteEl = document.getElementById("dailyMinute");
  if (!hourEl || !minuteEl) return;
  const h = Number(hourEl.value);
  const m = Number(minuteEl.value);
  if (!Number.isInteger(h) || h < 0 || h > 23 || !Number.isInteger(m) || m < 0 || m > 59) {
    showToast("时间无效，请重新选择");
    return;
  }

  let n = 6;
  let unit = "hour";
  if (scheduleMode === "interval") {
    const picked = currentIntervalValue();
    n = picked.n;
    unit = picked.unit;
    const { min, max } = picked.limits;
    if (n < min || n > max) {
      showToast(`间隔需在 ${min}-${max} ${unitLabel(unit)}之间`);
      return;
    }
  }

  const mm = pad2(m);
  const content = [
    `# AutoPurge Pro schedule (v4.4.2)`,
    `Set_Mode=${scheduleMode}`,
    `Set_Interval=${n}`,
    `Set_Interval_Unit=${unit}`,
    `Set_Time1=${h}`,
    `Set_minute1=${mm}`,
    `Set_weekday1=*`,
    `# Legacy compatibility`,
    `Set_Time2=${h}`,
    `Set_minute2=${mm}`,
    `Set_weekday2=*`,
    ""
  ].join("\n");

  if (!isKsuEnv()) {
    showToast("定时配置已在预览中修改，未写入设备");
    updateSimpleSchedulePreview();
    return;
  }
  const ok = await writeRootFile(FILE_PATHS.timing_conf, content, "644");
  if (!ok) {
    showToast("定时配置写入失败，请检查 Root 权限");
    return;
  }

  const res = await execRootCmd(`${SHELL} "${FILE_PATHS.timing_sh}"`, 30000);
  const output = `${res.stdout || ""}\n${res.stderr || ""}`.trim();
  if (res.errno !== 0 || /错误：|启动后立即退出|未找到包含/.test(output)) {
    showToast(output || "定时配置已保存，但定时服务启动失败");
    await refreshDashboard();
    return;
  }
  if (/后台任务未启动/.test(output)) {
    showToast("配置已保存；定时开关处于关闭状态");
  } else {
    showToast(scheduleMode === "interval"
      ? `定时服务已启动：每 ${n} ${unitLabel(unit)}`
      : `定时服务运行已确认：每天 ${pad2(h)}:${mm}`);
  }
  updateSimpleSchedulePreview();
  await refreshDashboard();

  // 用后台返回的下次执行时间补全摘要
  const statusRes = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" status`, 20000);
  const status = parseJsonLoose(statusRes.stdout);
  if (status && status.schedule && status.schedule.next_run_epoch) {
    const out = document.getElementById("scheduleSummary");
    if (out) {
      const base = scheduleMode === "interval"
        ? `每 ${n} ${unitLabel(unit)}自动清理`
        : `每天 ${pad2(h)}:${mm} 自动清理`;
      out.textContent = `${base}，下次 ${formatEpoch(status.schedule.next_run_epoch)}`;
    }
  }
}

// Dashboard Data Loading
let dashboardRefreshPromise = null;
let dashboardFailStreak = 0;
async function refreshDashboard() {
  if (dashboardRefreshPromise) return dashboardRefreshPromise;
  if (Bridge.ready) {
    dashboardRefreshPromise = (async () => {
      const { errno, stdout, stderr } = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" status`, 20000);
      const data = parseJsonLoose(stdout);
      if (errno === 0 && data) {
        renderDashboardData(data);
        dashboardFailStreak = 0;
        hideBridgeBanner();
        return;
      }
      dashboardFailStreak += 1;
      if (dashboardFailStreak === 1) {
        const detail = errno === 0
          ? `控制脚本输出无法解析：${String(stdout || "").slice(0, 160)}`
          : `status 命令返回 ${errno}。${String(stderr || "").slice(0, 200)}`;
        showBridgeBanner("bad", "模块状态读取失败", `${detail}\n可点“重试”或“复制诊断”反馈。`);
        showToast("模块状态读取失败，请查看页面顶部提示");
      }
    })();
    try { await dashboardRefreshPromise; } finally { dashboardRefreshPromise = null; }
    return;
  }
  if (!hasBridge()) {
    renderDashboardData({
      config: {
        master_switch: true, timed_cleaning: true, mt_cleaning: true, log_cleaning: true, log_purge_size: "2M",
        apk_cleaning: false, module_residue_cleaning: false, file_organize: false, blacklist_cleaning: true
      },
      schedule: { mode: "daily", interval: 6, interval_unit: "hour", next_run_epoch: 0, scheduler_running: true, t1: "0", m1: "00", w1: "*", t2: "12", m2: "00", w2: "*" },
      stats: {
        total_files: 1842, total_dirs: 316, total_runs: 28, total_freed_kb: 1482940, observed_space_increase_kb: 1482940,
        last_run_files: 64, last_run_dirs: 12, last_clean_time: "2026-11-06 11:30:00",
        bl_count: 492, wl_count: 18, mt_count: 31, log_size_bytes: 18432
      },
      daemons: { main_control: true, smart_clear: true, log_clear: true, crond: true },
      storage: { total_kb: 251658240, used_kb: 118489088, avail_kb: 133169152 }
    });
  }
  // 桥接存在但探测未通过时保留占位数据，避免用演示数字误导。
}

function renderDashboardData(data) {
  const cfg = data.config || {};
  const st = data.stats || {};
  const dm = data.daemons || {};
  const sc = data.schedule || {};
  const disk = data.storage || {};

  // Master switch UI
  const masterOn = cfg.master_switch !== false;
  const masterSwitch = document.getElementById("swMaster");
  if (masterSwitch) masterSwitch.checked = masterOn;
  document.getElementById("masterStatusTitle").textContent = masterOn ? "🟢 模块运行中" : "⏸️ 模块已暂停";
  document.getElementById("masterStatusDesc").textContent = masterOn ? "自动服务运行正常" : "后台自动任务已暂停";

  // Sub-switches（swCleanupMaster 表示全部子开关同时开启）
  const cleanupKeys = ["blacklist_cleaning", "mt_cleaning", "log_cleaning", "module_residue_cleaning", "apk_cleaning", "timed_cleaning"];
  setSwitch("swCleanupMaster", cleanupKeys.every((k) => cfg[k] !== false));
  setSwitch("swOrganizeMaster", cfg.file_organize === true);
  setSwitch("swTimed", cfg.timed_cleaning !== false);
  setSwitch("swMt", cfg.mt_cleaning !== false);
  setSwitch("swLog", cfg.log_cleaning !== false);
  setSwitch("swBlacklistClean", cfg.blacklist_cleaning !== false);
  setSwitch("swApkClean", cfg.apk_cleaning === true);
  setSwitch("swModResidue", cfg.module_residue_cleaning === true);
  const selLogSize = document.getElementById("selLogSize");
  if (selLogSize && cfg.log_purge_size) selLogSize.value = cfg.log_purge_size;

  // Daemons
  setDot("dotMain", dm.main_control);
  setDot("dotCron", dm.crond);
  setDot("dotSmart", dm.smart_clear);
  setDot("dotLog", dm.log_clear);

  // Stats
  setText("statTotalFiles", Number(st.total_files || 0).toLocaleString());
  setText("statTotalDirs", Number(st.total_dirs || 0).toLocaleString());
  setText("statLastFiles", `上次清理: +${st.last_run_files || 0} 个文件`);
  setText("statLastDirs", `上次清理: +${st.last_run_dirs || 0} 个目录`);
  setText("statTotalFreed", formatSizeFromKB(st.observed_space_increase_kb || 0));
  setText("statTotalRuns", `累计执行: ${st.total_runs || 0} 次`);
  setText("statLastTime", st.last_clean_time || "尚未执行");
  const schedText = sc.mode === "interval"
    ? `每 ${sc.interval || 6} ${unitLabel(sc.interval_unit)} · 下次 ${formatEpoch(sc.next_run_epoch)}`
    : `每天 ${pad2(sc.t1 ?? 0)}:${pad2(sc.m1 ?? 0)} · ${sc.scheduler_running ? "已启用" : "未运行"}`;
  setText("statCronSummary", schedText);

  // Badges
  setText("badgeBlCount", st.bl_count || 0);
  setText("badgeWlCount", st.wl_count || 0);
  setText("badgeMtCount", st.mt_count || 0);
  setText("curLogSizeDesc", `当前 Clear.log: ${(Number(st.log_size_bytes || 0) / 1024).toFixed(1)} KB`);

  // Storage bar
  if (disk.total_kb > 0) {
    const pct = Math.min(100, Math.round((disk.used_kb / disk.total_kb) * 100));
    const fill = document.getElementById("storageBarFill");
    if (fill) fill.style.width = `${pct}%`;
    setText("storagePercentText", `已用 ${pct}%`);
    setText("storageUsedText", `已用: ${(disk.used_kb / 1048576).toFixed(1)} GB`);
    setText("storageAvailText", `可用: ${(disk.avail_kb / 1048576).toFixed(1)} GB`);
  }

  applyThemeOnly();
}

function setDot(id, isOn) {
  const el = document.getElementById(id);
  if (el) el.className = "dot " + (isOn ? "on" : "off");
}
function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}
function setSwitch(id, checked) {
  const el = document.getElementById(id);
  if (el) el.checked = checked;
}

// Switch & Config Handlers
async function onCleanupMasterToggle(checked) {
  const keys = ["blacklist_cleaning", "mt_cleaning", "log_cleaning", "module_residue_cleaning", "apk_cleaning", "timed_cleaning"];
  const ids = ["swBlacklistClean", "swMt", "swLog", "swModResidue", "swApkClean", "swTimed"];
  ids.forEach((id) => setSwitch(id, checked));
  if (!isKsuEnv()) { showToast(`清理功能总开关已${checked ? "开启" : "关闭"}（预览模式）`); return; }
  const assignments = keys.map((key) => `${key} ${checked ? "true" : "false"}`).join(" ");
  const result = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" set_config ${assignments} && ${SHELL} "${CTL_SCRIPT}" apply`);
  if (result.errno !== 0) { showToast("清理总开关保存失败，请检查 Root 权限"); refreshDashboard(); return; }
  showToast(`清理功能及定时任务已${checked ? "全部启用" : "全部停用"}`);
  refreshDashboard();
}

async function onToggleSwitch(key, checked) {
  const val = checked ? "true" : "false";
  const label = SWITCH_LABELS[key] || key;
  if (isKsuEnv()) {
    const cmd = `${SHELL} "${CTL_SCRIPT}" set_config ${key} ${val} && ${SHELL} "${CTL_SCRIPT}" apply`;
    const result = await execRootCmd(cmd);
    if (result.errno !== 0) {
      showToast(`${label}保存失败，请检查 Root 权限`);
    } else {
      showToast(`已${checked ? "开启" : "关闭"} ${label}`);
    }
    refreshDashboard();
  } else {
    showToast(`已${checked ? "开启" : "关闭"} ${label}（预览模式）`);
  }
}

async function onChangeLogSize(val) {
  const allowed = ["512K", "1M", "2M", "5M", "10M"];
  if (!allowed.includes(val)) {
    showToast("无效的日志清理阈值");
    return;
  }
  if (isKsuEnv()) {
    const cmd = `${SHELL} "${CTL_SCRIPT}" set_config log_purge_size ${val} && (pkill -f "${MODDIR}/bin/LogClear" 2>/dev/null || true) && ${SHELL} "${CTL_SCRIPT}" apply`;
    const result = await execRootCmd(cmd);
    if (result.errno !== 0) {
      showToast("日志阈值保存失败，请检查 Root 权限");
      return;
    }
    showToast(`日志清理阈值已设为 ${val}`);
  } else {
    showToast(`日志清理阈值已设为 ${val}（预览模式）`);
  }
}

async function resetStats() {
  if (!window.confirm("确定重置累计清理统计吗？清理记录日志不会被删除。")) return;
  if (!isKsuEnv()) { showToast("已在预览模式重置统计"); return; }
  const res = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" reset_stats`);
  if (res.errno !== 0) { showToast("重置失败，请检查 Root 权限"); return; }
  showToast("累计统计已重置");
  refreshDashboard();
}

async function previewCleanup() {
  if (!isKsuEnv()) {
    showToast("清理预览需要在已授权的 Root WebUI 中执行");
    return;
  }
  const btn = document.getElementById("btnPreviewCleanup");
  if (btn) { btn.disabled = true; btn.textContent = "正在扫描…"; }
  try {
    const res = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" preview_cleanup`, 30000);
    if (res.errno !== 0) throw new Error(res.stderr || "预览扫描失败");
    const data = parseJsonLoose(res.stdout);
    if (!data || data.status !== "ok") throw new Error(data?.message || "预览结果无效");
    const details = (data.items || []).map((item) => {
      const type = item.type === "apk" ? "APK" : "本模块备份";
      return `[${type}] ${item.path}（${(Number(item.size || 0) / 1024).toFixed(1)} KB）`;
    });
    const summary = [
      `预览文件：${data.count || 0} 个`,
      `逻辑大小：${(Number(data.bytes || 0) / 1024).toFixed(1)} KB`,
      data.truncated ? "明细仅显示前 100 项。" : "",
      "",
      ...details,
      "",
      "注意：此预览只覆盖 Shell 管理的 APK 和本模块备份文件，不包含 TimingClear / MTClear 等闭源程序的清理目标。",
      "预览不会删除任何文件。"
    ].filter(Boolean).join("\n");
    window.alert(summary);
  } catch (e) {
    showToast(`清理预览失败：${String(e.message || e).slice(0, 90)}`);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = "预览清理范围"; }
  }
}

async function triggerCleanup(mode, btnId) {
  const btn = document.getElementById(btnId || (mode === "mt" ? "btnCleanMT" : "btnCleanAll"));
  if (btn && btn.disabled) return;
  const origText = btn ? btn.textContent : "";
  if (btn) { btn.disabled = true; btn.textContent = "⏳ 正在启动清理..."; }

  try {
    if (!isKsuEnv()) {
      await new Promise((r) => setTimeout(r, 600));
      showToast("清理完成！已删除 23 个文件，5 个目录（预览）");
      return;
    }

    const startRes = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" start_clean ${mode}`);
    let startInfo = {};
    try { startInfo = parseJsonLoose(startRes.stdout); } catch (_) {}
    if (startRes.errno !== 0 || !["started", "already_running"].includes(startInfo.status)) {
      throw new Error(startRes.stderr || "无法启动清理任务");
    }
    showToast(startInfo.status === "already_running" ? "已有清理任务正在执行，请稍候" : "清理任务已在后台启动，界面可继续操作");
    if (btn) btn.textContent = "⏳ 后台清理中...";

    const startedAt = Date.now();
    let finished = false;
    while (!finished && Date.now() - startedAt < 30 * 60 * 1000) {
      await new Promise((r) => setTimeout(r, 2000));
      const statusRes = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" clean_status`);
      let status = {};
      try { status = parseJsonLoose(statusRes.stdout); } catch (_) {}
      if (status.status === "done") {
        finished = true;
        showToast(status.success ? "清理已完成" : "清理任务结束，请查看运行日志");
        break;
      }
      if (status.status === "idle") {
        finished = true;
        showToast("清理任务状态已结束，请刷新统计或查看日志");
      }
    }
    if (!finished) showToast("清理仍在后台运行，可稍后查看清理记录");
    await refreshDashboard();
  } catch (e) {
    showToast(`清理启动失败：${String(e.message || e).slice(0, 80)}`);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = origText; }
  }
}

// Rules Management (Blacklist / Whitelist / MT.conf)
function switchRuleType(type) {
  currentRuleType = type;
  document.getElementById("segBtnBlacklist").classList.toggle("active", type === "blacklist");
  document.getElementById("segBtnWhitelist").classList.toggle("active", type === "whitelist");
  document.getElementById("segBtnMtlist").classList.toggle("active", type === "mtlist");
  document.getElementById("currentRuleFilePath").textContent = FILE_PATHS[type];
  reloadCurrentRuleFile();
}

function toggleRuleEditMode() {
  isRawEditMode = !isRawEditMode;
  document.getElementById("visualRuleView").style.display = isRawEditMode ? "none" : "block";
  document.getElementById("rawRuleView").style.display = isRawEditMode ? "block" : "none";
  document.getElementById("btnToggleEditMode").textContent = isRawEditMode ? "📋 列表模式" : "📝 源码模式";
  if (isRawEditMode) {
    document.getElementById("rawRuleTextarea").value = serializeRuleLines();
  } else {
    parseRuleTextToLines(document.getElementById("rawRuleTextarea").value);
    renderVisualRuleList();
  }
}

async function reloadCurrentRuleFile() {
  const path = FILE_PATHS[currentRuleType];
  const content = await readRootFile(path);
  document.getElementById("rawRuleTextarea").value = content;
  parseRuleTextToLines(content);
  renderVisualRuleList();
}

function parseRuleTextToLines(text) {
  const rawLines = (text || "").replace(/\r/g, "").split("\n");
  currentRuleLines = [];
  let pendingCategory = "";
  for (const rawLine of rawLines) {
    const trimmed = rawLine.trim();
    if (!trimmed) {
      currentRuleLines.push({ type: "empty", raw: "" });
      continue;
    }
    if (/^#\s*\//.test(trimmed)) {
      // 注释掉的路径 = 停用的规则
      currentRuleLines.push({ type: "rule", path: trimmed.replace(/^#\s*/, ""), enabled: false, category: pendingCategory });
    } else if (trimmed.startsWith("#")) {
      pendingCategory = trimmed.replace(/^#+\s*/, "");
      currentRuleLines.push({ type: "comment", text: trimmed });
    } else {
      currentRuleLines.push({ type: "rule", path: trimmed, enabled: true, category: pendingCategory });
    }
  }
}

function serializeRuleLines() {
  return currentRuleLines
    .map((item) => {
      if (item.type === "empty") return "";
      if (item.type === "comment") return item.text;
      return item.enabled ? item.path : `#${item.path}`;
    })
    .join("\n");
}

function getRuleAppGroup(path) {
  const patterns = [/\/data\/data\/([^/]+)\//, /\/Android\/data\/([^/]+)\//, /\/Android\/media\/([^/]+)\//, /\/Android\/obb\/([^/]+)\//];
  for (const re of patterns) {
    const m = path.match(re);
    if (m) return m[1];
  }
  return "其他路径";
}

function renderVisualRuleList() {
  const container = document.getElementById("visualRuleList");
  if (!container) return;
  const keyword = (document.getElementById("inpSearchRule")?.value || "").trim().toLowerCase();
  const groups = new Map();
  let activeCount = 0;
  currentRuleLines.forEach((item, idx) => {
    if (item.type !== "rule") return;
    if (item.enabled) activeCount++;
    const app = getRuleAppGroup(item.path);
    if (!groups.has(app)) groups.set(app, []);
    groups.get(app).push({ item, idx });
  });
  let html = "";
  for (const [app, items] of groups) {
    const visible = items.filter(({ item }) => !keyword || item.path.toLowerCase().includes(keyword) || app.toLowerCase().includes(keyword) || (item.category || "").toLowerCase().includes(keyword));
    if (!visible.length) continue;
    const enabled = visible.filter((x) => x.item.enabled).length;
    html += `<details class="rule-app-group" ${keyword ? "open" : ""}>
      <summary class="rule-app-summary"><span class="rule-app-name">${escapeHtml(app)}</span><span class="rule-app-meta">${enabled}/${visible.length} 启用</span><span class="rule-app-chevron">⌄</span></summary>
      <div class="rule-app-paths">${visible.map(({ item, idx }) => `
        <div class="rule-row ${item.enabled ? "" : "commented"}">
          <div class="rule-row-main"><div class="rule-path">${escapeHtml(item.path)}</div>${item.category ? `<span class="rule-note">${escapeHtml(item.category)}</span>` : ""}</div>
          <div class="rule-row-actions"><button class="btn btn-sm btn-outline" onclick="toggleRuleItem(${idx})">${item.enabled ? "已启用" : "已停用"}</button><button class="btn btn-sm btn-danger" onclick="deleteRuleItem(${idx})" aria-label="删除规则">✕</button></div>
        </div>`).join("")}</div>
    </details>`;
  }
  if (!html) html = `<div class="rule-empty">暂无符合条件的规则</div>`;
  container.innerHTML = html;
  const summary = document.getElementById("ruleCountSummary");
  if (summary) summary.textContent = `共 ${currentRuleLines.filter((x) => x.type === "rule").length} 条路径，${activeCount} 条启用 · 按应用归类`;
}

function addNewRuleItem() {
  const inp = document.getElementById("inpNewRulePath");
  const val = (inp.value || "").trim();
  if (!val) {
    showToast("请输入有效的路径或通配符规则");
    return;
  }
  if (!val.startsWith("/")) {
    showToast("路径规则必须以 / 开头，例如 /data/media/0/...");
    return;
  }
  currentRuleLines.unshift({ type: "rule", path: val, enabled: true, category: "WebUI自定义添加" });
  inp.value = "";
  document.getElementById("rawRuleTextarea").value = serializeRuleLines();
  renderVisualRuleList();
  showToast("已添加至列表顶部，请点击【保存修改】写入文件");
}

function toggleRuleItem(idx) {
  if (!currentRuleLines[idx]) return;
  currentRuleLines[idx].enabled = !currentRuleLines[idx].enabled;
  document.getElementById("rawRuleTextarea").value = serializeRuleLines();
  renderVisualRuleList();
}

function deleteRuleItem(idx) {
  currentRuleLines.splice(idx, 1);
  document.getElementById("rawRuleTextarea").value = serializeRuleLines();
  renderVisualRuleList();
}

async function saveCurrentRuleFile() {
  const content = isRawEditMode
    ? document.getElementById("rawRuleTextarea").value
    : serializeRuleLines();
  const path = FILE_PATHS[currentRuleType];
  const ok = await writeRootFile(path, content, "644");
  if (ok) {
    parseRuleTextToLines(content);
    renderVisualRuleList();
    showToast("名单配置已成功保存并生效！");
  } else {
    showToast("写入配置文件失败，请检查 Root 权限");
  }
}

// History & Logs Management
async function clearAllLogs() {
  if (!window.confirm("确定清空所有功能日志与操作记录吗？此操作不可撤销。")) return;
  if (isKsuEnv()) {
    const res = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" clear_logs`);
    if (res.errno !== 0) { showToast("日志清空失败，请检查 Root 权限"); return; }
  }
  const out = document.getElementById("featureLogView");
  if (out) out.textContent = "日志已清空。";
  showToast("功能日志已清空");
}

function escapeHtml(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function quickFillRule(path) {
  const input = document.getElementById("inpNewRulePath");
  if (!input) return;
  input.value = path;
  input.focus();
}

// File path preferences: persisted separately from the cleanup rules.
const PATH_FIELDS = ["storage_root", "download", "qq", "wechat", "telegram", "bluetooth", "images", "videos", "audio", "apks", "modules"];
const PATH_DEFAULTS = {
  storage_root: "/storage/emulated/0", download: "/storage/emulated/0/Download", qq: "/storage/emulated/0/QQfile_recv",
  wechat: "/storage/emulated/0/WeChat", telegram: "/storage/emulated/0/Telegram", bluetooth: "/storage/emulated/0/Bluetooth",
  images: "/storage/emulated/0/Pictures/AutoPurge", videos: "/storage/emulated/0/Movies/AutoPurge", audio: "/storage/emulated/0/Music/AutoPurge",
  apks: "/storage/emulated/0/安装包/AutoPurge", modules: "/storage/emulated/0/模块安装包/AutoPurge"
};
async function loadFilePaths() {
  let values = { ...PATH_DEFAULTS };
  if (isKsuEnv()) {
    const raw = await readRootFile(FILE_PATHS.file_paths);
    raw.split(/\r?\n/).forEach((line) => {
      const i = line.indexOf("=");
      if (i < 1) return;
      const key = line.slice(0, i).trim(), val = line.slice(i + 1).trim();
      if (PATH_FIELDS.includes(key) && val) values[key] = val;
    });
  }
  PATH_FIELDS.forEach((key) => {
    const el = document.getElementById(`path_${key}`);
    if (el) el.value = values[key];
  });
}
async function saveFilePaths() {
  const values = {};
  for (const key of PATH_FIELDS) {
    const el = document.getElementById(`path_${key}`);
    if (!el) continue;
    const val = el.value.trim();
    if (!val.startsWith("/storage/emulated/0/") && val !== "/storage/emulated/0" && !val.startsWith("/sdcard/") && val !== "/sdcard") {
      showToast("路径必须位于共享存储目录内"); el.focus(); return;
    }
    if (/(\.\.|[\n\r"'`$\\|;&<>])/.test(val)) {
      showToast("路径包含不支持的字符"); el.focus(); return;
    }
    values[key] = val;
  }
  if (values.storage_root && !Object.values(values).every((v) => v === values.storage_root || v.startsWith(values.storage_root + "/") || (values.storage_root === "/storage/emulated/0" && v.startsWith("/sdcard/")))) {
    showToast("所有扫描与归档路径必须位于扫描根目录内"); return;
  }
  const content = PATH_FIELDS.map((k) => `${k}=${values[k] || PATH_DEFAULTS[k]}`).join("\n") + "\n";
  if (!isKsuEnv()) { showToast("路径格式检查通过；请在 Root WebUI 中保存到设备"); return; }
  const ok = await writeRootFile(FILE_PATHS.file_paths, content, "600");
  showToast(ok ? "文件路径已保存" : "保存失败，请检查 Root 权限");
}

// Logs
let currentLogCategory = "all";
function openLogs() { switchTab("logs"); }
function switchLogCategory(category, button) {
  currentLogCategory = category;
  document.querySelectorAll(".log-category-tabs .seg-btn").forEach((el) => el.classList.remove("active"));
  if (button) button.classList.add("active");
  loadFeatureLogs();
}
async function loadFeatureLogs() {
  const out = document.getElementById("featureLogView");
  if (!out) return;
  let lines = "";
  if (isKsuEnv()) {
    const [clearRes, historyRes] = await Promise.all([
      execRootCmd(`tail -n 400 "${FILE_PATHS.clear_log}" 2>/dev/null`, 12000),
      execRootCmd(`tail -n 400 "${FILE_PATHS.history_log}" 2>/dev/null`, 12000)
    ]);
    lines = Array.from(new Set(`${clearRes.stdout || ""}\n${historyRes.stdout || ""}`.split(/\r?\n/).filter(Boolean))).join("\n");
    if (!lines && (clearRes.errno !== 0 || historyRes.errno !== 0)) lines = "日志读取失败，请检查权限或日志文件路径。";
  } else {
    lines = ["2026-11-06 12:00:00 [智能清理] 示例：清理任务完成", "2026-11-06 12:01:00 [MT清理] 示例：规则检查完成", "2026-11-06 12:02:00 [文件归位] 示例：文件归档完成", "2026-11-06 12:03:00 [服务] 示例：服务状态正常"].join("\n");
  }
  const match = {
    all: () => true,
    clean: (l) => /删除文件|删除目录|APK清理|模块残留/.test(l),
    mt: (l) => /MT清理|MT管理器/.test(l),
    files: (l) => /文件归位|文件整理/.test(l),
    service: (l) => /服务|守护|定时|LogClear/.test(l)
  }[currentLogCategory] || (() => true);
  const filtered = lines.split(/\r?\n/).filter(match);
  out.textContent = filtered.slice(-250).join("\n") || "该分类暂无日志记录。";
}

// File tasks run in a detached shell worker. The WebView only polls a tiny state file,
// so large find/mv operations never occupy the Root bridge for their full duration.
let fileTaskRunning = false;
let fileTaskPollToken = 0;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function runFileTask(task) {
  if (fileTaskRunning) { showToast("已有文件任务正在执行，请稍候"); return null; }
  if (!isKsuEnv()) { showToast("请在 Root WebUI 中执行真实文件任务"); return null; }
  fileTaskRunning = true;
  const token = ++fileTaskPollToken;
  try {
    const start = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" ${task === "scan" ? "scan_files" : "organize_files"}`, 8000);
    let info = {};
    try { info = parseJsonLoose(start.stdout); } catch (_) {}
    if (start.errno !== 0 || !["started", "already_running"].includes(info.status)) {
      throw new Error(start.stderr || "后台任务启动失败");
    }
    showToast(task === "scan" ? "扫描已在后台启动，可继续浏览页面" : "归档已在后台启动，可继续浏览页面");
    const began = Date.now();
    while (token === fileTaskPollToken && Date.now() - began < 10 * 60 * 1000) {
      await delay(2000);
      const poll = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" file_task_status`, 8000);
      let state = {};
      try { state = parseJsonLoose(poll.stdout); } catch (_) {}
      if (state.status === "running" || state.status === "already_running") continue;
      if (state.status === "done") return state;
      if (state.status === "error") throw new Error(state.message || "后台任务异常结束");
    }
    if (Date.now() - began >= 10 * 60 * 1000) throw new Error("任务仍在后台运行，稍后可重新查看状态");
    return null;
  } finally {
    fileTaskRunning = false;
  }
}

async function scanUserFiles() {
  const btn = document.getElementById("btnScanFiles");
  if (btn) { btn.disabled = true; btn.textContent = "扫描中…"; }
  try {
    const state = await runFileTask("scan");
    if (!state) return;
    const data = state.result || {};
    const values = [data.total, data.images, data.videos, data.audio, data.apks, data.archives];
    ["Total", "Images", "Videos", "Audio", "Apks", "Archives"].forEach((key, i) => {
      const el = document.getElementById(`scan${key}`);
      if (el) el.textContent = Number(values[i] || 0).toLocaleString();
    });
    showToast("扫描完成：已统计可识别文件");
  } catch (e) {
    showToast(`扫描失败：${String(e.message || e).slice(0, 70)}`);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = "扫描文件"; }
  }
}

async function organizeUserFiles() {
  if (fileTaskRunning) { showToast("已有文件任务正在执行，请稍候"); return; }
  if (!isKsuEnv()) { showToast("请在 Root WebUI 中执行真实文件整理"); return; }
  if (!window.confirm("将把识别到的媒体文件归入独立分类目录。不会主动删除文件，是否继续？")) return;
  const btn = document.getElementById("btnOrganizeFiles");
  if (btn) { btn.disabled = true; btn.textContent = "归档中…"; }
  try {
    const state = await runFileTask("organize");
    if (state) {
      const result = state.result || {};
      if (result.status === "error" || Number(result.failed || 0) > 0) {
        showToast(`归档结束：成功移动 ${Number(result.moved || 0)} 个，失败 ${Number(result.failed || 0)} 个`);
      } else {
        showToast(`归档完成：成功移动 ${Number(result.moved || 0)} 个文件`);
      }
    }
  } catch (e) {
    showToast(`归档失败：${String(e.message || e).slice(0, 70)}`);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = "开始归档"; }
  }
}

// Initialize on DOMContentLoaded
window.addEventListener("DOMContentLoaded", async () => {
  applyUiPrefs();
  initScheduleSelects();
  const connected = await probeRootBridge();
  if (connected) {
    await loadSimpleSchedule();
    await loadVersionInfo();
  }
  await refreshDashboard();
});

// Dynamic module version (falls back to the static HTML value)
async function loadVersionInfo() {
  if (!isKsuEnv()) return;
  try {
    const res = await execRootCmd(`${SHELL} "${CTL_SCRIPT}" version`);
    const info = parseJsonLoose(res.stdout);
    const el = document.getElementById("aboutVersion");
    if (el && info.version && info.version !== "unknown") el.textContent = `v${info.version}`;
  } catch (_) {}
}

// Appearance preferences (stored locally in WebView; independent from module engine)
const UI_PREFS_KEY = "autopurge_pro_ui_v400";
const LEGACY_UI_PREFS_KEY = "autopurge_pro_ui_v300";
const uiPrefs = (() => {
  try {
    const saved = localStorage.getItem(UI_PREFS_KEY) || localStorage.getItem(LEGACY_UI_PREFS_KEY) || "{}";
    return Object.assign({ theme: "auto", palette: "blue", language: "zh", navMode: "floating" }, JSON.parse(saved));
  } catch (_) { return { theme: "auto", palette: "blue", language: "zh", navMode: "floating" }; }
})();
function saveUiPrefs() {
  try { localStorage.setItem(UI_PREFS_KEY, JSON.stringify(uiPrefs)); return true; }
  catch (_) { showToast("个性化设置保存失败，可能是 WebView 存储空间不足"); return false; }
}
function setTheme(theme) {
  uiPrefs.theme = ["auto", "light", "dark"].includes(theme) ? theme : "auto";
  applyUiPrefs(); saveUiPrefs();
  showToast(uiPrefs.language === "en" ? "Theme updated" : "主题模式已切换");
}
function setPalette(palette) {
  uiPrefs.palette = ["blue", "sage", "lilac", "rose", "sand"].includes(palette) ? palette : "blue";
  applyThemeOnly(); saveUiPrefs();
  showToast("主题色已更新");
}
function setLanguage(language) {
  uiPrefs.language = language === "en" ? "en" : "zh";
  applyUiPrefs(); saveUiPrefs();
  showToast(uiPrefs.language === "en" ? "Language updated" : "语言已切换");
}
function setNavMode(mode) {
  uiPrefs.navMode = mode === "floating" ? "floating" : "traditional";
  applyThemeOnly(); saveUiPrefs();
  showToast(uiPrefs.language === "en" ? "Navigation style updated" : "底栏样式已切换");
}

// EN translations for exact-match static text nodes (kept in sync with index.html)
const UI_EN = {
  "轻量 · 安全 · 智能存储管理": "Light · Safe · Smart storage",
  "立即清理": "Clean now", "仅清理 MT": "MT only", "手动执行": "Manual run",
  "主控守护": "MainControl", "定时器": "Scheduler", "MT 监测": "MT Monitor", "日志守护": "Log Monitor",
  "🟢 模块运行中": "🟢 Module Running", "⏸️ 模块已暂停": "⏸️ Module Paused",
  "守护服务状态与运行概况": "Daemons & run overview", "自动服务运行正常": "Automatic services are running", "后台自动任务已暂停": "Automatic tasks are paused",
  "累计清理文件": "Files cleaned", "累计清理目录": "Dirs cleaned", "累计可用空间增加": "Observed space increase", "最近清理时间": "Last cleanup",
  "黑名单规则": "Blacklist rules", "白名单保护": "Whitelist", "MT清理规则": "MT rules",
  "存储空间": "Storage",
  "清理功能": "Cleanup", "黑名单清理": "Blacklist cleanup", "MT 残留清理": "MT residue cleanup",
  "日志自动维护": "Log maintenance", "模块残留清理": "Module residue", "APK 自动清理": "APK cleanup", "定时清理": "Scheduled cleanup",
  "文件整理": "File organizing", "扫描文件": "Scan files", "开始归档": "Organize", "修改路径": "Edit paths",
  "待整理": "Pending", "图片": "Images", "视频": "Videos", "音频": "Audio", "安装包": "APKs", "压缩包": "Archives",
  "规则与路径": "Rules & Paths", "黑名单": "Blacklist", "白名单": "Whitelist", "MT 名单": "MT list",
  "+ 添加": "+ Add", "重新读取": "Reload", "保存修改": "Save changes", "保存路径": "Save paths",
  "存储根目录": "Storage root", "扫描来源路径": "Scan sources", "分类归档目标": "Archive targets",
  "功能日志": "Logs", "刷新": "Refresh", "全部": "All", "清理": "Cleanup", "整理": "Files", "服务": "Service",
  "清空日志": "Clear logs", "返回设置": "Back to settings",
  "个性化外观": "Appearance", "主题模式": "Theme", "跟随系统": "System", "浅色": "Light", "夜间": "Dark",
  "主题色": "Accent color", "底部导航": "Bottom nav", "悬浮底栏": "Floating", "固定底栏": "Fixed",
  "界面语言": "Language", "中文": "中文", "English": "English",
  "⏰ 定时与服务": "⏰ Schedule & Service", "每天固定时间": "Fixed daily time",
  "按间隔": "Interval", "每天执行时间": "Daily run time", "每隔多久执行": "Run every",
  "每": "Every", "一次": "once", "分钟": "minutes", "小时": "hours", "天": "days",
  "30 分钟": "30 min", "1 小时": "1 hour", "6 小时": "6 hours", "12 小时": "12 hours",
  "2 天": "2 days", "7 天": "7 days",
  "每天固定时间或按间隔 · 服务开关 · 日志维护": "Daily time or interval · services · logs",
  "保存并应用定时设置": "Save & apply schedule", "模块总开关": "Master switch", "日志保留阈值": "Log threshold",
  "查看日志": "View logs", "重置统计": "Reset stats",
  "功能说明": "Feature guide", "关于模块 / About": "About",
  "模块名称": "Module", "当前版本": "Version", "作者": "Author", "项目地址": "Project",
  "GitHub 项目主页 ↗": "GitHub repository ↗",
  "首页": "Home", "清理整理": "Cleanup", "规则中心": "Rules", "设置中心": "Settings"
};
const UI_ZH_REVERSE = Object.fromEntries(Object.entries(UI_EN).map(([zh, en]) => [en, zh]));

let lastAppliedLanguage = null;
let themeListenerBound = false;
function bindThemeListener() {
  if (themeListenerBound) return;
  themeListenerBound = true;
  try {
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
      if (uiPrefs.theme === "auto") applyThemeOnly();
    });
  } catch (_) {}
}

// Cheap theme/palette/nav sync — safe to call on every dashboard refresh.
function applyThemeOnly() {
  const root = document.documentElement;
  const prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = uiPrefs.theme === "auto" ? (prefersDark ? "dark" : "light") : uiPrefs.theme;
  root.dataset.palette = uiPrefs.palette || "blue";
  bindThemeListener();
  document.body.classList.toggle("nav-floating", uiPrefs.navMode === "floating");
  const nav = document.querySelector(".bottom-nav");
  if (nav) nav.classList.toggle("nav-floating", uiPrefs.navMode === "floating");
  syncActiveButtons();
}

function syncActiveButtons() {
  ["themeAuto", "themeDark", "themeLight", "langZh", "langEn", "navTraditional", "navFloating",
   "paletteBlue", "paletteSage", "paletteLilac", "paletteRose", "paletteSand"].forEach((id) => {
    const el = document.getElementById(id);
    if (el) el.classList.remove("active");
  });
  const activeIds = { auto: "themeAuto", dark: "themeDark", light: "themeLight", zh: "langZh", en: "langEn", traditional: "navTraditional", floating: "navFloating" };
  const paletteIds = { blue: "paletteBlue", sage: "paletteSage", lilac: "paletteLilac", rose: "paletteRose", sand: "paletteSand" };
  const activeMap = { theme: activeIds, palette: paletteIds, language: activeIds, navMode: activeIds };
  Object.keys(activeMap).forEach((k) => {
    const el = document.getElementById(activeMap[k][uiPrefs[k]]);
    if (el) el.classList.add("active");
  });
}

// Heavy language sync (DOM text walker) — runs on init and explicit language change only.
function applyLanguageOnly() {
  if (lastAppliedLanguage === uiPrefs.language) return;
  lastAppliedLanguage = uiPrefs.language;
  const dict = uiPrefs.language === "en" ? UI_EN : UI_ZH_REVERSE;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    const raw = node.nodeValue, trimmed = raw.trim();
    if (!trimmed) continue;
    const translated = dict[trimmed];
    if (translated) node.nodeValue = raw.replace(trimmed, translated);
  }
  document.documentElement.lang = uiPrefs.language === "en" ? "en" : "zh-CN";
  document.title = uiPrefs.language === "en" ? "AutoPurge Pro" : "AutoPurge Pro";
}

function applyUiPrefs() {
  applyThemeOnly();
  applyLanguageOnly();
}
// Backwards-compatible alias
const applyUiPrefsOnce = applyUiPrefs;
