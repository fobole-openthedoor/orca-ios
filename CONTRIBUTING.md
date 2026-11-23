# Contributing

Issues and pull requests are welcome.

## Workflow

1. Fork, then branch from `main`: `feat/<topic>` or `fix/<topic>`.
2. Keep each pull request to one change. CI must pass: OrcaCore tests, an app build, and the gateway tests.
3. Pull requests are squash-merged; the pull request title becomes the commit.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): subject`, in English, imperative,
lower case, no trailing period. CI checks them on pull requests.

| Type | For |
| --- | --- |
| `feat` | a new feature |
| `fix` | a bug fix |
| `perf` | faster or lighter, same behaviour |
| `refactor` | code change with no behaviour change |
| `style` | visual polish with no behaviour change |
| `docs` | README, NOTICE, docs |
| `test` | tests only |
| `build` / `ci` | project, scripts, workflows |
| `chore` | anything else |

Scopes follow the app's areas: `chat`, `composer`, `session`, `home`, `host`, `workspace`, `tasks`, `scm`,
`browser`, `automations`, `accounts`, `bots`, `settings`, `push`, `pip`, `live-activity`, `gateway`, `app`.

Examples:

```
feat(chat): quote selected words into the next message
fix(push): open the workspace from a tapped notification without crashing
```

## Local checks

```sh
cd packages/OrcaCore && swift test
xcodegen && xcodebuild -project Orca.xcodeproj -scheme Orca -destination 'generic/platform=iOS Simulator' build
(cd gateway && npm ci && npm test)
(cd gateway-worker && npm ci && npm test)
```

## Releases

Bump `MARKETING_VERSION` in `project.yml`. When that reaches the default branch and no release `vX.Y.Z` exists yet, the Release workflow tags it, builds an unsigned IPA and publishes the release. Pushing a `vX.Y.Z` tag does the same.
