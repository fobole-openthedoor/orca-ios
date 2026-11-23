# Orca application-level RPC surface (mobile client)

Wire-level reference for reimplementing the Orca mobile screens natively.
Source: `stablyai/orca` at commit `6c32ef93c8a38fd21d709c241f9dd943f2af2d57` (2026-11-18), read from `/Users/qq12/orca`.
Paths below are relative to that repo root. `mobile/src/...` is the React Native client, `src/shared/...` the shared contract, `src/main/runtime/rpc/...` the host.

Out of scope (already understood): pairing offer, E2EE v2 handshake, the `{id, deviceToken, method, params}` → `{id, ok, result|error, streaming?}` envelope, `runtime.clientCapabilities.update`, the `status.get {probe:true}` liveness probe.

Conventions used here:

- Types are quoted as TypeScript. `?` means the key may be absent. "Older hosts omit" means treat absence as unknown, not as false.
- **UNVERIFIED** marks anything not confirmed from source in this pass.
- Host param schemas are zod. `.strict()` schemas **reject unknown keys**; plain `z.object` strips them. This matters: sending a newer optional field to a strict method on an older host fails the whole call, which is why most optional fields are gated on a host capability string.
- The complete map of method name → param schema is `src/shared/rpc-contract/rpc-params-catalog.generated.ts`. The methods a phone is allowed to call are listed in `src/main/runtime/rpc/server/runtime-rpc-mobile-method-allowlist.ts` (agent-session subset: `runtime-rpc-mobile-agent-session-methods.ts`).

Worktree selectors: every `worktree` param is a selector string. The mobile app always sends `id:<worktreeId>`; repo selectors are `id:<repoId>`. The host also resolves `path:`, `name:`, `branch:`, `issue:`, `identity:` prefixes.

---

## 1. Host status: `status.get`

Host: `src/main/runtime/rpc/methods/host-management/status.ts`. Params: `src/shared/rpc-contract/host-management/status-params.ts` (any object accepted; non-objects become `{}`).

- `{ probe: true }` → `{ runtimeId: string }` only.
- anything else → full status.

Host result type (`RuntimeStatus`, `src/shared/remote-runtime/session-graph/runtime-session-contracts.ts:68`) plus what the handler adds:

```ts
type StatusGetResult = {
  runtimeId: string
  pairedDeviceId?: string            // your authenticated device id
  rendererGraphEpoch: number
  graphStatus: RuntimeGraphStatus
  authoritativeWindowId: number | null
  desktopWindowStatus?: RuntimeDesktopWindowStatus
  liveTabCount: number
  liveLeafCount: number
  runtimeProtocolVersion?: number            // currently 3
  minCompatibleRuntimeClientVersion?: number // currently 2
  protocolVersion?: number                   // legacy alias of runtimeProtocolVersion (mobile reads this)
  minCompatibleMobileVersion?: number        // legacy alias (mobile reads this)
  capabilities?: string[]
  worktreeCreateIdempotency?: { dedupeTtlMs: number }
  degradations?: RuntimeDegradation[]
  appVersion?: string
  remoteUpdateSupport?: RemoteServerUpdateSupport
  hostPlatform?: NodeJS.Platform     // 'darwin' | 'linux' | 'win32' | ...
  machineName?: string
  hostMachine?: { kind: 'laptop' | 'desktop' | 'server'; model: string | null }
  hostDescriptor?: { installationId?: string, ... }
  terminalWindowsShell?: string | null
  deviceScope?: DeviceScope
  floatingWorkspaceEnabled?: boolean
  remoteControl?: ... | null
}
```

What the mobile app actually validates (`mobile/src/transport/hosts/host-status-reply-schema.ts`) — a loose object where every field is optional and individually salvaged (a malformed field is dropped, not fatal):

```ts
{
  protocolVersion?: number
  minCompatibleMobileVersion?: number
  appVersion?: string
  floatingWorkspaceEnabled?: boolean
  capabilities?: string[]        // salvaged as a whole: one bad entry drops the entire list
  hostPlatform?: NodePlatformName // unknown value → field dropped
  machineName?: string
  hostMachine?: { kind: 'laptop'|'desktop'|'server'; model: string|null } // unknown kind drops the field; bad model → null
  hostDescriptor?: { installationId?: string }
}
```

The reply envelope also carries `_meta?: { runtimeId: string }` (`mobile/src/transport/rpc/rpc-wire-types.ts`); mobile compares it across calls to detect a host replacement.

### Capabilities list meaning

`capabilities` is the host's advertised feature-flag list (aggregate: `RUNTIME_CAPABILITIES` in `src/shared/remote-runtime/protocol/protocol-version.ts`). The client uses it to decide (a) whether a method exists and is callable from a phone, and (b) whether an optional param may be sent to a strict schema. Absent capability = do not send / do not offer. The gates the chat screen needs (`mobile/src/session/native-chat/agent-session/mobile-structured-agent-session-host-support.ts`):

| Host capability string | Gates |
|---|---|
| `agent-session.structured.v1` | structured chat exists at all |
| `agent-session.status-feed.v1` | `agentSession.subscribeStatus` readable by a phone |
| `agent-session.text-append.v1` | may send `capabilities.textAppend: 1` on `agentSession.subscribe` |
| `agent-session.tool-output-append.v1` | may also send `capabilities.toolOutputAppend: 1` |
| `agent-session.attachments.phone.v1` | `agentSessionAttachment.upload*` callable from a phone (file attachments) |
| `agent-session.item-detail.v1` | `agentSession.item` (full output / full message) |
| `agent-session.send-recorded.v1` | `agentSession.sendRecorded` |
| `agent-session.queued-messages.v2` | `delivery: 'queue-if-active'` on send; `agentSession.queuedMessage*` |
| `agent-session.queued-commands.v1` | `delivery` on `conversationCommand` (`/compact`) |
| `agent-session.queued-message-edit.v1` | `queuedMessageUpdate` / `queuedMessageEditHold` |
| `agent-session.question-answers.v1` | `answers[]` on `respondToQuestion` (else packed `optionId`) |
| `agent-session.prompt-cancel.v1` | `prompt` on `agentSession.cancel` |
| `agent-session.conversation-stop.v1` | `agentSession.cancel` with no `turnId` |
| `agent-session.repeated-stop.v1` | host answers a repeated Stop quietly (no client-side join needed) |
| `agent-session.send-options.v1` | `options` on send |
| `agent-session.send-selection.v1` | `selection` on send |
| `agent-session.send-skills.v1` | `body.skills` on send |
| `agent-session.permission-modes.v1` | permission-mode picker |
| `agent-session.rewind.phone.v1` | `agentSession.rewind` from a phone |
| `agent-session.mcp.v1` | `agentSession.mcp` |
| `agentSession.create.message.v1` | `firstMessage` / `options` on `agentSession.create` |
| `agentSession.create.tab-placement.v1` | `tabPlacement` on `agentSession.create` |
| `agent.launch.v2` | `agent.launch` exists |
| `agent.launch.replay-required.v1` | `agent.launchReplay` exists (required for launching in an existing workspace) |
| `agent.launch.surface.v1` | `surface` on launch |
| `agent.launch.chat-options.v1` | `chatOptions` on launch |
| `notifications.remote-push.v1` | `notifications.registerPush` |
| `native-chat.text-attachment-read.v1` | `agentSessionAttachment.readTextChunk` |

---

## 2. Stream mechanics

Sources: `mobile/src/transport/rpc/rpc-client-stream-registry.ts`, `rpc-client-stream-request.ts`, `rpc-client-terminal-subscription.ts`, `rpc-client-server-subscription.ts`, `rpc-acceptance-policies.ts`, `rpc-subscription-result-shapes.ts`, `rpc-client-session-tabs-stream.ts`, `rpc-client-terminal-binary-frame.ts`, `rpc-client-terminal-stream-router.ts`. Host emitter: `src/main/runtime/rpc/dispatch/dispatcher-streaming-feature-emitter.ts`, `src/main/runtime/rpc/dispatcher.ts` (`dispatchStreamingObjects`).

### 2.1 Opening and recognising a stream

A stream is an ordinary request. Every frame the host emits for it reuses **the request's `id`**:

```json
{ "id": "<request id>", "ok": true, "streaming": true, "result": { "type": "...", ... }, "_meta": { "runtimeId": "..." } }
```

- A reply is a stream frame iff `ok === true && streaming === true` (`isStreamingOpenerReply`).
- A reply with the stream's id that is `ok: false` ends the stream; the client synthesises `{ type: 'error', message: error.message, error }` to the listener and forgets the stream.
- A reply with the stream's id that is `ok: true` **without** `streaming`:
  - `result.type === 'end'` → finish the stream (deliver `{type:'end'}`),
  - `result.type === 'scrollback'` → deliver to the listener and keep the stream (legacy non-binary terminal snapshot),
  - anything else → treated as "ended before ready": listener gets `{ type: 'error', message: 'Streaming request ended before it was ready.' }`.
- A host handler that throws after frames were sent also arrives as `ok: false` on the same id.

### 2.2 Well-known `result.type` values

| `type` | Shape | Meaning |
|---|---|---|
| `ready` | `{ type:'ready', subscriptionId: string, ... }` | Host named its registration. Used only by the four "ready-id" streams (2.3). Client stores `subscriptionId` for release. |
| `subscribed` | `{ type:'subscribed', streamId: number, ... }` | `terminal.subscribe` only. Binds the numeric `streamId` used in binary frames to this request id. |
| `snapshot` | `{ type:'snapshot', ... }` | First full state (`session.tabs.subscribe`, `agentSession.subscribe`, `agentSession.subscribeStatus`). |
| `updated` | | `session.tabs.subscribe` subsequent full state. |
| `batch` / `reset` | | `agentSession.subscribe` (section 6). |
| `status` | | `agentSession.subscribeStatus` single-session update. |
| `scrollback` / `data` / `resized` / `metadata` / `error` | | Terminal events; produced client-side from binary frames (2.5), or `scrollback` as a JSON reply on legacy hosts. |
| `end` | `{ type:'end' }` | Host ended the stream. Client removes it and does **not** send an unsubscribe. |
| `error` | `{ type:'error', message, error? }` | Synthesised by the client (never a host frame on JSON streams) from an `ok:false` reply, or from a terminal Error opcode. |

The registry does not interpret anything else: every streaming frame's `result` is handed to the listener verbatim.

### 2.3 Unsubscribe — three families

**(a) Ready-id streams** (`READY_STREAM_RELEASE_METHODS`): the host names the registration in its `ready` frame and only that id releases it.

| Subscribe | Unsubscribe | Params |
|---|---|---|
| `runtime.clientEvents.subscribe` | `runtime.clientEvents.unsubscribe` | `{ subscriptionId }` |
| `notifications.subscribe` | `notifications.unsubscribe` | `{ subscriptionId }` |
| `accounts.subscribe` | `accounts.unsubscribe` | `{ subscriptionId }` |
| `browser.screencast` | `browser.screencast.unsubscribe` | `{ subscriptionId }` |

If the caller disposes before `ready` arrives, mark the stream cancelled and send the unsubscribe when `ready` lands. If never sent, just drop it. Only one `browser.screencast` stream may be active per client; a new one disposes the previous.

**(b) Request-keyed streams**: the unsubscribe echoes selector params plus the opener's request id.

| Subscribe | Unsubscribe | Params |
|---|---|---|
| `session.tabs.subscribe` `{worktree}` | `session.tabs.unsubscribe` | `{ worktree, subscriptionId: <opener request id> }` |
| `agentSession.subscribe` `{sessionId,...}` | `agentSession.unsubscribe` | `{ sessionId, subscriptionId: <opener request id> }` — without `subscriptionId` the host ends **every** stream of that session on the socket |
| `nativeChat.subscribe` | `nativeChat.unsubscribe` | `{ subscriptionId }` taken from the subscribe params (legacy: `buildNativeChatUnsubscribe(agent, sessionId)`) |
| `terminal.subscribe` `{terminal, client?}` | `terminal.unsubscribe` | `{ subscriptionId: client ? `${terminal}:${client.id}` : terminal, client?: { id }, requestId: <opener request id> }` |

Rules: send the unsubscribe only if the opener was actually written to the socket. `session.tabs.subscribe` is special: older hosts register only with the first snapshot, so a dispose before the first `snapshot` is **held** — mark cancelled, and send the unsubscribe when that snapshot arrives (`rpc-client-session-tabs-stream.ts`).

**(c) No unsubscribe RPC**: every other streaming method (e.g. `agentSession.subscribeStatus`) — `buildStreamUnsubscribe` returns `null`, so the direct transport sends nothing and just forgets the stream. How the host releases it other than at socket close is **UNVERIFIED**.

Any unsubscribe is a fresh request with a new id, and carries the same top-level envelope routing fields (`RpcEnvelopeFields`) as the opener.

### 2.4 Reconnect replay

On socket loss every stream is marked unsent, its `subscriptionId` is cleared and terminal `streamId` bindings are reset. After re-authentication the registry re-sends each surviving stream **with the same request id and the stored params** (terminal params have had `viewport` updated in place by `updateTerminalViewport`). A stream may pass a `holdReplay` hook to delay its own resend. The opener's first frame after replay is a fresh `ready` / `subscribed` / `snapshot`.

### 2.5 Binary frames

Binary WebSocket messages (after E2EE open) are tried as, in order: browser screencast frame (`mobile/src/browser/screencast/browser-screencast-protocol.ts`), then terminal frame. If the client advertises `transport.compressed-frames.v1`, a binary message may first be a compressed envelope that must be inflated before either check (`src/shared/remote-runtime/e2ee/paired-e2ee-compressed-frame.ts`):

```
compressed frame: [0]=0x7a  [1]=payload kind (1=text JSON, 2=binary)  [2..6)=inflated byte length u32 LE  [6..]=one gzip member
```
The host compresses only payloads ≥ 1024 bytes. An inflated `text` payload is a normal JSON reply; `binary` is a terminal/screencast frame.

Terminal stream frame (`src/shared/terminal/stream/terminal-stream-protocol.ts`), 16-byte header, little-endian:

```
[0]      kind     = 0x74
[1]      version  = 1
[2]      opcode
[3]      0 (reserved)
[4..8)   streamId  u32 LE      (the number from the `subscribed` frame)
[8..12)  seq high  u32 LE
[12..16) seq low   u32 LE      seq = high * 2^32 + low
[16..]   payload
```

Opcodes: `Output=1, SnapshotStart=2, SnapshotChunk=3, SnapshotEnd=4, Resized=5, Error=6, Input=7, Resize=8, Subscribe=9, Unsubscribe=10, SnapshotRequest=11, Metadata=12, Ack=13, ClaimViewport=14, OutputSpan=15, SetOutputPaused=16, WriteUnavailable=17, InputAck=18, PausedOutputDropped=19, SetOutputCadence=20`.

How the mobile client turns host→client frames into listener events (`rpc-client-terminal-binary-frame.ts`):

| Opcode | Payload | Listener event |
|---|---|---|
| `Output` (1) | UTF-8 text | `{ type:'data', streamId, chunk }` |
| `OutputSpan` (15) | JSON `{ data: string, ... }` | `{ type:'data', streamId, chunk: data }` (non-string `data` → unreadable) |
| `SnapshotStart` (2) | JSON meta object | buffered; no event |
| `SnapshotChunk` (3) | UTF-8 text | appended to buffer |
| `SnapshotEnd` (4) | — | `{ ...meta, type: meta.kind === 'resized' ? 'resized' : 'scrollback', streamId, serialized: chunks.join('') }` |
| `Resized` (5) | JSON meta | `{ ...meta, type:'resized', streamId }` |
| `Metadata` (12) | JSON meta | `{ ...meta, type:'metadata', streamId }` |
| `Error` (6) | UTF-8 text | `{ type:'error', streamId, message }` |
| unknown opcode / other | | client synthesises `{ type:'error', streamId, message: 'Unsupported terminal stream frame (opcode N).' }` so the caller resubscribes and gets a fresh snapshot |

JSON payloads are capped at 8 MiB / nesting depth 32. Frames for an unregistered `streamId` are dropped. The mobile app does **not** send binary frames; input goes through the JSON `terminal.send` method.

---

## 3. `runtime.clientEvents.subscribe`

Types: `src/shared/remote-runtime/session-graph/runtime-client-events.ts`. Client wrapper: `mobile/src/transport/runtime-client-event-subscription.ts`. Host: `src/main/runtime/rpc/methods/client-events/client-events.ts`.

- Params: `null` (mobile). Ready-id stream: release with `runtime.clientEvents.unsubscribe { subscriptionId }`.
- First frame:

```ts
{ type: 'ready', subscriptionId: string,
  snapshot?: { nativeChatQueueFollowUps?: boolean; nativeChatCiResultLines?: boolean;
               repos?: unknown[]; sshStates?: { targetId: string; state: SshConnectionState }[] } }
```

- Then any `RuntimeClientEvent`, or `{ type: 'end' }`. All events are *invalidation hints*: none carries the data, the reader re-fetches. Unknown `type` values must be ignored. A `ready` after the first one means the stream reconnected and events were missed in between — re-read everything.

Events relevant to a native client:

```ts
| { type: 'reposChanged' }                                     // re-read repo.list (+ worktree.ps: folder workspaces ride it)
| { type: 'worktreesChanged'; repoId: string; sortOrderOnly?: boolean; sortOrders?: WorktreeSortOrderUpdate[] }
| { type: 'worktreeRowsChanged' }                              // an agent row changed; re-read worktree.ps
| { type: 'agentListChanged' }                                 // desktop Agents-list verdicts changed; worktree.ps carries them
| ({ type: 'workspaceMetadataSet' } & WorkspaceMetadataSet)
| { type: 'workspaceViewChanged' }                             // re-read ui.get
| { type: 'settingsChanged'; keys: string[] }                  // re-read settings.get for keys you show
| { type: 'gitStatusChanged'; repoId: string; worktreeIds?: string[] }
| { type: 'pullRequestChanged'; worktreeId: string; repoId: string; branch: string }
| { type: 'nativeChatQueueFollowUpsChanged'; queueFollowUps: boolean }
| { type: 'nativeChatCiResultLinesChanged'; ciResultLines: boolean }
| ({ type: 'nativeChatLaunchDraftResolved' } & RuntimeNativeChatLaunchDraftResolution)
| { type: 'relayHostsChanged' }
| { type: 'sshStateChanged'; targetId: string; state: SshConnectionState }
| { type: 'worktreeTerminalSleepState'; worktreeId: string; generation: number;
    phase: 'started'|'committed'|'cancelled'|'woken'; ptyIds: string[]; terminalHandles: string[] }
| { type: 'automationsChanged'; selector?: ...; reason?: 'definition'|'run'|'usage' }
| ({ type: 'botsChanged' } & BotChangeScope)
| { type: 'orchestrationSessionWorkersChanged'; sessionId: string }
| { type: 'browserProfilesChanged' }
| { type: 'linearLinkedIssueUpdated'; worktreeId: string; identifier: string; workspaceId: string }
| { type: 'notificationAttentionAcknowledged'; acknowledgement: NotificationAttentionAcknowledgement }
| { type: 'activateWorktree'; repoId: string; worktreeId: string; setup?; startup?; defaultTabs?;
    providesInitialSurface?: boolean; navigation?: RuntimeNavigationTarget }
| { type: 'terminalSideEffects'; batch }                       // host filters these out for mobile clients
| SidebarInputsChangedEvent | WorkspaceCleanupRunFinishedEvent | BrowserClientHostRequestEvent
```

The host list re-reads `worktree.ps` on `worktreesChanged`, `reposChanged`, `worktreeRowsChanged` (`mobile/src/host-screen/catalog/host-list-queries.ts`), floored by a poll interval.

---

## 4. Home / host screen: repos, projects, worktrees

Sources: `mobile/src/host-screen/host-screen-operations.ts`, `host-screen-reply-schema.ts`, `catalog/host-list-queries.ts`; `mobile/src/worktree/catalog/worktree-catalog-*.ts`, `worktree/workspace-list/workspace-list-types.ts`, `worktree/project-sections/project-sections-operations.ts`.

### 4.1 `worktree.ps` — the workspace list with live status

Params (`src/shared/rpc-contract/workspaces/worktree-params.ts`, `WorktreePsParams`, non-strict):

```ts
{
  limit?: number                          // mobile sends 10_000; the host default silently truncates at 200
  afterSnapshotId?: string | null         // 1..128 chars; the snapshot you hold
  acceptRowDelta?: true                   // you can rebuild from rowsFromBase
  supportsWorktreeVisibilitySourceDefaults?: true  // mobile injects this on EVERY worktree.ps call
  includeAgentWait?: true                 // expensive; not for pollers
}
```
(`mobile/src/transport/rpc/mobile-rpc-request-projection.ts` adds `supportsWorktreeVisibilitySourceDefaults: true` to every `worktree.ps` request.)

Result — one of three forms, distinguished by the client (`worktree-catalog-snapshot-client.ts`, `admitWorktreeCatalogResponse`):

```ts
// full
{ worktrees: Worktree[]; snapshotId?: string }
// unchanged — only valid if snapshotId === the afterSnapshotId you sent
{ unchanged: true; snapshotId: string }
// row delta — only valid if baseSnapshotId === the afterSnapshotId you sent
{ snapshotId: string; baseSnapshotId: string; rowsFromBase: (number | Worktree)[] }
```
`rowsFromBase` is the complete new list in order: a number is an index into the rows you hold for `baseSnapshotId`, an object is a new/changed row. An out-of-range index, or any other shape, is invalid → discard your snapshot id and re-read in full (once). Presence of `worktrees` always wins. One unreadable row invalidates the whole reply (dropping a row would shift delta indexes). Never persist a snapshot id across launches. The host-side field names for the unchanged/delta forms were confirmed from the mobile reader only (host producer **UNVERIFIED**).

Row (`RuntimeWorktreePsSummary`, `src/shared/worktree/catalog/runtime-worktree-contracts.ts:81`). Mobile treats only `worktreeId, repoId, repo, branch, displayName, path, liveTerminalCount, hasAttachedPty, unread, isPinned, linkedPR` as always present; everything else is optional on older hosts:

```ts
type Worktree = {
  worktreeId: string; repoId: string; repo: string; path: string; branch: string; displayName: string
  workspaceKind?: 'git' | 'folder-workspace'
  hostId?: string; identity?: ...; terminalPlatform?: NodeJS.Platform
  isArchived: boolean; isMainWorktree: boolean; isPinned: boolean; isActive: boolean; unread: boolean
  parentWorktreeId: string | null; childWorktreeIds: string[]
  workspaceStatus: string; sortOrder: number; manualOrder?: number
  lastActivityAt?: number; createdAt?: number
  smartTier?: SmartTier; smartAt?: number; sortedByStamps?: true
  linkedIssue: number | null
  linkedPR: { number: number; state: string; title?: string; url?: string;
              checksStatus?: CheckStatus; checksSummary?: ProviderCheckSummary } | null
  linkedLinearIssue: string | null; linkedGitLabMR: number | null; linkedGitLabIssue: number | null
  comment: string
  liveTerminalCount: number; hasAttachedPty: boolean; unverifiableTerminalCount?: number
  lastOutputAt: number | null; preview: string
  status: 'active' | 'working' | 'permission' | 'done' | 'inactive'
  workingMode?: 'monitoring'
  sidebarStatus?: string   // 'active'|'working'|'monitoring'|'permission'|'failed'|'interrupted'|'unconfirmed'|'done'|... — treat as open
  hasHostSidebarActivity: boolean
  agents: RuntimeWorktreeAgentRow[]
  removing?: true; removalRecorded?: true; removalError?: string
  defaultBranch?: boolean; automationCreated?: true; automationName?: string
  cliCreated?: true; detachedHead?: true; desktopOtherClient?: true
  bot?: string; botHome?: true
  recipeEnvironment?: { name: string; destroys?: boolean }
}

type RuntimeWorktreeAgentRow = {
  paneKey: string                    // `${tabId}:${leafId}`
  address?: string                   // terminal handle, or a chat's session address
  orcaSessionId?: string
  parentPaneKey: string | null
  state: 'working' | 'blocked' | 'waiting' | 'done'
  workingMode?: 'monitoring'
  agentType: string | null           // 'claude' | 'codex' | ... (open)
  prompt: string; taskTitle: string | null; displayName: string | null
  conversationName?: string; conversationForked?: true
  lastAssistantMessage: string | null; toolName: string | null; toolInput: string | null
  interrupted: boolean
  mainAgent?: AgentMainAgentStatus
  stateStartedAt: number; updatedAt: number
  children?: AgentChildWorkView[]; subagents?: AgentSubagentSnapshot[]
  subagentObservation?: 'live' | 'unverifiable'
  restoredUnconfirmed?: boolean      // sent only if client advertises agent-status.restored-unconfirmed.v1
  structuredHostOwned?: true; hasLivePty?: true
  programStatus?: ProgramStatusFacet; activity?: AgentListVerdict
}
```

### 4.2 `repo.list` — repos / projects

Params (`src/shared/rpc-contract/projects/repo-params.ts`): `{ afterSnapshotId?: string | null }`.
Result as mobile reads it (`hostRepoCatalogSnapshotSchema`):

```ts
| { unchanged: true; snapshotId: string }
| { repos: Repo[]; snapshotId?: string }

type Repo = {            // rows lacking id or displayName are dropped
  id: string; displayName: string
  path?: string; badgeColor?: string
  repoIcon?: { type:'lucide'; name: string } | { type:'emoji'; emoji: string } | { type:'image'; src: string; label?: string }
  connectionId?: string | null        // SSH connection
  executionHostId?: string | null     // unknown spellings map to local
}
```
Full host `Repo` type: `src/shared/repository/repo-types.ts` (not fully enumerated here).

### 4.3 Project groups / sections

- `projectGroup.list` → `{ groups: ProjectGroup[] }` (`src/shared/sidebar-list/catalog/project-section-catalog-schema.ts`):
  ```ts
  { id: string; name: string; parentPath: string | null; connectionId?: string | null; executionHostId?: string | null;
    parentGroupId: string | null; createdFrom: string /* default 'manual' */; tabOrder: number; rootProjectOrder?: number;
    isCollapsed: boolean; color: string | null; createdAt: number; updatedAt: number }
  ```
- `mobileRelay.projectSections` → `{ catalog: ProjectSectionCatalog | null }` (`{ repos, projects: {id, displayName}[], setups, ... }`); older hosts refuse the method → fall back to grouping by `repo.list`. Schema: same file as above. Params **UNVERIFIED**.
- `folderWorkspace.list` — folder (non-git) workspaces; their rows also appear in `worktree.ps` with `workspaceKind: 'folder-workspace'`. Shape **UNVERIFIED**.

### 4.4 View settings and row actions

- `ui.get` → `{ ui: { groupBy?: 'none'|'workspace-status'|'repo'|'pr-status'; sortBy?: 'name'|'smart'|'recent'|'repo'|'manual'; hideSleepingWorkspaces?; hideDefaultBranchWorkspace?; hideAutomationGeneratedWorkspaces?; hideCliCreatedWorkspaces?; hideDetachedHeadWorkspaces?; hideWorkspacesFromOtherDevices?; projectOrderBy?: 'manual'|'recent'; worktreeCardProperties?: string[]; agentActivityDisplayMode?: 'compact'|'full'; alwaysShowDefaultBranchWorkspace?; filterRepoIds?: string[]; collapsedGroups?: string[]; workspaceStatuses?: {id,label}[]; visibleWorkspaceHostIds?: string[] | null; workspaceHostScope?: string } }`. Write-back: `ui.set` (params **UNVERIFIED**).
- `worktree.set` (pin, rename, comment, linked PR, …), `worktree.sleep { worktree, markChatsAsleep? }`, `worktree.rm`, `worktree.activate { worktree, notifyClients?, navigation? }` (fire-and-forget on open), `worktree.show { worktree, matchFolderWorkspaces? }` → full `RuntimeWorktreeRecord`. Schemas: `src/shared/rpc-contract/workspaces/worktree-params.ts`.
- `ssh.listTargetSummaries` → `{ targets?: { id, label, connected?, connectionStatus? }[] }`; `host.platform` → `{ platform? }`.
- Alternate list path used only when a host's own phone reads the desktop sidebar feed: `sidebarInputs.read`, `sidebarInputs.repoIcons`, `ui.setCollapsed` (`mobile/src/host-screen/sidebar-feed/`). Not needed for a first native client.

---

## 5. Session tabs for a worktree

Types: `src/shared/remote-runtime/session-graph/runtime-mobile-session-tab-contracts.ts`, `runtime-session-contracts.ts:255-327`. Host: `src/main/runtime/rpc/methods/session-tabs/session-tabs.ts`. Params: `src/shared/rpc-contract/session-tabs/session-tabs-schemas-params.ts`.

### 5.1 `session.tabs.subscribe` / `session.tabs.list`

Params: `{ worktree: string }`. `session.tabs.list` returns one `RuntimeMobileSessionTabsResult`; the stream emits:

```ts
{ type: 'snapshot', ...RuntimeMobileSessionTabsResult }   // first
{ type: 'updated',  ...RuntimeMobileSessionTabsResult }   // every change (full state; see delta note)
{ type: 'end' }
```
Unsubscribe: `session.tabs.unsubscribe { worktree, subscriptionId: <opener request id> }` (held until the first snapshot — 2.3b).

```ts
type RuntimeMobileSessionTabsResult = {
  worktree: string                 // the stream keeps the spelling of its first snapshot
  publicationEpoch: string
  snapshotVersion: number
  navigationIntent?: 'follow'
  activeGroupId: string | null
  activeTabId: string | null
  activeTabType: 'terminal' | 'markdown' | 'file' | 'browser' | 'agent-session' | null
  tabGroups?: { id: string; activeTabId: string | null; tabOrder: string[]; recentTabIds?: string[] }[]
  tabGroupLayout?: TabGroupLayoutNode | null
  retiredTerminalSurfaces?: { parentTabId: string; leafId: string; ptyId: string; terminal: string; incarnationId?: string }[]
  tabs: Tab[]
  initialSurfaceLaunch?: { launchId: string; agent: string }
  clientHostedPagesUnreconciled?: true   // keep browser rows you hold that are absent here
  agentSessionsUnverifiable?: true       // keep chat rows you hold that are absent here
  removed?: true                         // workspace gone: tabs [], active* null
}
```

Tab kinds (discriminant `type`):

```ts
// terminal — what the client receives adds status + terminal handle
type TerminalTab = {
  type: 'terminal'; id: string; title: string
  customTitle?: string | null; quickCommandLabel?: string | null; generatedTitle?: string | null
  parentTabId: string; leafId: string; ptyId?: string | null; incarnationId?: string | null
  terminalTheme?: { mode: 'dark'|'light'; theme: TerminalColorOverrides; minimumContrastRatio?: number }
  agentStatus?: AgentStatusEntry | null; turnCompletedAt?: number
  launchAgent?: string; launchAttested?: boolean; startupCwd?: string
  parentLayout?: TerminalLayoutSnapshot
  color?: string | null; isPinned?: boolean
  viewMode?: 'terminal' | 'chat'       // 'chat' = legacy terminal-backed chat view, not a structured session
  launchDraft?: string; launchDraftCreatedAt?: number
  isActive: boolean
} & ({ status: 'pending-handle'; terminal: null } | { status: 'ready'; terminal: string })
// `terminal` is the handle for terminal.subscribe / terminal.send. With terminal.host-pane-respawn.v1
// advertised, follow the handle: the host may replace it on a later frame.

// structured agent chat
type AgentTab = {
  type: 'agent-session'; id: string; title: string
  sessionId: string                 // the id for every agentSession.* call
  replacesSessionId?: string
  agent: string                     // 'claude' | 'codex' | other registered agents
  forked?: true
  chatStatus?: Pick<AgentStatusEntry, 'state'|'workingMode'|'interrupted'|'mainAgent'|'updatedAt'|'evidenceObservedAt'|'structuredHostOwned'>
  color?: string | null; isPinned?: boolean; isActive: boolean
}

type BrowserTab = {
  type: 'browser'; id: string; title: string; browserWorkspaceId: string; browserPageId: string | null
  browserProfileId?: string; executionHostKey?: string; placement?: RuntimeBrowserPlacement
  url: string; initializationState?: 'pending'|'stopped'; loading: boolean; canGoBack: boolean; canGoForward: boolean
  faviconUrl?: string | null; loadError?: BrowserLoadError | null; certificateFailure?: BrowserCertificateFailure | null
  color?: string | null; isPinned?: boolean; isActive: boolean
}

type FileTab = {
  type: 'file'; id: string; title: string; filePath: string; relativePath: string; language: string
  mode?: 'edit' | 'diff'; diffSource?: 'staged' | 'unstaged'; oldPath?: string
  isDirty: boolean; color?: string | null; isPinned?: boolean; isActive: boolean
}

type MarkdownTab = {
  type: 'markdown'; id: string; title: string; filePath: string; relativePath: string; language: 'markdown'
  mode: 'edit' | 'markdown-preview'; isDirty: boolean; isActive: boolean
  sourceFileId: string; sourceFilePath: string; sourceRelativePath: string
  isUntitled?: true; documentVersion: string; color?: string | null; isPinned?: boolean
}
```

Notes:
- Tabs are projected per client capability (`session-tabs-client-projection.ts`). `agent-session` tabs are sent only to clients advertising the structured capabilities (section 10); tabs of agents other than Claude/Codex only with `agent-session.structured.registered-agents.v1`.
- Delta encoding of `updated` frames exists but is opt-in via client capability `session-tabs.tab-delta.v1`, which the mobile list does **not** advertise — so mobile always receives full tab lists. Do not advertise it unless you implement `src/shared/remote-runtime/session-graph/session-tabs-tab-delta.ts`.
- Order tabs by `tabGroups[].tabOrder` when present.

### 5.2 Tab mutations

| Method | Params (all extend `{ worktree }`) |
|---|---|
| `session.tabs.activate` | `{ tabId, leafId?, notifyClients?, navigation?, intent?, botLinkTarget? }` → a `RuntimeMobileSessionTabsResult` (+ `startupCwdFallback`) |
| `session.tabs.close` | `{ tabId, leafId?, reason?: 'user'|'replay', force?: true }` (`force`/`replay` are capability-gated) |
| `session.tabs.createTerminal` | `{ afterTabId?, targetGroupId?, command?, shell?, cwd?, env?, envToDelete?, startupCommandDelivery?: 'fast'|'shell-ready', agent?, launchToken?, sourceChatFork?: { sessionId }, ... }` → `{ tab: TerminalTab (client form), publicationEpoch, snapshotVersion, ... }` |
| `session.tabs.setTabProps` | `{ tabId, color?: string|null, isPinned?, viewMode?: 'terminal'|'chat', customTitle?: string|null }` |
| `session.tabs.move`, `updatePaneLayout`, `movePaneToNewTab` | see params file |

Terminal-only helpers used by the session screen (`mobile/src/session/mobile-session-terminal-operations.ts`): `terminal.list`, `terminal.read`, `terminal.rename`, `terminal.close`, `terminal.focus`, `terminal.setDisplayMode`.

---

## 6. Native agent chat (structured agent session)

All methods are `agentSession.*` / `agentSessionAttachment.*`. Wire types: `src/shared/agent-session/agent-session-wire.ts`. Param schemas: `src/shared/rpc-contract/structured-agent-session/*.ts`. Journal item types: `src/shared/agent-session/journal/agent-session-journal-types.ts`. Block types: `src/shared/native-chat/native-chat-types.ts`. Mobile callers: `mobile/src/session/native-chat/agent-session/*.ts`. Reference reducer (worth porting): `src/shared/agent-session/view/live-read/structured-agent-session-reducer.ts` and `structured-agent-session-live-read.ts`.

Identifiers:
- `sessionId`: `/^[A-Za-z0-9_-]{8,128}$/`. A client mints one as a plain random UUID (`createOrcaSessionId`).
- `Identifier` fields: 1..512 chars, must equal their own `.trim()`.
- Cursor: `{ epoch: string, sequence: number /* int >= 0; 0 = before first row */ }`.

### 6.1 Mutation envelope and fingerprint (applies to every write)

Every mutating call is `{ envelope, ...fields }` (`structured-agent-session-mutation-envelope.ts`, strict):

```ts
envelope: {
  sessionId: string
  clientOperationId: string          // idempotency key; reuse it verbatim to replay after a lost reply
  expectedRuntimeFence: number | null // positive int you last saw; null ONLY on create of a new session
  payloadFingerprint: string         // /^[0-9a-f]{64}$/ sha256 hex
}
```

`payloadFingerprint` (`src/shared/agent-session/lifecycle/operations/structured-agent-session-mutation.ts`) — the host recomputes and compares:

```
sha256_hex( utf8( canonicalize({ method: <fingerprintMethod>, sessionId, fields }) ) )

canonicalize(v):
  null / undefined / non-object  -> JSON.stringify(v ?? null)
  array                          -> "[" + items.map(canonicalize).join(",") + "]"
  object                         -> "{" + entries (drop value === undefined; sort by key, plain code-unit <) 
                                         .map(([k,v]) => JSON.stringify(k) + ":" + canonicalize(v)).join(",") + "}"
```
No whitespace. Strings/numbers use JavaScript `JSON.stringify` escaping (so `/` is not escaped, non-ASCII is emitted raw, lone surrogates as `\udXXX`, integers without a decimal point). `fields` is exactly the params object minus `envelope`.

`fingerprintMethod` equals the RPC method **except**:

| RPC method | fingerprint `method` |
|---|---|
| `agentSession.respondToApproval` | `agentSession.respondTo:approval` |
| `agentSession.respondToQuestion` | `agentSession.respondTo:question` |
| `agentSession.create` | `agentSession.create`, with `fields = { worktree, agent, resumeFrom, forkFrom, tabId, firstMessage, optionsMode, options }` (undefined dropped; `tabPlacement` is **excluded**) |

`clientOperationId` format minted by mobile: `` `${Date.now() as 13 digits}-${uuid without dashes, lowercase}` `` (`createStructuredAgentSessionOperationId`). `agent.launch`'s `operationId` requires this same format.

Result of every mutation:

```ts
type AgentSessionMutationResult<T> =
  | { ok: true; replayed: boolean; fence: number; cursor: AgentJournalCursor; value: T }
  | { ok: false; refusal: { code: AgentSessionWireRefusalCode; message: string; details?: ...; createAttemptRefusedBeforeCommit?: true } }
```
Note this is the RPC `result` — the envelope is `ok: true` and the refusal is inside. Refusal codes (`src/shared/agent-session/failures/agent-session-wire-refusals.ts`): `structured_agent_session_unsupported`, `agent_session_checkpoint_stale` (your fence is stale — take the new fence from the stream and retry), `agent_session_conflict`, `agent_session_ownership_unknown`, `agent_session_operation_conflict` (same operation id, different fingerprint), `agent_session_operation_expired`, `agent_session_operation_capacity`, `agent_session_operation_invalid`, `agent_session_operation_unknown` (outcome unknown — do not auto-retry with a new id), `agent_session_item_revision_stale`, `agent_session_already_resolved`, `agent_session_identity_required`, `agent_session_journal_unreadable`, `execution_owner_reconciling`, `agent_session_owner_restart_failed`. `details` shapes: `agent-session-refusal-details.ts` (**not enumerated here**).

The **fence** comes from `snapshot.fence` / `reset.fence` / `batch.fence?` / `page.fence?` / any mutation's `fence`. Keep the latest.

Mobile's timeout for these calls is 15 s. A transport failure or timeout is "unknown", never "failed": show it as unconfirmed and reconcile from the stream (the submission row carries your `clientMessageId`).

### 6.2 Opening a chat: hold, subscribe, history

Sequence used by `use-mobile-structured-agent-state.ts`:

1. `agentSession.hold { sessionId, holderId }` (best effort; a no-op on current hosts, kept for older ones). On close: `agentSession.release { sessionId, holderId }`. Subscribe after the hold settles **even if it was refused**.
2. Read `status.get` capabilities to decide `capabilities` for the subscribe.
3. `agentSession.subscribe` (strict params, `structured-agent-session-subscribe-params.ts`):

```ts
{
  sessionId: string
  cursor?: { epoch: string; sequence: number }   // resume point: your last applied cursor
  capabilities?: {                               // send ONLY if host advertises agent-session.text-append.v1
    textAppend?: 1
    toolOutputAppend?: 1                         // only with agent-session.tool-output-append.v1
    promptSuggestions?: 1
  }
}
```
There is no `ready` frame; the first frame is the state. Unsubscribe: `agentSession.unsubscribe { sessionId, subscriptionId: <opener request id> }`.

Events (`AgentSessionSubscribeEvent`):

```ts
| { type: 'snapshot'; sessionId; page: AgentSessionHistoryPage; fence: number; ...FrameExtras }
| { type: 'batch';    sessionId; batch: { cursor; items: RenderItem[]; removedItemIds: string[]; submissions: Submission[] };
    fence?: number; promptSuggestion?: { id; text } | null; latestTurn?: LatestTurn | null; hasNewer?: true;
    actionablePromptIds?: string[]; working?: boolean; ...FrameExtras }
| { type: 'reset';    sessionId; reset: 'epoch_changed'|'cursor_ahead'|'cursor_compacted'|'journal_gap'|'schema_unreadable';
    page: AgentSessionHistoryPage; fence: number; ...FrameExtras }
| { type: 'end' }

type FrameExtras = {
  backgroundTasks?: AgentSessionBackgroundTaskState | null
  queuedMessages?: AgentSessionQueuedMessage[] | null   // whole list; absent = unchanged; null/[] = empty
  queuePause?: { reason: 'stopped' | 'failed' } | null
  nextQueuedMessageId?: string | null
  commands?: AgentSessionSlashCommand[] | null          // absent = unchanged; null clears
  commandsChanged?: true                                // with agent-session.commands-on-request.v1: re-read agentSession.commands
  activity?: { turnId: string; text: string } | null    // ephemeral "what it is doing" line
  hostNow?: number                                      // host wall clock (ms) — anchor live timers on this, not the phone clock
  currentRequests?: AgentSessionCurrentRequestsMarker   // see 6.6
}
```

Semantics:
- `snapshot` and `reset` **replace** all state with `page`. `batch` is an upsert: items are full current states keyed by `itemId` (replace if `revision` is newer), `removedItemIds` are tombstones, `submissions` upsert by `clientMessageId`. Batches are cursor-qualified current states, not deltas, so a duplicate batch must converge. Advance your cursor to `batch.cursor`.
- Order items by `(sequence, sequenceIndex ?? 0)`, never by `observedAt`.
- A batch whose `cursor.epoch` differs from yours means the journal was renumbered.
- On `end` or an error frame: reconnect with backoff, passing your last cursor. Terminal ("final") read refusals stop retrying — see `src/shared/agent-session/failures/structured-agent-session-read-refusal.ts`.
- A subscribe opened with a cursor may answer with catch-up `batch` frames (`hasNewer: true` until the last one) instead of a snapshot.

**Text-append compression** (only if you sent `capabilities.textAppend: 1`; `src/shared/agent-session/view/live-read/agent-session-text-append.ts`). In a `batch`, an item may arrive as an append:

```ts
RenderItem & { textAppend: { from: number; text: string } }   // and its own text field is ""
```
It applies to (a) a `message` item with role `assistant` or `reasoning` whose `blocks` is exactly one `text` block — the text is `blocks[0].text`; (b) with `toolOutputAppend`, a `tool-call` item — the text is `output.head`. Restore as `base + textAppend.text` where `base` is the text you hold for that `itemId`; require `base.length === from` (**lengths are UTF-16 code units**) and the on-wire text to be `""`. Bookkeeping must mirror the host exactly:
- Keep a `Map<itemId, string>` of bases in insertion order. After each item (the restored whole item), delete its entry, then re-insert its text **only if** it is still growing: not `shortened`, and not finished (`tool-call`: `state === 'running'`; `message`: `completedAt === undefined`). Evict the oldest when size exceeds 8 (text only) or 16 (with `toolOutputAppend`).
- `snapshot`/`reset`: clear, set epoch to `page.epoch`, note every page item. A batch with a different `cursor.epoch`: clear first. Delete bases for `removedItemIds`.
- Any mismatch (no base, wrong `from`, malformed append) → drop the stream and open a new one from your last applied cursor; a new stream starts with whole items. After such a failure do not ask for appends again on that connection.

If this is too much for a first version: simply do not send `capabilities` — the host then sends whole items every time.

4. Older pages: `agentSession.history` (strict):

```ts
{ sessionId; direction: 'tail' | 'before' | 'after'; cursor?: Cursor /* required for before/after */; limit?: number /* 1..200, default 40 */ }
→ | { ok: true;  page: AgentSessionHistoryPage; providerSession? }
  | { ok: false; reset: ResetReason; page: AgentSessionHistoryPage /* a tail page */; fence?; providerSession? }
```

```ts
type AgentSessionHistoryPage = {
  sessionId: string; epoch: string; fence?: number
  direction: 'tail' | 'before' | 'after'
  items: RenderItem[]
  removedItemIds: string[]
  submissions: Submission[]
  window: { oldest: Cursor | null; newest: Cursor | null; nextCursor: Cursor }  // pass nextCursor to the next same-direction read
  liveCursor?: Cursor
  hasOlder: boolean; hasNewer: boolean
  backgroundTasks?: ... | null
  queuedMessages?: AgentSessionQueuedMessage[] | null; queuePause?: ... | null; nextQueuedMessageId?: string | null
  hostNow?: number
  subagentRoster?: { itemId; sequence; sequenceIndex?; revision; entry: NativeChatSubagentEntry }[]
  latestTurn?: { itemId: string; observedAt: number; turn: TurnLifecycle } | null
  actionablePromptIds?: string[]; working?: boolean
}
```
Mobile pages backwards with `direction: 'before'`, `cursor` = oldest loaded cursor, `limit: 200`. A page may contain only subagent rows (nothing to draw) — keep paging while `hasOlder`.

### 6.3 Transcript items

```ts
type RenderItem = {
  itemId: string; revision: number
  sequence: number; sequenceIndex?: number
  observedAt: number                       // host clock, ms
  body: ItemBody
  turnScope?: { kind: 'turn'; turnItemId: string } | { kind: 'thread' } | { kind: 'unknown' }
  // producer: absent agentId = the session's own (root) agent; present = a subagent's row
  agentId?: string; parentAgentId?: string; providerParentRef?: string
  producerKind?: 'agent' | 'background'; attempt?: number
  recovered?: true; recoveredAt?: number
  shortened?: true                         // text was cut for the wire; fetch whole via agentSession.item
}

type ItemBody =
  | MessageItem | ToolCallItem | DiffItem | ApprovalItem | QuestionItem | StatusItem | TurnItem
  | OrcaCardItem   // kinds: agent start/handoff, 'automation-saved', 'tool-added', 'wait-ended',
                   // 'automation-run-not-started', bot item note — see src/shared/agent-journal-orca-card-items.ts
```
`body.kind` is an open union: render unknown kinds as nothing (or a generic row), never fail the page.

```ts
type MessageItem = {
  kind: 'message'
  role: 'user' | 'assistant' | 'tool' | 'reasoning' | 'system'
  blocks: Block[]
  sentAs?: 'goal'
  command?: { name: string; instructions?: string }     // a /compact, /clear the user sent
  skills?: { name: string; path: string }[]
  from?: AgentMessageSource                              // sent by another agent via Orca
  typedBy?: ...                                          // which device typed it
  state?: 'running' | 'completed'                        // reasoning rows; absent = unknown, never live
  completedAt?: number
}

type Block =
  | { type: 'text'; text: string; presentation?: string; tone?: string; failure?: ...; providerFrame?: ...;
      orcaStop?: ...; forkedFrom?: ...; usageLimitTurnItemId?: string; ... }
  | { type: 'tool-call'; name: string; input: unknown; callId?: string;
      state?: 'running'|'completed'|'failed'; endedAs?: 'interrupted'|'unverifiable';
      mcpIdentity?: { server; tool }; exitCode?: number; durationMs?: number; webSearchResults?: ... }
  | { type: 'tool-result'; output: string; isError?: boolean; callId?: string;
      editPatch?: { filePath?: string; hunks: { oldStart; oldLines; newStart; newLines; lines: string[] }[] };
      fullOutputItemId?: string }
  | { type: 'image-ref'; path?: string; url?: string; alt?: string }   // exactly one of path/url
  | { type: 'subagent-group'; groupId: string; agents: SubagentEntry[] }
  | ({ type: 'subagent'; groupId: string; parentId?: string; run?: string; outcomeBasis?: 'stop-acknowledged'; background?: true } & SubagentEntry)
  | { type: 'background-task'; taskId: string; kind; label: string; state; parentToolUseId?; summary?; error?; outputFile?; tokens?; startedAt?; settledAt? }

type SubagentEntry = { id: string; label: string;
  state: 'working'|'idle'|'completed'|'failed'|'stopped'|'unverifiable';
  tokens?: number; startedAt?: number; settledAt?: number; agentType?: string; model?: string; effort?: string;
  operation?: { toolName: string; input?: string }; lastMessage?: string }

type ToolCallItem = {
  kind: 'tool-call'; name: string; input: unknown; callId?: string
  state: 'running' | 'completed' | 'failed'; endedAs?: 'interrupted' | 'unverifiable'
  output?: BoundedPayload
  mcpIdentity?; exitCode?; durationMs?; webSearchResults?
}
type DiffItem = { kind: 'diff'; path: string; paths?: string[]; patch: BoundedPayload }
type BoundedPayload = { head: string; byteLength: number /* of the ORIGINAL */; digest: string; truncated: boolean }

type StatusItem = { kind: 'status'; text: string; presentation?: string; tone?: string;
  turnLifecycle?: TurnLifecycle /* legacy carrier, only if you do NOT advertise agent-session.turn-item.v1 */;
  providerFrame?: { provider; kind; payload: BoundedPayload }; threadGoal?: ...; orcaStop?: { cause: string };
  forkedFrom?: ...; contextClear?: ...; failure?: ... }

type TurnItem = { kind: 'turn' } & TurnLifecycle
type TurnLifecycle = {
  turnId: string
  state: 'running' | 'completed' | 'interrupted' | 'unverifiable'
  outcome?: AgentJournalTurnOutcome        // absent = unknown, never success; 'completed' alone proves nothing
  userItemId?: string; startedAt?: number; requestedAt?: number; completedAt?: number; durationMs?: number
  contextUsage?: AgentSessionContextUsage; providerTurnId?: string
}
```
A running turn = a `turn` item with `state: 'running'`; its `turnId` is what `agentSession.cancel` names. `latestTurn` on pages/batches gives the newest turn even if its row is off-page. `working?: boolean` on pages/batches is the host's own "is it busy" verdict — prefer it over deriving.

Approvals and questions:

```ts
type PromptOption = { id: string; label: string; description?: string; preview?: string;
                      intent?: 'allow_once' | 'allow_always' | 'reject_once' | 'reject_always' }
type Resolution = { state: 'pending' | 'resolved' | 'cancelled'; selectedOptionId: string | null;
                    answers?: QuestionAnswer[]; resolvedBy: string | null;
                    resolvedByDevice?: { kind: 'current' } | { kind: 'named'; name: string }; resolvedAt: number | null }

type ApprovalItem = { kind: 'approval'; title: string; displayName?: string; description?: string; decisionReason?: string;
  blockedPath?: string; matchedAskRule?: ...; subject?: ApprovalSubject /* plan, url, ... */; personOnly?: true;
  detail: string | null; options: PromptOption[]; resolution: Resolution }

type QuestionItem = { kind: 'question'; question: string; options: PromptOption[];
  questions?: { id: string; question: string; header?: string; multiSelect: boolean; options: PromptOption[];
                freeTextQuestionId?: string; freeTextInput?: FreeTextInput }[];
  freeTextQuestionId?: string; freeTextInput?: { allowEmpty?; multiline?; initialValue?; placeholder? };
  resolution: Resolution }
```
Only prompts whose `itemId` is in `actionablePromptIds` (when the host sends it) are answerable; older hosts omit it and you fall back to loaded rows with `resolution.state === 'pending'`.

Submissions (delivery state of your sends — drive the "sending / sent / failed / unconfirmed" bubble state):

```ts
type Submission = {
  clientMessageId: string            // == the clientOperationId you sent
  fence: number; payloadFingerprint: string
  dispatchState: 'pending' | 'accepted' | 'rejected' | 'unknown'   // 'unknown' = delivery unconfirmed: neither sent nor failed
  providerItemId: string | null      // adopted on accept
  reason: string | null; rejection?: ...
  submittedAt: number; resolvedAt: number | null; submittedSequence?: number
  answeredInTurn?: { turnItemId: string; via: 'start' | 'steer' } | null
  recovered?: true; handoverRecorded?: true; handedOverAt?: number
  queuedMessageId?: string; keptAsQueuedMessageId?: string; source?: { kind: string }
}
```
The user's own message appears in the journal as a `message` item with `role: 'user'`; match your optimistic bubble to it through the submission (`clientMessageId` → `providerItemId` / item identity), then drop the echo.

Full item on demand: `agentSession.item { sessionId, itemId }` → `{ item: RenderItem | null }` (gate: `agent-session.item-detail.v1`).

### 6.4 Sending a message

`agentSession.send` (strict; `SendParams`):

```ts
{
  envelope,                                   // clientOperationId doubles as the clientMessageId
  body: {
    kind: 'message'; role: 'user'
    blocks: (                                  // 1..64 blocks; JSON.stringify(blocks) <= 256 KiB UTF-8
      | { type: 'text'; text: string }
      | { type: 'image-ref'; path?: string; url?: string; alt?: string }   // exactly one of path/url; each <= 4096 chars
    )[]
    skills?: { name: string; path: string }[]  // 1..16; gate: agent-session.send-skills.v1
  }
  delivery?: 'queue-if-active'                 // gate: agent-session.queued-messages.v2
  options?: Record<string, string>             // gate: agent-session.send-options.v1; mutually exclusive with selection
  selection?: AgentSessionSelection            // gate: agent-session.send-selection.v1
  usageLimitContinuationOfTurnItemId?: string  // gate: agent-session.send-usage-limit-continuation.v1
  retryUnknown?: true
}
```
Fingerprint fields = `{ body, delivery?, options?, selection?, usageLimitContinuationOfTurnItemId? }` (exactly the keys you send; `retryUnknown` handling in the fingerprint is **UNVERIFIED** — mobile never sends it).

Body construction used by mobile (`structuredAgentSessionSendBody`, `src/shared/agent-session/requests/structured-agent-session-send-mutation.ts`):
```ts
blocks = [
  ...(text.trim().length > 0 ? [{ type: 'text', text: text.trimEnd() }] : []),
  ...images.map(i => ({ type: 'image-ref', path: i.path }))
]
```
Text first, then one `image-ref` per image, `path` only (no `alt`). An empty `blocks` is not sent.

Result `value`:
```ts
| { clientMessageId: string; submission: Submission }
| { clientMessageId: string; queued: { messageId: string; position: number; state: 'waiting'|'dispatched'|'returned'|'withdrawn' } }
```

#### Attachments — two different mechanisms

**Images** are uploaded through the `clipboard.*` image-upload methods (not `agentSessionAttachment`) and referenced by host path in an `image-ref` block (`mobile/src/files/attachments/mobile-clipboard-image.ts`, `mobile/src/session/native-chat/composer/attachments/mobile-native-chat-image-attachment.ts`; params `src/shared/rpc-contract/clipboard/clipboard-params.ts`):

1. `clipboard.startImageUpload { expectedBase64Length: number, connectionId: string | null, fileName?: string }` → `{ uploadId: string }`
   - `expectedBase64Length` is the length **of the base64 string**, in characters. Client cap: 24 MiB of base64 chars.
   - `connectionId` is the SSH connection of the workspace's repo (`null` for a local workspace).
2. `clipboard.appendImageUploadChunk { uploadId, offset, contentBase64 }` — `offset` is a **base64 character offset**; chunk size 512 * 1024 chars (`512 KiB`), sent in order.
3. `clipboard.commitImageUpload { uploadId }` → **a bare string**: the stored host path.
4. On any failure: `clipboard.abortImageUpload { uploadId }` (best effort).
   - Legacy fallback when `startImageUpload` answers `method_not_found` and the image is ≤ 256 KiB base64: `clipboard.saveImageAsTempFile { contentBase64, connectionId }` → path string.

The base64 must be padded standard base64 with any `data:image/...;base64,` prefix stripped. Then send `{ type: 'image-ref', path }`. Limits per message: 20 images, 64 MiB total (`src/shared/agent-session/agent-session-attachments.ts`). Whether a session takes images: `agentSession.options` → `acceptsImages?: boolean`.

**Non-image files** (and long pasted text, saved as `orca-paste-<ms>-<uuid>.txt`) use the chat attachment store; gate `agent-session.attachments.phone.v1` (`mobile/src/files/attachments/mobile-agent-session-attachment-upload.ts`, params `agent-session-attachment-params.ts`, all strict):

1. `agentSessionAttachment.uploadStart { sessionId, name /* 1..1024 chars */, byteLength /* decoded bytes, <= 50 MiB */ }` → `{ uploadId: string }`
2. `agentSessionAttachment.uploadAppend { uploadId, offset, contentBase64 }` — here `offset` is a **decoded byte offset** (`(charOffset / 4) * 3`); chunk = 524 288 base64 chars = 393 216 bytes (384 KiB). **Send at least one append even for an empty file** (an empty-string chunk at offset 0).
3. `agentSessionAttachment.uploadCommit { uploadId }` → `{ path: string; name: string; byteLength: number }`
4. On failure: `agentSessionAttachment.uploadAbort { uploadId }`.

Files are **not** blocks. They are inlined into the message text as `@path` references appended on a new line after the user's text (`nativeChatTextWithFileReferences`, `formatNativeChatFileReference`):
```
<user text, trimEnd>\n@/host/path/a.pdf @"/host/path/with space.txt"
```
Quoting: no whitespace or `@` in path → `@path`; else `@"path"` if it has no `"`; else `@'path'` if it has no `'`; else `@"path with \" escaped"`. If the user text is blank the message is just the joined references.

Reading stored attachments back: `agentSessionAttachment.read { path }` → `{ content?: string /* base64 */, isBinary?, isImage?, mimeType? }` (image preview); `agentSessionAttachment.readTextChunk { path, offset, length, expectedSnapshot? }` (gate `native-chat.text-attachment-read.v1`). Images at other host paths: `files.readChatImage { worktree, path }` → same shape. Stored paths contain the segment `agent-session-attachments/<upload uuid>/<name>`.

### 6.5 Stop / interrupt

`agentSession.cancel` (strict; `CancelParams`):

```ts
{
  envelope,
  turnId?: string                                   // absent = stop whatever is in flight (gate: agent-session.conversation-stop.v1)
  scope?: 'background-tasks'; taskId?: string       // taskId requires scope; scope requires turnId
  prompt?: { itemId: string; expectedRevision: number }   // cancel a pending approval/question card (gate: agent-session.prompt-cancel.v1); not with scope
}
→ value: { turnId?: string; cancelled: boolean }
```
Mobile logic (`mobile-structured-agent-session-cancel.ts`): if the host has conversation-stop and no prompt is named, send `{}` fields; otherwise send `{ turnId }` of the running turn (plus `prompt` when supported). Mint a **new** `clientOperationId` per Stop press. A refusal with `agent_session_operation_unknown` on cancel or conversationCommand means "unconfirmed", not failed. On hosts without `agent-session.repeated-stop.v1`, join repeated presses client-side while one is in flight. `stopping?: true` on the status feed shows "Stopping…".

Related: `agentSession.continueInterrupted`, `agentSession.conversationCommand { envelope, command: 'clear' | 'compact', instructions?, delivery?: 'queue-if-active' }`, `agentSession.rewind { envelope, itemId, expectedEpoch }`, `agentSession.threadGoal { envelope, change: {kind:'set', objective} | {kind:'status', status:'active'|'paused'} | {kind:'clear'} }`.

### 6.6 Approvals, questions, current requests

- `agentSession.respondToApproval { envelope, itemId, expectedRevision, optionId }` — fingerprint method `agentSession.respondTo:approval`.
- `agentSession.respondToQuestion { envelope, itemId, expectedRevision, optionId? | answers? }` — exactly one of the two; fingerprint method `agentSession.respondTo:question`.
  ```ts
  answers: { questionId: string /* matched exactly, untrimmed */; optionIds: string[] /* <= 64 */; other?: string }[]   // 1..4
  ```
  `answers` requires host `agent-session.question-answers.v1`; otherwise pack into one `optionId` with `legacyAgentSessionSelectedOptionId` (`src/shared/agent-session/requests/prompts/agent-session-question-answer.ts`).
- Both return `value: { itemId: string; revision: number; resolution: Resolution }`. `expectedRevision` is compare-and-set against the item `revision` on screen; a loser gets `agent_session_item_revision_stale` / `agent_session_already_resolved`.
- `agentSession.skipAsyncQuestions`, `agentSession.cancelUsageLimitContinue` — see their params files.

**Current requests** (because the client advertises `agent-session.current-requests.v1`): pending approvals/questions are published independently of paged history. Frames carry a marker:

```ts
currentRequests?: { contract: 'agent-session.current-requests.v1'; sessionId; epoch; publisher; revision: number; owner; version: string /* uuid */ }
```
When the marker's `version` changes, read the list in pieces: `agentSession.currentRequests { sessionId, version, cursor?: number }` → `{ marker, json: string, nextCursor: number | null, restart?: true }`. Start at `cursor: 0`, concatenate `json` strings, continue with `nextCursor` until it is `null`, then `JSON.parse` the whole → `RenderItem[]` where every item is a pending `approval` or `question`. `restart: true` hands you a newer marker: discard pieces and start over with it. A piece whose marker `version/owner/epoch/sessionId` differs from the one you asked for is an error. Reader: `src/shared/agent-session/requests/agent-session-current-requests-reader.ts`. If you do **not** advertise the capability, pending prompts simply arrive as journal rows (simpler for a first version, but the list can be off-page).

### 6.7 Model / options pickers

- `agentSession.options { sessionId }` → `AgentSessionOptionsResult` (`src/shared/agent-session/options/protocol/agent-session-options-result.ts`). Essential subset:
  ```ts
  {
    models: AgentSessionModelOption[]; modelsKnown?: false; listedModelIds?: string[]
    current: { model?: string; effort?: string; fastMode?: boolean; serviceTier?: string;
               interactionMode?: 'default' | 'plan'; permissionMode?: string; reportedPermissionMode?: string | null;
               fastModeState?: 'off' | 'cooldown' | 'on'; reportedModel?: string; reportedEffort?: string; ... }
    fastModeSupport?: { supported: boolean; reason?: string }
    acceptsImages?: boolean
    sessionNeverStarted?: boolean
    conversationCommands?: ...; compactInstructions?: boolean
    rewind?: ...; forkSupport?: 'unknown' | 'supported' | 'unsupported'
    threadGoal?: { current: ThreadGoal | null; contextFloor?: Cursor }
    contextUsage?: { current: AgentSessionContextUsage; contextFloor?: Cursor }
    canSwitchAccount?: boolean; transcriptPath?: string
  }
  type AgentSessionModelOption = {
    id: string; label: string; description?: string; isDefault: boolean
    efforts: { value: string; label: string; description?: string }[]
    defaultEffort?: string; effortsKnown?: false; chatEfforts?: OptionChoice[]
    supportsFastMode?: boolean; defaultFastMode?: boolean; supportsAutoMode?: boolean
    serviceTiers?: OptionChoice[]; resolvedModel?: string | null
  }
  ```
  With `agent-session.options.optional-model.v1` advertised, `current.model` may be absent (unknown). Without it the host substitutes `model: ''` and prepends a fake `{ id: '', label: 'Model not reported' }` row.
- `agentSession.setOption { envelope, key, value /* <= 512 chars */ }` → `value: { key; value; options?: Record<string,string> /* full effective set if the provider reconciled */ }`. Keys used: `model`, `effort`, plus fast mode / service tier / interaction mode / permission mode — exact key strings: `src/shared/agent-session/options/agent-session-option-catalog.ts` (**not enumerated here**).
- `agentSession.modelCatalog` (strict) — models before a session exists (new-chat picker):
  ```ts
  { agent: string; sessionId?; worktree?; waitForListing?: boolean; savedOnly?: boolean; selectedModel?: string }
  → { listingInProgress?: true; waitExpired?: true; unavailable?: { reason: 'notSignedIn'; account? } | { reason: 'cliMissing' } }
    & ( { origin: 'unknown' }
      | { origin: 'live-session' | 'probe'; models: AgentSessionModelOption[]; fastModeSupport?; fetchedAt: number;
          listingNamesConfiguredModel?; defaultHoldsInEveryWorkspace?: true; modelsDifferByWorkspace?: true } )
  ```
  Send `waitForListing` only after a reply said `listingInProgress`; `savedOnly` is capability-gated (older hosts refuse unknown keys).
- `agentSession.commands { sessionId }` → `{ commands?: { name; kind: 'command'|'skill'; description?; argumentHint?; builtin?; path? }[]; commandsPending?: boolean }` (slash menu).
- `agentSession.agents {}` → the host's registered agents and what each supports (shape **UNVERIFIED**; `src/main/runtime/rpc/methods/structured-sessions/catalog/structured-agent-session-agents.ts`).

### 6.8 Status feed (list-level chat state without subscribing to transcripts)

`agentSession.subscribeStatus` params `{}`; gate `agent-session.status-feed.v1` (older hosts answer `forbidden`/method unavailable to phones). No unsubscribe RPC (2.3c).

```ts
| { type: 'snapshot'; sessions: AgentSessionStatusSummary[]; namingActiveSessionIds?: string[]; conversationNames?: ... }
| { type: 'status'; session: AgentSessionStatusSummary }
| { type: 'end' }

type AgentSessionStatusSummary = {      // essential subset; full type agent-session-wire.ts
  sessionId: string; workspaceId: string; agent: string
  status: 'working' | 'attention' | 'idle' | null    // null until the journal holds a message
  latestPrompt: string; lastAssistantMessage?: string
  toolName?: string; toolInput?: string               // only while working
  model?: string; effort?: string; fastMode?: string; serviceTier?: string; interactionMode?: 'default' | 'plan'
  turnOutcome?: AgentTurnOutcome; stopping?: true; awaitsAnswer?: true
  hostExecutionOwned?: true; hostExecutionPhase?: 'starting' | 'ready'
  conversationName?: string; conversationNameSource?: 'user'; forkedFrom?: ... | null
  sleptAt?: number; launchDirectory?: string
  updatedAt: number; statusStartedAt?: number
}
```
This feed never decides list membership — tabs do.

### 6.9 Queued messages (only with `agent-session.queued-messages.v2`)

Published as whole lists on frames/pages:
```ts
type AgentSessionQueuedMessage = { messageId: string; position: number; body: MessageItem; state: 'waiting' | 'returned';
  paused?: true; pausedReason?: 'send_failed'; returnedReason?: string | null; returnedRejection?; steers?: true }
```
Methods (each `{ envelope, messageId, ... }`): `agentSession.queuedMessageSend`, `queuedMessageDelete`, `queuedMessageMove`, `queuedMessageUpdate`, `queuedMessageEditHold` (not enveloped: `{ sessionId, messageId, editId, action: 'acquire'|'renew'|'release', expectedBodyFingerprint? }`), `agentSession.queuedMessagesResume { envelope }`. Result types: `src/shared/agent-session/requests/agent-session-queued-message-wire.ts`. Image-bearing cards are only published to clients advertising `agent-session.queued-image-cards.v1`.

### 6.10 Creating a new chat / launching an agent

Two routes. Mobile prefers **agent launch** (the host chooses chat vs terminal); `agentSession.create` is the direct chat route.

#### `agent.launch` / `agent.launchReplay` (`src/shared/rpc-contract/agent-launch/agent-launch-params.ts`; gate `agent.launch.v2`)

```ts
{
  agent: TuiAgent                    // 'claude' | 'codex' | 'gemini' | 'opencode' | 'cursor' | ... (src/shared/agent-launch/catalog/tui-agent.ts)
  operationId?: string               // `${13-digit ms}-${32 hex}`; REQUIRED on agent.launchReplay
  target:
    | { kind: 'existing'; worktree: string /* `id:<worktreeId>` */ }
    | { kind: 'create-worktree'; create: WorktreeCreateParams /* minus agent fields, see below */ }
    | { kind: 'create-folder-workspace'; create: FolderWorkspaceCreate }
  prompt?: { text: string; delivery: 'submit' | 'draft' }
  sessionOptions?: Record<string, string>     // model / effort / mode applied on whichever route
  chatOptions?: Record<string, string>        // gate: agent.launch.chat-options.v1
  agentArgs?: string | null                   // null = no args; absent = settings default
  surface?: 'chat' | 'terminal'               // gate: agent.launch.surface.v1 (older hosts strip it silently)
  nativeChatDefault?: boolean                 // the phone user's "prefer chat" preference
  launchSource?: string                       // free-form telemetry label
  paneKey?: string; sessionId?: string        // caller-reserved identities (sessionId refused if it already exists)
  placement?: { groupId?: string; afterTabId?: string }
  presentation?: 'focused' | 'background'
  cwd?: string; reuseTerminal?: { handle: string }
}
```
- New chat/agent tab in an **existing** workspace: mobile uses **`agent.launchReplay`** only (requires host `agent.launch.replay-required.v1`), so that a lost reply can be replayed with the same `operationId` without creating a second agent (`mobile/src/session/agent-launch/mobile-existing-agent-launch.ts`). Never mint a new `operationId` after an ambiguous outcome.
- New workspace + agent: `agent.launch` with `target.kind: 'create-worktree'`; `create` is the `worktree.create` payload with the reserved startup fields deleted (`AGENT_LAUNCH_RESERVED_CREATE_FIELDS`: `startupAgent`, `startupCommand`, `startupPrompt`, `startupDraft`, `startupLaunchConfig`, `startupEnv`, `startupCommandDelivery`, `launchSource`). `createdWithAgent` is **kept**. Note that a task-sourced create's `startupDraft` (the issue URL) is therefore dropped on this route; pass it as `prompt: { text, delivery: 'draft' }` if you want it (whether mobile does so on this path is **UNVERIFIED**).

Result (`src/shared/agent-launch/contracts/agent-launch-intent.ts`):
```ts
type AgentLaunchResult = {
  outcome:
    | { kind: 'structured'; sessionId: string; handle: string; tabId?: string }
    | { kind: 'terminal'; handle: string; paneKey?: string }
  worktreeId: string
  warning?: string
  setupTrustMismatch?: ...
  receipt: { mode: 'structured' | 'terminal'; preferred: 'structured' | 'terminal'; reason: AgentLaunchModeReason; detail: string }
  prompt?: { delivery: ... } & ( { outcome: 'journaled'; messageId: string } | { outcome: 'handed-to-terminal' }
                               | { outcome: 'not-delivered' } | { outcome: 'unconfirmed' } )
  placement?: { groupId: string; fallback?: 'anchor-group' | 'active-group' }
}
```
`prompt.outcome`: only `not-delivered` means you still own the text; never resend on the others. The host publishes and activates the new tab before replying, so navigate to `worktreeId` and let `session.tabs.subscribe` show it. Refusals `method_not_found` / `forbidden` / message containing `agent_launch_unsupported` mean "fall back to `worktree.create` with `startupAgent`".

#### `agentSession.createSupport` + `agentSession.create`

1. `agentSession.createSupport { worktree, agent, resumeFrom? }` (strict) → `{ supported: boolean; reason?: 'agent' | 'remote' | 'wsl' | 'windows' | 'chat-program' }`. Mobile retries a `selector_not_found` error at 50/150/300 ms (a just-created worktree may not resolve yet).
2. `agentSession.create` (strict, `CreateIntentParams`):
   ```ts
   {
     envelope: { sessionId: <new uuid>, clientOperationId, expectedRuntimeFence: null, payloadFingerprint },
     worktree: string, agent: string,
     forkFrom?: { sessionId: string; throughItemId: string }, resumeFrom?: ...,
     tabId?: string,                                              // gate: agentSession.create.tab-id.v1
     tabPlacement?: { groupId?: string; afterTabId?: string },    // gate: agentSession.create.tab-placement.v1; NOT in the fingerprint
     firstMessage?: { clientMessageId: string; body: SendBody; selection? },   // gate: agentSession.create.message.v1
     options?: Record<string,string>, optionsMode?: 'replace-model-selection'  // gate: agentSession.create.message.v1
   }
   → AgentSessionMutationResult<{ sessionId: string; fence: number; page: AgentSessionHistoryPage;
                                   firstMessage?: Submission; unconfirmedClientMessageIds: string[]; tabId?: string }>
   ```
   On a transport error, replay the **identical params once** (same envelope). Only a definitive refusal (`isDefinitiveAgentSessionCreateRefusal`, `src/shared/agent-session/failures/agent-session-definitive-refusal.ts`) may be treated as "not created"; anything else is unknown and must not trigger a sibling create. Other methods here: `agentSession.ensure` (attach by provider handle), `agentSession.reveal { sessionId }` → `{ ok: true, sessionId, workspaceId, agent, readable } | { ok: false, refusal }`, `agentSession.close`.

### 6.11 New worktree creation (`mobile/src/new-workspace/`)

`worktree.create` (`src/shared/rpc-contract/workspaces/worktree-create-params.ts`, large; non-strict). What mobile sends for a blank workspace (`blank-workspace-create.ts`):

```ts
{
  repo: `id:${repoId}`,
  name: string,
  setupDecision: 'run' | 'skip' | 'inherit',
  displayNameKind: 'generated' | 'user', displayName?: string,   // displayName only when user-typed
  nameWasGenerated?: true,
  comment?: string,
  startupAgent?: TuiAgent, createdWithAgent?: TuiAgent,          // startupAgent is deleted on the agent.launch route; createdWithAgent stays
  approvedSetupHash?: string
}
```
From a task/issue (`workspace-create-params.ts`) it adds `activate: true`, `startupDraft: <item url>`, `baseBranch?`, `compareBaseRef?`, `branchNameOverride?`, `pushTarget?: { remoteName, branchName, remoteUrl? }`, `sparseCheckout?: { directories, presetId? }`, and one of `linkedIssue` / `linkedPR` / `linkedGitLabIssue` / `linkedGitLabMR` / `linkedLinearIssue` (+ `linkedLinearIssueWorkspaceId`, `linkedLinearIssueOrganizationUrlKey`) / `linkedWorkItem`.

Result `CreateWorktreeResult` (`src/shared/worktree/create-types.ts:177`): `{ worktree: Worktree & {...}; setup?; setupReceipt?: { requested, hookFound, startupPolicy, state: 'running'|'skipped'|'not_configured'|'spawn_failed', terminalHandle? }; defaultTabs?; setupTrustMismatch?; warnings?; catalogVersion? }`.

Supporting calls: `repo.hooks` (setup script + trust hash), `ui.get`, `worktree.prefetchCreateBase`, `worktree.resolvePrBase`, `worktree.resolveMrBase`, `worktree.runApprovedSetup { worktree, approvedSetupHash }`, `preflight.detectAgents` / `preflight.detectRemoteAgents` (installed agents), `settings.get`. Name-collision retry and idempotency: `mobile/src/new-workspace/creation/worktree-create-retry.ts`, `worktree-create-idempotency-policy.ts` (uses `status.get.worktreeCreateIdempotency`).

---

## 7. Terminal

Params: `src/shared/rpc-contract/terminal/terminal-stream-params.ts`, `terminal-unary-params.ts`, `terminal-viewport-schemas-params.ts`. Mobile: `mobile/src/terminal/session/streaming/use-mobile-session-terminal-subscription.ts`, `mobile/src/terminal/host-operations/mobile-terminal-operations.ts`.

### 7.1 `terminal.subscribe`

```ts
{
  terminal: string                                   // handle from the tab (`tab.terminal`)
  client?: { id: string; type: 'mobile' | 'desktop' } // mobile sends a stable per-install id, type 'mobile'
  viewport?: { cols: number /* 1..1000 */; rows: number /* 1..500 */ }  // sent so the host fits BEFORE serialising the snapshot
  capabilities?: {
    terminalBinaryStream?: 1        // always sent by mobile: output arrives as binary frames (2.5)
    mobileInputLeaseOnly?: 1        // hold input ownership without receiving output (terminal hidden under chat); omit viewport too
    outputAck?: 1                   // credited output; only if you will send terminal.ackOutput
    writeUnavailable?: 1; desktopViewportClaims?: 1
  }
  resume?: { streamToken: string; units: number }    // continue an ended stream; units = UTF-16 code units of Output applied since snapshot
  snapshotByteBudget?: number
}
```
First JSON frame:
```ts
{ type: 'subscribed', streamId: number, lines: string[], truncated: boolean, cols?: number, rows?: number,
  displayMode: 'auto' | 'desktop' | ..., seq?: number /* layout seq */,
  outputAck?: true, streamToken?: string,            // only if you asked for outputAck and the host grants it
  resumed?: true }                                   // resume accepted: no snapshot follows, only missed output
```
Then binary frames for `streamId`: a snapshot (`SnapshotStart` meta → chunks → `SnapshotEnd`) surfacing as
```ts
{ type: 'scrollback', streamId, serialized: string /* xterm serialize output */, cols, rows, displayMode, seq?,
  cwd?, truncated?, truncatedByByteBudget?, oscLinks?, alternateScreen?, terminalOwner?, lastTitle?, kittyKeyboardFlags? }
```
followed by live `{ type: 'data', streamId, chunk }`, `{ type: 'resized', ... }`, `{ type: 'metadata', ... }`. The meta keys other than `serialized`/`type`/`streamId` come from the host's snapshot meta JSON (`terminal-subscribe-binary-snapshot.ts`); treat all as optional. Feed `serialized` then `chunk`s into a terminal emulator (the RN app uses xterm.js in a WebView). `{type:'end'}` or `{type:'error'}` → resubscribe.

Unsubscribe: `terminal.unsubscribe { subscriptionId: `${terminal}:${clientId}`, client: { id: clientId }, requestId: <opener request id> }`.

Output credit (only if `subscribed.outputAck === true`): `terminal.ackOutput { streamToken, units }` where `units` = UTF-16 code units of Output parsed since your last ack; mobile batches at 128 KiB units or 250 ms. If you asked for `outputAck` and stop acking, the stream stalls. Simplest: do not request `outputAck`.

### 7.2 Input

`terminal.send` (`TerminalSend`):
```ts
{
  terminal: string
  text?: string
  enter?: boolean            // append Enter (schema is z.unknown(); mobile sends a boolean)
  interrupt?: boolean        // Ctrl-C (same)
  inputSequence?: { sessionId: string; seq: number /* positive, monotonically increasing */ }   // ordered-input session
  requireWriteSettlement?: true
  client?: { id: string; type?: 'mobile' | 'desktop' }   // identifies the driver for the presence lock
  viewport?: { cols: number; rows: number }; claimViewport?: true
  inputKind?: 'query-reply'
  agentPrompt?: true; waitSubmitMs?: number; resolvedLaunchDraft?: { text; createdAt }; requireAgentStatus?: 'sendable'; requireStartupDialog?: string
}
→ { send: { handle: string; accepted: boolean; bytesWritten: number;
            refusedReason?: 'no-agent' | 'permission' | 'approval-unseen'; prompt?: ...; writeSettlement?: ... } }
```
Raw keystrokes are sent as `text` (escape sequences included) with `enter` unset. `terminal.openInputSession { terminal, client: { id, type: 'mobile' } }` opens the `inputSequence` session (result shape **UNVERIFIED**; see `mobile/src/terminal/input-delivery/`). Unsequenced `terminal.send { terminal, text }` works without it.

### 7.3 Resize / viewport

- `terminal.updateViewport { terminal, client: { id, type?: 'mobile' }, viewport: { cols, rows }, claim?: boolean }` — update in place; do **not** resubscribe to resize. Also update the stored subscribe params so a reconnect replay carries the new viewport.
- `terminal.setDisplayMode { terminal, mode: 'auto' | 'desktop', client?, viewport? }` — `auto`: the phone drives PTY dimensions while subscribed (desktop restores when the last phone leaves); `desktop`: no resize, phone scales to fit.
- `terminal.getAutoRestoreFit` / `terminal.setAutoRestoreFit { ms: number | null }`, `terminal.clearBuffer { terminal }`.

### 7.4 Scrollback

Initial scrollback is the `scrollback` snapshot above (bounded by `snapshotByteBudget`). On demand: `terminal.read { terminal, cursor?: number, limit?: number, screen?: true }` (`cursor` and `screen` are mutually exclusive; check `source` in the reply — reply shape **UNVERIFIED**). Host: `src/main/runtime/rpc/methods/terminal/session-terminal-scrollback.ts`.

---

## 8. Files and source control (brief)

All take `{ worktree: string, ... }`. Params: `src/shared/rpc-contract/filesystem/files-params.ts`, `files-target-params.ts`; `src/shared/rpc-contract/source-control/git-params.ts`. Mobile readers: `mobile/src/files/explorer/file-explorer-reply-schema.ts`, `mobile/src/files/preview/file-preview-reply-schema.ts`, `mobile/src/source-control/git/git-status-reply-schema.ts`.

| Method | Params | Result (as mobile reads it) |
|---|---|---|
| `files.readDir` | `{ worktree, relativePath: string /* '' = root */, followSymlinks?, after?: { name, isDirectory }, limit? }` | without `after`/`limit`: `{ name: string; isDirectory: boolean; isSymlink?: boolean }[]`; with either: `{ entries: [...]; total: number; hasMore: boolean }` (older hosts ignore `limit` and send the bare array) |
| `files.list` | `{ worktree }` | `{ files: { relativePath: string; basename?; kind? }[]; truncated: boolean }` (capped, legacy) |
| `files.searchPaths` | `{ worktree, query, limit? /* <= 32, default 16 */, includeIgnored?, excludePaths?, mode?: 'quick-open' }` | list of path matches (shape **UNVERIFIED**) |
| `files.read` | `{ worktree, relativePath }` | `{ content: string; truncated?: boolean; byteLength?: number; isBinary?: boolean }`; binary files raise error code `binary_file` |
| `files.readPreview` | `{ worktree, relativePath }` | text: as `files.read`; image: `{ content?: string /* base64 */; isBinary?; isImage?; mimeType? }` |
| `files.readChunk` | `{ worktree, relativePath, offset, length /* <= 512 KiB */ }` | chunk (shape **UNVERIFIED**) |
| `files.stat`, `files.pathsExist` | see params | |
| `files.open` | `{ worktree, relativePath, line?, column?, navigation? }` | opens a file tab in the session (appears on the tabs stream) |
| `files.openDiff` | `{ worktree, relativePath, staged?, oldPath?, navigation? }` | opens a diff tab |
| `git.status` | `{ worktree, includeIgnored?, includeLineStats?, reuseLineStats?, admissionTier? }` | see below |
| `git.diff` | `{ worktree, filePath, staged: boolean, compareAgainstHead?, oldPath? }` | `GitDiffResult` below |
| `git.stage` / `git.unstage` / `git.discard` | `{ worktree, filePath }` | |
| `git.bulkStage` / `git.bulkUnstage` | `{ worktree, filePaths: string[] }`; `bulkStage` also takes `scope?: 'all' \| 'tracked'` | |
| `git.commit` | `{ worktree, message }` | |
| `git.push` | `{ worktree, publish?, forceWithLease?, pushTarget? }` | |
| `git.pull`, `git.fetch`, `git.fastForward` | `{ worktree, pushTarget? }` | |
| `git.history`, `git.branchCompare`, `git.branchDiff`, `git.commitCompare`, `git.commitDiff` | see params | |

```ts
// git.status
{
  entries: {
    path: string
    status: 'modified' | 'added' | 'deleted' | 'renamed' | 'untracked' | 'copied'   // unknown → 'modified'
    area?: 'staged' | 'unstaged' | 'untracked'                                      // unknown → undefined: withhold stage/unstage/commit
    oldPath?: string; added?: number; removed?: number
    conflictKind?: 'both_modified'|'both_added'|'both_deleted'|'added_by_us'|'added_by_them'|'deleted_by_us'|'deleted_by_them'
    conflictStatus?: 'unresolved' | 'resolved_locally'; conflictStatusSource?: 'git' | 'session'
    submodule?: { commitChanged: boolean; trackedChanges: boolean; untrackedChanges: boolean; restoreRecurses?: boolean }
    submoduleRoot?: string
  }[]
  conflictOperation?: 'merge' | 'rebase' | 'cherry-pick' | 'unknown'
  branch?: string; head?: string
  upstreamStatus?: { hasUpstream: boolean; ahead: number; behind: number; upstreamName?: string;
                     hasConfiguredPushTarget?: boolean; behindCommitsArePatchEquivalent?: boolean }
  readError?: string        // host's own failure, sent alongside whatever entries it got
}

// git.diff  (src/shared/git/diff/git-diff-compare-types.ts) — whole-file contents, NOT a unified patch
| { kind: 'text'; originalContent: string; modifiedContent: string; originalIsBinary: false; modifiedIsBinary: false; largeDiffRenderLimit? }
| { kind: 'binary'; originalContent: string; modifiedContent: string; originalIsBinary: boolean; modifiedIsBinary: boolean;
    isImage?: boolean; mimeType?: string; modifiedDeleted?: boolean; tooLarge?: boolean }
```
Refresh trigger: `gitStatusChanged` client event (section 3). PR surfaces use `github.*`, `pr.forBranch`, `hostedReview.create` (not covered).

---

## 9. Push notifications (brief)

Sources: `mobile/src/notifications/push-registration.ts`, `push-registration/mobile-push-registration-operations.ts`; `src/shared/rpc-contract/notifications/notifications-params.ts`; `src/shared/notifications/mobile-push-contract.ts`; host `src/main/runtime/rpc/methods/notifications/notifications.ts`.

- Gate: host capability `notifications.remote-push.v1`. Registered per host.
- `notifications.registerPush` (**strict** — do not add `deviceId`; the host derives it from the authenticated device):
  ```ts
  { platform: 'ios' | 'android'; token: string /* 1..4096 */; apnsEnvironment?: 'sandbox' | 'production' /* REQUIRED for ios */;
    filter: { onlyWhenDesktopAway?: boolean; onlyWhenAgentNeedsInput?: boolean; sound?: boolean } }
  → { registered: true; registrationId: string }
  | { registered: false; reason: 'gateway_unreachable' | 'gateway_rejected' | 'not_mobile' | 'registration_storage_failed' | 'throttled' }
  ```
  Mobile timeout 5 s. Registrations carry a host-side lease (`expiresAt`) that the app renews (`mobile-push-lease-renewal.ts`).
- `notifications.unregisterPush` params `null`.
- `notifications.testPush` → `{ accepted: true } | { accepted: false; reason: 'not_registered' | 'unavailable' | 'rate_limited' | 'rejected' }` (params **UNVERIFIED**).
- In-app stream: `notifications.subscribe { includeDesktopSuppressed?: boolean }` (params object optional) — ready-id stream. First frame `{ type: 'ready', subscriptionId, epoch: string }`; then
  ```ts
  { type: 'notification'; source: 'agent-task-complete' | 'terminal-bell' | 'test' | 'plugin'; title: string; body: string;
    worktreeId?: string; paneKey?: string; executionHost?: `runtime:${string}`; workspaceExecutionHostId?: string | null;
    notificationId?: string; notificationSeq?: number; notificationEpoch?: string;
    agentState?: 'working' | 'blocked' | 'waiting' | 'done'; attentionKey?: string; desktopAway?: boolean; emittedAt?: number; ... }
  ```
  plus a dismiss event (`MobileNotificationDismissEvent`, same file as the dispatch type: `src/main/runtime/push/notifications/runtime-mobile-notification-controller.ts`) and `{ type: 'end' }`.
- Catch-up after reconnect: `notifications.getMissedSince { lastSeenSeq: number; epoch?: string; includeDesktopSuppressed?: boolean; deliveredPushes?: { notificationId, notificationEpoch, notificationSeq }[] /* <= 256 */ }`. `epoch` identifies the host's sequence-counter lifetime (changes on host restart).

---

## 10. Client capability strings

`mobile/src/transport/connection/mobile-runtime-client-capabilities.ts` builds the list sent in `runtime.clientCapabilities.update { clientCapabilities: string[] }` as `remoteRuntimeClientCapabilities([...mobile-specific])` (`src/shared/remote-runtime/remote-runtime-client-capabilities.ts`), de-duplicated.

Rule of thumb for a reimplementer: **each string is a promise that you can read a newer wire shape. Advertise only what you implement.** Without a capability the host downgrades to the older shape.

### 10.1 Mobile-specific additions (the constants in the file)

| Constant | Literal | Effect on the wire |
|---|---|---|
| `AGENT_SESSION_COMMANDS_ON_REQUEST_CAPABILITY` | `agent-session.commands-on-request.v1` | Subscribe frames stop carrying the full `commands` list; they carry `commandsChanged: true` and you read `agentSession.commands` yourself. |
| `AGENT_SESSION_COHERENT_MODEL_CATALOG_CAPABILITY` | `agent-session.coherent-model-catalog.v1` | Client reads the coherent `agentSession.modelCatalog` answer (exact host-side change **UNVERIFIED**). |
| `STRUCTURED_AGENT_SESSION_RUNTIME_CAPABILITY` | `agent-session.structured.v1` | Host publishes structured chat tabs (`type: 'agent-session'`) and lets you call journal/lifecycle methods. Without it you get metadata-only placeholders for non-PTY sessions. |
| `AGENT_SESSION_CURRENT_REQUESTS_CLIENT_CAPABILITY` | `agent-session.current-requests.v1` | Frames carry the `currentRequests` marker and you must read pending approvals/questions via `agentSession.currentRequests` (6.6); also (with snapshot catch-up) changes history reads. |
| `AGENT_SESSION_PENDING_SEND_RESULT_RUNTIME_CAPABILITY` | `agent-session.pending-send-result.v1` | `agentSession.send` returns immediately with a durable `pending` submission instead of the host waiting (bounded) for settlement. You must render later rejection from the stream. |
| `STRUCTURED_AGENT_SESSION_HOLD_RUNTIME_CAPABILITY` | `agent-session.structured.hold.v1` | Client uses explicit `agentSession.hold` / `release` surface holds. |
| `CLAUDE_STRUCTURED_AGENT_SESSION_RUNTIME_CAPABILITY` | `agent-session.structured.claude.v1` | Enables Claude structured sessions (gated separately from Codex). |
| `STRUCTURED_AGENT_SESSION_REGISTERED_AGENTS_RUNTIME_CAPABILITY` | `agent-session.structured.registered-agents.v1` | Host sends chat tabs / status rows for agents other than Claude/Codex; `agent` becomes an open string. |
| `PI_STRUCTURED_DIALOGS_RUNTIME_CAPABILITY` | `agent-session.structured.pi-dialogs.v1` | Pi agent dialogs arrive as ordinary approval/question items you must answer. |
| `AGENT_SESSION_OPTIONAL_MODEL_CLIENT_CAPABILITY` | `agent-session.options.optional-model.v1` | `agentSession.options.current.model` may be absent; without it the host sends `model: ''` plus a fake "Model not reported" row. |
| `SESSION_TABS_SPLIT_GROUP_PLACEMENT_RUNTIME_CAPABILITY` | `session-tabs.split-group-placement.v1` | Host reports complete split-parent placement on tab results instead of making the client wait for the snapshot. |
| `AGENT_SESSION_TURN_ITEM_CAPABILITY` | `agent-session.turn-item.v1` | Journal sends `body.kind: 'turn'` items. Without it turns are downgraded to `status` items carrying `turnLifecycle`. (Also in the base list.) |
| `AGENT_LAUNCH_RUNTIME_CAPABILITY` | `agent.launch.v2` | Tells the host you handle both `structured` and `terminal` launch outcomes, so `agent.launch` may route to chat. Without it the host keeps the legacy `worktree.create` + `startupAgent` terminal behaviour. |
| `AGENT_LAUNCH_UNSTARTED_TAB_CLIENT_CAPABILITY` | `agent.launch.unstarted-tab.v1` | Host may list a launch's tab before its terminal exists (`status: 'pending-handle'`, `terminal: null`). A listed tab is then not proof the agent is alive. |
| `AGENT_LAUNCH_TAB_CLOSED_CLIENT_CAPABILITY` | `agent.launch.tab-closed.v1` | A launch whose tab was closed during startup answers the definite `agent_launch_tab_closed` instead of `agent_session_operation_unknown`. |
| `AGENT_STATUS_RESTORED_UNCONFIRMED_RUNTIME_CAPABILITY` | `agent-status.restored-unconfirmed.v1` | Agent status may carry `restoredUnconfirmed` (host restored a turn it cannot verify — offer no Stop). Without it the host reports `done`. |
| `AGENT_SESSION_CREATE_MESSAGE_RUNTIME_CAPABILITY` | `agentSession.create.message.v1` | Client understands create-owned first messages (the host owns the opening message from creation; `firstMessage` in the create result). |
| `AGENT_SESSION_QUEUED_IMAGE_CARDS_CLIENT_CAPABILITY` | `agent-session.queued-image-cards.v1` | Queued-message cards that contain images are published to you; you must preserve the images when editing. |
| `TERMINAL_HOST_PANE_RESPAWN_CLIENT_CAPABILITY` | `terminal.host-pane-respawn.v1` | A terminal tab's `terminal` handle may change in place when the host restarts the pane; rebind your subscription to the new handle. |
| `COMPRESSED_FRAMES_CLIENT_CAPABILITY` | `transport.compressed-frames.v1` | Host may send any frame ≥ 1024 bytes as a gzip binary frame (kind `0x7a`, section 2.5) that you must inflate. (Also in the base list.) |

### 10.2 Base set (`remoteRuntimeClientCapabilities`) — also advertised by mobile

| Literal | Effect |
|---|---|
| `agent-session.background-task-stop.v1` | background-task state includes stop controls |
| `agent-session.background-task-row-stop.v1` | per-row background-task stop |
| `agent-session.background-task-child-views.v1` | status summaries may carry `children` views |
| `agent-session.turn-item.v1` | (see above) |
| `agent-session.session-boundary.v1` | session-boundary rows/markers in the journal |
| `session-tabs.close-intent.v1` | host honours close intent semantics on `session.tabs.close` |
| `session-tabs.authoritative-inventory.v1` | tab snapshots are the authoritative inventory (absent tabs are gone, except under `clientHostedPagesUnreconciled` / `agentSessionsUnverifiable`) |
| `skills.install-result.v2` | newer skill-install result shape |
| `worktree.github-pr-suppression.v1`, `worktree.visibility-defaults.v1`, `worktree.visibility-source-defaults.v1` | worktree rows carry host-derived visibility facts (`defaultBranch`, `automationCreated`, `cliCreated`, `detachedHead`, …) |
| `automation.owner-fencing.v1` | automation writes are owner-fenced |
| `repo.search-qualified-refs.v1`, `repo.search-canonical-refs.v1` | ref search returns qualified/canonical refs |
| `terminal.quick-commands.long-prompts.v1`, `terminal.quick-commands.large-lists.v1` | quick-command limits |
| `google.triggers.v1` | automation rules may contain Gmail/Calendar triggers |
| `workspace-unread.host-raises.v1` | only in Electron builds with `ORCA_SIDEBAR_INPUTS === 'main'`; **not** sent by the phone |
| `transport.compressed-frames.v1` | unless env `ORCA_DISABLE_MOBILE_COMPRESSED_FRAMES=1` |

Exact per-capability behaviour for the base rows is summarised from the constants' comments; the individual host projections were not all traced (**UNVERIFIED** in detail).

### 10.3 Minimal viable set for a first native client

To render the list, the tab strip, a chat transcript, and send messages with attachments, advertising only this is coherent:

```
agent-session.structured.v1
agent-session.structured.claude.v1
agent-session.turn-item.v1
agent-session.pending-send-result.v1
agent.launch.v2
```
Add `agent-session.structured.registered-agents.v1`, `agent-session.options.optional-model.v1`, `agent-session.current-requests.v1`, `agent-session.commands-on-request.v1`, `transport.compressed-frames.v1`, `terminal.host-pane-respawn.v1`, `agent.launch.unstarted-tab.v1` as each reader is implemented. (That this reduced set behaves correctly end-to-end against a current host is **UNVERIFIED** — it follows from the per-capability downgrade comments, not from a test.)

---

## Appendix: UNVERIFIED items in one place

- Host-side producer of the `worktree.ps` `unchanged` / `rowsFromBase` forms (field names taken from the mobile reader).
- Params of `ui.get`, `ui.set`, `mobileRelay.projectSections`, `folderWorkspace.list`, `notifications.testPush`.
- Result shapes of `files.searchPaths`, `files.readChunk`, `terminal.read`, `terminal.openInputSession`, `agentSession.agents`.
- Exact option key strings for `agentSession.setOption`.
- `AgentSessionRefusalDetails` per-code shapes.
- How a stream without an unsubscribe RPC (`agentSession.subscribeStatus`) is released before socket close.
- Whether `retryUnknown` participates in the send fingerprint.
- Browser screencast binary frame layout (`mobile/src/browser/screencast/browser-screencast-protocol.ts`, not read).
- Host-side effect of `agent-session.coherent-model-catalog.v1` and of each base-set capability.
- The "minimal viable capability set" in 10.3.
