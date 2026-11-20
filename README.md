# DogEarBooks for KOReader

Decorative bookmarks for KOReader: choose a charm, ribbon, or corner image, then use KOReader’s normal page bookmarks. This fork packages **DogEarBooks 1.6** with browsable source code and installation instructions, including the confirmed PageScribe combination on a **Viwoods AiPaper Mini**.

DogEarBooks works independently. PageScribe is optional; when using both, install **PageScribe 0.12.1 or newer**.

## Install

1. Download **dogearbooks.koplugin.zip** from [Releases](https://github.com/seshakiran/dogearbooks.koplugin/releases/latest).
2. Extract it and copy the whole **dogearbooks.koplugin** folder into KOReader’s **plugins** directory.
3. Fully close and reopen KOReader. Enable **dogearbooks** in the plugin manager if needed, then restart again.
4. Open a book and find **dogearbooks** in the **Typesetting** menu.

The exact layout must be:

```text
koreader/
└── plugins/
    └── dogearbooks.koplugin/
        ├── main.lua
        ├── _meta.lua
        ├── dogearbooks_gallery.lua
        └── ...
```

Do not copy only the ZIP, rename the plugin folder, or nest it twice. GitHub’s automatic “Source code” ZIP is a repository snapshot; the release asset named **dogearbooks.koplugin.zip** is the ready-to-install package. Existing users should back up any custom images before replacing their plugin folder.

## Add and use a bookmark

1. Open a book.
2. Tap the **very top-right corner with your finger** to bookmark the current page. Tap it again to remove the bookmark.
3. Open KOReader’s top menu → **Bookmarks** to revisit a saved page.
4. Choose a design under **Typesetting → dogearbooks → Charm Library** or **Folders**. Use **Charm Studio** to adjust size and position, then save.

DogEarBooks changes the image shown on an already bookmarked page. Choosing an image in the gallery does not create a page bookmark. Gesture assignments can vary by device and user configuration.

## Using DogEarBooks with PageScribe

Install [PageScribe 0.12.1 or newer](https://github.com/seshakiran/pagescribe.koplugin/releases/latest) alongside this plugin. Keep their folder names:

```text
koreader/plugins/dogearbooks.koplugin/
koreader/plugins/fingerink.koplugin/    ← PageScribe’s retained installation name
```

PageScribe provides handwriting and its floating toolbar. DogEarBooks decorates KOReader’s native page bookmarks. Each plugin can be installed and used on its own.

For the confirmed reading/bookmark workflow:

1. In PageScribe, choose **Read**.
2. Close the toolbar with **×**, leaving the small handwriting launcher visible.
3. Tap the page’s **top-right corner with your finger**.
4. Check the chosen charm or KOReader’s **Bookmarks** list.

An expanded PageScribe toolbar uses the first outside tap to close itself, so close it before using the corner shortcut. Finger behavior in drawing modes depends on PageScribe’s selected input mode; the steps above use Read mode.

### Why PageScribe 0.12.1 is needed

Earlier PageScribe versions could block the bookmark action even in Read mode with the tray closed. KOReader processes the corner tap, then dispatches a separate **ToggleBookmark** event. Because PageScribe’s floating toolbar was the top window, the action did not reach the reader.

The [PageScribe fix](https://github.com/seshakiran/pagescribe.koplugin/commit/f098bcd) relays those reader actions through KOReader’s active-widget dispatch while preserving dialog precedence. Input is not forwarded twice, and broadcast/lifecycle events are not duplicated.

**The compatibility fix is in PageScribe; DogEarBooks’ runtime code is unchanged.** Reinstalling DogEarBooks alone will not fix an older PageScribe installation. Native bookmarking with both plugins enabled was confirmed on a Viwoods AiPaper Mini on November 20, 2026. Other devices and KOReader builds still need testing; this does not claim universal compatibility.

## Collections and customization

Use **Folders** to browse collections and **Favorites** to keep preferred designs. Hold a preview to add or remove a favorite; tap it normally to choose it. **Day/Night Pair** supports separate designs and optional automatic switching with KOReader’s night mode.

Add supported SVG, PNG, BMP, JPG, JPEG, or alpha images to a collection folder or `custom_icons/`. The original feature guide, collection details, and customization instructions are preserved in [the upstream README](docs/UPSTREAM_README.md) and the plugin’s own README.

## Troubleshooting

- **No dogearbooks menu:** check the exact installation path, enable the plugin, restart KOReader, and open a book.
- **Corner tap does nothing with PageScribe:** update PageScribe to 0.12.1 or newer, restart, choose Read, and close its tray. Check the reader’s top-right tap assignment under KOReader’s gesture settings.
- **Page is in Bookmarks but no image appears:** select a design and use Charm Studio to check size and position. Try a day-mode design on a light page.
- **Page is absent from Bookmarks:** the native bookmark action did not add it; selecting another decorative image will not create it.

For a report, include your device, KOReader version, both plugin versions, whether the PageScribe tray is open, and whether the page appears in KOReader’s Bookmarks list. Share error text without account credentials or private settings files.

## Source and packaging

The installable source lives in [dogearbooks.koplugin](dogearbooks.koplugin/). Run `./scripts/package.sh` to build `dist/dogearbooks.koplugin.zip`. CI parses the Lua files with Lua 5.1 and verifies the package inventory; device behavior is a separate manual check.

The original upstream ZIP is retained at the repository root. [Provenance](docs/provenance.json) records the upstream revision and archive checksum used for the device-tested package.

## Credits and license

DogEarBooks is [Wolfazzo’s fork](https://github.com/Wolfazzo/dogearbooks-koreader) of [Book Nook Charms by KitanaCode](https://github.com/KitanaCode/booknookcharms.koplugin). The original project credits cat bookmarks to **u/AggravatingDebt4621**. This fork adds source packaging and PageScribe integration documentation; it retains upstream’s runtime, artwork, history, and attribution.

DogEarBooks is distributed under the **MIT license**; see [LICENSE](LICENSE) and the included plugin license. PageScribe is a separate **AGPL-3.0** project and remains in its own repository and package.
