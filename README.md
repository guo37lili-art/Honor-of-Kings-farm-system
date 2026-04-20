# 王者农场助手 🌱

为《王者荣耀》S43「小屋农场」玩法设计的种植/浇水/收获时间管理工具。基于土地干涸机制精确计算最优浇水时间表，支持 8/16/32h 作物、4 种玩法模式、多账号和好友只读分享。

**单页 HTML + Supabase 后端 + GitHub Pages 托管，零运维，免费。**

---

## 功能

- ✅ 四种模式：Fast（4 次浇水，11T/15 成熟）、Lazy（2 次，5T/6）、Target（目标时间反推）、Nowater（0 次，卡点用）
- ✅ 干涸度实时可视化，浇水目标 / 截止时间双提示
- ✅ 末次浇水专属"浇水即熟"倒计时 UI
- ✅ 多账号（昵称 + 4 位 PIN），好友只读链接分享
- ✅ 手机浏览器可用，可加主屏当 app 用

---

## 部署步骤（~15 min）

### 1. 创建 Supabase 项目

1. 去 https://supabase.com/ 注册（免费）
2. 新建项目（名字随意，数据库密码记好）
3. 等项目启动（~2min）
4. 点左侧 **SQL Editor** → New query → 粘贴 `schema.sql` 全文 → Run
5. 点左侧 **Project Settings → API**，记下：
   - Project URL（形如 `https://xxx.supabase.co`）
   - anon / public key（`eyJ...` 开头的长串）

### 2. 配置前端

打开 `index.html`，找到顶部：

```js
const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY';
```

把两个值替换成上一步记下的。

### 3. 发布到 GitHub Pages

```bash
# 在本目录
git init
git add index.html schema.sql README.md
git commit -m "initial"
git branch -M main

# 到 GitHub 新建一个 repo（例如 wz-farm），按页面提示：
git remote add origin https://github.com/<你的用户名>/wz-farm.git
git push -u origin main
```

在 repo 的 **Settings → Pages**：
- Source：Deploy from a branch
- Branch：`main` / `/ (root)`
- Save

等 1-2 分钟，打开 `https://<你的用户名>.github.io/wz-farm/` 即可使用。

### 4. 使用

- 手机浏览器打开网址
- 输入昵称 + 4 位数字 PIN（首次自动注册）
- 点「+ 添加作物」开始种

**朋友只读分享**：把 `https://<你的用户名>.github.io/wz-farm/#/u/<你的昵称>` 发给朋友，他们无需登录就能看你的农场。

**添加到主屏**：iOS Safari 点分享 → 添加到主屏幕；Android Chrome 点右上菜单 → 添加到主屏幕。

---

## 核心机制（给感兴趣的人）

### 成熟时间公式

- 每次浇水减少成熟时间 = `d × T/12`，其中 `d = min(1, 3·gap/T)` 为土地干涸度
- 首次浇水 `d = 1` 恒定（土地默认干）
- 正常 4 次浇水（Fast 模式）：时间表 `0, T/3, 2T/3, 11T/15`，成熟于 **11T/15**

### 模式对照表

| 模式 | 浇水次数 | 成熟时间 | 适用场景 |
|---|---|---|---|
| Fast | 4 | 11T/15（8h→5h52min）| 追求最优效率 |
| Lazy | 2 | 5T/6（8h→6h40min）| 只想关心种 + 收两端 |
| Target | 动态 | 用户指定 | 要卡特定收获点（如周五 18:00 双倍开闸）|
| Nowater | 0 | T（8h→8h）| 懒到极致，或卡点不减 |

### 末次浇水"浇水即熟"

Fast 模式下第 4 次浇水必须**卡在预期成熟时刻**——浇下去作物立即成熟。工具在第 3 次浇水完成后自动切换到倒计时 UI，提示最后这一次必须精准。

---

## 本地调试

直接用浏览器打开 `index.html` 就能跑（需要先把 Supabase URL 和 key 填进去）。

在浏览器 Console 跑：

```js
__farmTests()
```

会输出 6 个数学自测结果，全 ✅ 说明算法没问题。

---

## 技术栈

- **前端**：单文件 `index.html`，Alpine.js + Tailwind（全 CDN，无构建）
- **后端**：Supabase（Postgres + PostgREST + RPC），pgcrypto 做服务端 bcrypt
- **托管**：GitHub Pages（静态）
- **认证**：自建昵称 + 4 位 PIN，服务端 hash 比对

## 限制

- PIN 只有 4 位，建议不同昵称用不同 PIN，并保护你的 URL 链接
- 数据未加端到端加密（朋友之间可见彼此作物，这是功能不是 bug）
- 需要浏览器时间准确；离线时无法同步

## License

MIT
