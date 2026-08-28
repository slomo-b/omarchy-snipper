# Snipper — Omarchy Bar Widget (screen snip + OCR)

A fully standalone **Omarchy shell bar widget**: a small pill in the top bar
(clicking it opens a polished keyboard panel). The panel *is* the whole
app — capture, OCR and clipboard run right there, no separate process.

Pick a screen area → its **text (or image) is copied to the clipboard** via
local OCR (`tesseract`).

> This repo is the Omarchy plugin only. The **Windows desktop app** (Tauri /
> SvelteKit) lives in the separate **`slomo-b/snipper`** repo and is unaffected
> by this plugin.

## Features

- **Snip it!** (panel button): select an area on the full-screen overlay —
  the panel grabs the screen with `grim`, you drag a box, the region is cut via
  ImageMagick and recognized with `tesseract`. Text lands on the clipboard
  (`wl-copy`) and appears in the panel. If no text is recognized, the image is
  copied instead.
- **Text / image mode**: toggle the extraction mode in the panel header
  (text = OCR, image = copy the raw region).
- **Copy text**: re-copies the latest result
  (`omarchy-clipboard-paste-text --copy-only`).
- **History**: the last entries (persisted in
  `~/.local/state/snipper/history`), scrollable inside a fixed area; click an
  entry to re-copy it. "Clear history" empties it.
- **Localized UI**: follows the system locale (`de*` → German, otherwise
  English). The call-to-action stays **"Snip it!"** in both.

Built on Omarchy's standard bar-widget + `KeyboardPanel` structure.

## Requirements (present on Omarchy)

- `omarchy-capture-screenshot` / `omarchy-capture-region` (Omarchy bins)
- `grim`, `convert` (ImageMagick), `wl-copy` (Wayland clipboard)
- `tesseract` (OCR) — engine language via the panel `lang` (`eng` default)
- German OCR: `sudo pacman -S tesseract-data-deu`, then set `lang` to
  `eng+deu` / `deu` in the panel.

## Install

```bash
omarchy plugin add https://github.com/slomo-b/omarchy-snipper.git --enable
```

The marker is added to the **center** section (`defaultSection`). Move it with
`omarchy bar move`.

## Keyboard shortcut (optional, host-specific)

Like any bar widget, the pill toggles the panel on click. To open/toggle it
with a global key (e.g. `SUPER + ALT + S`), add a Hyprland binding on the host:

```lua
-- ~/.config/hypr/bindings.lua
SUPER+ALT+S = omarchy-shell shell toggle io.github.slomo-b.snipper '{}'
```

## Repo layout

`omarchy plugin add` needs `manifest.json` **at the repo root** — that is the
case here, so the repo is directly installable:

```
omarchy-snipper/
├── manifest.json      # plugin manifest (schemaVersion 1, bar-widget)
├── BarWidget.qml      # bar pill (renders the SVG cuttermesser icon, tinted)
├── Panel.qml          # the full app: snip overlay, OCR, clipboard, history
└── assets/
    └── cutter-knife.svg
```

## Develop / validate

```bash
omarchy plugin validate .            # schema check (exit 0 = ok)
# local hot development:
cp -r . ~/.config/omarchy/plugins/io.github.slomo-b.snipper/
omarchy-shell shell rescanPlugins
# NOTE: after editing the QML, a full `omarchy restart shell` is needed for
# bar-widget changes to show (hot reload alone does not rebuild the bar pill).
```

## Notes

- On Wayland only one item sits on the clipboard at a time; text wins over the
  image. If no text is recognized, the image is copied instead.
- The plugin is self-contained on Omarchy; it does not run or require the
  Tauri app.

## Security & trust

Omarchy runs bar plugins as unsandboxed code inside the long-lived
`omarchy-shell` process, with your user rights. That is how the platform works
— a sandbox would remove the screen/clipboard/OCR access the tool needs. To
make trusting this plugin easy, here is exactly what it does (so you can review
before enabling):

**External commands it runs — all local, no network:**
- `grim` — capture the current screen
- `convert` (ImageMagick) — crop the selected region
- `tesseract` — OCR, runs on your machine (text never leaves it)
- `wl-copy` — put text/image on the clipboard
- Omarchy bins: `omarchy-capture-screenshot` (via the bar), `omarchy-clipboard-paste-text`, `omarchy-notification-send`

**What it touches:**
- Only files under `~/.local/state/snipper/` (history, a temp capture, a log).
- No system directories, no `/etc`, no services, no autostart.

**What it does NOT do:**
- No network requests — no telemetry, no data leaves your machine.
- No `sudo`, no system changes, no persistent installs.
- It never reads your secrets, keys, or tokens.
- OCR output and history text are shell-quoted / passed via stdin, so
  recognized or pasted text cannot inject shell commands.

**Review before enabling** (the whole plugin is ~5 small files):

```bash
git clone https://github.com/slomo-b/omarchy-snipper && ls
```

Releases are exact git tags (e.g. `v0.3.0`), so a reviewed version can be pulled
and compared. This mirrors Omarchy's own guidance: inspect the few files, then
run `omarchy plugin add`.

## License

MIT. See `LICENSE`.