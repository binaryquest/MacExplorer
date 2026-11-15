# Install or update a translation

Explorer reads translations from your user Library when it starts. You can add a language or override an existing one without rebuilding Explorer or editing the signed application.

## Install a ready-made translation

English is included in Explorer. Open the disk image and double-click **Install Explorer.command**. It copies Explorer to **Applications** and adds any missing language packs for the current user. Existing packs are kept so custom translations survive reinstalling.

For manual installation, drag **Explorer.app** onto **Applications** in the disk image. Run **Open Language Packs Folder.command** and copy the desired `.lproj` folders from the image’s **Localizations** folder into the Finder window that opens. Reopen Explorer to load them. **Localizations/TRANSLATING.txt** provides an offline guide for new translations.

Explorer stores installed packs in `~/Library/Application Support/Explorer/Localizations/`. You can also add packs from **Settings → General → Install Language Packs…** or copy them there using Finder. Replacing the app in **Applications** keeps those packs. To remove both, run **Uninstall Explorer.command** from the disk image. It moves the app and the installed language packs to Trash and keeps your preferences.

A local build includes a separate `Localizations` folder beside `build/Explorer.app`. Explorer finds those packs when launched in place. A user-installed pack takes precedence over a same-language pack beside the app. Keep the folder beside the app or install it before moving the app elsewhere.

Chinese is available in Simplified and Traditional variants. The Serbian pack uses Cyrillic, and the Norwegian pack uses Bokmål. The Arabic, Hebrew, and Urdu packs translate text. Selecting them does not explicitly change the layout direction of AppKit controls.

## Create a translation

1. In Finder, press **⌘⇧G** and go to `~/Library/Application Support/`. Create the folders `Explorer/Localizations` there if needed.
2. In `Localizations`, create a folder named for the language’s BCP 47 identifier with an `.lproj` extension. Examples are `it.lproj` for Italian, `pt-BR.lproj` for Brazilian Portuguese, and `zh-Hant.lproj` for Traditional Chinese.
3. Save a UTF-8 plain text file named `Localizable.strings` in that folder. Check that the filename ends in `.strings` and that the editor uses straight double quotes around keys and values.
4. Quit Explorer with **⌘Q** and reopen it. Open **Settings → General → Interface language** to pick the new language. After changing the selection, click **Apply and Restart**. Automatic mode uses the primary macOS language and can match a language or script when there is no exact regional match.

For example, `Localizations/it.lproj/Localizable.strings` can start with just these entries:

```text
"About Explorer" = "Informazioni su Explorer";
"Settings…" = "Impostazioni…";
"Interface language" = "Lingua dell’interfaccia";
"Open in %1$@" = "Apri in «%1$@»";
"%lld items" = "Elementi: %lld";
```

The current keys are in [the English catalog](../Sources/ExplorerCore/Resources/en.lproj/Localizable.strings) and [its count keys](../Sources/ExplorerCore/Resources/en.lproj/Localizable.stringsdict). You can also find both files in an installed build by choosing **Show Package Contents** for Explorer.app in Finder and browsing to `Contents/Resources/en.lproj`. Use those files as a reference or copy the English `Localizable.strings` to your own language directory before editing. Use one entry per key. To check a file’s syntax in Terminal, run:

```sh
plutil -lint "$HOME/Library/Application Support/Explorer/Localizations/it.lproj/Localizable.strings"
```

## Keep a translation compatible with Explorer updates

- Translate only the value on the right. The key on the left is the identifier, even when it looks like an English sentence. Keep punctuation, spaces and escapes such as `\n` in the key exactly as they appear in the English catalog.
- Add new keys as you translate them. A partial file works immediately. Explorer checks installed translations for the chosen locale, then falls back to the English text. Obsolete keys are ignored, and missing or empty entries use the fallback. An existing file can stay in place when you update Explorer.
- Copy placeholders such as `%1$@` and `%2$@` exactly. You can move them to suit your language. In a formatted value, write a literal percent sign as `%%`. Explorer uses the fallback if a formatted value drops, adds, or changes a placeholder.
- For count keys, put the entry in your external `Localizable.strings` with exactly one `%lld`. Use wording that works for any number, such as “Elementi: %lld”. For different plural forms, put the count key in a `Localizable.stringsdict` file beside your translation instead. Copy the structure from the English count catalog, keep the `count` variable and the `lld` type, and supply the plural categories your language uses (`zero`, `one`, `two`, `few`, `many`, or `other`). Include `other` and use at most one `%lld` per form. Explorer chooses the form for your language. System-owned panels and permission dialogs use macOS localization.
- Optionally add a `LocalizationCredit.strings` file alongside the translation with entries such as `"Title" = "Traduzione italiana — Your Name";` and `"URL" = "https://github.com/your-username";`. Explorer displays it as a link in **About Explorer**.

To remove an override, move its `.lproj` folder out of `Localizations` and relaunch. If the manually selected language is no longer available, Explorer uses Automatic.

## Contribute a translation

Add or update the language directory in [Localizations](../Localizations). Only English belongs in the application resources. When adding interface text to Explorer, add its key to the English catalog and keep existing keys stable when editing English wording. If the meaning changes, use a new key and let older translations fall back to English until they are updated.
