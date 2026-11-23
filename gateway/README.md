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
