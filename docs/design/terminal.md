# Terminal behaviour and UX (reference: official Orca mobile app) and native port plan

Scope: what the official React Native app's terminal *does* (xterm.js in a WebView), so the native SwiftTerm terminal in orca-ios can match or beat it. Wire shapes (method params, binary frame layout, capability strings) are **not** repeated here; see `docs/protocol/rpc-surface.md` section 2.4 (reconnect replay), 2.5 (binary frames), 7 (terminal methods), 6.4 (image upload RPCs) and 10 (capabilities).

All paths are relative to the Orca checkout (`/Users/qq12/orca`). `T/` abbreviates `mobile/src/terminal/`. Anything marked **UNVERIFIED** was not confirmed in source.

Architecture of the reference, in one paragraph: one WebView ("document") per terminal handle, at most 3 mounted (`MOUNTED_TERMINAL_LIMIT = 3`, `T/session/pane-layout/mounted-terminal-lru.ts`). xterm's own keyboard is disabled (`textarea.readOnly = true`, `inputmode=none`, custom key handler returns false — `T/document/engine/query-reply.ts`). Typing happens in a separate React Native `TextInput` ("live input") in a dock under the terminal; an accessory key row sits above that field. Native code owns the RPC stream and posts `init` / `write` / `resize` / `reflow` commands into the document; the document posts back modes, taps, gesture bytes, selection, query replies and cell metrics (`T/webview/terminal-webview-messages.ts`, `T/webview/terminal-webview-contract.ts`).

---

## 1. Viewport and sizing

### 1.1 The sizing model (the important part)

The phone **does resize the host PTY** by default. There are two display modes per terminal (`T/session/mobile-terminal-model.ts`: `MobileDisplayMode = 'auto' | 'phone' | 'desktop'`; `phone` is an observed state reported by the host, the client only ever requests `auto` or `desktop`):

| Mode | Who owns PTY cols/rows | What the phone draws |
|---|---|---|
| `auto` (default; `phone` is treated the same — `T/session/pane-layout/terminal-phone-display-mode.ts`) | The phone. The host resizes the PTY to the phone's `viewport` while a phone is subscribed ("phone-fit"). | Grid at 1:1, fills the frame. |
| `desktop` | The desktop pane. The phone subscription is passive ("Desktop-mode subscriptions only watch and must not claim the floor", `src/main/runtime/terminal/layout/mobile-terminal-subscribe.ts`). | The desktop-sized grid **scaled down to fit the width**, pinned top-left, pannable/pinch-zoomable. |

Host-side take-over / restore concept (`src/main/runtime/terminal/layout/`):

- On a phone subscribe in `auto` with a measured viewport the host captures the desktop size as a restore baseline, then fits the PTY to the phone. Desktop shows a banner with "Restore" / "Restore all".
- When the last phone subscriber leaves, restoration is governed by the desktop setting `mobileAutoRestoreFitMs` (`src/shared/settings/default-global-settings.ts`): default **`null` = hold phone dimensions indefinitely** until the desktop user presses Restore ("indefinite hold — the Restore banner is the explicit return action"). Finite values clamp to 5 s – 60 min (`MOBILE_AUTO_RESTORE_FIT_MIN_MS = 5_000`, `MOBILE_AUTO_RESTORE_FIT_MAX_MS = 60*60*1000`, `terminal-desktop-reclaim.ts`). The phone can read/write this with `terminal.getAutoRestoreFit` / `terminal.setAutoRestoreFit` (`T/viewport/terminal-auto-restore-fit-state.ts`).
- Desktop "take back" (`terminal.restoreFit`, `reclaimTerminalForDesktop`) flips the mode to `desktop`; an automatic phone resubscribe (e.g. iOS resume) must then stay passive — "only a deliberate phone gesture reclaims it (#28487)". The deliberate gesture is `terminal.setDisplayMode { mode: 'auto', client, viewport }` ("Requesting auto explicitly takes the input floor and phone dimensions", `T/session/streaming/use-mobile-session-terminal-stream-display.ts`).
- Multiple phones: the "most recent actor" drives the size; sending input with `client: {id, type:'mobile'}` takes the input floor ("Take the input floor so multi-phone contention follows the latest actor", `T/input-delivery/terminal-send-request.ts`).
- The design docs these comments cite (`docs/mobile-fit-hold.md`, `docs/mobile-presence-lock.md`, `docs/mobile-terminal-layout-state-machine.md`) are **not in the checkout**; the above is reconstructed from code comments. Exact floor/lock arbitration is **UNVERIFIED** beyond that.

The user toggles the mode from: a key in the accessory row (Monitor / Smartphone icon), the "more keys" sheet ("Desktop width" / "Phone width"), and the tab action sheet ("Switch to Desktop" / "Switch to Phone") — `T/session/accessory-keys/MobileSessionAccessoryKeys.tsx`, `TerminalMoreKeysSheet.tsx`, `T/session/tab-actions/mobile-terminal-action-sheet-actions.ts`. The mode displayed is whatever the stream last reported (`displayMode` on `subscribed` / `scrollback` / `resized`), never an optimistic local value (`terminalDisplayModeAdopter`, `T/session/streaming/terminal-stream-layout.ts`).

### 1.2 Computing cols/rows

`T/viewport/terminal-grid-fit.ts`:

```ts
const EXACT_FIT_TOLERANCE = 1e-6
cols = Math.floor(width / cell.cellWidth + EXACT_FIT_TOLERANCE)
if (!(cols >= TERMINAL_VIEWPORT_MIN_COLS)) return null          // 20
rows = Math.floor(height / cell.cellHeight + EXACT_FIT_TOLERANCE)
return { cols, rows: Math.max(TERMINAL_VIEWPORT_MIN_ROWS, rows) } // 8
```

Limits (`src/shared/terminal/viewport/terminal-viewport.ts`): `MIN_COLS = 20`, `MAX_COLS = 1024`, `MIN_ROWS = 8`, `MAX_ROWS = 500`.

- `width`/`height` are the **unrounded** laid-out frame of the terminal view, not the window ("Fit the unrounded measured frame; window height can exceed visible area").
- The cell box is measured by the renderer (`css.cell.width/height`) and reported together with the font scale it was measured at; a cell box measured at another text scale may not authorize a fit (`fitDimensions` in `T/webview/use-terminal-webview-controller.ts`). A width narrower than 20 columns yields *no* fit (nothing is sent).
- There is **no padding**: the grid starts at the top-left of the frame. The fractional row left at the bottom is painted with the last row's background (`T/document/viewport/bottom-row-backdrop.ts`) so a TUI footer colour extends to the edge.

### 1.3 Reporting to the host

1. **On subscribe**: the measured viewport rides in `terminal.subscribe.viewport` "so host fitting precedes snapshot serialization without a focus/fit race" (`T/session/streaming/use-mobile-session-terminal-subscription.ts`). The subscribe is gated on: document ready, frame laid out, viewport measured.
2. **After the snapshot** (`runTerminalViewportFitPass`, `T/session/streaming/mobile-terminal-viewport-resubscribe.ts`): compare the host's reported `cols/rows` with the phone's viewport.
   - `displayMode === 'desktop'` → converged by definition (mismatch is intended).
   - host omitted dims → `hold` (keep the stream; do not invent 80x24 — "invented 80x24 can never match phone size and causes a refit loop").
   - mismatch → unsubscribe + resubscribe, bounded: `MAX_TERMINAL_VIEWPORT_RESUBSCRIBE_ATTEMPTS = 3`, backoff `[0, 750, 3000]` ms. On exhaustion a one-time toast: "Couldn't fit the terminal to this screen". The budget refills only after the handle disappears from `terminal.list` and returns.
3. **Later layout changes**: `terminal.updateViewport` in place (preferred; "keeps the mobile subscriber record alive"), then `rpc.updateTerminalSubscriptionViewport(handle, dims)` so reconnect replay carries the new size. If the reply has `applied: true` the client **reflows its local buffer** to the new grid, because "updateViewport re-streams only the visible screen, so local scrollback stays wrapped at the old width". If the method is not found (older host) fall back to unsubscribe + subscribe (`T/viewport/terminal-viewport-refit.ts`, `terminal-viewport-refit-state.ts`).
4. The host answers with `resized` events. With `serialized` present → full re-init of the emulator from that snapshot (`preserveScroll: true`); without → plain `resize(cols, rows)`. Superseded `resized` events are dropped by layout `seq`: drop when `eventSeq < last && last - eventSeq <= 20`; each `subscribed` resets the mark; `scrollback.seq` is **not** a layout seq ("binary scrollback seq counts output bytes, not layout changes") — `acceptTerminalLayoutSeq`.

### 1.4 Refit triggers and timings (`T/viewport/terminal-viewport-refit.ts`)

All refits are debounced through one timer: **150 ms**. A refit that computes the same grid as last sent is a no-op unless forced.

| Trigger | Behaviour |
|---|---|
| Tab strip appears/disappears (`terminals.length > 1`) | refit |
| Window dimensions change (rotation, fold, split view) | refit — except a height-only change while the keyboard is visible (ignored, see 1.5) |
| Terminal frame width changes without a window change (dock/sidebar) | refit |
| Terminal frame height changes | refit, unless keyboard visible → deferred |
| Font size / family / line height / weight changes (`fontMetricsKey`) | refit |
| Renderer reports a changed cell box at an unchanged grid (`cell-box` with `refit: true`) | refit |
| iOS app returns to foreground (`background`/`inactive` → `active`) | **forced** refit ("cached grid can match while the host PTY changed in background; reassert equal dims") |
| Connection returns to `connected` | **forced** refit, and the cached "updateViewport unsupported" verdict is cleared |
| Native chat covers the active terminal | no refit ("would push phone dims into a PTY nobody on this device is viewing") |

After every applied `scrollback` / `resized` the client schedules one "settled fit" (`resetZoom` → re-apply fit scale) **200 ms** later, latest-wins (`T/session/streaming/mobile-terminal-stream-subscribe.ts`).

### 1.5 Keyboard show/hide

The keyboard does **not** resize the PTY. "Expo edge-to-edge keeps window size on IME open; lift input from keyboard height without resizing the desktop PTY" (`T/session/input-controls/use-mobile-session-keyboard-lift.ts`).

- The dock (key row + live field) is translated up by the keyboard height (iOS: `max(0, keyboardHeight - dockBottomInset)`).
- The terminal view is translated up (`transform: translateY(-lift)`) by only as much as needed (`T/keyboard/terminal-keyboard-avoidance-lift.ts`):
  - alternate screen → full keyboard lift (TUIs draw to the bottom);
  - normal buffer → `min(keyboardLift, anchorOverflow)` where `anchorRow = max(cursorY, contentBottomRow)` and `anchorOverflow = max(0, (anchorRow + 1) * rowHeight + rowHeight - visibleBottom)` — i.e. keep the cursor/last content row plus one spare row above the dock, and do not move at all when the prompt is still near the top;
  - a desktop-mode grid drawn shorter than its frame caps the lift to the drawn content.
  - The emulator feeds this with `keyboard-avoidance-metrics { cursorY, contentBottomRow, rows, altScreen, rowPitch }` after every parsed write (`T/document/viewport/keyboard-avoidance-metrics.ts`).
- Height changes while the keyboard is visible are recorded as `pending` and coalesced into **one** refit after the keyboard closes; if the keyboard reopens during the 150 ms debounce the refit is deferred again ("Defer typing-time height refits … instead of reflowing mid-keystroke", `reduceTerminalFrameHeightRefit`).
- Keyboard dismissal: a fixed "dismiss keyboard" key at the left of the key row, outside its scroll view, shown while the keyboard is up (#5106). After a submit to a tab that runs an agent the keyboard is dismissed automatically ("Agent sends hand over the turn, so reveal the reply; shell commands keep the keyboard for command bursts", `T/session/input-controls/agent-send-keyboard-dismissal.ts`). Entering selection mode dismisses the keyboard.
- Tapping the terminal focuses the live field after 50 ms (`scheduleTerminalLiveInputFocus`), because the WebView still holds first responder during its touchend.

### 1.6 Desktop-mode scaling, pan and pinch (`T/document/viewport/fit-scale.ts`, `viewport-transform.ts`, `T/document/surface-input/surface-touch-gestures.ts`)

- Fit scale = `min(1, viewportWidth / (cellWidth * cols))`; values `>= 0.95` snap to 1 ("sub-pixel scrollbars cannot create endless non-noop fits"). The surface gets `translate(panX, panY) scale(currentScale * userScale)`, `transform-origin: top left`.
- The emulator grid is **never** resized locally to suit the phone: "resizing only phone xterm would change cursor coordinates and corrupt subsequent live PTY repaints" (`adjustRowsForViewport` is an intentional no-op).
- Pan: horizontal one-finger pan only when the scaled content overflows the width; vertical drags always scroll (never pan) "to keep scrollback reachable". Pan is clamped so content covers the viewport and pins top-left when smaller.
- Pinch = text size. During the gesture a transient CSS scale is applied, clamped so apparent size stays within the font limits (`MIN_TERMINAL_TEXT_SCALE / currentTextScale … MAX_TERMINAL_TEXT_SCALE / currentTextScale`). On release it commits to a whole point (`pinchedTerminalTextScale`: no change unless the pinch moved at least 1 pt), resets `userScale = 1, panX = panY = 0`, applies the new font size, re-fits the grid, persists the size, and the native side resizes the PTY. A haptic "selection" tick fires when the size changed. A pinch cancels an active text selection.
- Font size limits (`T/preferences/terminal-text-scales.ts`): `TERMINAL_BASE_FONT_PX = 13`, `TERMINAL_MIN_FONT_PX = 8`, `TERMINAL_MAX_FONT_PX = 26`; stored value is `points / 13`, always snapped to a whole point.

### 1.7 Split panes on the phone

Two terminals can be shown at once (`T/session/pane-layout/mobile-terminal-pane-layout.ts`): direction `auto` = side-by-side when `frame.width >= 600 && width > height`, otherwise stacked; user override `side-by-side` / `stacked`. Each pane has its own frame/viewport state and its own subscription; the one being typed into is marked "· Input". With the keyboard up, stacked panes each get half of the remaining height.

---

## 2. Output flow

### 2.1 Attach sequence (`T/session/streaming/use-mobile-session-terminal-subscription.ts`)

Preconditions for `terminal.subscribe`: connected, client id known, not already subscribed, view mounted and ready, frame laid out; measure viewport if not yet measured.

1. Send subscribe `{ terminal, client: {id, type:'mobile'}, viewport, capabilities, resume? }`. No `snapshotByteBudget` on native ("Native sockets have no bridge-frame cap; omit a client limit so the host keeps its full scrollback budget").
2. `subscribed` → record layout seq, start output-ack state (only if the host echoed `outputAck: true` + `streamToken`), note `resumed`.
3. `scrollback` (the snapshot) → `init({ cols, rows, initialData: serialized, preserveScroll: true, oscLinks, kittyFlags, frame })`:
   - cols/rows = host's, else the phone viewport, else 80x24.
   - The emulator is **replaced**, not appended to: a fresh engine is built hidden, the snapshot replayed into it, and only when the parse drained is it swapped in (`T/document/engine/surface-swap.ts`) — no flash of an empty or half-drawn screen.
   - Replay data is written as `ESC[0m` + snapshot; the pen is *not* reset afterwards ("later live output continues the host TUI's attributes").
   - A repeat `scrollback` for the same `streamId` after initialization is ignored.
   - `preserveScroll`: if the reader had scrolled up, the distance from the bottom (in rows) is restored after the replay; a bottom-pinned reader stays at the bottom.
4. `data` → write chunk. `metadata` → cwd only. `resized` → see 1.3. `end` / `error` → tear down this subscription and request inventory recovery (section 7.5).

### 2.2 Ordering / dedup between snapshot and live output

- Per stream, the host orders: snapshot first, then output newer than the snapshot ("Snapshots omit queries but trim their live chunks by seq", `src/main/runtime/rpc/methods/terminal/terminal-subscribe-binary-snapshot.ts`). The client therefore does **no seq arithmetic** on output; it relies on arrival order.
- Client rules that make that safe:
  - `init` clears any coalesced-but-unwritten output first ("The init snapshot supersedes buffered chunks; replaying them afterward would duplicate old output", `use-terminal-webview-controller.ts`).
  - Each init bumps a generation; queued writes of an older generation are discarded (`T/document/engine/write-queue.ts`, `terminal-init.ts`).
  - A `data` chunk arriving before any snapshot is still written but logged (`data RECEIVED before scrollback`); with a missing view it is dropped (and its credit returned).
  - Every unsubscribe bumps `subscribeSeq`, and callbacks of older subscriptions are ignored (`lifetime.isCurrent()`).
  - Writes are flushed before a `resize`/`reflow` "so terminal bytes stay ordered".

### 2.3 Alternate screen

- Snapshot of an alt-screen app: if the serialized data's last `ESC[?1049h` is after its last `ESC[?1049l`, everything before that `1049h` is **dropped** ("replaying both duplicates TUI frames and can flatten SGR", `normalizeInitialData`, `T/document/surface-input/mouse-mode-decset-scan.ts`). Normal-buffer scrollback is therefore not available while attached mid-TUI. Scroll position is not preserved for alt-screen snapshots.
- Local reflow (after `updateViewport`) is skipped on the alternate screen ("full repaints can lose SGR under local resize", `T/document/viewport/reflow.ts`); the app's own repaint is used.
- Scrolling in alt-screen is converted to input (section 5.1). The scroll indicator is hidden.

### 2.4 Write batching and flow control

- Native → emulator coalescing (`T/output-flow/terminal-write-coalescer.ts`): `TERMINAL_WRITE_FLUSH_WINDOW_MS = 48`; after a touch gesture that produced terminal input the window drops to `TERMINAL_INTERACTIVE_WRITE_WINDOW_MS = 16` for `TERMINAL_INTERACTIVE_WRITE_DURATION_MS = 180`; hard cap `TERMINAL_WRITE_MAX_PENDING_UNITS = 512 * 1024` UTF-16 units forces a flush. The first chunk after an idle window is delivered immediately. (This exists to amortise the WebView bridge; a native emulator needs far less.)
- Emulator write queue: slices of at most `TERMINAL_WRITE_SLICE_UNITS = 16 * 1024` so input and paint can interleave; one write in flight at a time.
- Before the document is ready, commands are queued, bounded at `1_000_000` code units / `4096` write messages, dropping the oldest writes first (`T/webview/terminal-webview-pending-messages.ts`).
- **Credit-based backpressure** (optional, `capabilities.outputAck`; `T/output-flow/terminal-output-ack.ts`): the host holds a per-stream window of `OUTPUT_CREDIT_WINDOW_UNITS = 512 * 1024` UTF-16 units of unparsed output (`src/main/runtime/rpc/methods/terminal/terminal-output-credit.ts`). The client returns credit with `terminal.ackOutput { streamToken, units }` once the emulator has **parsed** the chunk: batch at `ACK_BATCH_UNITS = 128 * 1024` or `ACK_DELAY_MS = 250` after the first unacked unit. Output dropped unwritten must still be acked "or the host's window leaks and the stream stalls". A refused ack is retried on the timer, never inline. When the window overflows the host replaces held output with one current-screen snapshot (delivered as an in-place `resized` with `serialized`) once the link drains — "so a client skips stale output after Ctrl-C".
  - The RN native build does **not** ask for credit: only an in-process document exposes `writeWithParseAck` ("a native route can't, and its stream would stall"). So on iOS today the stream is uncredited.

### 2.5 Reconnect and resume

- Transport level: active streams are replayed with the same request id and stored params (rpc-surface 2.4); the first frame after replay is a fresh `subscribed` followed by a fresh snapshot, which replaces the emulator content as in 2.1. Viewport params were updated in place, so the replay asks for the current phone size.
- Session level (`T/session/use-mobile-session-terminal-webview.ts`): whenever the visible handle set or the connection state changes — unsubscribe handles that are no longer visible; when connected, subscribe every visible handle. Hidden terminals are not streamed at all.
- On reconnect a forced viewport refit re-asserts the phone size (1.4).
- **Resume instead of snapshot** (only for credited streams, so not on RN-iOS today; `T/session/streaming/terminal-stream-resume.ts`): the client remembers `{ streamToken, units }` = UTF-16 units of Output applied since that stream's snapshot. The next subscribe sends `resume`; if the host answers `resumed: true` no snapshot follows, only missed output. The position must be forgotten whenever the emulator may no longer show exactly that output: a hole or foreign-stream chunk, a stream `error`, a mid-stream `resized` snapshot, a document reload, an iOS foreground repaint, a cache clear, a text-size change, a pane unmount. A resumable stream is cancelled on connection loss so the transport does not replay it as a snapshot.
- **iOS foreground recovery** (`T/webview/terminal-foreground-recovery.ts`): on return to foreground, forget all resume positions, clear "initialized" for every mounted terminal, unsubscribe the visible ones and resubscribe after `TERMINAL_FOREGROUND_RECOVERY_DELAY_MS = 120`; if disconnected at that moment the recovery is deferred until reconnect. This exists because WKWebView can lose its backing store; a native view does not lose state, but the *resubscribe-for-a-fresh-snapshot on resume* behaviour is still worth keeping because output was missed while suspended.
- Readiness watchdog: no ready signal from the emulator within `WEB_READY_WATCHDOG_MS = 15000` (foreground only) surfaces an error state instead of a blank pane.

### 2.6 Terminal query replies

Programs query the terminal (DA, CPR/DSR, DECRPM, window size `CSI 18t`, Kitty flags, OSC colour queries, DECRQSS, XTVERSION …). Rule (`T/host-operations/mobile-terminal-query-reply.ts`): "Subscriptions, including hidden panes, suppress the desktop responder and own replies" — so while the phone is subscribed **the phone's emulator must answer**.

- Replies are sent with `terminal.send { text, enter: false, inputKind: 'query-reply', client }`, immediately (never batched with typing).
- Only when all hold: connected, the terminal is currently subscribed, the bytes match the reply grammar `isTerminalQueryReply` (`src/shared/terminal/protocol/queries/terminal-query-reply.ts`), and the host advertises `terminal.query-reply-input.v1`. Without that capability the reply is **dropped** — an older host strips `inputKind` and the reply "would land as ordinary floor-taking input".
- OSC 7501 (program status) replies only if the host advertises `terminal.program-status.v1`.
- Replies generated while replaying a snapshot are suppressed: reply authority is revoked at each init and re-granted at a boundary queued behind the replay data ("Snapshot queries must never reach live PTY input").
- OSC 52 clipboard writes from the program are honoured on the viewing device (copied to the phone clipboard), but not during replay (`T/document/engine/osc52-clipboard-bridge.ts`).

---

## 3. Input

### 3.1 Delivery layer (`T/input-delivery/`)

Everything the user types ends in `terminal.send { terminal, text, enter: false, client: { id, type: 'mobile' } }` (`buildTerminalSendParams`). Escape sequences are plain characters inside `text`. `enter` is not used by the terminal path (Return is sent as `\r` text).

- **Never queue across a disconnect**: `TERMINAL_INPUT_SEND_OPTIONS = { failWhenDisconnected: true }` — "Never park keystrokes during connect waits; they would replay stale input into the PTY after reconnect". On any state change away from `connected`, and on a connection-path change (relay ↔ direct), all pending input is cancelled (`inputSender.cancelAll()`).
- **Ordered input** (`MobileTerminalInputSender`, used when the host advertises `terminal.ordered-input.v1`): one owner per terminal handle; `terminal.openInputSession { terminal, client }` → `inputSessionId`; each send carries `inputSequence { sessionId, seq }` with `seq` starting at 1 and incrementing. Up to `TERMINAL_ORDERED_INPUT_WINDOW = 8` sends in flight (globally and per owner). Without the capability: 1 in flight per terminal, no sequence. The owner is keyed by an epoch `${client.generation}:${lastConnectedAt}`; a new connection gets a new owner and a new session.
- **Batching**: a new request merges into the pending tail batch when both are plain `{terminal, text, enter, client}` from the same client, same kind, kind ≠ `control`, and the merged text stays ≤ `TERMINAL_LIVE_INPUT_MAX_BYTES = 256 KiB`. Kinds: `gesture` (has a deadline), `control` (`enqueue.control`, `enter`, `interrupt`), `text`. "A control never joins a text batch, so it can be skipped when that text fails to arrive."
- **Limits**: 64 owners; `TERMINAL_ORDERED_INPUT_MAX_WAITERS = 128`; byte budget `TERMINAL_INPUT_MAX_BYTES (16 MiB) + 1 MiB`. Single live input over 256 KiB → toast "Input too large (max 256 KiB)".
- **Failure = no retry**: only `send.accepted === true` proves delivery (`terminalSendAcceptedSchema`). Any refusal, error or staleness marks the owner failed; all its pending batches resolve as refused; the next keystroke builds a new owner (and a new input session). A lost reply means *unknown* delivery, and the client never resends typed input. The live field is cleared and a failure surfaced (`delivery-unconfirmed`).
- Before sending typed text the terminal is scrolled to the bottom (not for pointer-originated bytes).

### 3.2 Typed text and IME (the "live input" mirror — `T/live-input/`)

Because the emulator's own keyboard is disabled, the RN app mirrors a text field into the PTY:

- The field keeps the text typed since the last line end. On each change the client diffs field text against what it already sent and emits `DEL (0x7f) × eraseCount + appendText` (`computeTerminalLiveMirrorStep`, `buildTerminalLiveMirrorPayload`, code-point based). Autocorrect/dictation rewrites become backspaces + retype.
- **IME composition is never sent while composing**: with a reported marked-text range (iOS; the app patches React Native to expose `isComposing = markedTextRange != nil`, `mobile/patches/react-native@0.88.1.patch`) the composing tail is held and sent on commit, never on a timer. Trailing conjoining Hangul jamo are held even without marked text (iOS 10-key). Platforms without a range (Android) hold the trailing non-ASCII run and commit after `TERMINAL_LIVE_HELD_PREEDIT_COMMIT_DELAY_MS = 300`.
- Field config: `autoCapitalize: none`, `autoCorrect: false`, `spellCheck: false`, `smartInsertDelete: false`, `autoComplete: off`, `keyboardType: default` ("ASCII-only keyboard types hide non-Latin IMEs"), `returnKeyType: default`, `blurOnSubmit: false` (`mobile/src/session/MobileSessionCommandDock.tsx`).
- iOS smart dashes: `–` / `—` are mapped to `--` before sending (`normalizeTerminalTextInput`).
- Return (`onSubmitEditing`) → flush held text, send `\r`, clear the field and reset the mirror ("end the field session").
- Special keys from the field while it holds text: Backspace, Delete, ArrowLeft, Home edit the field locally (the mirror diff then syncs the PTY); ArrowRight/End go to the PTY only when the caret is at the field end ("where shells accept an autosuggestion"). With an empty field every special key is sent raw.
- A control key pressed while composing first commits the held text, then sends the key, both queued synchronously so later keystrokes cannot overtake.
- Any external writer (paste, image attach, quick insert, mouse click) first flushes pending/held text and ends the field session (`flushPendingLiveInputBeforeExternalSend`).
- The mirror state is reset on disconnect ("Outages make delivered echo unknown") and on a tab switch.

A native emulator view that is itself the first responder (SwiftTerm's `TerminalView` implements `UITextInput`) does **not** need this mirror; see the port plan.

### 3.3 Paste (`T/session/input-controls/use-mobile-terminal-paste.ts`)

- Text: if the pane has DECSET 2004 on → `ESC[200~` + text + `ESC[201~`, with line endings normalised `\r?\n → \r` and every embedded `ESC` replaced by `␛` (U+241B) "so pasted framing bytes cannot close the frame and execute its tail" (`src/shared/terminal/input/terminal-bracketed-paste-text.ts`). Otherwise just the `\r` normalisation.
- Sent in order in chunks of `PASTE_SEND_CHUNK_BYTES = 64 * 1024` (UTF-8 safe split). Stop at the first refusal or when the connection epoch changes; if a bracketed paste was partly delivered, send `ESC[201~` so the program leaves paste mode. Max total `TERMINAL_INPUT_MAX_BYTES = 16 MiB` → "Paste is too large."
- One paste at a time per session. Pending IME text is flushed first. Paste is cancelled if the active terminal changed meanwhile ("Paste canceled (terminal changed)").
- OS paste into the live field: a single append longer than `UNFRAMED_AGENT_INPUT_MAX_BYTES = 512` bytes in a bracketed-paste pane is framed as a paste and ends the field session ("Agents can split or keep only the last read of unframed input longer than a PTY read").
- The Paste key is shown only when the clipboard has text or an image.
- Empty text clipboard + image → image paste (section 8).

### 3.4 Special keys and mode-dependent encoding

Base bytes (`T/key-input/terminal-key-definitions.ts`, `terminal-accessory-keys.ts`): Esc `\x1b`, Tab `\t`, Enter `\r`, Shift+Tab `\x1b[Z`, Backspace `\x7f`, Del `\x1b[3~`, arrows `\x1b[A/B/C/D`, Home `\x1b[H`, End `\x1b[F`, Ins `\x1b[2~`, PgUp `\x1b[5~`, PgDn `\x1b[6~`, F1–F4 `\x1bOP..S`, F5 `\x1b[15~`, F6 `17~`, F7 `18~`, F8 `19~`, F9 `20~`, F10 `21~`, F11 `23~`, F12 `24~`.

Modifiers (xterm style): parameter `1 + shift(1) + alt(2) + ctrl(4)`; CSI-final keys become `ESC[1;{p}X` (F1–F4 switch from SS3 to CSI when modified), tilde keys `ESC[{code};{p}~`. Printables: Shift applies the US-layout shift map; Ctrl+letter → `charCode - 96`; Ctrl+symbol via `CTRL_PRINTABLE_BYTES` (e.g. space/@/2/` → `\x00`, `[`/3 → `\x1b`, `\` /4 → `\x1c`, `]`/5 → `\x1d`, `^`/6 → `\x1e`, `_`/7 or `/` → `\x1f`, `?`/8 → `\x7f`); Alt prefixes `ESC`. Ctrl+Backspace → `\x17`; Ctrl+other Backspace combos `\b`.

Applied at send time per pane (`encodeTerminalKeyForModes`, `T/key-input/terminal-key-mode-encoding.ts`):

- **Application cursor keys** (DECCKM on and Kitty flags == 0): unmodified arrows/Home/End `ESC[X` → `ESC O X`.
- **Shift+Enter** (`\x1b[13;2u` placeholder): Kitty flags > 0 → `ESC[13;2u`; else `modifyOtherKeys > 0` → `ESC[27;2;13~`; else `ESC \r`.
- **Ctrl+Enter** (`\x1b[13;5u` placeholder): sent as CSI-u when Kitty flags > 0 or the host is known not to be Windows; otherwise `\r` ("Un-negotiated ConPTY types CSI-u literally").

The modes come from the emulator after every parsed write: `{ bracketedPasteMode, altScreen, mouseTrackingMode, sgrMouseMode, sgrMousePixelsMode, applicationCursorKeysMode, kittyKeyboardFlags, modifyOtherKeys }` (`T/document/engine/mode-mirroring.ts`). The snapshot meta's `kittyKeyboardFlags` seeds the Kitty state because a serialized snapshot cannot carry it.

### 3.5 Accessory key bar (`T/session/accessory-keys/`)

A horizontally scrolling row above the live field. Left to right:

1. Keyboard-dismiss key (fixed, outside the scroller, only while the keyboard is up).
2. Optional "smart rail" agent keys (section 8.3), off by default.
3. Display-mode toggle (desktop ⇄ phone).
4. Paste (only when the clipboard has content).
5. Built-in keys in user order, default order and visibility = all of:
   `Esc`, `Tab`, **`Shift` `Ctrl` `Alt` latches (inserted right after Tab)**, `Enter`, `Shift+Tab`, `Space`, `⌫`, `Del`, `↑`, `↓`, `←`, `→`, `Ctrl+C` (`\x03`), `Ctrl+D` (`\x04`), `Ctrl+L` (`\x0c`), `Ctrl+Z` (`\x1a`), `Ctrl+R` (`\x12`), `Ctrl+A` (`\x01`), `Ctrl+E` (`\x05`), `Ctrl+W` (`\x17`), `Ctrl+U` (`\x15`).
6. User custom keys (long-press 400 ms → delete prompt).
7. `+` (add custom key).

A "more keys" sheet (`TerminalMoreKeysSheet.tsx`) holds: Paste, Photo, File, Desktop/Phone width; the built-in keys not on the row; extra keys `Home End PgUp PgDn Ins F1–F12`; Ctrl combos; custom keys.

Sticky modifiers (`T/key-input/terminal-sticky-modifiers.ts`, `use-terminal-dock-keys.ts`):
- States `off → once → off`; a second tap within `STICKY_MODIFIER_DOUBLE_TAP_MS = 350` while `once` → `locked`; any later tap → `off`.
- The next key (row key, more-keys key, or **the next character typed on the software keyboard**) takes all held modifiers; `once` latches release, `locked` stay.
- Latches are per tab: switching the active terminal clears them.
- A key that cannot take the held modifiers is sent unmodified.

Long-press repeat (`T/key-input/terminal-accessory-repeat.ts`): only `⌫`, `Del` and the four arrows are repeatable. `TERMINAL_ACCESSORY_REPEAT_DELAY_MS = 400`, then every `TERMINAL_ACCESSORY_REPEAT_INTERVAL_MS = 45` — but the next repeat is scheduled only **after the previous send was accepted** (self-throttling on a slow link). Repeats stop on release, on scroll of the row, app backgrounding, tab switch, disconnect, client change.

Touch rules (`use-terminal-key-row-touch.ts`): a key fires on release only if the finger moved ≤ 8 px (`PRESS_MOVE_SLOP`) and the row did not scroll since touch-down. Taps on the row never dismiss the keyboard (`keyboardShouldPersistTaps="always"`).

Layout preference (`T/key-input/terminal-accessory-layout.ts`): AsyncStorage key `orca:terminal-accessory-layout`, `{ version: 2, orderedBuiltInIds, visibleBuiltInIds, directionPadEnabled, smartRail }`; newly shipped built-ins are inserted next to their canonical neighbour and made visible.

### 3.6 Hardware keyboard

- Keys reach the live field's `onKeyPress` by name and are mapped (`TERMINAL_LIVE_SPECIAL_KEY_IDS`, `T/live-input/terminal-live-input.ts`): Escape, Tab, Backspace, Delete, Insert, arrows, Home, End, PageUp, PageDown, F1–F12. Enter goes through submit only ("handling both native key and submit events would double-send Return").
- Modifier chords (Ctrl/Alt + key, Shift+Enter, Ctrl+Enter) are captured only by the web sibling `T/live-input/terminal-text-field-submit-binding.web.ts` (keydown capture; skips IME composition, `metaKey`, AltGr, Ctrl+Alt, Ctrl+Space, and on iOS Alt+printable so Option still types symbols). The native binding (`terminal-text-field-submit-binding.ts`) is a no-op. Whether hardware Ctrl-chords work in the native RN iOS build is **UNVERIFIED** (the code suggests they do not).
- Cmd shortcuts are not mapped to terminal bytes ("Cmd is absent because macOS swallows it before shell", `T/shortcuts/settings/CustomKeyModal.tsx`).

---

## 4. Quick commands and custom shortcuts

Two different features:

### 4.1 Custom keys ("shortcuts") — local to the device

`T/key-input/terminal-custom-keys.ts`, `T/shortcuts/settings/`. Stored in AsyncStorage key `orca:custom-accessory-keys` as `[{ id, label, bytes, enter, visible? }]`. Built from a key + Ctrl/Alt/Shift picker (single printable or a special key); bytes produced by `buildTerminalShortcutKey` (3.4). Sent as raw bytes through the same accessory path (`handleAccessoryKey({ bytes })`), with mode encoding applied. Migration: a saved `Ctrl+Enter` with bytes `\r` is upgraded to `\x1b[13;5u`.

### 4.2 Quick commands — host-synced (`T/quick-commands/`)

- Stored on the **host**, shared with desktop: `settings.getTerminalQuickCommands` / `settings.updateTerminalQuickCommands { mutation }` (reply `{ terminalQuickCommands }`). Shown only when the host advertises `terminal.quick-commands.v1`. Loaded when the sheet opens; writes are serialized, optimistic, and adopt the host's canonical list; an unparseable list is treated as *unknown*, never as empty ("cannot erase host commands").
- Shape: `{ id, label, scope: {type:'global'} | {type:'repo', repoId}, action }` where action is `terminal-command { command, appendEnter }` or `agent-prompt { agent, prompt }`.
- Running one **creates a new terminal tab** (it does not type into the current one) via the session-tab terminal create request (`T/session/creation/mobile-session-terminal-create-request.ts`) with:
  - command + `appendEnter !== false` → `{ command: <flattened command>, startupCommandDelivery: 'shell-ready' }`;
  - command + `appendEnter === false` → a plain terminal is created, then the command text is typed into it with `terminal.send { terminal: <new handle>, text: command, enter: false, client }` (inserted, not run; toast "<label> inserted") — `T/session/creation/use-mobile-session-terminal-create-actions.ts`;
  - agent prompt → `{ agent, agentPrompt }`.
  - plus `{ worktree: 'id:<id>', afterTabId, clientMutationId, activate: false, select: true, navigation: 'caller' }`.
- The created tab carries `quickCommandLabel` for its title.

---

## 5. Pointer input

### 5.1 Scrolling (`T/document/surface-input/mouse-input-encoding.ts`, `surface-touch-gestures.ts`, `T/document/viewport/normal-buffer-smooth-scroll.ts`)

Decision per scrolled row (`routeScrollLines`):

1. Mouse tracking on with wheel support (`vt200`/`drag`/`any`) but the **encoding is unproven** → scroll local scrollback. ("Replay may omit encoding; guessed legacy reports could type escape bytes into the TUI.") Encoding is proven by seeing `?1006h`/`?1016h`, a full reset `ESC c`, or a *live* (not replayed) tracking enable.
2. Mouse tracking with wheel support → send wheel reports to the app, even on the normal buffer: SGR `ESC[<64;col;rowM` (up) / `65` (down), 1-based cells; SGR-pixels (1016) uses pixel coordinates; legacy `ESC[M` + `(64|65)+32`, col+32, row+32 only if every byte ≤ 126, else fall back to arrow keys.
3. Alternate screen without mouse tracking → arrow keys: `ESC[A`/`ESC[B`, or `ESC O A`/`ESC O B` under DECCKM.
4. Otherwise → local scrollback.

- At most 32 sequences per event (`count = min(|lines|, 32)`); rows accumulate from pixel deltas using the drawn cell height.
- Native-side validation and rate limit for gesture bytes (`T/pointer-input/terminal-gesture-input.ts`, `T/session/input-controls/terminal-gesture-input-policy.ts`, `use-mobile-session-terminal-input.ts`): only arrow-scroll, SGR mouse (`button ∈ {0,32,64,65}`) and legacy mouse sequences are accepted, ≤ 2048 chars / 32 sequences per message; token bucket `capacity 64`, `refill 120/s` per handle; queued gesture input older than `TERMINAL_GESTURE_INPUT_MAX_QUEUE_AGE_MS = 250` is dropped ("Drop queued gesture arrows on disconnect so reconnect cannot move the TUI long after the swipe"); only accepted when the pane is alt-screen or mouse-tracking and is the active terminal tab.
- Local scrollback: whole rows only ("fractional transforms shimmer against xterm's row-based repaint"), coalesced to one scroll per frame. Momentum: velocity smoothed `0.55 * old + 0.45 * instant`, friction `0.972` per 16 ms, stop below `0.012` px/ms, no momentum if the finger rested > 100 ms before release. Momentum also drives app-routed scrolling.
- A custom scroll indicator (3 px thumb, min 24 px) appears while scrolling and hides after 550 ms; hidden when scroll is routed to the app or there is no scrollback.
- New output does not yank a reader who scrolled up (xterm default); sending typed input scrolls to the bottom.

### 5.2 Taps (`T/document/surface-input/tap-dispatch.ts`, `surface-tap.ts`)

Tap = single finger, moved ≤ `TAP_SLOP = 24` px (|dx|+|dy|), duration ≤ `TAP_MAX_MS = 700`, did not scroll a row, did not stop a momentum scroll. Priority on tap:

1. OSC 8 hyperlink under the finger → file link → `onFileTap`, URL → `onOpenUrl`. Links inside the snapshot arrive separately as `oscLinks` ranges (row/startCol/endCol/uri) and are valid only while the text at that range is unchanged.
2. Plain-text `http(s)` URL at the cell (wrap-aware) → open URL.
3. File path at the cell (`path[:line[:col]]`) → file tap with candidates; the host resolves which exists.
4. If the app has mouse tracking with proven encoding → send a click: press+release (`ESC[<0;c;rM` + `ESC[<0;c;rm`; X10 mode press only; legacy `ESC[M` form when not SGR and coords ≤ 126). Marked `click: true` so it bypasses the gesture rate limit and is ordered after pending typed text ("Flush pending live text before a click can move the TUI cursor").
5. Focus the keyboard (always for touch).

URL opening honours a preference (`linkOpenMode`): in-app Orca browser tab, system, or ask via an action sheet (`T/session/links/use-mobile-terminal-link-open.tsx`).

### 5.3 Selection and copy (`T/document/selection/`)

- Long-press `LONG_PRESS_MS = 500` (slop 10 px) enters selection mode, seeding a **word** selection (xterm double-click rules; grapheme-aware), haptic tick, keyboard dismissed. The same finger can keep dragging the end handle.
- Two 44x44 drag handles and a floating pill menu: **Copy**, **Select All**. Dragging within 40 px of the top/bottom edge auto-scrolls one row every 60 ms, with an "edge-bump" haptic at the buffer end.
- Copy: text optionally passes `stripTerminalSelectionGutter` (host setting `terminalCopyTrimsGutter`, read once per connection via `settings.get`, default on); success haptic; toast "Copied" on iOS; selection cleared.
- Selection is cancelled by: a tap/drag on the surface (the same gesture continues as a scroll), a pinch, a new snapshot. If output evicts the selected rows from scrollback → "Selection cleared (scrolled out of buffer)".
- Mouse-tracking apps: touch long-press still selects locally. With a real pointer (mouse/trackpad), a drag sends press/motion/release reports to the app when tracking is on (motion once per cell), otherwise it selects by character.

### 5.4 Trackpad / mouse wheel

Wheel events are claimed before the emulator sees them and routed through the same logic as touch scrolling; `ctrl+wheel` (trackpad pinch) is swallowed (`T/document/surface-input/wheel-scroll.ts`).

---

## 6. Preferences

### 6.1 Fonts

- Choices (`T/preferences/terminal-font-style.ts`): `system` (SF Mono via `ui-monospace` on iOS), `menlo`, `courier-new`, and bundled variable fonts `jetbrains-mono` (JetBrains Mono, wght 100–800), `fira-code` (Fira Code, 300–700), `geist-mono` (Geist Mono, 100–900) — latin + latin-ext subsets only (`mobile/assets/fonts/*.woff2`); other glyphs fall through to the system mono stack.
- Symbol fallbacks: "Orca Nerd Font Symbols" (`SymbolsNerdFontMono-Regular`, ranges `U+E000-F8FF, U+F0000-FFFFD, U+100000-10FFFD`); "Orca Terminal Symbols" (Noto Sans Symbols 2 subset, `U+23F4-23F7`) is Android-only ("iOS already draws ⏴⏵⏶⏷ from system fonts").
- Line height options `[1, 1.15, 1.3]`; regular weight options `[300, 400, 500]`; bold weight = regular + 200.
- Defaults (`T/preferences/terminal-font-defaults.ts`): phone **13 pt, system, weight 300, line height 1**; tablet (by *screen*, not window) **15 pt, system, weight 400, line height 1.15**. Range 8–26 pt.
- Settings UI: slider (preview while dragging, commit on release) + −/+ stepper, font/weight/spacing pickers with a live preview, reset. Stored per device.

### 6.2 Theme and colours

The palette is **host-driven per terminal**: each terminal tab carries `terminalTheme: { mode: 'dark' | 'light', theme: TerminalColorOverrides, minimumContrastRatio? }` (`src/shared/remote-runtime/session-graph/runtime-mobile-session-tab-contracts.ts`), so the phone shows the desktop's terminal theme regardless of the app's own light/dark scheme. Any key the host omits falls back to the built-in default (`T/terminal-webview-html/theme.ts`); there is **no separate built-in light palette** — `colors.terminalBg` is `#1a1b26` in both app schemes (`mobile/src/theme/mobile-theme.ts`).

Default theme (Tokyo Night):

| Key | Value | Key | Value |
|---|---|---|---|
| background | `#1a1b26` | foreground | `#c0caf5` |
| cursor | `#c0caf5` | cursorAccent | `#1a1b26` |
| selectionBackground | `#33467c` | selectionForeground | `#c0caf5` |
| black | `#15161e` | brightBlack | `#414868` |
| red | `#f7768e` | brightRed | `#f7768e` |
| green | `#9ece6a` | brightGreen | `#9ece6a` |
| yellow | `#e0af68` | brightYellow | `#e0af68` |
| blue | `#7aa2f7` | brightBlue | `#7aa2f7` |
| magenta | `#bb9af7` | brightMagenta | `#bb9af7` |
| cyan | `#7dcfff` | brightCyan | `#7dcfff` |
| white | `#a9b1d6` | brightWhite | `#c0caf5` |

- Minimum contrast (`src/shared/terminal-themes/terminal-contrast-correction.ts`): host override if present, else by background luminance: light background `4.5`, dark background `3`.
- Theme re-application is skipped when nothing changed, because "Theme assignment resets OSC palette changes".
- The view/page background is painted with the theme background so the fractional bottom row and overscroll match.
- Selection handle colour `#7aa2f7` with `#c0caf5` border; selection menu `#2a2f4a` / text `#c0caf5`.

### 6.3 Cursor and emulator options

`T/terminal-webview-html/theme.ts`, `T/document/engine/terminal-init.ts`:

- Cursor: `cursorStyle: 'bar'`, `cursorBlink: false`, `cursorInactiveStyle: 'block'`, `showCursorImmediately: true`.
- `scrollback: 5000` (`DESKTOP_TERMINAL_SCROLLBACK_ROWS_DEFAULT`; the phone does not follow a larger desktop setting), `convertEol: false`, `allowProposedApi: true`, WebGL renderer with context-loss recovery.
- Unicode: xterm Unicode 11 widths plus Orca's ZWJ rule (`src/shared/terminal/appearance/terminal-unicode-provider.ts`, version id `orca-11-zwj`): a ZWJ and the code point after it join the preceding wide glyph, so a ZWJ emoji sequence occupies **one** wide cell ("CLIs budget ZWJ emoji as one wide glyph").
- `.xterm { font-variant-emoji: text }` and the Claude status dot rule (section 8.4).
- OSC 52 write supported; OSC 8 hyperlinks supported; OSC 7501 program-status responder installed.

### 6.4 Other preferences touching the terminal

Accessory row layout and smart rail (3.5), custom keys (4.1), split layout `auto | side-by-side | stacked`, link open mode, `terminalCopyTrimsGutter` (host), auto-restore-fit (host, 1.1).

---

## 7. Session / tab relationship

### 7.1 Mapping

- A terminal is addressed by an opaque **handle** string. Tabs come from `session.tabs.subscribe` (rpc-surface 5): a terminal tab is `{ type: 'terminal', id, title, terminal: string | null, status?: 'pending-handle' | 'ready', parentTabId?, leafId?, terminalTheme?, agentStatus?, customTitle?, quickCommandLabel?, generatedTitle?, aiVaultTitle?, launchDraft?, isActive }` (`T/session/inventory/mobile-terminal-records.ts`).
- The app keeps selection by **tab id**; the active handle is the active tab's `terminal`. `terminal.list { worktree: 'id:<id>', includeVisualLayouts: false, includePreview: false }` is a secondary inventory used to enrich records (`connected`, `orphaned`, `agentIdentity`) and to prune dead handles — "Session tabs own surfaces; inventory refreshes only existing terminals' metadata."
- Split panes on desktop appear as separate terminal tabs with `parentTabId`/`leafId`.
- A tab may exist before its terminal (`status: 'pending-handle'`, `terminal: null`): show a spinner; the app polls with a budget of `PENDING_TERMINAL_HANDLE_RECOVERY_ATTEMPTS = 5` per `(tab id, parentTabId, leafId)` context.
- Mount policy: visible terminals plus most-recently-visible others up to 3 keep their emulator (and scrollback) alive; only **visible** terminals hold a stream. A terminal that is unmounted loses its emulator and must get a fresh snapshot when shown again (`releaseTerminalDocument`).

### 7.2 Titles

The strip title is host-computed (`tab.title`, default "Terminal"), with `customTitle` (rename), `quickCommandLabel`, `aiVaultTitle`, `generatedTitle` as provenance fields. The phone does not derive titles from OSC 0/2 itself; the snapshot meta carries `lastTitle` but mobile does not read it (no reference under `mobile/src`). Rename → `terminal.rename`; close → session tab close (preferred) or `terminal.close`; "Clear Terminal" → `terminal.clearBuffer`, then unsubscribe + resubscribe for a fresh snapshot if currently streamed, toast "Terminal cleared" / "Couldn't clear terminal".

### 7.3 Bell and notifications

No bell handling exists in the mobile terminal (no `onBell`, no BEL handling under `T/`). Attention is driven by host agent status on tabs and by push/notification streams (rpc-surface 9), not by the terminal emulator. **UNVERIFIED** whether the host turns BEL into a notification.

### 7.4 Host pane respawn (`terminal.host-pane-respawn.v1`)

Meaning (`src/shared/terminal/pty/lifecycle/host-pane-respawn-capability.ts`): "A client that rebinds its view when the host replaces a pane's terminal with a new one." Host side (`src/main/runtime/terminal/view/runtime-terminal-view-subscribers.ts`): a remote viewer **without** the capability is recorded as a "respawn-blind view" — one "whose client would show a dead pane if the host replaced its terminal"; `everyRemoteViewFollowsHostRespawn(ptyId)` is false while any such view exists, which (by its name and comment) holds the host back from replacing that pane's terminal. Advertising it promises:

- the same tab `id` may reappear with a **different** `terminal` handle;
- the client must then drop the old handle's subscription and emulator and attach the new handle from scratch (fresh snapshot, new input session, cleared sticky modifiers / modes / cwd / viewport budget).

The RN app has no special-case code for this; it falls out of its structure: everything is keyed by handle, selection is by tab id, the "visible handles" effect unsubscribes handles that left the visible set and subscribes the new ones, and `terminal.list` pruning deletes per-handle caches. What exactly triggers a respawn on the host and whether the old stream receives `end` first is **UNVERIFIED**.

### 7.5 Process exit / stream end

- When the PTY exits the host flushes remaining output, then ends the stream (`{type:'end'}`; "A PTY exit sends held output and later deliveries at once", `terminal-output-credit.ts`; first screen is still published before `end`, `terminal-subscription-registration.ts`).
- Client on `end` or `error`: unsubscribe, bump the subscribe seq, then run **inventory recovery** (`T/session/inventory/use-mobile-terminal-inventory-recovery.ts`): `terminal.list` now and a confirmation pass `TERMINAL_INVENTORY_CONFIRMATION_DELAY_MS = 750` later; an empty inventory must be seen twice before the screen shows empty. Handles absent from the list are pruned. A slow safety sweep runs every `CERTIFIED_TERMINAL_SWEEP_MS = 60_000`.
- There is no "[process exited]" banner in the mobile terminal; the tab simply disappears when the host removes it, or stays with whatever the final snapshot showed. Activation of a tab whose saved folder is gone reports `startupCwdFallback: 'workspace-root'`.
- If a handle is still listed after `end`, the visible-handles effect resubscribes it (bounded by the viewport budget and normal gates).

### 7.6 Terminal hidden under native chat

When a structured chat view covers a terminal tab the client keeps a **lease-only** subscription (`capabilities.mobileInputLeaseOnly`, no viewport) so input ownership is retained without output; returning to the terminal view resubscribes for a fresh snapshot (rpc-surface 7.1).

---

## 8. Agent TUIs (Claude Code, Codex, …)

### 8.1 Image / file paste into a terminal

Supported. Two entry points with the same back end:

- **Paste key** with an image on the clipboard and no text (`use-mobile-terminal-paste.ts`).
- **Attach button** next to the live field: tap = photo library, long-press (350 ms) = file picker; also "Photo" / "File" in the more-keys sheet (`T/session/input-controls/MobileTerminalInputActions.tsx`, `mobile/src/files/attachments/mobile-image-attachment.ts`).

Flow:

1. Fit the image for agents: long edge ≤ `AGENT_IMAGE_MAX_LONG_EDGE = 2000`, bytes ≤ `AGENT_IMAGE_MAX_BYTES = floor(5 MiB / 4 * 3)`; if larger, re-encode as JPEG quality 0.85 on a white background; images in a readable format under the limits pass through unchanged (`mobile/src/files/attachments/mobile-agent-image-fit.ts`).
2. Upload to the host with the chunked clipboard upload (`clipboard.startImageUpload` → `appendImageUploadChunk` (512 KiB base64 chars) → `commitImageUpload` → **host file path**; abort on failure; legacy `clipboard.saveImageAsTempFile` for ≤ 256 KiB) — rpc-surface 6.4. `connectionId` = the repo's SSH connection id (so the file lands where the PTY runs) or `null`; max 24 MiB base64. Status "Uploading image to host" covers the field without changing its height.
3. Type the **path** into the terminal as a bracketed paste, always framed "even when it is one line so agents receive it atomically", plus a trailing space so later typing does not glue onto the filename:
   `ESC[200~` + formatted path (ESC → `␛`) + `ESC[201~` + `" "`.
4. Path formatting by agent (`mobile/src/files/attachments/mobile-clipboard-image.ts`, `src/shared/native-chat/input/composer/agent-image-paste.ts`, `src/shared/terminal/input/image-path-paste.ts`):
   - unknown agent or `codex`: raw path if it has no shell-unsafe characters, else backslash-escaped (POSIX) / shell-escaped (Windows);
   - agents that turn a pasted path into an attachment (`claude`, `openclaude`, `codex`, `gemini`, `cursor`, `copilot`, `droid`, `grok`): the bare path;
   - other agents: a file mention `@path`, `@"path with space"`, or `@'…'`.
5. Pending IME text is flushed before the path is sent.

### 8.2 Keyboard behaviour for agent tabs

- Shift+Enter (newline in agent composers) and Ctrl+Enter are encoded per negotiated keyboard mode (3.4). Kitty flags come from the snapshot meta.
- The more-keys sheet treats an agent tab's primary row as `Esc, Shift+Tab, Enter, Ctrl+C, arrows`, a shell tab's as `Esc, Tab, arrows`.
- Keyboard auto-dismiss after a submitted send on an agent tab (1.5).
- Long pastes are bracketed (3.3) because agents mis-handle unframed input longer than one PTY read.

### 8.3 Smart keys (`src/shared/terminal/input/agent-smart-keys.ts`)

Optional context keys at the front of the key row, derived from the tab's agent and its `agentStatus`; never a key that quits the agent. Multi-write keys are sent as separate writes `AGENT_SMART_KEY_STEP_MS = 120` apart ("ESC ESC in one write reads as Alt+Esc").

| Agent | State | Keys (label → bytes) |
|---|---|---|
| claude | working | Stop → `ESC`; Send now → `\x18\x13`; Background → `\x02`; Mode → `ESC[Z` |
| claude | permission | Yes → `1`; Always → `2`; No → `ESC` |
| claude | idle | Mode → `ESC[Z`; History → `ESC[A`; Rewind → `ESC`, `ESC` |
| claude | question | `1…n` (≤ 9), `←`, `→`, Cancel → `ESC` |
| codex | working | Stop → `ESC`; Queue → `\t`; Edit → `ESC[1;2D` |
| codex | permission | Yes → `y`; No → `n` |
| codex | question (async) | Answer → `ESC[1;2D`; digits; Enter; Skip → `\x1d` |
| opencode | working | Stop → `ESC`, `ESC` |
| opencode | permission | `←`, `→`, Confirm → `\r`, Reject → `ESC` |

### 8.4 Rendering details that matter for agent TUIs

- Claude's status dot `⏺` (U+23FA) is forced to **text presentation**: every `⏺` followed by any VS15/VS16 is rewritten to `⏺` + U+FE0E, including across chunk boundaries, because iOS draws it as a colour emoji otherwise (`normalizeStatusDotPresentation`, `T/document/engine/write-queue.ts`); plus `font-variant-emoji: text` globally.
- `⏴⏵⏶⏷` (Claude's mode marker) must have a font.
- ZWJ emoji width rule (6.3) and Nerd Font PUA glyphs.
- Query replies must be answered by the phone (2.6) or agent start-up probes time out.
- Launch drafts: a tab may carry `launchDraft` (host-parked unsent prompt text) — out of scope here beyond noting it exists.

---

## 9. Known pitfalls (lessons a reimplementation must respect)

From `mobile/terminal-output-streaming-findings.md` (2026-04-28):

1. **Never deliver emulator commands before the emulator is ready.** Messages posted before handlers were installed were silently dropped; the fix was two queues (before "web-ready", and before the engine's `init` completes). Native equivalent: do not `feed` before the view has a non-zero size and a font; buffer until then.
2. **Subscribe only after the socket is `connected`**, and keep full stream request metadata so active streams can be replayed after reconnect.
3. **`terminal.unsubscribe` must use the id the host registered** (handle / `handle:clientId`, see rpc-surface 2.3) or host cleanup does not run.
4. **Clear and resubscribe when the worktree or the active handle changes**; track the active handle in a mutable reference so callbacks from a stale handle are ignored.
5. `terminal.send` returning `ok` does **not** prove output will arrive. The original bug was host-side (daemon PTY data not forwarded to `runtime.onPtyData`). Debug order: reproduce without the phone first (`mobile/scripts/test-subscribe.ts`); if the wire is healthy, then suspect the view.
6. An initial `scrollback` may be empty (`lines: []`, no `serialized`) — that is valid; render an empty terminal and keep the stream.

From `mobile/issue-5049-unresponsive-session-findings.md` (2026-06-09) — "a session that looks alive but ignores input":

7. **A reconnect loop that gives up must be un-parkable.** The client stopped after 12 attempts (~6.5 min) and nothing restarted it. Required: on app foreground, on network restoration and on Wi-Fi ↔ cellular handoff → if `reconnecting`: clear backoff, reset the attempt budget, reconnect now.
8. **Detect half-open sockets quickly on resume.** A TCP path killed while backgrounded reports no close; sends blackhole. On foreground while `connected`, run a liveness probe immediately (≤ 8 s timeout) rather than waiting for the periodic 20 s + 8 s probe.
9. **Never keep driving a replaced client object.** After a forced reconnect every screen must pick up the new client; a status label fed by one object and RPCs sent through another produced "Connected" with every call failing.
10. **The terminal screen needs its own visible recovery affordance** (status row "— tap to retry" calling force-reconnect); retry buttons that only resend a request into a parked connection are useless.
11. Corollary used throughout `T/`: typed input is **dropped, never queued**, when not connected (3.1), and every in-flight send is tied to a connection epoch.

Additional pitfalls visible in the code:

12. Do not invent `80x24` when the host omits dimensions; it can never match and causes a refit loop.
13. Bound every "resize → mismatch → resubscribe" loop (3 attempts, backoff) — unbounded loops broke gestures and drained battery.
14. Do not resize the PTY when the keyboard opens; do not resize a PTY that is covered by another view; re-assert the size after foreground and after reconnect.
15. Layout `seq` and output `seq` are different domains; filtering snapshots by the layout mark discards valid data.
16. Never send guessed mouse encodings; never send legacy mouse bytes > 126 (not representable as safe text over JSON).
17. Do not answer queries found in a replayed snapshot, and do not send query replies to a host without `terminal.query-reply-input.v1`.
18. Replies and gestures can take the input floor; anything not caused by a deliberate user action must not carry floor-taking semantics.
19. If credit is requested (`outputAck`) every Output unit must eventually be acked, including dropped ones; otherwise the stream stalls. Not requesting it is safe.
20. Empty `terminal.list` once is not proof of emptiness (two consecutive reads).

---

## 10. Native port plan (SwiftTerm + UIKit)

SwiftTerm facts below were read from the repository's `main` branch on 2026-11-19 (`Sources/SwiftTerm/{iOS/iOSTerminalView.swift, Apple/AppleTerminalView.swift, Apple/TerminalViewDelegate.swift, Terminal.swift, TerminalOptions.swift}`; latest tag at that time `v1.99.3`, whose view files were spot-checked for the `terminal` accessor only). Re-check them against whatever version gets pinned:

- `TerminalView` (iOS) is a `UIScrollView` subclass implementing `UITextInput`; `init(frame:font:options:)`, `terminalDelegate`.
- `TerminalViewDelegate`: `sizeChanged(source:newCols:newRows:)`, `send(source:data: ArraySlice<UInt8>)`, `setTerminalTitle`, `hostCurrentDirectoryUpdate`, `scrolled(source:position:)`, `requestOpenLink(source:link:params:)`, `bell(source:)`, `clipboardCopy(source:content:)`, `rangeChanged`, `selectionFinished`, `programStatusChanged`.
- `feed(byteArray:)`, `feed(text:)`, `resize(cols:rows:)` (**also calls `terminal.softReset()`**), `changeScrollback(_:)`, `clearScrollback()`, `scrollUp(lines:)`, `scrollDown(lines:)`, `scroll(toPosition:)`, `scrollPosition`, `canScroll`, `getSelection()`, `selectAll()`, `selectNone()`, `clearSelection()`, `hasActiveSelection`, `installColors(_:)`, `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor`, `selectedTextBackgroundColor`, `minimumContrastRatio`, `setCursorStyle(_:)`, `font` / `setFonts(normal:bold:italic:boldItalic:)`, `inputAccessoryView` (settable; a default `TerminalAccessory` exists), `optionAsMetaKey`, `allowMouseReporting`, `linkReporting`, `controlModifier`, `metaModifier`, `returnByteSequence`, `terminalStateSnapshot()` (dimensions, cursor, `bracketedPasteMode`, cursorStyle, visible rows), `getOptimalFrameSize()`, `sendMouseEvent(...)`, `send(txt:)`.
- `layoutSubviews` → internal `processSizeChange(newSize:)`: `rows = Int(height / cell.height)`, `cols = Int(width / cell.width)`, resizes the terminal (no soft reset) and calls `sizeChanged`. So **the view's bounds decide the grid**.
- `TerminalOptions`: `cols, rows, convertEol, termName, cursorStyle (.blinkBlock…​.steadyBar), scrollback (default 500), enableOsc8Hyperlinks, …`.
- Hardware keys are handled in `pressesBegan`, IME through marked text, both encoding with the terminal's Kitty flags / application cursor state; gesture recognizers exist for tap, double/triple tap, long press, pan-as-mouse, pan-selection. No pinch recognizer.
- `Terminal` exposes `mouseMode`, `isCurrentBufferAlternate`, `applicationCursor`, `bracketedPasteMode`, `keyboardEnhancementFlags`, but on this branch `TerminalView.terminal` is **internal** and there is no public `getTerminal()` (older releases had one). **UNVERIFIED**: the supported way to read alt-screen / mouse mode from outside the view on the version we pin.

### 10.1 Decisions

**D1. Sizing: container-driven, host-confirmed grid.** `TerminalView` lives inside our own `TerminalContainerView`. The container is what Auto Layout sizes; the `TerminalView`'s frame is set **manually** to exactly `cols * cellW` by `rows * cellH` (plus an epsilon smaller than one device pixel so `Int(width / cellW)` cannot round down), where `cols/rows` is the grid the host last confirmed. `sizeChanged` is treated as an echo and never triggers an RPC. This reproduces "the emulator grid is always the PTY grid" and keeps the keyboard from resizing anything.
  - Requested grid = `floor(containerW / cellW + 1e-6)`, `max(8, floor(containerH / cellH + 1e-6))`, no fit below 20 columns; `cellW/cellH` taken from `getOptimalFrameSize()` divided by the current cols/rows, or measured from the `UIFont` (**UNVERIFIED** which matches SwiftTerm's internal `cellDimension` exactly; verify with a unit test comparing `sizeChanged` output to our prediction).
  - Use frame sizing, not `resize(cols:rows:)`, to avoid the soft reset.
  - `auto` mode: frame equals the grid at scale 1, top-left. `desktop` mode: same frame at natural size with `transform = scale(min(1, containerW / (cols * cellW)))`, values ≥ 0.95 snapped to 1, anchor top-left, optional horizontal pan when zoomed.
  - Refit scheduler: one 150 ms debounced task; triggers from 1.4 (`viewDidLayoutSubviews` of the container, `traitCollectionDidChange`/size-class and rotation via `viewWillTransition(to:with:)`, font change, `UIApplication.didBecomeActiveNotification` (forced), connection → connected (forced)); height changes while the keyboard is visible are parked until `keyboardDidHide`.
  - RPC path: subscribe with `viewport`; later `terminal.updateViewport` + update stored subscribe params; on `applied: true` re-layout the frame to the new grid (SwiftTerm reflows its buffer on resize — **UNVERIFIED** that its reflow matches xterm's well enough; if not, resubscribe for a width-correct snapshot); on method-not-found resubscribe. Bounded mismatch loop: 3 attempts, `[0, 750, 3000]` ms, toast on exhaustion.

**D2. Keyboard avoidance without resizing.** Dock (key row) pinned to `view.keyboardLayoutGuide.topAnchor`. Terminal container keeps its full-height constraints; apply `transform.translatedBy(y: -lift)` with `lift` from the formula in 1.5, fed by cursor row / last non-empty row / alt-screen from `terminalStateSnapshot()` (cursor, visible rows) plus our mode mirror (D6). Animate alongside the keyboard notification curve.

**D3. Attach / replay sequence.**
  1. Gate: connected ∧ view laid out ∧ font metrics known ∧ requested grid computed.
  2. `terminal.subscribe { terminal, client, viewport, capabilities: { terminalBinaryStream: 1 } }` — **no `outputAck` in v1** (so no acks, no resume).
  3. `subscribed` → store `streamId`, layout `seq`, `displayMode`.
  4. `scrollback` → build a **new** `TerminalView` off-screen (or reset the existing one — SwiftTerm has `Terminal.resetToInitialState()`, reachable from the view only if public on our pinned version, **UNVERIFIED**; creating a fresh view is the safe route), size it to the host's cols/rows, apply theme/font, suppress outgoing `send` (D7), `feed(text: "\u{1b}[0m" + normalizedSnapshot)` where an alt-screen snapshot is cut to start at its last `ESC[?1049h`, then swap it into the container, restore the reader's distance-from-bottom, re-enable `send`, seed Kitty flags from `kittyKeyboardFlags` (**UNVERIFIED** how to seed SwiftTerm's Kitty state from outside; fall back to feeding `ESC[>{flags}u` after the snapshot).
  5. `data` → `feed(text:)` in arrival order on the main actor; no seq math. Chunks received between `subscribed` and `scrollback` are discarded (the snapshot covers them). A light coalescer (one flush per display link tick, cap 512 KiB) is enough natively.
  6. `resized` with `serialized` → step 4 with `preserveScroll`; without → set the frame for the new grid. Drop stale `resized` by layout seq (rule in 1.3).
  7. `end` / `error` → drop the subscription, run inventory recovery; resubscribe if the handle is still listed and visible.
  8. Reconnect: transport replays subscribe (same request id) → treat the next `subscribed` + `scrollback` as step 3–4. On foreground: unsubscribe + resubscribe visible terminals after ~120 ms to get a fresh snapshot instead of trusting a stale buffer.
  - **UNVERIFIED**: that SwiftTerm renders xterm's serialize-addon output faithfully (SGR, wide chars, wrapped lines, cursor position). This is the first thing to test with real snapshots from a host.

**D4. Input: the terminal view is the first responder; no mirror field.** `TerminalView` already implements `UITextInput` with marked text, so IME composition is held natively and committed text arrives through `send(source:data:)`. This removes the whole DEL-diff mirror (3.2) and its failure modes, and makes hardware keyboards work through SwiftTerm's `pressesBegan` (mode-aware arrows, Kitty protocol, Option-as-Meta). Set `autocorrectionType = .no`, `autocapitalizationType = .none`, `smartDashesType = .no`, `smartQuotesType = .no`, `spellCheckingType = .no`, `keyboardType = .default`.
  - `send(source:data:)` → decode as UTF-8. If the bytes are not valid UTF-8 (legacy mouse reports > 127) **drop** them. Classify (D7), then hand to the `TerminalInputSender`.
  - `TerminalInputSender` (actor, one per connection epoch): implements 3.1 — fail-when-disconnected, optional ordered session (`terminal.openInputSession`, `inputSequence.seq` from 1, window 8) when the host advertises `terminal.ordered-input.v1`, else serial; merges adjacent text up to 256 KiB; control bytes never merge with text; any refusal fails the owner and drops pending input; cancel everything on disconnect or path change; no automatic resend.
  - Scroll to bottom on typed input.
  - Dictation and smart-dash normalisation: map `–`/`—` to `--` in `insertText` (override or filter in our `send` hook).

**D5. Accessory bar: our own `inputAccessoryView`.** Replace SwiftTerm's `TerminalAccessory` with a custom `UIInputView` (`inputViewStyle: .keyboard`) holding a horizontal `UIScrollView`/`UICollectionView` with the keys and order from 3.5, plus a fixed keyboard-dismiss button. Because the accessory is part of the keyboard, also show the same row docked at the bottom when the keyboard is hidden (the reference keeps the row visible at all times).
  - Sticky modifiers: implement the `off/once/locked` reducer (350 ms double tap) ourselves and build the bytes with a Swift port of `buildTerminalShortcutKey` + `encodeTerminalKeyForModes`; for characters typed on the software keyboard while a latch is held, either set SwiftTerm's `controlModifier` / `metaModifier` (its own one-shot Ctrl exists) or intercept in `insertText` and re-encode (Shift/Alt/locked states are ours — prefer our own interception for uniform behaviour).
  - Repeat: `UILongPressGestureRecognizer` (0.4 s) starting a loop that awaits each send's acceptance and then sleeps 45 ms; cancel on touch end, scroll, resign active, tab switch, disconnect.
  - Touch slop 8 pt; the row must not resign first responder.
  - Hardware shortcuts for app actions (not terminal bytes): `UIKeyCommand`s on the view controller for ⌘V paste, ⌘C copy selection, ⌘K clear, ⌘+/⌘− text size, ⌘T new terminal, ⌘W close, ⌘⇧[ / ⌘⇧] switch tab. These go beyond the reference (which maps no ⌘ keys).

**D6. Mode mirror.** Keep a tiny Swift scanner over the output stream (port of `updateMouseModeFromData`, carrying a ≤ 4096-char tail for split sequences) tracking: mouse tracking (9/1000/1002/1003), SGR (1006/1016) and "encoding proven", alt screen (1049/1047/47), DECCKM (1), bracketed paste (2004), `modifyOtherKeys` (`CSI > 4 ; n m`), Kitty flags (push/pop/set). It feeds paste framing, key encoding for accessory keys, scroll routing, keyboard lift and gesture validation, and does not depend on SwiftTerm internals. Where SwiftTerm exposes the same fact publicly (`terminalStateSnapshot().bracketedPasteMode`) prefer it.

**D7. Query replies.** Everything SwiftTerm emits that was not caused by a user event is a reply. Implementation: a flag set around `feed` (if SwiftTerm parses synchronously inside `feed` — **UNVERIFIED**, the current branch has a frame driver/event queue) or, robustly, classify with a Swift port of `isTerminalQueryReply`. Replies → `terminal.send { inputKind: 'query-reply' }` immediately, only if the host has `terminal.query-reply-input.v1` and the terminal is subscribed; otherwise drop. Suppress all output of `send` during snapshot replay.

**D8. Scrolling and pointer.** Disable SwiftTerm's own pan-as-mouse routing if it cannot be made to follow the rules in 5.1 (`allowMouseReporting = false` and send our own reports), and install one `UIPanGestureRecognizer`:
  - route per row using D6: unproven encoding → local scroll; wheel-capable mouse mode → SGR wheel reports at the touch cell; alt screen → arrows (SS3 under DECCKM); else local `scrollUp/scrollDown(lines:)` (or let the `UIScrollView` scroll natively for the normal buffer — preferable for native feel, as long as alt-screen and mouse modes are intercepted).
  - cap 32 sequences per event; token bucket 64 / 120 per s; drop gesture bytes older than 250 ms; never queue across disconnect.
  - Tap: OSC 8 link → plain URL → file path → mouse click (press+release, ordered after pending text) → `becomeFirstResponder()`. Use `requestOpenLink` for OSC 8 and our own detector over the tapped row for plain URLs / paths (**UNVERIFIED** how much `linkReporting = .implicit` already covers).
  - Selection: use SwiftTerm's long-press selection + `UIEditMenuInteraction` (Copy / Select All), `getSelection()` → gutter strip (if host setting) → `UIPasteboard`; haptics via `UISelectionFeedbackGenerator` / `UINotificationFeedbackGenerator`.
  - Pinch: `UIPinchGestureRecognizer` on the container — transient `transform` during the gesture clamped to 8–26 pt apparent size; on end snap to a whole point (≥ 1 pt change), set `terminalView.font`, recompute cell metrics, refit (D1), persist.
  - Pointer devices: `UIHoverGestureRecognizer`/scroll events (`allowedScrollTypesMask = .all`) routed through the same scroll logic; swallow pinch-scroll.

**D9. Paste and images.** Override paste (edit menu, ⌘V, accessory Paste key) with our own: bracketed framing by D6 with ESC → U+241B and `\r` line endings, 64 KiB UTF-8-safe chunks, stop on first refusal, close the frame if partially sent, 16 MiB cap. If the pasteboard has an image and no text (`UIPasteboard.general.hasImages`): downscale (long edge 2000, ≤ 3.75 MB, JPEG 0.85 on white via `UIGraphicsImageRenderer`), upload with the clipboard upload RPCs, then send the bracketed, agent-formatted path + space. Same back end for `PHPickerViewController` (photo) and `UIDocumentPickerViewController` (file). Also accept drag-and-drop of images on iPad (`UIDropInteraction`) — beyond the reference.

**D10. Appearance.** `installColors` with the 16 ANSI colours from the tab's `terminalTheme.theme` merged over the Tokyo Night defaults; `nativeBackgroundColor`/`nativeForegroundColor`/`caretColor`/`selectedTextBackgroundColor` likewise; `minimumContrastRatio` = host value or 4.5 (light bg) / 3 (dark bg); container background = theme background. Cursor `.steadyBar`. `TerminalOptions(scrollback: 5000)`. Fonts: `UIFont.monospacedSystemFont(ofSize: 13, weight: .light)` default on phone (15 / `.regular` on iPad), Menlo, Courier New, bundled JetBrains Mono / Fira Code / Geist Mono registered with `CTFontManagerRegisterFontsForURL` (ship TTF/OTF, not the woff2 subsets), and Symbols Nerd Font Mono as a cascade fallback (`UIFontDescriptor.AttributeName.cascadeList`). Line-height options 1 / 1.15 / 1.3: **UNVERIFIED** whether SwiftTerm exposes line spacing; if not, ship v1 with 1.0 only. ZWJ-emoji-as-one-wide-cell width rule and `⏺` text presentation: test against SwiftTerm's width tables; if `⏺` renders as emoji, rewrite `U+23FA (FE0F)?` → `U+23FA U+FE0E` in the feed path as the reference does.

**D11. Tabs and lifecycle.** Model `TerminalSession` keyed by handle, owned by a `TerminalTabController` keyed by tab id. On every tabs snapshot: if a tab's `terminal` changed (respawn) → tear down the old session (unsubscribe, discard view, input sender, modes, latches) and attach the new handle; advertise `terminal.host-pane-respawn.v1` only once this is implemented. Keep ≤ 3 live `TerminalView`s (LRU), stream only visible ones, snapshot again on re-show. `pending-handle` → spinner + bounded polling. `end` → inventory double-check (750 ms) → remove or resubscribe.

### 10.2 Behaviour → API map and priority

| Behaviour (section) | SwiftTerm / UIKit technique | Priority |
|---|---|---|
| Host-confirmed grid, manual frame sizing (1.1–1.3) | container view + manual `frame`; ignore `sizeChanged` for RPC | **v1 must** |
| Viewport in subscribe; `updateViewport`; bounded mismatch loop (1.3) | RPC layer + 150 ms debounce task | **v1 must** |
| `auto` / `desktop` display mode + toggle (1.1, 1.6) | `terminal.setDisplayMode`; `CGAffineTransform` scale in desktop mode | **v1 must** (toggle UI can be minimal) |
| Keyboard does not resize PTY; cursor-aware lift (1.5) | `keyboardLayoutGuide` + transform; `terminalStateSnapshot()` | **v1 must** (simple full lift acceptable first, cursor-aware next) |
| Rotation / size-class / foreground / reconnect refits (1.4) | `viewWillTransition`, `didBecomeActive`, connection observer | **v1 must** |
| Snapshot replay into a fresh emulator, alt-screen trimming (2.1–2.3) | new `TerminalView` + `feed(text:)`, swap | **v1 must** |
| Live output in order, stale-subscription fencing (2.2) | per-subscription generation token; main-actor feed | **v1 must** |
| Reconnect → fresh snapshot (2.5) | transport replay + D3 | **v1 must** |
| Foreground resubscribe (2.5) | `didBecomeActive` + 120 ms | **v1 must** |
| Typed text, IME, Return (3.2) | `TerminalView` as first responder; `send(source:data:)` | **v1 must** |
| Ordered, non-queued, non-retried delivery (3.1) | `TerminalInputSender` actor | **v1 must** (serial mode first; ordered session when capability present) |
| Query replies with `inputKind` + capability gate (2.6) | D7 classifier | **v1 must** (at minimum: drop replies when unsupported, suppress during replay) |
| Accessory row with Esc/Tab/Ctrl/Alt/Shift latches/arrows/Ctrl combos, repeat (3.5) | custom `inputAccessoryView`, long-press repeat | **v1 must** (default layout; reordering later) |
| Mode-aware key encoding for accessory keys (3.4) | D6 mirror + Swift port of encoders | **v1 must** for DECCKM arrows; Shift/Ctrl+Enter rules **v1 must** for agent use |
| Bracketed, sanitised, chunked paste (3.3) | override `paste(_:)`, D9 | **v1 must** |
| Scroll routing: scrollback vs wheel vs arrows (5.1) | pan recognizer + D6 | **v1 must** (momentum polish later) |
| Tap to focus keyboard; URL tap (5.2) | tap recognizer, `requestOpenLink`, `UIApplication.open` | **v1 must** |
| Selection + copy (5.3) | SwiftTerm selection, edit menu, `UIPasteboard` | **v1 must** |
| Host theme + default palette, cursor bar, 5000 scrollback (6) | `installColors`, `TerminalOptions` | **v1 must** |
| Font size setting 8–26 pt, default 13 (6.1) | `terminalView.font` + refit | **v1 must** |
| Tab ↔ handle binding, respawn rebind, stream end handling (7) | D11 | **v1 must** |
| Connection recovery affordances (9: 7–10) | transport layer + "tap to retry" in the terminal header | **v1 must** |
| Image / file paste and attach (8.1) | pasteboard image, `PHPicker`, upload RPCs, bracketed path | **v1 should** (high value for Claude Code/Codex) |
| Pinch to change font size (1.6) | `UIPinchGestureRecognizer` | v1.1 |
| File-path tap → open file tab (5.2) | detector + file tab navigation | v1.1 |
| Mouse click / drag reporting to TUIs (5.2, 5.3) | `sendMouseEvent` or own SGR encoder | v1.1 |
| Smart agent keys (8.3) | key row section driven by tab `agentStatus` | v1.1 |
| Custom keys + layout editor (4.1, 3.5) | `UserDefaults`, settings screen | v1.1 |
| Quick commands sheet (4.2) | host settings RPCs + terminal create | v1.1 |
| Font family / weight / line-height pickers, bundled fonts (6.1) | CoreText registration | v1.1 |
| Split panes (1.7) | two containers, per-pane viewport | later |
| Output credit + resume (2.4, 2.5) | `terminal.ackOutput`, UTF-16 unit counting of fed text | later (only worth it on slow relay links) |
| OSC 52 clipboard write (2.6) | `clipboardCopy(source:content:)`, replay-suppressed | later |
| Lease-only stream under native chat (7.6) | `mobileInputLeaseOnly` capability | when the chat/terminal toggle ships |
| Auto-restore-fit setting on the phone (1.1) | `terminal.get/setAutoRestoreFit` | later |
| Hardware ⌘ shortcuts, drag-and-drop images, native scroll physics | `UIKeyCommand`, `UIDropInteraction`, `UIScrollView` | beyond reference; cheap wins after v1 |

### 10.3 UNVERIFIED items to resolve first

1. Public access to terminal state (alt screen, mouse mode, Kitty flags) on the SwiftTerm version to be pinned; D6 avoids the dependency.
2. Whether `feed` parses synchronously (affects D7 and snapshot-swap timing).
3. Exact cell metrics API (D1) and line-spacing support (D10).
4. Fidelity of xterm serialize-addon snapshots when replayed into SwiftTerm, and of SwiftTerm's reflow on width change.
5. Seeding Kitty keyboard flags after a snapshot.
6. Host behaviour around pane respawn (what the old stream receives) and around `displayMode` when two phones are attached.
7. Hardware Ctrl-chord behaviour of the reference native build (irrelevant to the port, which gets them from SwiftTerm).
8. Whether BEL should produce any phone-side feedback (the reference has none; `bell(source:)` could drive a light haptic).
