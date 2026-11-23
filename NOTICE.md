# Notice

## A community project

orca-ios is a community-maintained iPhone client for [Orca](https://github.com/stablyai/orca).

It is **not** made, maintained, reviewed or endorsed by Orca's authors (Lovecast Inc. / Stably).
Please report problems with this app here, at
[github.com/huami1314/orca-ios/issues](https://github.com/huami1314/orca-ios/issues), not to the
Orca project.

"Orca" and the Orca logo belong to their owners. They are used here only to say which desktop app
this client works with.

## License and policies

This app follows its upstream, Orca:

- **License:** MIT, the same license as Orca. See [LICENSE](LICENSE). Interface copy, translations
  and design taken from the official Orca mobile app keep Orca's copyright notice
  (Copyright (c) 2026 Lovecast Inc.).
- **Privacy policy and terms:** the app follows Orca's [privacy policy](https://orca.dev/privacy)
  and terms. It talks only to the Orca desktop you pair it with, and, if you turn on push
  notifications, to the community push gateway that relays your desktop's notifications to Apple.

## Third-party software

| Project | License | Used for |
| --- | --- | --- |
| [Orca](https://github.com/stablyai/orca) | MIT | Interface copy, translations, design, protocol |
| [Ghostty](https://github.com/ghostty-org/ghostty) via [libghostty-spm](https://github.com/Lakr233/libghostty-spm) | MIT | Terminal |
| [MarkdownView](https://github.com/Lakr233/MarkdownView) | MIT | Chat and file Markdown |
| [Litext](https://github.com/Lakr233/Litext) | MIT | Text layout (via MarkdownView) |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | MIT | Math in Markdown (via MarkdownView) |
| [LRUCache](https://github.com/nicklockwood/LRUCache) | MIT | Caching (via MarkdownView) |
| [DisplayLink](https://github.com/Lakr233/DisplayLink) | MIT | Animation timing (via MarkdownView) |
| [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 | Data structures (via dependencies) |
| [Lucide](https://github.com/lucide-icons/lucide) | ISC | Icons |
| [tweetnacl-js](https://github.com/dchest/tweetnacl-js) | Unlicense | Push gateway signatures |
