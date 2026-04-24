// ============================================================
// 王者农场助手 · 共享代码
// 被 index.html / collection.html / feed.html 共同引用
// 改这个文件后所有 HTML 顶部 <script src="./common.js?v=N"> 的 N 要 bump
// ============================================================

// ========== Supabase 配置 ==========
const SUPABASE_URL = 'https://eebimxoefmibbxxtmebp.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVlYmlteG9lZm1pYmJ4eHRtZWJwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2NDIzNzQsImV4cCI6MjA5MjIxODM3NH0.zfHwvQ_o17Q10ZovGdWy9uNzhL_FsD463rUnDpNN180';

// v1.1.0 好友系统上线后，"好友浇水提醒"横幅已整体移除
// 原硬编码 FRIEND_LIST 废弃：['长缨', '华山一棵松', 'lc']
// 现在"好友"走双向申请流程，见 friends.html

// 时间单位常量
const HOUR_MS = 3600 * 1000;

// Supabase client 懒加载单例
// 每个 HTML 页面在 Alpine init() 里调 initSbClient() 一次，拿到同一个实例
let sbClient = null;
function initSbClient() {
  if (sbClient) return sbClient;
  if (!window.supabase || typeof window.supabase.createClient !== 'function') return null;
  sbClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  return sbClient;
}

// ========== 登录态 helpers ==========

// 从 localStorage 读当前登录用户 { nickname, pin_hash }，未登录返回 null
function loadSavedMe() {
  const saved = localStorage.getItem('wz_me');
  if (!saved) return null;
  try { return JSON.parse(saved); } catch { return null; }
}

// 保存登录态
function saveMe(me) {
  localStorage.setItem('wz_me', JSON.stringify(me));
}

// 清除登录态（登出）
function clearMe() {
  localStorage.removeItem('wz_me');
}

// ========== 时间格式化 helpers ==========

// 格式化绝对时刻。今天显示"今 HH:mm"，明天显示"明 HH:mm"，更远的显示"MM/DD HH:mm"
function formatDateTime(ts) {
  if (!ts) return '--';
  const d = new Date(ts);
  const now = new Date();
  const opts = { hour: '2-digit', minute: '2-digit' };
  const sameDay = d.toDateString() === now.toDateString();
  const tomorrow = new Date(now.getTime() + 86400000).toDateString() === d.toDateString();
  if (sameDay) return '今 ' + d.toLocaleTimeString('zh-CN', opts);
  if (tomorrow) return '明 ' + d.toLocaleTimeString('zh-CN', opts);
  return d.toLocaleDateString('zh-CN', {month:'2-digit',day:'2-digit'}) + ' ' + d.toLocaleTimeString('zh-CN', opts);
}

// 格式化时长。ms < 0 时返回"已过"；否则按 "Xh Ymin" / "Zmin" / "Ws" 递减精度
function formatDuration(ms) {
  if (ms < 0) return '已过';
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h > 0) return `${h}h ${m}min`;
  if (m > 0) return `${m}min`;
  return `${s}s`;
}

// 倒计时格式：H:MM:SS 或 MM:SS
function formatCountdown(ms) {
  if (ms < 0) return '00:00';
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`;
  return `${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`;
}

// Date → HTML <input type="datetime-local"> 的 value 格式
function toLocalIsoForInput(d) {
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// 返回"下一个周五 08:00"的毫秒时间戳（本地时区）
// 如果今天是周五且已过 08:00，返回 null 表示本周提示窗口已过（双倍窗口近在眼前或已开始）
function nextFridayEightAM(nowMs) {
  const d = new Date(nowMs);
  const day = d.getDay();  // 0=周日 ... 5=周五
  if (day === 5) {
    const today8 = new Date(d);
    today8.setHours(8, 0, 0, 0);
    if (nowMs >= today8.getTime()) return null;
    return today8.getTime();
  }
  const daysToFriday = (5 - day + 7) % 7;
  const target = new Date(d);
  target.setDate(d.getDate() + daysToFriday);
  target.setHours(8, 0, 0, 0);
  return target.getTime();
}

// ========== 平台判断 ==========

// Apple 设备（iOS/iPadOS/macOS）统一走 webcal:// —— 系统自带日历 app
// Windows/Android/Linux 走 https:// —— 浏览器按 MIME 处理
function isAppleDevice() {
  const ua = navigator.userAgent;
  if (/iPad|iPhone|iPod/.test(ua) && !window.MSStream) return true;
  if (/Macintosh|Mac OS X/.test(ua)) return true;
  return false;
}

// ========== 纪念册：变异类型枚举 + 渲染辅助 ==========

const MUTATION_TYPES = {
  hero: {
    label: '英雄',
    multiplier: 28,
    // 文字渐变（彩虹）：class 要配合 Tailwind 的 bg-clip-text + text-transparent
    textClass: 'bg-gradient-to-r from-red-500 via-yellow-500 via-green-500 via-blue-500 to-purple-500 bg-clip-text text-transparent font-bold',
    badgeClass: 'bg-gradient-to-r from-red-50 via-yellow-50 via-green-50 via-blue-50 to-purple-50 border border-purple-300',
  },
  giant: {
    label: '巨大化',
    multiplier: 8,
    textClass: 'text-amber-500 font-bold',
    badgeClass: 'bg-amber-50 border border-amber-400 text-amber-700',
  },
  purple: {
    label: '紫色',
    multiplier: 2.5,
    subnames: ['青玉', '明珠', '璀璨', '琉璃', '冰晶', '琥珀', '青铜', '铸铁'],
    textClass: 'text-purple-600 font-bold',
    badgeClass: 'bg-purple-50 border border-purple-400 text-purple-700',
  },
  normal: {
    label: '普通',
    multiplier: 1.5,
    textClass: 'text-blue-500 font-bold',
    badgeClass: 'bg-blue-50 border border-blue-400 text-blue-700',
  },
};

// 给一组 mutations 算总倍数乘积，无变异 = 1
function totalMultiplier(mutations) {
  if (!mutations || mutations.length === 0) return 1;
  return mutations.reduce((p, m) => p * (MUTATION_TYPES[m.type]?.multiplier || 1), 1);
}

// 渲染一组变异为 badge 文本（给朋友圈/纪念册卡片用）
// 紫色带子名时显示子名 + 倍数，其他显示类型名 + 倍数
function mutationBadgeLabel(m) {
  const t = MUTATION_TYPES[m.type];
  if (!t) return '';
  if (m.type === 'purple' && m.name) return `${m.name} ${t.multiplier}×`;
  return `${t.label} ${t.multiplier}×`;
}

// 取 mutations 中最高稀有度变异的文字样式（给作物名配色用）
// 优先级：hero > giant > purple > normal；无变异返回空字符串
function topMutationTextClass(mutations) {
  if (!mutations || mutations.length === 0) return '';
  const priority = ['hero', 'giant', 'purple', 'normal'];
  for (const type of priority) {
    if (mutations.some(m => m.type === type)) {
      return MUTATION_TYPES[type]?.textClass || '';
    }
  }
  return '';
}

// 按固定稀有度顺序（hero → giant → purple → normal）返回排序副本
// 给纪念册 / 朋友圈卡片 badge 渲染用，保证左到右的顺序统一
function sortedMutations(mutations) {
  if (!mutations || mutations.length === 0) return [];
  const order = { hero: 0, giant: 1, purple: 2, normal: 3 };
  return [...mutations].sort((a, b) => (order[a.type] ?? 99) - (order[b.type] ?? 99));
}

// ========== 图片上传（Sprint 4）==========

// 从 Supabase public URL 反推出 storage 里的 object key（path）
// URL 格式：https://xxx.supabase.co/storage/v1/object/public/collection-images/{path}
// 拿不到就返回 null（调用方应跳过清理步骤）
function extractStoragePath(url) {
  if (!url) return null;
  const match = url.match(/\/public\/collection-images\/(.+)$/);
  return match ? decodeURIComponent(match[1]) : null;
}

// 尝试从 Storage 删除指定 public URL 对应的文件；失败静默不抛错
// 给删除 collection 和换图编辑用：就算这里失败，图片变孤儿但 DB 已正确，业务不 block
async function removeImageByUrl(url) {
  const path = extractStoragePath(url);
  if (!path) return;
  try {
    await sbClient.storage.from('collection-images').remove([path]);
  } catch (e) {
    console.warn('Storage 清理失败（图孤儿，不影响业务）:', e);
  }
}

// 上传原图到 Supabase Storage 并返回 public URL
// 不压缩，保留原始画质（bucket file size limit 50MB 够用）
// 路径扁平化用 UUID：Supabase Storage key 不接受中文
async function uploadImage(file, userNickname) {
  if (!file.type || !file.type.startsWith('image/')) {
    throw new Error('只能上传图片');
  }
  const uuid = (crypto.randomUUID && crypto.randomUUID()) ||
    (Date.now() + '-' + Math.random().toString(36).slice(2));
  // 按原 MIME 推扩展名（保证 PNG 还是 PNG，JPEG 还是 JPEG）
  const mimeToExt = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif' };
  const ext = mimeToExt[file.type] || 'jpg';
  const path = `${uuid}.${ext}`;
  const { error } = await sbClient.storage
    .from('collection-images')
    .upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw error;
  const { data } = sbClient.storage.from('collection-images').getPublicUrl(path);
  return data.publicUrl;
}
