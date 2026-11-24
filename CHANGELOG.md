# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.3] - 2026-11-24

### Added

- Delete a workspace from its long-press menu; a folder workspace leaves Orca and stays on disk.
- Child worktrees show under their parent, folding and unfolding from a count on the parent row.
- The two-line Picture in Picture scrolls one row at a time when three or more agents work, and shows
  each agent's total tokens.

### Fixed

- Scrolling up a chat jumped and showed blank screens.
- A project's workspace count didn't drop after one was deleted.

## [0.1.2] - 2026-11-24

### Fixed

- A crash, and blank gaps in a chat, when a reply grew while its row was still being prepared.
- The chat flickering while rows kept re-measuring each other.
- Stopped subagents and workers stayed in the toolbar above the composer.

## [0.1.1] - 2026-11-24

### Added

- Subagents and Orca workers in chat, grouped under their parent in workspace and agent lists.
- An optional two-line Picture in Picture that cycles through working agents on every paired desktop.
- Terminal agent sessions open as a read-only chat.

### Fixed

- A reply that arrived whole could stop halfway on screen until the chat was reopened.
- A notification about the workspace on screen still showed, and tapping it opened the workspace again.
- A desktop could stay on loading after its connection dropped mid-refresh.
- Picture in Picture opens on leaving only for the chat's own turn, not for a subagent left running.

## [0.1.0] - 2026-11-24

### Added

- Native Swift and UIKit client for Orca on iOS 26: pairing, Feed, Bots, Agents, Usage, Automations,
  workspaces and tabs, a Ghostty terminal, source control and pull requests, Tasks, browser tabs and settings.
- Live Activities and the Dynamic Island, Picture in Picture for chats and terminals.
- Push notifications through a community gateway on Cloudflare Workers.
- Chat: quote, `/btw` side questions, send-or-queue, streaming thoughts and replies, tool calls that expand in
  place, a context usage ring, tappable file paths.
- Composer: paste and drop attachments, photos and videos picked in place, `/` commands and `@` file mentions.
- Settings › Orca iOS: sending, tips, hidden tabs, Picture in Picture and Live Activities.
