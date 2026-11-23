# Orca iOS 推送网关

一个可以自己部署的小服务。Orca 桌面端把推送交给它，它再通过 APNs 发到社区版 iOS App（bundle id `com.thm.orcaios`）。支持两类推送：

- 普通通知（alert / 角标）
- ActivityKit 实时活动（结束）

桌面端这一侧不需要改代码。启动 Orca 时设置环境变量 `ORCA_PUSH_GATEWAY_URL`，桌面端就会改用这个网关，握手和接口与官方网关（`https://push.onorca.dev`）一致。

依赖：Node.js 20.12 及以上，运行时只用到 `tweetnacl`，不需要构建。

## 取舍：改用自建网关后，官方 App 收不到推送

桌面端同一时间只认一个网关。设置了 `ORCA_PUSH_GATEWAY_URL` 之后：

- 这台桌面发出的所有手机推送都只走这个网关，不会再发到官方网关。
- 官方 Orca iOS / Android App 仍然可以配对、使用，但收不到这台桌面的推送：
  - Android 的注册会被拒绝，本网关只实现了 APNs。
  - 官方 iOS App 的 token 会按本网关的 topic（`com.thm.orcaios`）发送，APNs 返回 `DeviceTokenNotForTopic`，注册随即被删除。
- 取消这个环境变量并重启 Orca，就会回到官方网关。手机需要重新注册一次推送（打开 App 即可）。

## 快速开始

```sh
cd gateway
npm ci --omit=dev
cp .env.example .env    # 按下文填写
node server.js          # 启动时会自动读取当前目录下的 .env
```

用 Docker：

```sh
docker build -t orca-push-gateway .
docker run -d --name orca-push-gateway --restart unless-stopped \
  -p 127.0.0.1:8787:8787 \
  -v orca-push-data:/data \
  -v /path/to/AuthKey_ABCDE12345.p8:/keys/apns.p8:ro \
  -e PUBLIC_ORIGIN=https://push.example.com \
  -e APNS_KEY_PATH=/keys/apns.p8 -e APNS_KEY_ID=ABCDE12345 -e APNS_TEAM_ID=TEAMID1234 \
  -e TRUST_PROXY=1 \
  orca-push-gateway
```

检查是否在运行：`curl https://push.example.com/health`，会返回 `{"ok":true,"pushProtocol":1,"apnsConfigured":true}`。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PUBLIC_ORIGIN` | 必填 | 桌面端访问网关用的源，例如 `https://push.example.com`。要和 `ORCA_PUSH_GATEWAY_URL` 完全一致：协议、主机名、端口都要相同，且不能带路径。这个值会写进握手签名的 transcript，不一致时桌面端会拒绝登录。 |
| `HOST` | `0.0.0.0` | 监听地址。前面有反向代理时建议设为 `127.0.0.1`。 |
| `PORT` | `8787` | 监听端口。 |
| `DATA_DIR` | `./data` | 状态文件位置，文件为 `$DATA_DIR/state.json`，权限 0600。 |
| `APNS_KEY_PATH` | 无 | `.p8` 文件路径。 |
| `APNS_KEY` | 无 | 也可以直接放 `.p8` 的内容（PEM），支持用 `\n` 写成一行。优先于 `APNS_KEY_PATH`。 |
| `APNS_KEY_ID` | 无 | 10 位 Key ID。 |
| `APNS_TEAM_ID` | 无 | 10 位 Team ID。 |
| `APNS_DEFAULT_TOPIC` | `com.thm.orcaios` | 不带前缀的纯十六进制 token 使用这个 topic。 |
| `APNS_ALLOWED_TOPICS` | 等于默认 topic | 逗号分隔。token 里写的 topic 必须在列表中，避免别人借你的 Key 往同一团队的其他 App 发推送。 |
| `ALLOWED_HOST_FINGERPRINTS` | 空（不限制） | 逗号分隔的桌面指纹。设置后只有这些桌面能登录。指纹可以在日志的 `host_signed_in` 或 `host_not_allowed` 行里找到。 |
| `SESSION_TTL_MS` | `86400000`（24 小时） | 桌面会话有效期，单位毫秒。桌面端会在到期前 60 秒自动重新握手。 |
| `TRUST_PROXY` | 关 | 设为 `1` 后，从 `CF-Connecting-IP` / `X-Forwarded-For` 读取客户端 IP，只用于握手接口的限流。 |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error`。日志里不会输出 token。 |
| `APNS_HOST_OVERRIDE` | 无 | 仅用于测试：把 APNs 请求发到指定地址，`http://` 时使用 h2c。 |
| `ENV_FILE` | `.env` | 启动时读取的 env 文件。已经存在的环境变量不会被覆盖。 |

没有配置 APNs 密钥时，服务照样能启动、完成握手和注册，但每次发送都会返回 `error`。

## 从 Apple Developer 获取 .p8 密钥

1. 登录 [Apple Developer](https://developer.apple.com/account)，进入 Certificates, Identifiers & Profiles。
2. 在 Identifiers 里确认 `com.thm.orcaios` 这个 App ID 已经勾选 Push Notifications。
3. 打开 Keys，点 `+` 新建密钥，勾选 Apple Push Notifications service (APNs)。新版页面会让你选择环境和范围：环境选 Sandbox & Production；范围选 Team Scoped，或者选 Topic Specific 并指定 `com.thm.orcaios`。
4. 下载 `AuthKey_XXXXXXXXXX.p8`。这个文件只能下载一次，请妥善保存。文件名里的 10 位字符就是 `APNS_KEY_ID`。
5. `APNS_TEAM_ID` 在 Membership details 页面可以找到。

说明：

- Live Activity 的远程推送只支持基于 token 的认证（.p8），证书方式不行。
- 环境由 App 上报的 `apnsEnvironment` 决定：Xcode 直接安装的开发版用 `sandbox`，TestFlight / App Store / Ad Hoc 用 `production`。两者的 token 不能混用。

## 放在 HTTPS 后面

打包版的 Orca 只接受 `https://` 的网关地址。`http://` 只在开发版 Orca、并且地址是 `127.0.0.1` / `localhost` 时可用。

### Caddy

Caddy 会自动申请证书。`Caddyfile`：

```
push.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

网关这边设置 `PUBLIC_ORIGIN=https://push.example.com`、`HOST=127.0.0.1`、`TRUST_PROXY=1`。

### Cloudflare Tunnel

适合没有公网 IP 的机器。要使用固定域名的命名隧道：临时隧道（`cloudflared tunnel --url ...`）每次启动的域名都不同，而 `PUBLIC_ORIGIN` 必须保持不变。

```sh
cloudflared tunnel login
cloudflared tunnel create orca-push
cloudflared tunnel route dns orca-push push.example.com
```

`~/.cloudflared/config.yml`：

```yaml
tunnel: orca-push
credentials-file: /Users/you/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: push.example.com
    service: http://127.0.0.1:8787
  - service: http_status:404
```

然后运行 `cloudflared tunnel run orca-push`，网关设置 `PUBLIC_ORIGIN=https://push.example.com`、`TRUST_PROXY=1`。

## 部署到 Cloudflare Workers（`../gateway-worker`）

`gateway-worker/` 是同一个网关的 Worker 版本，跑在 Cloudflare 上，不需要一台常开的 Mac。接口、握手字节、校验规则、限额和 TTL 与 Node 版完全一致，桌面端看不出区别。

和 Node 版的差别：

- 状态不再写 `state.json`，而是放在一个 SQLite 存储的 Durable Object（类名 `GatewayDurableObject`，实例名 `global`）里。所有 `/v1/*` 请求都转给这一个实例，相当于 Node 版的单进程，读写天然串行。表结构：

  | 表 | 内容 |
  | --- | --- |
  | `sessions` | 会话 token 的 sha256、桌面指纹、过期时间。每台桌面只留一行。 |
  | `registrations` | 注册 id、桌面指纹、`deviceId`、环境、原始 token、解码后的 device（JSON）、`device_token`（算角标总数用）。`(桌面指纹, deviceId)` 唯一，每台桌面最多 64 条。 |
  | `badges` | 每条注册最后上报的未读数。 |
  | `challenges` | 握手 challenge：指纹、期望 proof 的摘要、过期时间、是否已用。10 秒有效，过期 30 秒后清掉，最多 2000 条。 |
  | `rate_limits` | 握手接口每个 IP 每分钟 60 次的计数。 |
  | `meta` | 表结构版本，以及每个 APNs Key 当前的 provider JWT（50 分钟内复用，对象重启也不会重新签）。 |

- APNs 用 `fetch()` 直连 `api[.sandbox].push.apple.com`（Cloudflare 走 HTTP/2），JWT 用 WebCrypto 做 ES256 签名。
- 客户端 IP 直接取 `CF-Connecting-IP`，没有 `TRUST_PROXY`。`HOST`、`PORT`、`DATA_DIR`、`APNS_KEY_PATH`、`ENV_FILE` 在 Worker 里没有意义。
- `/health` 由 Worker 直接回答，不唤醒 Durable Object。

### 配置

普通变量写在 `gateway-worker/wrangler.toml` 的 `[vars]` 里，改完重新部署；私钥用 secret，不进仓库。

| 名称 | 类型 | 说明 |
| --- | --- | --- |
| `PUBLIC_ORIGIN` | var | 同 Node 版，必须和桌面端的 `ORCA_PUSH_GATEWAY_URL` 完全一致。现在是 `https://orca-push.huami.dev`。 |
| `APNS_TEAM_ID` | var | `S639XDDS5S` |
| `APNS_DEFAULT_TOPIC` | var | `com.thm.orcaios` |
| `APNS_SANDBOX_KEY` / `APNS_SANDBOX_KEY_ID` | secret / var | sandbox 环境用的 .p8 和它的 Key ID。 |
| `APNS_PRODUCTION_KEY` / `APNS_PRODUCTION_KEY_ID` | secret / var | production 环境用的 .p8 和它的 Key ID。 |
| `APNS_KEY` / `APNS_KEY_ID` | secret / var | 可选的兜底 Key：哪个环境没有自己的 Key，就用它。 |
| `ALLOWED_HOST_FINGERPRINTS`、`APNS_ALLOWED_TOPICS`、`SESSION_TTL_MS`、`LOG_LEVEL` | var | 含义同 Node 版。 |

为什么分两把 Key：这个团队只能建 Topic Specific 的 Key，而这种 Key 只对一个环境有效。每次发送按注册时上报的 `apnsEnvironment` 选 Key，每把 Key 各自缓存一个 JWT。某个环境没有 Key 时，发往该环境设备的推送返回 `error`，日志里的原因是 `apns_sandbox_not_configured` 或 `apns_production_not_configured`；另一个环境不受影响。两个环境都没有 Key 时，握手和注册照常，`/health` 返回 `apnsConfigured:false`，所有发送都返回 `error`。

### 部署

```sh
cd gateway-worker
npm install
npm test                 # 先用 wrangler 打出 dist/，再在本地 workerd 里跑全部测试
npx wrangler deploy      # 部署为 orca-push，地址 https://orca-push.huami1314.workers.dev
```

拿到 .p8 之后（命令在 `gateway-worker/` 下执行，文件名换成实际的）：

```sh
# 1. 在 wrangler.toml 的 [vars] 里填 APNS_SANDBOX_KEY_ID / APNS_PRODUCTION_KEY_ID，然后
npx wrangler deploy

# 2. 上传私钥（secret 立即生效，不用再部署）
npx wrangler secret put APNS_SANDBOX_KEY < AuthKey_XXXXXXXXXX.p8
npx wrangler secret put APNS_PRODUCTION_KEY < AuthKey_YYYYYYYYYY.p8

# 3. 确认
curl https://orca-push.huami1314.workers.dev/health   # apnsConfigured 应为 true
```

注意：`wrangler deploy` 会用 `wrangler.toml` 里的 `[vars]` 覆盖控制台上手动改过的变量，Key ID 请写在文件里；secret 不受影响。

`PUBLIC_ORIGIN` 已经写成 `https://orca-push.huami.dev`。在自定义域名接到这个 Worker 之前，桌面端只能通过 workers.dev 地址访问，而 transcript 里的 origin 对不上，握手会被桌面端拒绝；这是预期的，域名切过来后就能用。切换时在 Cloudflare 控制台（或 `wrangler.toml` 的 `routes`/`custom_domain`）把 `orca-push.huami.dev` 指到 Worker，并停掉原来指向 Mac 的隧道路由。

看日志：`npx wrangler tail orca-push`。

## 让桌面端使用这个网关

`ORCA_PUSH_GATEWAY_URL` 必须在 Orca 进程启动时就存在。它的值必须是不带路径的源，例如 `https://push.example.com`（末尾多一个 `/` 没关系，带其他路径不行）。格式不对或不是 https 时，桌面端不会报错，而是直接退回官方网关。

macOS 上任选一种方式（先完全退出 Orca）：

```sh
# 只对这次启动生效
open --env ORCA_PUSH_GATEWAY_URL=https://push.example.com -a Orca

# 或者直接运行可执行文件
ORCA_PUSH_GATEWAY_URL=https://push.example.com /Applications/Orca.app/Contents/MacOS/Orca

# 或者对之后从 Dock / Finder 打开的 App 都生效（重启电脑后失效）
launchctl setenv ORCA_PUSH_GATEWAY_URL https://push.example.com
```

如果推送服务跑在无界面的 `orcad` / `orca serve` 宿主进程里，这个变量需要设置在那个进程的环境中。

切换网关之后，在 iOS App 里重新开启一次推送（或者重新连接这台桌面），让桌面端向新网关注册。网关日志里出现 `host_signed_in` 和 `device_registered` 就说明接通了。

另外，桌面端会校验握手时间：网关和桌面的时钟相差超过 30 秒时会拒绝登录，两台机器都要开启 NTP。

## 协议说明

桌面端调用的接口（与官方网关一致）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/v1/host/challenge` | `{v:1, hostPublicKeyB64}`，返回 `{challengeId, gatewayEphemeralPublicKeyB64, nonceB64, ciphertextB64, expiresAt}` |
| POST | `/v1/host/session` | `{v:1, challengeId, proofB64}`，返回 `{sessionToken, expiresAt, hostFingerprint}` |
| POST | `/v1/devices` | Bearer。`{v:1, deviceId, platform:"ios", token, apnsEnvironment}`，返回 `{registrationId}`。同一桌面、同一 `deviceId` 再次注册时，`registrationId` 不变，token 整体替换。 |
| DELETE | `/v1/devices/:id` | Bearer。成功返回 204，不存在或属于其他桌面返回 404。 |
| GET | `/v1/devices` | Bearer。列出本桌面的注册。 |
| POST | `/v1/send` | Bearer。返回 `{results:[{registrationId, status}]}`，`status` 取值为 `queued` / `dead` / `rate_limited` / `error`。 |

握手过程：网关用临时 X25519 密钥把 transcript 和一个 32 字节随机数加密给桌面的公钥（NaCl box）。桌面解开后校验 transcript，其中包括 `gatewayOrigin`，再返回 `HMAC-SHA256(随机数, "orca-push-host-proof/v1\0ack\0" || transcript)`。桌面指纹为 `base64url(sha256(公钥))` 的前 16 个字符。每台桌面同时只保留一个会话。注册归属于创建它的桌面，其他桌面不能向它发送，也不能删除它。

时间单位：所有 `expiresAt` 都是毫秒时间戳。

### 设备 token 格式（App 与网关之间的约定）

```
token = "orcaios1." + base64url(JSON)
{
  "d": "<十六进制 APNs device token>",
  "t": "com.thm.orcaios",
  "h": "<桌面显示名>",
  "k": "<App 内这台桌面的 id，用于深链>",
  "s": "<十六进制 push-to-start token>",            // 可选
  "a": { "<worktreeId>": "<十六进制 activity update token>" }  // 可选
}
```

不以 `orcaios1.` 开头的 token 按纯十六进制 device token 处理，topic 使用 `APNS_DEFAULT_TOPIC`。桌面端对 token 的长度上限是 4096 个字符，`a` 里的条目不宜过多（每条约 200 个字符），已结束的活动应及时从 `a` 中去掉。

### 一条通知会变成哪些 APNs 请求

- `kind` 为 `alert` 或缺省时，向 `d` 发送普通通知。内容是 `aps.alert {title, body}`；`sound: "default"`，桌面端发 `sound:false` 时不带声音；`thread-id` 取 worktreeId；有角标记录时带上 `badge`；自定义字段 `orca` 包含 `{hostFingerprint, worktreeId, paneKey, notificationId, executionHost, notificationSeq, notificationEpoch, source, agentState, host: k}`。`apns-collapse-id` 是对 `[hostFingerprint, notificationId]` 做 sha256 得到的 64 位十六进制串；`apns-expiration` 取自 `expiresAt`。
- `kind: "badge"`：记录这台桌面的未读数，然后把同一个 `d` 在所有桌面上的未读数相加，发一条只带角标的推送（`apns-expiration: 0`）。
- `kind: "dismiss"`：不发送任何推送，直接返回 `queued`。
- 实时活动：只在有 `worktreeId` 和 `agentState` 时发送。topic 为 `t + ".push-type.liveactivity"`，`apns-push-type: liveactivity`，优先级 10。
  - 手机上的实时活动只在智能体工作时存在，由 App 自己开始和更新；桌面只在工作停下时通知（`needs-input` 或 `finished`），所以网关只负责结束：
    - 如果 `a[worktreeId]` 存在，发 `event: "end"`，phase 为 `needsYou` 或 `done`，`dismissal-date` 为当前时间，活动立即消失。发送成功后，网关会从已存的注册中删掉这个 update token。
    - 不会用 `s` push-to-start：开始一个活动只会显示一个已经停下的智能体。
  - `content-state` 为 `{phase, detail, since}`。`detail` 是 body 压成一行后的结果，最多 120 个字符；body 为空时用 title。`since` 是从 2001-01-01 起算的秒数，对应 Swift `Date` 的默认解码方式。
  - 实时活动推送失败不影响返回的状态，状态只反映发往 `d` 的那条推送。APNs 认为某个活动 token 已失效时，网关会把它从注册中删掉。
- 结果映射：200 对应 `queued`；410、400 `BadDeviceToken`、400 `DeviceTokenNotForTopic` 对应 `dead`，同时删除这条注册（桌面端也会删掉自己的记录）；429 对应 `rate_limited`；其余情况对应 `error`。

## 测试

```sh
npm install    # 包含测试用的 zod 和 esbuild
npm test
```

- `test/handshake-vector.test.js`：用官方仓库里的 proof 向量（`cloud/packages/push-contract/src/push-host-proof-vector.json`）逐字节核对 transcript、加密明文和 HMAC。
- `test/gateway.test.js`：通过 HTTP 跑完整流程。握手部分用独立移植的桌面端 `answerPushHostChallenge`，APNs 用本地 HTTP/2 桩代替，检查各种通知生成的 APNs 请求头和 payload。
- `test/desktop-interop.test.js`：把 Orca 仓库里桌面端真正的 `PushGatewayClient` 及其依赖的 TS 文件复制到临时目录，用 esbuild 即时编译后跑注册、发送和删除。找不到 Orca 仓库时会跳过，可以用 `ORCA_REPO=/path/to/orca` 指定位置。

测试只使用 18431–18434、18441、18442 端口。

Worker 版的测试在 `gateway-worker/test/`，`npm test` 先执行 `wrangler deploy --dry-run --outdir dist`，再用 Miniflare 在本地 workerd 里运行这份与线上相同的 bundle，APNs 请求由测试里的假服务接住：

- 上面三组测试都移植了过来，断言不变；原来读 `state.json` 的地方改为读 Durable Object 的 SQLite。
- `worker.test.js`：没有 Key 时的行为、404 和响应头、每 IP 每分钟 60 次的限流、JWT 复用。
- `apns-keys.test.js`：sandbox / production 各用各的 Key、只有一个环境有 Key、`APNS_KEY` 兜底、每把 Key 单独缓存和作废 JWT。

Worker 版测试使用 18431–18433、18441、18451、18452、18461–18463 端口，和 Node 版的测试不要同时跑。
