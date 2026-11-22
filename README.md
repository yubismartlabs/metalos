# MetalOS

[Source repository](https://github.com/yubismartlabs/metalos)

Formerly NXStudio. Existing `.nxstudio` library folders, preferences, Keychain entries, and the macOS bundle identifier are retained for compatibility.

A native SwiftUI macOS game launcher with a full-screen, controller-driven library and a local NXNative build backend. macOS 14+ for the launcher. Running NXNative games requires Apple silicon and the macOS/Xcode/dependencies specified by your checkout.

## Run

```sh
swift run MetalOS
```

Build an ad-hoc signed Mac app:

```sh
./scripts/package-app.sh
open dist/MetalOS.app
```

The app is unsigned for distribution (ad-hoc signing only). Developer ID signing and notarization are required for normal public distribution. No third-party Swift packages are required.

## First launch and NXNative

On first launch, MetalOS opens a full-screen setup page. Choose the folder that will hold your Switch game folders and MetalOS data. The app creates `.nxstudio/` there for its library, artwork, and installed engines. PS2 disc images may stay anywhere and are added by reference. The setup is one-time; open the selected folder later in **Settings → Library Folder**.

In **Settings → Engine**, install the [Yubismartlabs NXNative fork](https://github.com/yubismartlabs/nxnative) or choose an existing custom checkout. MetalOS checks the current requirements and shows which ones are ready. If it can install missing tools and Python packages with Homebrew, it asks before doing so. Requirements that need manual setup, such as Xcode or Homebrew itself, are explained there. The managed engine and Python environment live under `<library>/.nxstudio/Engines/`.

Add a Switch game by choosing its base file, then optionally an update and DLC files. MetalOS reads the base filename for the game title, copies the selected packages into a new game folder under the library, then builds and runs the game directly through NXNative. Mac `.app` games and apps are added to the database by path and are not copied into the game library.

A PS5-style build card stays visible over the library while NXNative runs, with the current build step and a progress bar; it shows a percentage when NXNative reports one. Toasts announce build start, completion, failure, and cancellation. The official per-game profile revision is recorded with each successful build. When a later scan finds a newer official profile, the library prompts **Update / Rebuild** so you can apply the fixes. Existing builds get a baseline on the first profile check after this feature is added; later profile changes prompt normally.

The build studio streams real output and stores a full build log. NXNative's Mac-only build keeps extraction and intermediate files under `<game folder>/.nxstudio/Work/`, then runs the host executable directly from that workspace; MetalOS does not package a game `.app`. Cancel sends SIGTERM to the isolated build process group; upstream NXNative also manages its child tool groups.

There is no bundled NXNative, game content, keys, or compatibility fix. MetalOS installs the Yubismartlabs fork by default; a custom checkout can be selected in Engine settings. MetalOS does not make unsupported titles compatible; that depends on your engine changes. See the [NXNative setup](https://github.com/yubismartlabs/nxnative#how-to-play) and [NX Play](https://github.com/varyform/nx-native-wrapper) for context.

## Switch library folders

Choose **Add a library folder** and select the parent folder containing your games, or one game's folder. Each game gets one library entry. Put its base game, updates and DLC together, directly inside the game folder. The game title is the exact folder name. Supported container extensions are `.nsp`, `.xci`, `.nsz`, `.xcz` and `.nup`, in any letter case. For example:

```text
Switch Library/
  Super Mario Bros. Wonder/
    Super Mario Bros. Wonder [010015100B514000][v0].nsp
    Super Mario Bros. Wonder [010015100B514800][v327680].nsp
  Another Game/
    Another Game [base title ID].xci
```

Discovery uses the exact game folder name as the title, preserving punctuation, case, and spacing. Container filenames provide title IDs for support checks only. Each game folder stays its build input. Files without an ID are added with unknown support. Each detected folder is one game entry; container title IDs are used only for NXNative support lookup. Rescans preserve favorites, artwork, checkout overrides and successful builds.

After scanning or importing, MetalOS downloads the [Yubismartlabs NXNative games table](https://github.com/yubismartlabs/nxnative/blob/main/dm/games/README.md) and checks the exact base title ID. Build Studio shows whether a title has a profile, is unlisted, or could not be checked. Profiles include the tested build and a link to game-specific progress/known issues; being listed does not promise that every version runs on Mac. A selected custom checkout does not change the MetalOS support catalog. Missing IDs and network failures stay unknown; scan again to retry. Only the public table is requested: game names, files, and paths are not sent.

Extraction, build caches, logs, and the playable host stay under each game's hidden `.nxstudio` folder. NXNative reads the base game, update, and DLC containers together from the game folder. Generated folders and app contents are excluded from discovery.

## PlayStation 2 games

MetalOS launches PS2 games through [ARMSX2](https://github.com/ARMSX2/ARMSX2), an actively maintained PCSX2 fork with native Apple Silicon recompilers. Open **Settings → PlayStation 2** to install or update the official macOS arm64 nightly in `<library>/.nxstudio/Engines/ARMSX2/`. The nightly is unsigned, so macOS may ask you to approve it in **System Settings → Privacy & Security** on first launch. Intel Macs are not supported by this managed runtime.

Choose **Add a PlayStation 2 game** and select a disc image. MetalOS keeps the image at its current path and derives the game title from its filename. ISO, CHD, CSO, ZSO, CUE/BIN, MDF, and NRG images are recognized. Images found inside the selected library folder are also discovered when you scan; scans skip hidden folders and app bundles.

Open ARMSX2 setup from **Settings → PlayStation 2** on first use and configure a BIOS dumped from your own PlayStation 2. ARMSX2 manages BIOS settings, controller mapping, memory cards, and saves. MetalOS does not download or include game images or BIOS files.

## Discovery

MetalOS scans only the chosen game library for Switch game folders and PS2 disc images. It does not scan Steam or Heroic, mounted volumes, or the Mac for app bundles. Add a game image or a macOS `.app` explicitly with the **+** button. App bundles remain available under **Apps**; games appear under **Games**. Switch scans inspect each immediate game folder; PS2 scans inspect folders recursively to a bounded depth. Symlinks are skipped.

## Artwork

MetalOS uses [LizardByte GameDB](https://github.com/LizardByte/GameDB), a public static database sourced from IGDB, for game art and metadata. It matches the library folder title and retrieves box art, descriptions, screenshots, genres, platforms, release dates, developers, and publishers. Metadata, screenshots, and art are stored under `<library>/.nxstudio/Artwork/`. Nintendo title-ID artwork fills gaps for Switch games, and NXNative's extracted `icon.jpg` takes priority as the game's own icon.

GameDB lookup does not require credentials and does not send game files or paths. MetalOS looks up artwork and details automatically after imports and library scans, with Nintendo artwork as an additional Switch fallback.

Automatic artwork and metadata retrieval runs after scans and imports. Switch title metadata is cached for seven days. If a lookup is unavailable, the game remains in the library and can be checked again on a later scan.

The Games page shows each selected game's available description, genres, platforms, release date, and screenshots below its Play controls. Failed lookups retain existing images. Artwork images are validated, resized, and downloaded only from trusted HTTPS image hosts.

## Home screen and in-game Game Bar

The home screen uses a console-style horizontal game rail, enlarged selected tile, ambient game-icon backdrop, a large title area, and quick-action cards. Games and Collection tabs switch between the home screen and the full grid. The charcoal and lime palette is shared by the home screen and Game Bar.

While a game launched through MetalOS is in the foreground, hold **LB + RB and press Menu** to toggle the floating Game Bar. **View/Options + Menu** is an alternative; **Guide/Home** works when macOS delivers it to the app. macOS may reserve Guide/Home for its own features. D-pad/left stick selects tiles, A confirms, B closes it, X captures a screenshot, and Y toggles Favorite. The bar shows the game title, session time, controller battery, and the game process's CPU and memory, styled after the Xbox Game Bar widgets. It offers Resume, Library, Capture, Favorite, and normal Quit for a matched native game. It never quits Steam, Heroic, or CrossOver clients.

Capture hides the bar, saves a PNG of the main display to `~/Pictures/MetalOS/`, and restores the bar. It requires Screen Recording permission for MetalOS; macOS may require relaunching MetalOS after the permission is granted. The toolbar Game Bar button or **⌘⇧O** opens it from MetalOS, including a preview when no game is running. Keyboard arrows, Return, S for capture, and Escape work in the panel. The overlay is a separate native window above the game, not injected into its renderer. Games keep running and may still receive controller input while it is open.

Foreground matching works when the game app or executable lives inside its recorded installation path. Windows games whose Wine/CrossOver host executable lives outside that folder may not be recognized for background toggling. macOS and individual games can reserve controller buttons or exclusive display modes; those cases require hardware testing. The overlay does not require Accessibility or Screen Recording permission.

## Full-screen games

Choosing Play asks the launched game to enter macOS full screen as soon as its window appears. macOS exposes this only through the Accessibility API, so allow MetalOS under **System Settings → Privacy & Security → Accessibility** on the first launch. Games are matched to their installation path, which covers native, App Store, CrossOver, Steam, and built NXNative apps; Wine-hosted Heroic titles may keep their own display mode. If a game is left with its own borderless or windowed presentation, that choice is respected after the initial launch. Turn the behavior off with **Settings → Console → Games start in full screen**.

## Games and Apps

The PS5-style home keeps its square game tiles; portrait box art is centered, cropped, and clipped inside each rounded tile. Collection posters retain the full cover.

The **Games** tab always keeps the home layout. A permanent welcome game card and an add card frame the game rail; the selected title's summary and screenshots appear below its Play controls. **Apps** lists non-game `.app` bundles added with the **+** button. Press **Menu / Options** or **X / Square** on a selected item to open its options; **A / Cross** confirms and **B / Circle** goes back.

On a keyboard, **M** or **Space** opens game options. Arrow keys move within menus and pages, Return confirms, and Escape closes them. The existing three-button overlay chord remains available during gameplay.

## Gamepad setup, settings, and file browsing

The launcher's own setup and library workflows can be used with a gamepad. Choose the **+** icon in the top navigation to add a Mac app or a Switch game folder. The in-app browser includes Home, Applications, Downloads, Computer, and mounted drives.

In the browser, A opens a directory or selects an app/file, X selects the current folder when choosing folders, Y toggles hidden items, and LB/RB changes locations. Menu moves to the footer, where Find in folder and Cancel are available. Find in folder uses the virtual keyboard and filters the listing before its 2,000-item display limit. B goes back through folder history. No native file picker is required.

PS5-style Settings provides controller-selectable categories and action rows. Game artwork and metadata are fetched automatically, with a library scan available from Settings. Build Studio starts the build, lets you cancel, and shows its log without opening another app. MetalOS detects a local NXNative checkout, Python, and keys when available; setup paths remain available for machines where automatic discovery cannot find them. Controller status shows reported battery percentage, charging state, player assignment, and supported features; unsupported readings remain unavailable. Battery status also appears on the home screen and Game Bar.

The virtual keyboard supports letters, numbers, symbols, shift, space, delete, clear, and confirm. A enters the highlighted key, X deletes, Y inserts a space, LB toggles shift, RB toggles symbols, and B closes it. Directional input stays scoped to the topmost panel and returns to its parent when the panel closes. Optional external links open their normal browser; macOS permissions and other applications retain their own system interfaces.

## Navigation sound and motion

MetalOS uses original synthesized cues for movement, confirm, back, opening menus, and favorites. Controller input, keyboard navigation, and button presses share the same sound settings. Cues are short and quiet, and directional repeats are throttled. Ordinary controller input during gameplay does not make launcher sounds while the Game Bar is hidden.

In **Settings → Console**, toggle **Navigation sounds**, select **Sound volume** and adjust with Left/Right, or enable **Reduce motion**. A or B finishes volume adjustment. These preferences persist locally. System Reduce Motion is also respected. Focus, page/menu transitions, button presses, the virtual keyboard, and the overlay animate with short fades and gentle movement; reduced motion disables decorative animation.

## Controls

D-pad / left stick: navigate; A: play/open build; Y: favorite; LB/RB: library; Menu: controls; B: close panel/exit console mode. Input is handled only while MetalOS is active. Games retain their own controller handling. Settings, imports, and file selection are operated inside MetalOS using the controller.

Arrow keys, Return, and Escape work in the library. `⌘⇧F` toggles console mode, `⌘I` imports Switch inputs, `⌘O` adds apps, `⌘R` scans, and `⌘,` opens Settings. Enable startup console mode in Settings.

Library metadata and local path settings are persisted in `<library>/.nxstudio/library.json`; game content and keys are not copied into that file. Artwork and game details are looked up automatically when games are imported or discovered during a scan. Favorites sort before recently played games. Entries remain in the library when their game folder is unavailable.

## Running the app

The current `dist/MetalOS.app` is a locally signed development build. Open it in Finder; on first launch, choose the library folder, then install NXNative from **Settings → Engine** before adding and building a Switch game.

To package a development build again, run `./scripts/package-app.sh debug`. To generate an optimized release build, run `./scripts/package-app.sh release` (the default). Release packaging may need permission for Xcode's dSYM tools when run inside a restricted agent sandbox. The app is not notarized for distribution.

## Development

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" \
swift test --disable-sandbox
```

The tests use temporary fixture manifests and checkout scripts; they do not require game files or an NXNative installation. An actual title build/run and physical-controller validation still need your local checkout, content, dependencies, and hardware.
