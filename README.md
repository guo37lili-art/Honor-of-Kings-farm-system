# 王者农场助手 🌱

为《王者荣耀》S43「小屋农场」玩法设计的种植/浇水/收获时间管理工具。基于土地干涸机制精确计算最优浇水时间表。

**架构**：单页 HTML（GitHub Pages）+ Supabase（数据库 + Edge Function）。零运维，免费额度内永久使用。

---

## 功能

### 核心算法
- 支持 8h / 16h / 32h 三种作物
- 基于"土地干涸度随时间线性累积 + 每次浇水减少成熟时间"的真实机制
- 首次浇水 d=1 奖励 · 每次浇水后冷却 T/30（8h→16min · 16h→32min · 32h→64min）

### 三条路径展示
每张作物卡同时展示三条策略路径的最优行动：
- 🏃 **最快路径**：多次浇水，目标 11T/15 最短成熟
- 💤 **懒人路径**：一次浇水即熟，目标 5T/6
- 🌱 **自然生长**：不浇水，目标 T

每条路径显示：浇水时机（具体时刻）· 预计成熟 · 冷却禁浇期提醒

### 用户体验
- **立刻浇水 🔥**：未浇过水 / 已过 T/3 截止 → 高亮提示立即动作
- **浇水即熟判定**：实时模拟"此刻浇水"是否触发即熟，自动切红色卡片
- **禁浇期警告**：最终浇水前 T/30 内浇水会破坏即熟，界面提前高亮警告
- **路径收敛检测**：最快 == 懒人时合并显示"· 浇水即熟"标签，去掉"前"字

### 作物管理
- **新种作物**：种类 + 种植时间（"当前时间"一键填充）+ 是否立刻浇水 + 自定义名字
- **已种导入**：游戏内成熟时间 + 水分剩余 → 反推内部状态，加入列表
- **重命名**：卡片顶部 ✏️ 可随时改名（空=默认显示"作物"）
- **自动清理**：已收获 30min 后自动删除，也可随时手动删

### 日历订阅
- Supabase Edge Function 托管动态 .ics
- iOS 走 `webcal://` 协议 → 原生"订阅日历"对话框，**一次订阅永久自动同步**
- Android / 桌面走 HTTPS 链接
- **用户级订阅**：`?user=昵称&path=fast` 聚合所有未收获作物
- **单作物订阅**：`?crop_id=xxx&path=fast` 精细粒度
- 浇水、收获后日历自动刷新（iOS 默认 15min-1h 一次）

### 多账号
- 昵称 + 4 位 PIN 登录（服务端 bcrypt hash）
- 作物数据公开可读，写操作校验 PIN
- 朋友通过 `/#/u/<昵称>` URL 查看他人农场（只读）

### 管理后台
- `admin.html` 独立页面，需输入管理员昵称 + PIN
- 聚合查看所有用户 + 所有作物
- 按"活动中 / 待收获 / 已收获"筛选

---

## 技术栈

| 层 | 技术 |
|---|---|
| 前端 | 单文件 `index.html`，Alpine.js v3 + TailwindCSS（CDN），无构建 |
| 后端 | Supabase（Postgres + PostgREST + Edge Functions） |
| 认证 | 自建昵称 + PIN，pgcrypto bcrypt hash |
| 托管 | GitHub Pages（静态） |

---

## 文件结构

```
/
├── index.html                          前端主应用
├── admin.html                          管理后台
├── schema.sql                          Supabase 初始化 SQL
├── supabase/
│   └── functions/ics/index.ts          Edge Function（动态 .ics）
├── README.md                           本文件
└── TODO.md                             待优化项
```

---

## 部署步骤

### 1. Supabase 数据库

1. 创建 Supabase 项目：https://supabase.com
2. **SQL Editor** → New query → 粘贴 [`schema.sql`](schema.sql) 全文 → Run
3. **Project Settings → API**：复制 Project URL 和 anon key

### 2. 前端配置

编辑 [`index.html`](index.html) 和 [`admin.html`](admin.html)，替换顶部两行：

```js
const SUPABASE_URL = 'https://<你的>.supabase.co';
const SUPABASE_ANON_KEY = '<你的 anon key>';
```

`admin.html` 里另外改 `ADMIN_NICKNAME` 为你的昵称。

### 3. Edge Function（日历订阅）

- Dashboard → **Edge Functions** → **Create a new function**
- 名字填 `ics`
- 粘贴 [`supabase/functions/ics/index.ts`](supabase/functions/ics/index.ts) 全文
- **关闭 "Verify JWT"**（日历 App 不带认证头）
- Deploy

### 4. GitHub Pages

```bash
cd /path/to/project
git init
git add .
git commit -m "initial"
git branch -M main
git remote add origin https://github.com/<username>/<repo>.git
git push -u origin main
```

Repo Settings → Pages → Source: main / root → Save。1-2 分钟后 `https://<username>.github.io/<repo>/` 生效。

---

## 数学模型

### 成熟时间公式

```
每次浇水减少 = d × T/12
d = min(1, 3·gap/T)   // 干涸度线性累积到 1 over T/3
首次浇水恒 d=1          // 奖励 T/12
冷却 = T/30             // 两次浇水间的最小间隔
```

### 三条路径的最优成熟

| 路径 | 最优成熟 | 浇水次数 |
|---|---|---|
| 最快 | 11T/15 ≈ 0.733T | 4 次（平均每次 T/15 间隔） |
| 懒人 | 5T/6 ≈ 0.833T | 2 次（plant + 5T/6） |
| 自然 | T | 0 次 |

### Window A（最快路径下次浇水截止）

```
Window A = min(lastEvent + T/3, currentMat, Window B)
```

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

## License

MIT
