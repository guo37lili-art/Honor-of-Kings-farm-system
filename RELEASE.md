# Release Notes

## v0.3 — 2026-04-22

- ➕ **🏆 我的纪念册**：收获稀有变异作物一键收入册子，记录英雄 / 巨大化 / 紫色（青玉·明珠·璀璨·琉璃）/ 普通四类变异，最稀有的名字自动彩虹色
- ➕ **+ 手动录入**：以前游戏里出的老变异也能补录进纪念册
- ➕ **👥 朋友圈**：公开收藏给大家一起看，作物名按变异稀有度着色一眼识别
- ➕ **❤️ 点赞 / ❓ 问号**：朋友圈里两种互动都能 toggle，点错可以再点一下取消
- ➕ **📷 截图**：收藏时附一张原图，点击可全屏放大
- ➕ **朋友主页**：朋友圈点昵称先看 TA 的纪念册（只读），再跳 TA 的农场
- ➕ **一键分享**：顶部 SVG 分享图标，复制链接直接发朋友
- ✨ 主工具顶部「我的纪念册」+「朋友圈」并列两个大按钮，金橙 + 蓝紫渐变
- ✨ 已收获卡片加「🏆 收入纪念册」按钮，收藏过的自动变灰防二次收入
- 🐛 纪念册改名 / 换截图 / 删除条目时顺带清理云端孤儿文件

---

## v0.2 — 2026-04-20

- ➕ 已收获的作物一键「再种一棵」，继承原配置
- ➕ 顶部新增「复制农场链接」，发给朋友粘贴就能看你的农场
- ➕ 顶部新增「🔄 刷新」按钮
- ✨ 改了作物名，日历提醒标题同步更新
- ✨ Mac 点订阅日历直接唤起日历 app，不再下载文件
- 🐛 修复手快连点两下会多算一次浇水的问题

---

## v0.1 — 2026-04-20

首个可用版本。以代码为准记录当前实际落地的能力。

### 核心机制

- 支持 8h / 16h / 32h 三种作物
- 时间模型：
  - `computeMatTime`：累积浇水减少量 `reduction = T/12 + Σ d_i × T/12`，首次 d=1，后续 `d = clamp(3·gap/T, 0, 1)`
  - `cooldownMs = T/30`（8h→16min · 16h→32min · 32h→64min）
  - `computeDryness` / `moisture = 1 − dryness`
  - `computeWindowA`：最快路径下次浇水截止 = `min(lastEvent + T/3, currentMat, windowB)`；0 次浇水直接返回 `now`
  - `computeWindowB`：懒人即熟时刻，分支公式 + 冷却下限
  - `computePredictedFastMat`：`(4·currentMat + lastEvent)/5 + waste/5`，0 次浇水时走虚拟首浇
  - `previewWaterEffect`：现在浇水能减多少、是否触发即熟（含冷却期判定）
- 自测用例：`window.__farmTests()` 覆盖空浇水 / Fast 4 次 / Lazy 2 次 / 单次 d=1

### 作物卡片相位

卡片根据 `cropState(crop).phase` 呈现 6 种状态：
- `harvested`：已收获 + 30 分钟后自动清理提示
- `mature`：🌾 可收获
- `locked`：🔒 冷却锁定（cooldownEnd > currentMat，无法再浇水，只能等自然成熟）
- `last-water`：🔴 浇水即熟（含冷却中按钮禁用 + 倒计时）
- `nowater`：🌱 自然生长中（不在当前主路径展示，作为兜底）
- `normal`：三路径并列展示

### 三路径展示

每张作物卡在 `normal` 相位同时展示：
- 🏃 **最快路径**：显示 Window A、预计成熟、禁浇期警告、立刻浇水 🔥、节奏已过补浇止损、快慢路径收敛（fastConverged 去掉"前"字并加"· 浇水即熟"）
- 💤 **懒人路径**：显示 Window B、预计成熟、禁浇期警告
- 🌱 **自然生长**：显示 matMs、距成熟时长

每路径右上角带 📅 按钮可单独订阅日历。

### 作物管理

- **新种**：种类 / 名字 / 种植时间（"当前时间"一键填充）/ 是否立刻浇水；附实时三路径预览（`addFormPreviewPaths`）
- **已种导入**：用游戏里的"成熟时间 + 水分剩余"反推内部状态（`buildImportedVirtualCrop`），附实时三路径预览
- **重命名**：卡片顶部 ✏️，空字符串 fallback 到"作物"
- **浇水 / 收获 / 浇水+收获**：RPC 原子操作，冷却期按钮禁用并显示倒计时
- **删除**：二次确认 modal
- **自动清理**：已收获 30 min 后在 `loadCrops` 里批量删除
- **排序**：`sortedCrops` 按 phase rank → nextTarget/matMs 升序

### 日历订阅

- Supabase Edge Function 动态生成 .ics（`supabase/functions/ics/index.ts`）
- 单作物订阅：`?crop_id=xxx&path=fast|lazy|natural`
- 用户级聚合订阅：`?user=昵称&path=xxx`，聚合所有未收获作物
- 事件标题带作物名（本版新增）：`{type}h {name||'作物'}`
- 事件类型按 path 和当前状态分支：
  - fast: `🔥 立刻浇水` / `🌾 浇水即熟` / `🏃 下次浇水截止`
  - lazy: `💤 浇水即熟`
  - natural: `🌱 自然成熟`
- VALARM 提前提醒：fast deadline -10min，其他 -5min
- 事件 UID 只依赖 `cropId` + path，改名不重复建事件
- REFRESH-INTERVAL + X-PUBLISHED-TTL 声明 1h
- 响应头 `Cache-Control: public, max-age=300`
- Apple 设备（iOS/iPadOS/macOS）走 `webcal://` 触发原生订阅对话框（本版新增 macOS 支持），其他设备走 `https://`

### 多账号

- 昵称（≤20 字符）+ 4 位数字 PIN 登录/注册（`auth_login` RPC）
- PIN 服务端 `pgcrypto extensions.crypt` bcrypt hash，返回 stored hash 作为写操作 token
- 朋友视图：`/#/u/<昵称>` URL 只读查看他人农场
- `localStorage.wz_me` 持久化登录态

### 管理后台

- 独立页 `admin.html`，硬编码 `ADMIN_NICKNAME = '长缨'`
- 聚合查看所有用户所有作物，按"活动中 / 待收获 / 已收获"筛选

### 数据层

- Postgres 表：`users`（nickname PK + pin_hash） · `crops`（id/user_nickname/type 8|16|32/planted_at/water_events jsonb/mode/target_harvest/harvested_at/name/created_at）
- RLS：公开读，写全部走 RPC
- RPC：`auth_login(text, text)` → stored_hash | `crop_write(nickname, pin_hash, action, crop_id, payload)` 支持 action: `insert` · `delete` · `water` · `harvest` · `water_and_harvest` · `update`

### 技术栈

- 前端：单文件 `index.html`，Alpine.js v3 + TailwindCSS（CDN），无构建
- 后端：Supabase（Postgres + PostgREST + Edge Functions，Deno 运行时）
- 托管：GitHub Pages（静态）

---

### 已知限制

- .ics 订阅刷新走 HTTP 抓取（不支持推送），默认 1h 一次；强刷需杀日历 app 冷启动或在"设置 → 日历 → 账户 → 订阅 → 获取"里调整
- iOS 默认剥离订阅日历的 VALARM，需用户在同一路径关闭"Remove Alarms"
- 管理员身份硬编码，未做动态配置
- 无撤销机制：浇水 / 收获 / 删除都是直接写
