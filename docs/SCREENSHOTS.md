# Demo screenshots

The README images show the real interface using generated sample files and fictional drive capacities, network shares, and cloud accounts. No personal drive listing is used.

Build the separate demo app:

```sh
zsh scripts/demo.sh
open ".build/Explorer Demo.app"
```

The script prints the temporary sample folder. The demo opens with This Mac, Projects, and Pictures tabs, uses a separate bundle identifier and preferences, and disables the global shortcut. Normal builds do not enable demo mode.

In the demo, use **File → Export Demo Screenshot** (⇧⌘S) to save the window to `docs/images`. The filename is chosen from the current view: `this-mac.png`, `search.png`, `dual-pane.png`, or `files.png`.

To recreate the README views:

1. Export the initial **This Mac** view.
2. Select **Projects**, search for `design`, and export the search results.
3. Close search, enable dual panes with ⇧⌘D, and open the generated **Pictures** folder in the right pane. Use medium icons (⌘2) on the left and large icons (⌘3) on the right, then export.

Stay inside the generated sample folders while taking screenshots. The demo still browses the real filesystem if you navigate elsewhere. Review each image before publishing it.

Quit the demo before rebuilding it. Its app bundle is inside ignored `.build`; its sample files remain in the printed temporary folder and can be removed when finished. The regular app remains at `build/Explorer.app`.
