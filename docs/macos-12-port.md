# Running Compositor on macOS 12 (Intel)

This branch ports Compositor 1.5.8 to build with **Xcode 14.2 / Swift 5.7** and run on
**macOS 12.3 or later on Intel Macs**. The project, the app and the saved-file format are all
unchanged from the user's point of view; this document records what had to change underneath.

## Build

```sh
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build
```

The `Compositor` scheme builds the app. The app target is built for `x86_64` with
`MACOSX_DEPLOYMENT_TARGET = 12.3`.

`CompositorTests` still contains the original Swift Testing suite (macros from the
`Testing` package, Xcode 16+). Xcode 14 cannot compile it, so the test target is not part of
the scheme's build action. Running the 721 tests on this toolchain would require converting
them to XCTest; that is tracked separately.

## Project file

* `project.pbxproj` was converted from the Xcode 16 object version (77, synchronized folder
  references) to the classic Xcode 14 format with explicit file references and build phases.
* `Package.resolved` was downgraded to the v1 format Xcode 14's SwiftPM reads; Sparkle still
  resolves and links.
* The scheme's blueprint identifiers were updated to the new target identifiers, so
  `xcodebuild -scheme` builds the app rather than an empty target.
* Code signing defaults to ad-hoc; open the project in Xcode or pass a team to sign normally.

## Actor isolation

The original set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (a Swift 6 default). Swift 5.7
has no such setting, so the isolation is written out:

* UI types (`View`, `ViewModifier`, `NSViewRepresentable`), `CompositorApp`, and the
  observable models (`EditorSession`, `ProjectWorkspace`, `DocumentHistory`, the edit
  classes, the panels and the singleton settings) are annotated `@MainActor`.
* Pure helpers that background rendering calls (`colorRangeResult`, `blurMargin`,
  `textImage`, `shapeImage`, `makeStyledName`, …) are `nonisolated`.
* Without this, continuations after `await` run off the main thread and mutate `@Published`
  state; SwiftUI on macOS 12 logs “Publishing changes from background threads is not allowed”
  and tears the window down. This was observed with Remove Background before the port.

## Observation → ObservableObject

`Observation` is a macOS 14 framework. Every `@Observable` class became `ObservableObject`
with `@Published` on stored properties only (computed properties stay plain), and views use
`@ObservedObject` / `@StateObject`.

Observation tracked nested objects automatically; `ObservableObject` does not. Two pieces of
plumbing restore that:

* `EditorSession` forwards `objectWillChange` from `history`, `levels`, `hueSaturation`,
  `colorRange`, `filterEdit` and `colorPicker`.
* `ProjectWorkspace` is a shared instance that forwards the current session's changes, so the
  SwiftUI `App` re-evaluates its menu commands as the document changes. `ProjectWorkspaceView`
  and `ProjectTabStrip` observe the workspace.

The app's menu enablement (Save/Export/Undo and so on) depends on this.

## macOS 12 compatibility layer

`Compositor/Compat` contains the shims. Where a macOS 13+ API could be replaced without
changing behaviour, it was:

| Original | Port |
| --- | --- |
| `ScrollPosition`, `onScrollGeometryChange`, `ScrollIndicatorVisibility` | NSScrollView in the export preview; indicator shims where purely cosmetic |
| `.onContinuousHover` | `.onHover` in numeric scrubbing |
| `ViewThatFits` | Tool rail chooses one or two columns from the window height |
| `Grid` / `GridRow` | nested `HStack`s (canvas size, trim, color picker, export size) |
| `ToolbarSpacer`, `labelReservedIconWidth`, `Toggle(_:systemImage:)` | standard toolbar content and `Label`-based toggles |
| `.defaultWindowPlacement` | first launch sizes the window to the screen's visible frame |
| `Window` scene, `openWindow` | `WindowGroup`; `showEditor` raises the existing window |
| `CIRAWFilter` highlight recovery | runtime check with the older highlight keys |
| Vision foreground-instance matte | attention saliency, stretched to full contrast, with a “no subject” error on flat images |
| `CGPath` boolean operations (macOS 13) | rasterize, combine, trace outline (`PathBoolean`) |
| `ProposedViewSize` sizing callbacks (macOS 13) | controls keep their intrinsic AppKit sizes |
| `pointerStyle` grab cursors | no-op; default cursors |
| `Duration` / `Clock` (Swift 5.9) | nanoseconds and `Date` |
| `@MainActor.assumeIsolated` (Swift 5.9) | message-send shim for synchronous callbacks |

### Tabs

The project tabs are a toolbar item in the original. On macOS 12, an NSToolbar item hosting
that SwiftUI view is given a narrow hosting area and clips the pills. The port renders the
same `ProjectTabStrip` as a 34 pt bar at the top of the editor content instead, where width
and hit-testing are reliable. Dragging, overflow, closing, and the modified dot are unchanged.
The toolbar keeps the New button and the zoom controls.

### Export preview

`JPEGPreview`'s zoomed state is an `NSScrollView` with a custom document view: checkered
background, nearest-neighbour drawing at 100 % and above, drag to pan, and double-click to
return to Fit. Zooming keeps the viewport centred on the same part of the image.

## Behavioural notes

* Saved projects keep format version 17 and load in both builds.
* Intel-only: `ARCHS = x86_64`. Add `arm64` (and arm64 slices for Sparkle) to ship universal.
* Remove Background, Object Selection and Camera Raw use the fallbacks above; they work, but
  the models differ from the macOS 14/26 ones. On an image with no clear subject, Remove
  Background reports that no subject was found instead of hiding the layer.
* Native semantic tuning from newer macOS (cursor shapes, toolbar materials, window restore)
  is approximated by AppKit defaults.
