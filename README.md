# 王者农场助手 🌱

《王者荣耀》S43「小屋农场」玩法的浇水/收获辅助工具，附带变异纪念册 + 朋友圈社交。

**架构**：多页静态 HTML（GitHub Pages）+ Supabase（Postgres + Edge Function + Storage）。无构建，零运维，免费额度内永久使用。

---

## 功能

### 🌾 主工具（`index.html`）—— 种植与浇水决策

- 支持 8h / 16h / 32h 三种作物
- 基于"土地干涸度随时间线性累积 + 每次浇水减少成熟时间"的真实游戏机制
- 首次浇水 d=1 奖励 · 每次浇水后冷却 T/30（8h→16min · 16h→32min · 32h→64min）
- **三条路径展示**同一张卡片
  - 🏃 最快路径：多次浇水，目标 11T/15（浇水时机 + 预计成熟 + 禁浇期警告）
  - 💤 懒人路径：一次浇水即熟，目标 5T/6
  - 🌱 自然生长：不浇水，目标 T
- 立刻浇水提示、浇水即熟判定、路径收敛检测、冷却锁定相位
- 作物管理：新种（含命名）/ 已种导入 / 重命名 / 删除 / 再种一棵 / 收入纪念册
- 日历订阅：iOS / macOS 走 `webcal://`，其他走 https://，支持单作物或用户级聚合
- **好友圈即熟提醒横幅**：`FRIEND_LIST` 内任何人 1h 内可浇水即熟时主动弹
- **周末双倍窗口提醒**：新种作物最快都晚于本周五 08:00 时弹警告
- 顶部"🔗 分享"一键复制农场链接
- 多账号 + 朋友视图：昵称 + 4 位 PIN；`/#/u/昵称` 看他人农场（只读）

### 🏆 纪念册（`collection.html`）—— 变异作物收藏

- 四类变异：英雄 28× · 巨大化 8× · 紫色 2.5×（子名：青玉 / 明珠 / 璀璨 / 琉璃 / 冰晶 / 琥珀 / 青铜 / 铸铁）· 普通 1.5×
- 同时最多 3 种，同类型不可重复
- 作物名随**最高稀有度**着色（英雄彩虹 / 巨大化金 / 紫色紫 / 普通蓝 / 无变异灰）
- 总倍数数字也按变异色渲染
- 排序：按倍数乘积 ↓ · 按时间 ↓
- 从主工具已收获作物一键收入，或「+ 手动录入」补录老变异
- 可附截图（原图直传 Supabase Storage，点击 lightbox 全屏放大）
- 每条可编辑 / 删除 / 切换公开私密
- 删除或换图时自动清理 Storage 里对应文件（防孤儿）
- 同一页面 `hash routing` 复用："自己视图" vs `#/u/朋友昵称` 进入朋友只读纪念册（只看 TA 公开的，不能操作）

### 👥 朋友圈（`feed.html`）—— 公开变异汇总

- 所有用户公开的收藏，时间倒序
- 互动：❤️ 点赞 toggle · ❓ 问号 toggle（各自独立计数，乐观更新无闪烁）
- 点昵称 → 跳对方纪念册（只读）→ 再跳对方农场
- 自己的条目右上有 🔒 按钮，一键隐藏（切回私密）
- 截图 lightbox 全屏
- 未登录拦截（需要登录才能看）

### 📊 管理后台（`admin.html`）

- 管理员昵称硬编码 + PIN 登录
- 聚合查看所有用户 + 所有作物
- 按"活动中 / 待收获 / 已收获"筛选

---

## 技术栈

| 层 | 技术 |
|---|---|
| 前端 | 多页静态 HTML，Alpine.js v3 + TailwindCSS（CDN），无构建。`common.js` 共享配置 + helpers + 变异枚举 |
| 后端 | Supabase（Postgres + PostgREST + Edge Functions + Storage） |
| 认证 | 自建昵称 + 4 位 PIN，pgcrypto bcrypt hash，PIN hash 作为写操作 token |
| 托管 | GitHub Pages（静态） |

---

## 文件结构

```
/
├── common.js                       共享代码：SUPABASE 配置 / FRIEND_LIST / helpers / MUTATION_TYPES
├── index.html                      主工具（种植/浇水/日历订阅/朋友圈横幅）
├── collection.html                 纪念册（自己 + 朋友只读，hash routing 区分）
├── feed.html                       朋友圈
├── admin.html                      管理后台
├── schema.sql                      Supabase 数据库初始化 SQL（10 段，幂等可重复跑）
├── supabase/
│   └── functions/ics/index.ts      Edge Function（动态生成 .ics 日历）
├── README.md                       本文件
└── RELEASE.md                      版本历史
```

---

## 部署步骤

### 1. Supabase 项目

注册 https://supabase.com → New project。

### 2. Schema 初始化

**SQL Editor** → New query → 粘贴 [`schema.sql`](schema.sql) 全文 → Run。

脚本幂等（所有 CREATE 都用 IF NOT EXISTS、函数用 CREATE OR REPLACE），以后加功能重跑整段也安全。

### 3. Storage Bucket（纪念册截图用）

Dashboard → **Storage** → **New bucket**：
- 名字：`collection-images`
- **勾选 Public bucket**
- File size limit 建议 50MB

然后 SQL Editor 跑 3 条 RLS 策略让 anon 能读/传/删：

```sql
create policy "anon read collection-images" on storage.objects
  for select to anon using (bucket_id = 'collection-images');

create policy "anon upload collection-images" on storage.objects
  for insert to anon with check (bucket_id = 'collection-images');

create policy "anon delete collection-images" on storage.objects
  for delete to anon using (bucket_id = 'collection-images');
```

### 4. Edge Function（日历订阅）

Dashboard → **Edge Functions** → **Create a new function**：
- 名字：`ics`
- 粘贴 [`supabase/functions/ics/index.ts`](supabase/functions/ics/index.ts) 全文
- **关闭 Verify JWT**（日历 App 请求不带认证头）
- Deploy

### 5. 前端配置

编辑 [`common.js`](common.js) 开头（Project Settings → API 可拿 URL 和 anon key）：

```js
const SUPABASE_URL = 'https://<你的>.supabase.co';
const SUPABASE_ANON_KEY = '<你的 anon key>';
const FRIEND_LIST = ['你', '朋友1', '朋友2'];  // 好友圈即熟提醒名单
```

[`admin.html`](admin.html) 另外改 `ADMIN_NICKNAME` 为管理员昵称。

### 6. GitHub Pages 部署

```bash
cd /path/to/project
git init
git add .
git commit -m "initial"
git branch -M main
git remote add origin https://github.com/<username>/<repo>.git
git push -u origin main
```

Repo Settings → **Pages** → Source: main / root → Save。1-2 分钟后 `https://<username>.github.io/<repo>/` 生效。

---

## 数据模型

### 核心表

| 表 | 用途 |
|---|---|
| `users` | 昵称（PK）+ PIN bcrypt hash |
| `crops` | 在种作物（`water_events jsonb`, `harvested_at`）|
| `collections` | 纪念册条目（`mutations jsonb`, `image_url`, `is_public`, `source_crop_id` → crops.id）|
| `collection_likes` | 点赞（主键 = (collection_id, user_nickname)）|
| `collection_questions` | 问号反应，和 likes 对称 |

### 关键 RPC

- `auth_login(nickname, pin)` → stored_hash（作为后续写操作 token）
- `crop_write(nickname, pin_hash, action, crop_id, payload)` — action: `insert` / `water` / `harvest` / `water_and_harvest` / `delete` / `update`
- `collection_write(nickname, pin_hash, action, row_id, payload)` — action: `insert` / `update` / `delete` / `like_toggle` / `question_toggle`

---

## 核心数学模型

### 成熟时间公式

```
每次浇水减少 = d × T/12
d = min(1, 3·gap/T)   // 干涸度线性累积到 1 over T/3
首次浇水恒 d=1         // 奖励 T/12
冷却 = T/30            // 两次浇水间的最小间隔
```

### 三条路径的最优成熟

| 路径 | 最优成熟 | 浇水次数 |
|---|---|---|
| 最快 | 11T/15 ≈ 0.733T | 4 次（平均每次 T/15 间隔） |
| 懒人 | 5T/6 ≈ 0.833T | 2 次（plant + 5T/6） |
| 自然 | T | 0 次 |

### Window A（最快路径下次浇水截止）

```
Window A = min(lastEvent + T/3, currentMat, Window B, predicted − T/30)
```

最后一项保证「倒数第二次浇水」后还有时间给「即熟水」完成冷却。

### Window B（懒人即熟时刻）

```
分支 A (gap < T/3): B = (4·current_mat + lastEvent) / 5
分支 B (gap ≥ T/3): B = max(lastEvent + T/3, current_mat - T/12)
冷却约束：B ≥ lastEvent + T/30
```

### 最快路径预计成熟

```
predicted = (4·currentMat + lastEvent)/5 + waste/5
waste = max(0, now - lastEvent - T/3)  // 超 T/3 的浪费时间
```

### Locked 状态

```
lockedByCooldown = (events.length > 0) && (cooldownEnd > currentMat)
```

此时冷却期长于剩余时间，用户无法再浇水，UI 显示单条"等自然成熟"提示。

---

## 版本历史

见 [`RELEASE.md`](RELEASE.md)。

---

## License

MIT
