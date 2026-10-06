# 🍻 KOTavern

**A [SillyTavern](https://github.com/SillyTavern/SillyTavern)-style AI chat client for [KOReader](https://github.com/koreader/koreader).** 📖

KOTavern is a SillyTavern "clone" for e-ink: manage characters and personas, then chat with any OpenAI-compatible API, straight from your reader. It aims for SillyTavern parity where it makes sense on a KOReader device (card format, samplers, World Info, regex, swipes, reasoning blocks), so your existing characters and habits carry over.

---

## 📋 Requirements

- 📱 KOReader (any device where plugins are supported: Kindle, Kobo, PocketBook, Android, desktop emulator...)
- 🌀 `curl` available on the device (used for streaming and for updates)
- 🌐 Network access to your chosen API endpoint
- 🔑 An API key for hosted providers (not needed for local servers)

## 📦 Installation

### From a release (recommended)

1. Download `kotavern.koplugin-<version>.zip` from the [Releases](https://github.com/akachiina/kotavern.koplugin/releases) page.
2. Extract it so you end up with a `kotavern.koplugin` folder.
3. Copy that folder into KOReader's `plugins/` directory:

   | Platform | Path |
   | --- | --- |
   | Kindle | `koreader/plugins/` |
   | Kobo | `.adds/koreader/plugins/` |
   | Android | `koreader/plugins/` (in the KOReader data folder) |
   | Linux (desktop) | `~/.config/koreader/plugins/` or `koreader/plugins/` |

4. Restart KOReader.

### From source

```bash
git clone https://github.com/akachiina/kotavern.koplugin.git
```

Copy the cloned folder into KOReader's `plugins/` directory (the folder name must stay `kotavern.koplugin`) and restart KOReader.

## 🚀 Getting started

1. Open the KOReader navigation menu (KOTavern sits at the bottom, next to ZenPM)
2. Add a **connection**: pick a provider preset (or enter a custom base URL), paste your API key, and choose a model.
3. Create or import a **character**, and optionally a **persona** or/and **preset**.
4. Start chatting! 💬

> 💡 The base URL can be given with or without `/chat/completions`. KOTavern adds it when needed.

## 🔄 Updating

Check for updates from the kebab menu (**Check for updates**) or from Settings → **Updates**. Pick a channel:

- 🟢 **Stable**: the latest non-prerelease GitHub Release.
- 🧪 **Commits**: a snapshot of the latest `main` branch.


## 🤝 Contributing

Issues and pull requests are welcome! If you add or change user-facing strings, please update the files in `locales/` as well.

## 🙏 Acknowledgements

- [SillyTavern](https://github.com/SillyTavern/SillyTavern): the project KOTavern is modeled on. Feature set, behavior and character-card format follow it. KOTavern is an independent project and is not affiliated with SillyTavern.
- [KOReader](https://github.com/koreader/koreader): the platform that makes all of this possible.

## 📄 License

[MIT](LICENSE).
