# WebTag Share（移动端收藏投递器）设计合同（2026-08-09）

> **状态**：MVP 产品与安全决策已冻结。Android 是唯一维护的快速 MVP 目标；iOS 仅保留已提交但未在 macOS/Xcode、模拟器或真机上验证的源码快照，不承诺继续实现、签名或发布。
> **权威边界**：现有后端行为以 `internal/app/assets/openapi.json`、生产代码和迁移为准；本文只定义移动收藏入口的产品与跨平台数据约束，不改变后端运行语义。
> **实施状态权威**：[`README.md`](../README.md) 维护当前平台支持和轻量验证命令；[`ARCHITECTURE.md`](../ARCHITECTURE.md) 维护进程、存储、身份、队列与重试边界。完成的开发计划与并行执行流程只保留在 Git 历史中。

---

## 支持边界与 MVP 决策

| 范围 | 当前支持边界 | MVP 决策 |
|---|---|---|
| Android 分享入口 | **唯一维护目标** | Kotlin + 半透明 `ACTION_SEND` Activity；提交前先持久化，WorkManager 提供持久调度兜底 |
| iOS 分享入口 | **冻结源码快照** | 保留 SwiftUI 宿主、Share Extension、App Group/Keychain 与后台恢复源码；不把静态检查解释为可安装或可发布证据 |
| URL 提取 | **维护** | 只做可证明的本地确定性提取；多个不同 URL 时由用户选择；零 URL 时不上传或排队原始分享文本 |
| 直接 URL 提交 | **维护** | 请求只传 `url`，省略 `parse_depth`、`requested_library_kind` 和尚不存在的 `destination` |
| 结果反馈 | **维护** | 只按 `SubmitResponse.status` 映射；`job_id` 不用于推断新建或复用；`failed` 不隐式 refresh |
| 凭证与连接检查 | **维护** | API origin + write-only API key；`GET /api/session` 验证 canonical `write` scope 和 namespace |
| 离线队列 | **维护** | 先持久化、后发送；稳定 `Idempotency-Key`；分类重试；7 天后转 `expired` 而不静默删除 |
| 文本 AI 兜底 | **不进 MVP** | 不新增 `/api/links/from-text`，不让客户端或模型猜测无法追溯到输入的 URL |
| 构建与分发 | **快速收口** | Android 以 JVM 单测、debug assemble 和 lint 为维护门禁；真机、签名、生产 smoke 与重型平台矩阵均为可选发布信心工作 |

本文不再维护实施里程碑或逐次测试记录。任何平台进度、CI 口径和未运行
验证以组件 README 为准；这不会重新打开 iOS 实施范围。

---

## 产品概述

**WebTag Share** 是一个移动端「收藏投递器」——一个只干一件事的 APP：接住系统分享出来的链接，直接打进 WebTag 后端，触发已有的 AI 解析流程。

**要解决的问题**：浏览器插件把桌面端收藏做得很顺，移动端却完全断裂。现在手机上看到一篇好文章，流程是「分享到微信文件传输助手 / 备忘录 → 回到电脑 → 打开 WebTag → 复制粘贴 URL → 提交」。四步、跨设备、延迟数小时，结果就是大量该收的东西根本没收。

**目标用户**：WebTag 的自部署使用者本人（当前即作者一人）。技术背景足够自己签名安装 APP、自己铸 API Key，不需要引导式登录、不需要多账号、不需要商店分发。

**核心价值**：把移动端收藏从「四步跨设备」压缩成「点分享 → 选 WebTag → 完」。全程不跳出正在阅读的 APP；单 URL 主路径以 2.5 秒为交互上限，超时即交给持久队列。收藏之后的抓取、标题、摘要与标签继续由后端处理。MVP 沿用 `POST /api/links` 当前默认行为，不替 D28 / W6 决定未来的 inbox / library 服务端默认值。

**一句话定位**：它不是 WebTag 的移动客户端，它是 WebTag 的移动端**入口**。看的事情交给浏览器和 reader，它只负责「收」。

---

## 应用场景

- **公众号长文**：地铁上刷到一篇值得细读的公众号文章，读到一半没时间了。右上角 → 分享 → WebTag → 屏幕上闪过「已收藏」→ 回到文章继续读完剩下的。晚上打开 Reader，按当前后端分类结果处理或阅读它。

- **X / Twitter 上的技术贴**：刷到一条带外链的推文，链接指向一篇技术博客。长按 → 分享 → WebTag。分享出来的是「推文正文 + 短链 + @作者」一坨脏文本，APP 自己把 URL 抽出来，用户无感。

- **手机浏览器随手收**：Safari / Chrome 手机版看到一个页面想留着，分享菜单直接选 WebTag，比在手机上操作 web 端 WebTag 快十倍。

- **飞行模式下的收藏**：飞机上用离线阅读器看文章，只要分享载荷里含可识别 URL，APP 会先把 URL 写进本地队列，再尝试提交；落地联网后由系统调度补发。没有 URL 的纯文本不属于 MVP 收藏对象，APP 会明确提示而不是悄悄保存原文。

- **播客 / 知乎 / 少数派**：这类 APP 的分享文本格式各不相同，有的带标题前缀，有的带推广尾巴。客户端按平台结构化 URL、平台 URL detector 和受控文本扫描三层提取；多个不同候选时显示紧凑选择器，避免静默收藏错链接。

---

## 功能需求

### 核心功能

- **F1 · 接收系统分享**
  用户在任意 APP 点击分享 → 分享面板中出现「WebTag」→ 点选 → APP 接住分享内容。
  - iOS：Share Extension，声明接受 `public.url` 与 `public.plain-text`
  - Android：`ACTION_SEND` + `text/plain` 的半透明 Share Activity
  - 不接受图片、视频、文件。MVP 只吃链接和文本。

- **F2 · 可证明的 URL 提取**
  客户端只提交能从系统分享载荷中证明来源的 `http` / `https` URL，不让模型猜链接。
  - 优先读取结构化 URL：iOS `public.url`；Android 解析完整的 `EXTRA_TEXT` URI 与 `ClipData` URI。
  - 结构化 URL 不可用时，iOS 使用 `NSDataDetector`，Android 使用受测试约束的 URL matcher 扫描 `text/plain`；统一去除紧邻 URL 的成对括号、中文引号和句末标点，但不改 query、fragment 或 percent-encoding。
  - 去重后只有一个候选时直接进入 F3；有多个不同候选时，在同一个瞬时分享界面显示 host + 截断路径供用户选择，不凭“第一个 URL”猜目标。
  - 没有候选时显示「没找到链接」，结束本次分享，不上传、不记录、不排队原始文本。
  - 短链（`t.co`、`b23.tv` 等）不在客户端展开，原样提交；重定向与 SSRF 防护由现有后端抓取链负责。
  - iOS 与 Android 必须共同消费一份脱敏分享夹具，保证同一输入产生同一候选集合和选择顺序。

- **F2x · 文本 AI 兜底**（MVP 明确不做）
  MVP 不新增 `POST /api/links/from-text`。只有至少 200 条合成或人工脱敏的真实分享夹具证明确定性方案成功率低于 99%，且失败样本确实包含可恢复 URL 时，才允许重新立项。未来若立项，模型输出必须是输入原文中的 URL 子串，或由该子串经过确定性 scheme 补全得到；仅通过 SSRF 校验不足以证明 URL 与原分享有关。

- **F3 · 静默提交**
  APP 带凭证请求 `POST /api/links`，body 为 `{"url": "<提取到的 URL>"}` → 后端返回 `202 + SubmitResponse` → APP 显示极简成功反馈并自行关闭。
  - **全程不跳出用户当前所在的 APP**，不启动 WebTag 主界面
  - MVP 不传 `parse_depth`、`requested_library_kind` 或尚不存在的 `destination`，严格沿用当前后端默认行为；D28 后续若落地，必须通过新的 OpenAPI 契约和客户端版本再启用
  - 当前 `SubmitResponse` 只适用于确实已经生成 link 的路径。D28 若允许 `destination=inbox`，新合同必须用 `target_kind` 判别并返回 `inbox_id`，Mobile 在生成客户端理解该 union 前不得发送 inbox destination
  - 重复 URL 无需处理：`POST /api/links` 是幂等的，同 URL 只返回现有状态，不会重复建解析任务
  - `status=pending|processing` 显示「已收藏」；`status=done` 显示「已在库中」；`status=failed` 显示「已在库中，解析失败」。`job_id` 只用于后续诊断，不能区分新建与复用
  - 在第一次网络请求之前，先原子写入队列条目并生成稳定 `Idempotency-Key`；前台请求和全部后台补发始终复用该 key
  - 单 URL 主路径的总交互预算为 **2.5 秒**：URL 提取与持久化目标 100ms，HTTP deadline 2 秒，终态反馈最多 300ms；超时只表示交给队列，不表示服务端取消
  - `status=failed` 代表提交已经成功命中既有记录，因此不留在提交队列；设置页“最近一条结果”提供显式「重新解析」操作，调用 `POST /api/links/{link_id}/refresh`
  - `POST /api/links` 的 OpenAPI operation 正式声明可选 `Idempotency-Key` 与 `Idempotent-Replay`。客户端为每个队列条目生成独立 UUID，并把该 key 永久绑定到同一 URL 请求体；服务端不比较同 key 的不同 body，因此客户端严禁换 URL 后复用 key
  - Mobile 部署必须保持默认 `IDEMPOTENCY_ENABLED=true`，发布 smoke 用同 key 重放同一请求并断言第二次响应带 `Idempotent-Replay: true`。默认回放 TTL 为 24 小时；TTL 之后仍由 URL 唯一性与服务端提交锁保证不重复建链

- **F4 · 凭证配置**
  用户打开 WebTag APP 主界面 → 填入 Server URL 和 API Key → 保存 → 凭证写入系统安全存储。
  - Server URL 是 **API origin**，形如 `https://webtag.alpenl.com`；`https://reader.alpenl.com` 是前端站点，不能作为默认 API 示例
  - API Key：通过后端 `POST /api/admin/api-keys` 事先铸好，请求体显式使用 `{"name":"webtag-share","scopes":["write"]}`，再在 APP 内粘贴录入；不依赖服务端默认 scope
  - 保存后调用 `GET /api/session` 验证身份并检查 canonical scopes 包含 `write`，明确区分网络失败、凭证无效与 scope 不足
  - 凭证必须对分享扩展可见：iOS 走 App Group + Keychain Sharing；Android 使用 Android Keystore 支撑的加密存储，不把 API key 写入普通 SharedPreferences、日志或备份
  - 使用结构化 URL API 规范化 origin：拒绝 userinfo、query、fragment 和非根 path；禁止 HTTPS 降级及携带 Authorization 的跨 origin 重定向。API key 与规范化 origin 成对保存，修改服务器地址时必须清除或重新验证 key，不能静默复用

- **F5 · 失败队列与自动重试**
  每次提交都先建立本地条目，再尝试网络发送。成功响应删除活动队列条目并更新“最近一条结果”；失败根据错误分类迁移状态。
  - 活动状态固定为 `pending_submit`、`retry_wait`、`blocked_auth`、`blocked_scope`、`blocked_quota`、`blocked_identity`、`failed_permanent`、`expired`，两端字段与迁移规则一致。
  - 无网络、DNS timeout、连接中断、客户端 deadline、HTTP 408/425 和 5xx → `retry_wait`；采用带抖动指数退避，单次最大 6 小时，网络恢复可提前唤醒但不能并发重复发送同一条目。
  - 证书链、hostname 或系统 trust 校验失败 → `failed_permanent`；客户端不通过重复请求掩盖配置错误，也不提供跳过 TLS 校验的开关。
  - `429 rate_limit_exceeded` → 读取 `Retry-After`，保留提交条目并调度到指定时间；没有合法提示时最少等待 60 秒。
  - 显式 refresh 的 `429 cooldown_active` 不创建或复活提交队列条目；最近结果单独保存 `refresh_not_before` 并禁用按钮。`Retry-After` 缺失或无效时同样最少等待 60 秒。
  - `429 quota_exceeded`：提交条目转 `blocked_quota`；显式 refresh 则只在最近结果记录配额阻断，不创建提交条目。两者都不自动重试；用户更换档位或额度窗口恢复后在设置页手动操作。
  - `401` → `blocked_auth`；`403 insufficient_scope` → `blocked_scope`；两者不自动重试，更新凭证并重新通过 `GET /api/session` 后可批量恢复。
  - 保存的 API origin 或 `client_data_namespace` 与当前身份不一致 → `blocked_identity`；旧条目不得静默发送到新服务器或新 tenant。最近结果同样绑定创建它的 origin / namespace；不匹配时隐藏 URL / `link_id` 并禁用 refresh，只允许切回原身份或删除本地记录，不能把旧 `link_id` 迁移到新身份。
  - 当前 `POST /api/links` 没有声明可恢复的 409 分支；收到未知 409 时与 400/413/422 及其余确定性 4xx 一样转 `failed_permanent`。只有未来 OpenAPI 按 `error_code` 明确某个 409 可恢复后，客户端才可把该分支改为重试。
  - Android 由唯一名称的 `WorkManager` 任务串行清空队列，使用 `NetworkType.CONNECTED` 和平台退避；Activity 在条目持久化且前台交接完成前不 `finish()`。
  - iOS 使用 App Group SQLite 作为唯一队列 source of truth；Share Extension 可创建带 `sharedContainerIdentifier` 的 background upload，宿主 App 接管 background session 事件，每次启动和回前台时再扫队列兜底。
  - 条目首次失败 7 天后转为 `expired` 并停止自动调度，但仍在设置页可见；只有用户明确“删除”或“清空”才物理移除。
  - API key 永不进入队列表、URL 日志、分析或崩溃上报。iOS 队列使用 `NSFileProtectionCompleteUntilFirstUserAuthentication` 并排除备份；Android URL 字段使用 Keystore AES-GCM 加密且禁用云备份。

### 辅助功能

- **测试连接**：设置页按钮调用 `GET /api/session`，验证 Server URL、API Key、tenant identity 与 `write` scope，返回明确的成功 / 失败原因（网络不通 / 凭证无效 / 权限不足）。
- **队列状态**：设置页按待重试、凭证阻断、配额阻断、永久失败、已过期分组，显示总数和每条 URL；支持单条重试 / 删除、批量重试和带二次确认的清空。
- **最近一条结果**：设置页只在其 origin / namespace 与当前已验证身份一致时显示上一次分享的 URL、`status`、时间和服务端 `link_id`。当 `status=failed` 时显示「重新解析」，请求前再次执行身份 gate，再显式调用 refresh 端点并遵守 cooldown / quota 响应；身份不匹配时不发请求。

---

## UI 布局

整个 APP 只有 **两个界面**，一个是设置页，一个是分享时的瞬时界面。多 URL 选择也发生在瞬时界面内，不增加独立页面。没有收藏列表、阅读器或底部导航栏。

### 界面 1 · 设置页（主 APP 的唯一界面）

单栏纵向滚动，从上到下：

1. **标题区**：「WebTag Share」+ 一行副标题「分享即收藏」
2. **服务器配置区**
   - 「服务器地址」单行输入框，placeholder `https://webtag.alpenl.com`，键盘类型 URL
   - 「API Key」单行输入框，默认掩码显示，右侧一个「显示/隐藏」眼睛图标，支持长按粘贴
   - 「保存并测试连接」主按钮，通栏宽度
   - 按钮下方状态行：`连接正常` / `凭证无效` / `缺少 write 权限` / `无法连接服务器`，带上次测试时间
3. **本地队列区**（队列为空时整区隐藏）
   - 区标题「待处理 · N 条」，按 `retry_wait` / blocked / permanent / expired 分组
   - 条目列表：每条显示截断后的 URL、中文状态、首次失败时间和下次计划时间
   - 每条提供「重试」和删除图标；底部提供「重试可恢复条目」「清空」，清空必须确认
4. **最近一条结果区**
   - 单行显示：URL（截断）+ 状态徽标（已收藏 / 已在库中 / 解析失败 / 已加入队列）+ 相对时间
   - 解析失败时追加「重新解析」按钮；请求进行中禁用重复点击
5. **底部说明区**（灰色小字）
   - 一行使用提示：「在任意 APP 中点击分享，选择 WebTag 即可收藏」
   - 版本号

### 界面 2 · 分享时的瞬时反馈

- **iOS**：Share Extension 使用不超过屏幕高度 1/3 的紧凑界面。单候选时依次显示「正在收藏」与终态；多候选时显示可点击的 host + 路径列表。终态停留不超过 300ms 后调用 `completeRequest`，错误态由用户确认或最多停留 1.5 秒。
- **Android**：使用 `Theme.Translucent.NoTitleBar` 的半透明 Activity，设置 `excludeFromRecents`，不采用“Toast 后立即 finish”的不可靠模型。Activity 显示与 iOS 同构的状态或候选列表；条目已持久化且请求成功、失败或交给 WorkManager 后才 `finish()`。

两端核心文案严格一致：`正在收藏` / `已收藏` / `已在库中` / `已在库中，解析失败` / `已加入队列` / `没找到链接` / `凭证无效，请检查设置` / `API Key 缺少 write 权限` / `配额已用完`。

---

## 用户使用流程

### 路径 A · 首次配置（一次性，约 2 分钟）

1. 在服务器上执行 `POST /api/admin/api-keys` 铸一个带 `write` scope 的 API Key，复制
2. 手机上安装 WebTag APP（iOS 自签安装 / Android 直装 APK）
3. 打开 APP，填入服务器地址，粘贴 API Key
4. 点「保存并测试连接」，看到 `连接正常`
5. 关闭 APP。正常成功路径不需要再次打开；凭证轮换、阻断队列、手动重新解析、iOS 被强退后的后台恢复和签名到期仍需打开主 APP。

### 路径 B · 日常收藏（主路径，总交互不超过 2.5 秒）

1. 在任意 APP 中看到想收藏的内容，点击分享
2. 在系统分享面板中选择「WebTag」
3. 屏幕按 `status` 显示「已收藏」「已在库中」或「已在库中，解析失败」
4. 回到原 APP 继续做原来的事
5. 新链接由后端抓正文 → 提标题摘要 → 打标签；已有链接保持现状，失败记录不会被重复提交隐式刷新
6. 之后在电脑或手机浏览器打开 Reader，按当前后端分类结果继续处理

### 路径 C · 离线补发（URL 可提取时）

1. 无网络状态下分享 → 显示「已加入队列」
2. URL 存入本地队列
3. 网络恢复 → 系统在平台允许的时机调度后台任务重发；iOS 被用户强退后需重新打开主 APP 才会恢复调度
4. 成功后静默从队列移除，不打扰用户
5. 条目超过 7 天仍未成功时停止自动重试并显示为「已过期」，不静默删除

### 路径 D · 凭证失效（异常路径）

1. 分享后显示「凭证无效，请检查设置」或「API Key 缺少 write 权限」
2. 已持久化条目转 `blocked_auth` 或 `blocked_scope`，停止自动调度但不丢 URL
3. 用户打开 APP，重新录入 API Key并测试连接；origin 与 namespace 仍匹配时恢复条目
4. 若新 key 指向另一 tenant，条目转 `blocked_identity`，必须由用户删除或逐条确认迁移

### 路径 E · 已有记录解析失败

1. `POST /api/links` 返回 `202 + status=failed`
2. 分享界面显示「已在库中，解析失败」，不谎报新任务已经开始，也不把它当网络失败重复提交
3. 主 APP 的最近结果保留 `link_id`，用户可点「重新解析」
4. refresh 成功返回 202；`cooldown_active` 按 `Retry-After` 延后；`quota_exceeded` 进入配额阻断

---

## AI 边界

| 能力类型 | 用途说明 | 应用位置 |
|---------|---------|---------|
| 文本理解（已有，后端） | 抓取网页正文，生成标题、摘要、标签，判定归属库（reading / site） | 后端收到 `POST /api/links` 后由 ingest pipeline 自动触发，APP 不参与、不等待 |
| URL 候选抽取（本地、确定性） | 从结构化分享项或纯文本中找出可证明来源的 URL | iOS / Android 客户端；同一共享夹具锁定一致行为 |

APP 客户端本身不集成模型，MVP 也不上传原始分享文本请求 URL 抽取。后端既有 AI 只在成功提交 URL 后参与抓取、摘要、标签与分类。

---

## 技术方向

下表是已冻结的 MVP 技术方向；“已冻结”不表示完整功能已经实现。

| 维度 | 选择 | 理由 |
|------|------|------|
| 产品类型 | Mobile（iOS + Android 双端原生） | 核心能力是接收系统分享，这是纯平台特性。iOS Share Extension 必须用 Swift 独立进程实现，Flutter engine 无法也不该塞进去；Android 侧同理。选定「静默提交 + 纯投递器」后，跨平台框架仅能承载一个设置页，引入 Flutter/RN 的收益为负 |
| iOS 技术栈 | Swift + SwiftUI + Share Extension + App Group + Keychain Sharing + URLSession | 系统原生能力直用，无第三方依赖。Keychain Sharing 是让 Extension 读到主 APP 凭证的唯一正规途径 |
| Android 技术栈 | Kotlin + 半透明 Activity（`ACTION_SEND`）+ Room + WorkManager + Android Keystore | Activity 承担候选选择和 2 秒前台交接，Room 是持久状态源，WorkManager 串行重试；URL payload 用 Keystore AES-GCM 加密 |
| 认证方式 | API Key（`ApiKeyBearer`），不做 OIDC | 单人自用场景。API Key 长期有效、无刷新流程、Extension 里读一次就能用。走 OIDC Authorization Code + PKCE 需要注册移动端 client、处理 redirect scheme、实现 token 刷新，且 refresh 逻辑在朝生暮死的 Share Extension 进程里极难做对 |
| 数据存储 | 纯本地，极少量 | 凭证进 Keychain / Keystore；加密队列与“最近一条结果”保存 URL、幂等 key、状态与时间，不保存网页正文或原始分享文本；数据文件排除备份。成功提交立即移除活动队列，失败 / 过期条目保留到用户删除，最近结果由下一次成功覆盖或由用户显式清除 |
| 部署方式 | Android：源码与 debug APK 快速交付；签名私有分发按需执行。iOS：仅冻结源码快照 | 只给自己用，不上架；本次收口不承诺 iOS 签名、安装或发布 |
| 后端改动 | MVP 无后端功能改动 | 复用 `POST /api/links`、refresh 和 session identity；只补齐 `Idempotency-Key` 与 API key scope 的 OpenAPI 描述，不新增路由、DTO、迁移或运行逻辑 |

---

## 技术说明

### 可复用的现有后端契约

- `POST /api/links`
  - 请求：`LinkCreateRequest`，必填字段仅 `url`
  - 响应：`202 + SubmitResponse{link_id, status, job_id?}`
  - **幂等**：已存在的 URL 直接返回当前状态，不重复建任务；pending / processing / failed / done 都可能携带真实 `job_id`，客户端只按 `status` 解释业务状态
  - 认证：`Authorization: Bearer <api-key>`，需 `write` scope
- `GET /api/session`：验证凭证对应的 identity、namespace 与 canonical scopes；设置页用它确认 `write` 权限
- `POST /api/admin/api-keys`：铸 key，需 `ADMIN_AUTH_TOKEN`，运维侧一次性操作
- `POST /api/links/{link_id}/refresh`：只由设置页的显式重新解析操作调用；终态在 cooldown 外重入队，cooldown 返回 `429 cooldown_active + Retry-After`
- `Idempotency-Key`：`POST /api/links` 已在 OpenAPI 声明该可选 header；生产中间件在默认启用时回放写请求的 2xx 和确定性 4xx，409 / 425 / 429 / 5xx 不缓存。回放缓存默认保留 24 小时，客户端不得把同一 key 用于不同请求体，Mobile 发布前必须验证部署没有关闭该能力

### 关键工程约束

- **Share Extension 是短命进程**。稳定 idempotency key 和 URL 必须在发出第一条请求前原子写入 App Group 队列；前台最多等待 2 秒。服务端原请求可能已经成功，后续补发必须按同一幂等身份安全重放。background `URLSession` 需唯一 identifier、`sharedContainerIdentifier`、file-backed upload、宿主事件接管和真机验证，不能只凭配置名假定会自动完成。
- **Android 后台限制**：国产 ROM 对后台任务限制激进。WorkManager 是当前最稳的持久调度基础，但不能保证秒级补发；Activity 退出前必须完成 Room 事务与唯一 work 入队。7 天只结束自动重试，不删除数据。
- **iOS 发布已退出当前范围**：冻结源码不代表可安装产物。若未来重新启用 iOS，证书期限、签名、设备安装和后台恢复必须在新的明确范围内重新验证。
- **HTTPS 强制**：Server URL 只接受 https，不为自签证书或 http 开后门。
- **API origin 规范化**：只接受无 userinfo、query、fragment 的 origin；path 必须为空或 `/`，保存时去尾斜杠。原生客户端不受浏览器 CORS 限制，但仍执行系统证书链校验，不提供“忽略证书错误”。禁止 HTTPS 降级和携带 Authorization 的跨 origin 重定向；key 与规范化 origin 成对保存，修改 origin 时必须清除或重新验证 key。

### 明确的非目标（MVP 不做）

以下全部**不做**，不是排期靠后，是本版本明确不做：

- ❌ 收藏列表 / 阅读界面 / 搜索 —— 这些 reader 已经有了，手机浏览器打开即可
- ❌ 编辑标签、改标题、选归属库 —— 投递器只投递
- ❌ 多用户 / 登录注册 / OIDC
- ❌ 分享图片、视频、文件
- ❌ 上架 App Store / Google Play
- ❌ 推送通知（解析完成不通知，用户不需要知道）
- ❌ 小红书这类只提供 APP 内链、不给公开 URL 的平台 —— 技术上无解，明确不支持
- ❌ `/api/links/from-text` 与任何客户端 / 服务端 LLM URL 猜测
- ❌ 在 MVP 中实现 D28 的 inbox / library destination 新字段

---

## 补充说明

| 状态文案 | 触发条件 | 后续行为 |
|---------|---------|---------|
| `已收藏` | `202 status=pending|processing` | 后端已有进行中的解析任务；不声称新建或复用 |
| `已在库中` | `202 status=done` | 已有完成记录，不创建新任务 |
| `已在库中，解析失败` | `202 status=failed` | 不自动 refresh；最近结果提供显式重新解析 |
| `已加入队列` | 无网络 / timeout / 408 / 425 / 5xx / 短期限流 | 保留本地条目，按计划自动重发 |
| `没找到链接` | 本地确定性提取没有候选 | 直接结束，不记录原始文本 |
| `凭证无效，请检查设置` | `401` | 条目转 `blocked_auth`，需用户去设置页修 |
| `API Key 缺少 write 权限` | `403 insufficient_scope` | 条目转 `blocked_scope`，需重新铸 key 或调整 scope |
| `本月配额已用完` | `429 quota_exceeded` | 不做短周期自动重试，保留条目等待用户处理 |

## 已冻结的实施参数

| 参数 | MVP 决定 | 后续变更条件 |
|-------|---------|------|
| Mobile destination | 省略不存在的 `destination`，沿用当前 `POST /api/links` 默认 | D28 被接受、OpenAPI 落地且旧客户端省略语义保持兼容后再升级 |
| 文本 AI 兜底 | 不做 | 至少 200 条脱敏夹具、确定性成功率低于 99%、可证明 URL provenance，并另开安全评审 |
| `Idempotency-Key` | 每条队列记录一个独立 UUID，同 URL 请求的前后台发送始终复用；部署保持默认启用 | 改动服务端回放语义、TTL 或 capability 暴露时同步升级客户端契约测试 |
| API Key 录入 | 粘贴 write-only key | 二维码必须另行评估相机权限、出码端与密钥暴露面 |
| iOS 最低版本 | iOS 16.0 | 只有真实目标设备更旧才下调，并补相应 API 兼容测试 |
| Android 最低版本 | API 26；compile / target SDK 35 | SDK 升级走独立依赖变更并重跑最低与当前版本矩阵 |
| 应用标识 | 显示名 `WebTag`；默认 bundle / application id `com.alpenl.webtag.share` | 自部署 fork 可覆盖签名标识，但共享 App Group / access group 必须随之成套修改 |
| 队列到期 | 7 天后转 `expired`，停止自动重试但不删除 | 只有用户明确删除；未来更改需同步迁移两端队列 schema |
| Android 前台模型 | 半透明 Activity 等待持久化与最多 2 秒 HTTP 交接 | 不退回 Toast-only + 立即 `finish()` |
| iOS 后台承诺 | 冻结源码描述尽力调度 + 主 App 恢复兜底 | 不承诺用户强退后系统仍自动唤醒；若未来重新启用 iOS，另立范围验证这一边界 |

## 同步与验收权威

本文维护产品与安全决策；`README.md` 维护当前平台支持、构建与
验证状态；`ARCHITECTURE.md` 维护进程、存储、身份、队列、重试、
加密和 lease 不变量。共享 fixture 变化必须同步 reference comparator 与
Android 测试；冻结的 iOS snapshot 只接受保持共享合同可读所需的静态同步，
不因此恢复 iOS 开发或发布承诺。

任何 route、DTO 或 scope 变化仍须先改后端的
`internal/app/assets/openapi.json`，再生成 `packages/webtag-api/src/generated.ts`
——这两个路径都在上游的 WebTag 私有仓库，不在本仓。移动端拆仓之后这条契约变成了
**跨仓缝隙**：本仓没有任何门禁能发现后端契约先行变更，它只会在对真实服务器发请求时
以运行时失败的形式暴露。因此后端改动这些内容时，必须同时更新本仓的
`shared/fixtures/` 与 `scripts/mobile-wire-smoke.py`。
Android 的维护门禁是 README 中列出的 fixture、X1、wire、JVM 单测、debug assemble 和 lint。
真机、签名、生产 smoke、升级/回滚与重型设备矩阵可按发布需要执行，
但不再阻断本次快速收口。完成的实施计划和并行流程由 Git 历史保存，
不创建归档文档。
