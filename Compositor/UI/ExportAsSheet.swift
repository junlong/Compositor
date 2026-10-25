import SwiftUI
import UniformTypeIdentifiers

/// File › Export As…: the flattened canvas, or frame timelines driving it, sized and previewed as written.
@MainActor
struct ExportAsSheet: View {
    let raster: ExportRaster
    /// The same flattened at 16 bits a channel, when the document has a 16-bit layer to keep.
    let deepRaster: ExportRaster?
    /// The same flattened in half floats, when the document has an HDR layer: what an EXR is written from, the only
    /// format offered that keeps light brighter than white. Without one, EXR isn't offered.
    let hdrRaster: ExportRaster?
    /// The document's layers, which Channel Pack and GIF read; without it, neither is offered.
    let snapshot: ProjectSnapshot?
    private var formats: [ExportFormat] {
        ExportFormat.allCases.filter { ($0 != .exr || hdrRaster != nil) && (($0 != .channelPack && $0 != .gif) || snapshot != nil) }
    }
    @ObservedObject var session: EditorSession
    let finish: ((data: Data, format: ExportFormat)?) -> Void
    @State private var format: ExportFormat
    @State private var options: JPEGOptions
    @State private var gifOptions: GIFExportOptions
    @State private var width: Int
    @State private var height: Int
    /// Channel Pack's red, green, blue and alpha, in that order.
    @State private var channels: [ChannelPack.Source]
    /// Each document's last Channel Pack choices, while the app is open.
    private static var channelChoices: [UUID: [ChannelPack.Source]] = [:]
    /// JPEG's quality from the last export, which the next one starts from.
    private static let qualityKey = "jpegExportQuality"

    init(raster: ExportRaster, deepRaster: ExportRaster? = nil, hdrRaster: ExportRaster? = nil, snapshot: ProjectSnapshot? = nil,
         session: EditorSession, format: ExportFormat, finish: @escaping ((data: Data, format: ExportFormat)?) -> Void) {
        self.raster = raster
        self.snapshot = snapshot
        self.deepRaster = deepRaster
        self.hdrRaster = hdrRaster
        let layers = snapshot?.manifest.layers ?? []
        let remembered = snapshot.flatMap { Self.channelChoices[$0.manifest.documentID] }?
            .filter { if case .layer(let id) = $0 { return layers.contains { $0.id == id } } else { return true } }
        _channels = State(initialValue: remembered?.count == 4 ? remembered!
                          : ChannelPack.Channel.allCases.map { ChannelPack.defaultSource(for: $0, in: layers) })
        self.session = session
        self.finish = finish
        var start = JPEGOptions()
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.quality = min(1, max(0, saved))
        }
        _options = State(initialValue: start)
        _gifOptions = State(initialValue: GIFExportOptions())
        _format = State(initialValue: (format == .exr && hdrRaster == nil) || (format == .channelPack && snapshot == nil) ? .png : format)
        _width = State(initialValue: raster.image.width)
        _height = State(initialValue: raster.image.height)
    }

    /// What's written depends on these; a change makes a new preview.
    struct Settings: Equatable {
        var format: ExportFormat
        var options: JPEGOptions
        var gifOptions: GIFExportOptions
        var width: Int
        var height: Int
        var sixteenBit: Bool
        /// In this CMYK profile's inks, for print (JPEG, TIFF and PDF); nil for RGB.
        var cmyk: CMYKProfile?
        /// Channel Pack's sources; empty for the other formats.
        var channels: [ChannelPack.Source] = []
    }
    struct Encoded {
        let id = UUID()
        let settings: Settings
        let data: Data
        let preview: CGImage
        var durations: [TimeInterval] = []
    }
    private var settings: Settings {
        Settings(format: format, options: options, gifOptions: gifOptions, width: width, height: height, sixteenBit: sixteenBit && format == .png && deepRaster != nil,
                 cmyk: cmyk && takesCMYK ? profile : nil, channels: format == .channelPack ? channels : [])
    }
    /// The formats that can be written in a printer's inks.
    private var takesCMYK: Bool { format == .jpeg || format == .tiff || format == .pdf }
    /// CMYK for print: off each time, as most exports are for screens.
    @State private var cmyk = false
    /// The CMYK profile, as View › CMYK › Profile sets it.
    private var profile: CMYKProfile? { session.proofProfile ?? CMYK.chosen }
    /// A PNG at 16 bits a channel: off by default, it's about twice the size.
    @State private var sixteenBit = false
    @State private var result: Encoded?
    @State private var error: String?
    @State private var gifProgress: (completed: Int, total: Int)?
    @State private var gifPreviewImage: CGImage?
    @State private var gifPreviewIndex = 0
    @State private var isGIFPreviewPlaying = true
    private var isReady: Bool { result?.settings == settings && error == nil }
    /// The preview's zoom, 1 being 100%; nil fits the whole image.
    @State private var zoom: Double?
    @Environment(\.displayScale) private var displayScale
    private var shownZoom: Double {
        zoom ?? JPEGPreview.fitZoom(width: width, height: height, in: JPEGPreview.frame, displayScale: displayScale)
    }

    @ViewBuilder private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Export As").font(.title2.bold())
            Spacer()
            if format == .gif, let result, result.durations.count > 1 {
                Button {
                    if !isGIFPreviewPlaying, gifPreviewIndex == result.durations.count - 1, !gifOptions.loopsForever {
                        gifPreviewIndex = 0
                        gifPreviewImage = result.preview
                    }
                    isGIFPreviewPlaying.toggle()
                } label: { Image(systemName: isGIFPreviewPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white) }
                    .disabled(!isReady)
                    .help(isGIFPreviewPlaying ? "Pause the animation preview." : "Play the animation preview.")
                    .accessibilityLabel(isGIFPreviewPlaying ? "Pause animation preview" : "Play animation preview")
            }
            Button("Fit") { zoom = nil }.disabled(zoom == nil)
                .help("Show the whole image (⌘0)")
            Button { zoomBy(1) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(JPEGPreview.step(from: shownZoom, in: 1) == nil)
                .help("Zoom in (⌘+), now \(percent). At 100% each pixel of the export is one pixel of the screen")
            Button { zoomBy(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(JPEGPreview.step(from: shownZoom, in: -1) == nil)
                .help("Zoom out (⌘−), now \(percent)")
        }
        .padding(.bottom, -8)
    }

    @ViewBuilder private var previewArea: some View {
        ZStack {
            Color(white: 0.12)
            if let result {
                JPEGPreview(image: result.settings.format == .gif ? gifPreviewImage ?? result.preview : result.preview,
                            pixelWidth: result.settings.width, pixelHeight: result.settings.height, zoom: $zoom)
            }
            if !isReady && error == nil {
                ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }.frame(width: JPEGPreview.frame.width, height: JPEGPreview.frame.height).clipped()
            .help("Enabled masks apply here, as on the canvas. Drag or scroll to move around; double-click switches between Fit and 100%.")
    }

    @ViewBuilder private var settingsArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsFormatRow
            settingsSizeRow
            if format == .jpeg { settingsQualityRow }
            if format == .png, deepRaster != nil { settingsDepthRow }
            if takesCMYK { settingsColorRow }
            if format == .channelPack {
                ForEach(Array(ChannelPack.Channel.allCases.enumerated()), id: \.offset) { index, channel in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(channel.rawValue).frame(width: 80, alignment: .leading)
                        channelPicker(index, channel: channel)
                    }
                }
            }
            if format == .pdf { settingsPageRow }
            if format == .gif { settingsGIFRows }
            if format == .jpeg || format == .pdf || (format == .tiff && cmyk) || (format == .gif && !gifOptions.keepsTransparency) {
                settingsBackgroundRow
            }
        }
    }

    @ViewBuilder private var settingsFormatRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Format").frame(width: 80, alignment: .leading)
            // The everyday formats side by side, JPEG first; the rest (PDF, and EXR with an HDR layer) in a menu beside them,
            // which takes the chosen one's name.
            HStack(spacing: 12) {
                Picker("Format", selection: $format) {
                    ForEach([ExportFormat.jpeg, .png], id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                moreFormats
            }
        }
    }

    @ViewBuilder private var settingsSizeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Size").frame(width: 80, alignment: .leading)
            HStack(spacing: 6) {
                sizeField(width, set: setWidth).help("Width in pixels; the height follows, keeping the proportions")
                Text("×").foregroundStyle(.secondary)
                sizeField(height, set: setHeight).help("Height in pixels; the width follows, keeping the proportions")
                Text("px").foregroundStyle(.secondary)
                Menu("\(scalePercent)%") {
                    ForEach([25, 50, 75, 100, 200], id: \.self) { percent in
                        Button("\(percent)%") { setScale(Double(percent) / 100) }
                    }
                }
                .fixedSize().help("Scale the export: the document stays as it is")
            }
        }
    }

    @ViewBuilder private var settingsQualityRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Quality").frame(width: 80, alignment: .leading)
            HStack {
                Slider(value: $options.quality, in: 0...1, step: 0.01).frame(width: 300)
                Text("\(Int((options.quality * 100).rounded()))%").monospacedDigit().frame(width: 45, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var settingsDepthRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Depth").frame(width: 80, alignment: .leading)
            Toggle("16 bits per channel", isOn: $sixteenBit)
                .help("Keep the 16-bit layers' full precision, in a file about twice the size")
        }
    }

    @ViewBuilder private var settingsColorRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Color").frame(width: 80, alignment: .leading)
            HStack(spacing: 10) {
                colorMenu
                // CMYK goes through View › CMYK › Profile's profile, named under the settings; a printer's own
                // can be loaded here too.
                if cmyk {
                    Button("Load Profile…") { loadProfile() }
                        .help("Use a CMYK ICC profile, such as the one your printer gave you")
                }
            }
        }
    }

    @ViewBuilder private var settingsPageRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Page").frame(width: 80, alignment: .leading)
            Text(pageSize).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var settingsGIFRows: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Loop").frame(width: 80, alignment: .leading)
            Picker("Loop", selection: $gifOptions.loopsForever) {
                Text("Forever").tag(true)
                Text("Once").tag(false)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!gifHasAnimation)
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Transparency").frame(width: 80, alignment: .leading)
            Toggle("Keep transparent areas", isOn: $gifOptions.keepsTransparency)
                .help("GIF keeps fully transparent or opaque pixels; soft edges use a 50% threshold.")
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Frames").frame(width: 80, alignment: .leading)
            Text(gifSummary).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var settingsBackgroundRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Background").frame(width: 80, alignment: .leading)
            DialogColorSwatch(title: "Export Background", color: format == .gif ? gifMatte : matte, session: session)
                .help("Color that fills transparent areas")
        }
    }

    @ViewBuilder private var footerArea: some View {
        HStack(spacing: 12) {
            Text(format == .channelPack ? "Each channel from a layer, read as grayscale · PNG"
                 : format == .gif ? "Up to 256 colors · sRGB" : format == .exr ? "Brighter than white kept · Transparency kept"
                 : takesCMYK && cmyk ? "CMYK – \(profile?.name ?? "No profile")"
                 : format == .png || format == .tiff ? "Transparency kept · sRGB" : "sRGB")
                .foregroundStyle(.secondary)
            Spacer()
            if isReady, let result {
                Text(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)).monospacedDigit()
            } else if error == nil {
                Text(format == .gif ? gifProgress.map { "Encoding frame \(min($0.completed + 1, $0.total)) of \($0.total)…" } ?? "Updating…" : "Updating…")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Cancel") { DialogColorSwatch.closePicker(session); finish(nil) }.configuredNativeShortcut(.escape)
            Button("Export…") {
                DialogColorSwatch.closePicker(session)
                if format == .jpeg { UserDefaults.standard.set(options.quality, forKey: Self.qualityKey) }
                if format == .channelPack, let snapshot { Self.channelChoices[snapshot.manifest.documentID] = channels }
                if let result { finish((result.data, result.settings.format)) }
            }
                .configuredNativeShortcut(.return)
                .disabled(!isReady)
        }
    }

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            previewArea
            settingsArea
            footerArea
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).frame(maxWidth: JPEGPreview.frame.width, alignment: .leading) }
        }
        .padding(24)
        .onAppear {
            setScale(Double(width) / Double(raster.image.width))
            session.previewZoom = { command in
                switch command {
                case .zoomIn: zoomBy(1)
                case .zoomOut: zoomBy(-1)
                case .fit: zoom = nil
                case .actual: zoom = 1
                }
            }
        }
        .onDisappear { session.previewZoom = nil }
        .onChange(of: format) { _ in setScale(Double(width) / Double(raster.image.width)) }
        .task(id: settings) {
            let requested = settings
            error = nil
            gifProgress = nil
            do {
                try await Task.sleep(nanoseconds: UInt64(200) * 1_000_000)
                if requested.format == .gif, let snapshot {
                    let encoded = try await GIFExporter.shared.encode(snapshot, width: requested.width, height: requested.height,
                        options: requested.gifOptions) { completed, total in
                            await MainActor.run {
                                if settings == requested { gifProgress = (completed, total) }
                            }
                        }
                    try Task.checkCancellation()
                    gifPreviewIndex = 0
                    gifPreviewImage = encoded.preview
                    isGIFPreviewPlaying = true
                    result = Encoded(settings: requested, data: encoded.data, preview: encoded.preview, durations: encoded.durations)
                    return
                }
                if requested.format == .channelPack, let snapshot {
                    let packed = try await ImageExporter.shared.channelPack(snapshot, sources: requested.channels,
                                                                            width: requested.width, height: requested.height)
                    try Task.checkCancellation()
                    result = Encoded(settings: requested, data: packed.data, preview: packed.preview)
                    return
                }
                let source = requested.format == .exr ? hdrRaster ?? raster : requested.sixteenBit ? deepRaster ?? raster : raster
                let sized = try await ImageExporter.shared.resized(source, width: requested.width, height: requested.height)
                let data: Data, preview: CGImage
                switch requested.format {
                case .jpeg:
                    let encoded = try await ImageExporter.shared.jpeg(sized, options: requested.options, cmyk: requested.cmyk)
                    (data, preview) = (encoded.data, encoded.preview)
                case .tiff:
                    let matte = CGColor(srgbRed: requested.options.red, green: requested.options.green, blue: requested.options.blue, alpha: 1)
                    (data, preview) = try await ImageExporter.shared.tiffData(sized, cmyk: requested.cmyk, matte: matte)
                case .png, .channelPack: (data, preview) = (try await ImageExporter.shared.pngData(sized), sized.image)
                // Shown as everything is, brighter than white as white.
                case .exr: (data, preview) = (try await ImageExporter.shared.exrData(sized), try DeepLayer.dithered(sized.image))
                case .pdf:
                    let background = CGColor(srgbRed: requested.options.red, green: requested.options.green,
                                             blue: requested.options.blue, alpha: 1)
                    data = try await ImageExporter.shared.pdfData(sized, background: background, cmyk: requested.cmyk)
                    if let cmyk = requested.cmyk {
                        preview = try CMYK.convert(sized.image, to: cmyk, over: background)
                    } else {
                        preview = try await ImageExporter.shared.flattened(sized, over: background)
                    }
                case .gif: return
                }
                try Task.checkCancellation()
                result = Encoded(settings: requested, data: data, preview: preview)
            } catch is CancellationError {
                // A newer setting superseded this preview.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .task(id: GIFPreviewRequest(resultID: result?.id, isPlaying: isGIFPreviewPlaying, isReady: isReady)) {
            guard isReady, isGIFPreviewPlaying, let result, result.settings.format == .gif,
                  result.durations.count > 1 else { return }
            do {
                try await GIFPreviewPlayback.play(durations: result.durations, startingAt: gifPreviewIndex,
                                                   loops: result.settings.gifOptions.loopsForever) { index in
                    let image = try await GIFExporter.shared.preview(result.data, index: index)
                    try Task.checkCancellation()
                    gifPreviewIndex = index
                    gifPreviewImage = image
                }
                isGIFPreviewPlaying = false
            } catch is CancellationError {
                // A setting changed, playback paused, or the dialog closed.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private struct GIFPreviewRequest: Equatable {
        let resultID: UUID?
        let isPlaying: Bool
        let isReady: Bool
    }
    private var gifSchedule: GIFExportSchedule? { snapshot.flatMap { try? GIFExportSchedule($0, options: gifOptions) } }
    private var gifHasAnimation: Bool {
        guard let snapshot else { return false }
        return snapshot.gifExportLayers.contains { (snapshot.animations[$0.id]?.frames.count ?? 0) > 1 }
    }
    private var gifSummary: String {
        guard !(snapshot?.gifExportLayers ?? []).isEmpty else { return "1 frame · Still canvas" }
        guard let schedule = gifSchedule else { return "—" }
        let count = "\(schedule.frames.count) \(schedule.frames.count == 1 ? "frame" : "frames")"
        let durations = schedule.durations
        return "\(count) · \(durations.reduce(0, +).formatted(.number.precision(.fractionLength(0...2)))) s"
    }

    /// RGB or CMYK: one small menu, as few need CMYK. The profile CMYK goes through is View › CMYK › Profile's, named in
    /// the line under the settings.
    private var colorMenu: some View {
        Menu(cmyk ? "CMYK" : "RGB") {
            Toggle("RGB", isOn: Binding(get: { !cmyk }, set: { if $0 { cmyk = false } }))
            Toggle("CMYK", isOn: Binding(get: { cmyk }, set: { if $0 { cmyk = true } }))
        }
        .menuStyle(.borderlessButton).buttonStyle(.bordered).fixedSize()
        .help("CMYK writes a printer's inks through the profile in View › CMYK › Profile")
    }

    private func loadProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.message = "Choose a CMYK ICC profile, such as the one your printer gave you"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { session.proofProfile = try CMYK.load(url) }
        catch { self.error = error.localizedDescription }
    }

    /// Animation formats, TIFF, PDF, and EXR with an HDR layer: a menu beside PNG and JPEG, blue with the chosen one's name while it's chosen,
    /// as the selected segment beside it would be.
    @ViewBuilder private var moreFormats: some View {
        let others = formats.filter { $0 != .png && $0 != .jpeg }
        let chosen = others.contains(format)
        let menu = Menu(chosen ? format.rawValue : "More") {
            Picker("More formats", selection: $format) {
                ForEach(others, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Other formats: TIFF, PDF and GIF\(others.contains(.exr) ? ", EXR to keep light brighter than white" : ""), and Channel Pack for game textures")
        if chosen { menu.buttonStyle(.borderedProminent) } else { menu.buttonStyle(.bordered) }
    }

    /// A channel's source: one of the document's layers or groups, top first, or solid black or white.
    private func channelPicker(_ index: Int, channel: ChannelPack.Channel) -> some View {
        let layers = snapshot?.manifest.layers ?? []
        return Picker(channel.rawValue, selection: $channels[index]) {
            Text("Black").tag(ChannelPack.Source.black)
            Text("White").tag(ChannelPack.Source.white)
            Divider()
            ForEach(layers.reversed().filter { $0.adjustment == nil }, id: \.id) { layer in
                Text(layer.name).tag(ChannelPack.Source.layer(layer.id))
            }
        }
        .labelsHidden().frame(width: 260)
        .help("What fills the \(channel.rawValue.lowercased()) channel: a layer or group read as grayscale, or solid black or white")
    }

    private func sizeField(_ value: Int, set: @escaping (Int) -> Void) -> some View {
        TextField("", value: Binding(get: { value }, set: set), format: .number.grouping(.never))
            .frame(width: 64).multilineTextAlignment(.trailing)
    }
    /// Both sides follow one, keeping the canvas's proportions, within the export limits.
    private func setWidth(_ value: Int) { setScale(Double(value) / Double(raster.image.width)) }
    private func setHeight(_ value: Int) { setScale(Double(value) / Double(raster.image.height)) }
    private func setScale(_ scale: Double) {
        let maximumSide = DocumentLimits.maxSide
        let largest = min(Double(maximumSide) / Double(max(raster.image.width, raster.image.height)),
                          (Double(DocumentLimits.maxSurfacePixels) / Double(raster.image.width * raster.image.height)).squareRoot())
        let clamped = min(largest, max(0.01, scale.isFinite ? scale : 1))
        width = max(1, Int((Double(raster.image.width) * clamped).rounded()))
        height = max(1, Int((Double(raster.image.height) * clamped).rounded()))
    }
    private var scalePercent: Int { Int((Double(width) / Double(raster.image.width) * 100).rounded()) }
    /// The PDF page: the export's pixels at the document's resolution.
    private var pageSize: String {
        let dpi = raster.resolution > 0 ? raster.resolution : 72
        let inches = { (pixels: Int) in (Double(pixels) / dpi).formatted(.number.precision(.fractionLength(0...2))) }
        return "\(inches(width)) × \(inches(height)) in at \(Int(dpi.rounded())) DPI"
    }
    private var percent: String { "\(Int((shownZoom * 100).rounded()))%" }
    private func zoomBy(_ direction: Int) {
        if let next = JPEGPreview.step(from: shownZoom, in: direction) { zoom = next }
    }
    private var matte: Binding<PaletteColor> {
        Binding(get: { PaletteColor(red: options.red, green: options.green, blue: options.blue) },
                set: { options.red = $0.red; options.green = $0.green; options.blue = $0.blue })
    }
    private var gifMatte: Binding<PaletteColor> {
        Binding(get: { PaletteColor(red: gifOptions.red, green: gifOptions.green, blue: gifOptions.blue) },
                set: { gifOptions.red = $0.red; gifOptions.green = $0.green; gifOptions.blue = $0.blue })
    }
}

/// The export, fitted or zoomed (1 is 100%: one image pixel per screen pixel, as the canvas counts it), where it
/// can be dragged or scrolled around. Double-click switches between Fit and 100%.
@MainActor
struct JPEGPreview: View {
    static let frame = CGSize(width: 560, height: 330)
    static let steps: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    let image: CGImage
    /// The exported image's size, which the preview may have been decoded smaller than.
    let pixelWidth: Int
    let pixelHeight: Int
    @Binding var zoom: Double?
    @Environment(\.displayScale) private var displayScale

    /// The zoom at which the whole image fits `frame`.
    static func fitZoom(width: Int, height: Int, in frame: CGSize, displayScale: CGFloat) -> Double {
        let points = CGSize(width: CGFloat(width) / max(1, displayScale), height: CGFloat(height) / max(1, displayScale))
        return Double(min(frame.width / points.width, frame.height / points.height))
    }
    /// The next zoom step past `zoom` in `direction` (1 in, -1 out), or nil at the end.
    static func step(from zoom: Double, in direction: Int) -> Double? {
        direction > 0 ? steps.first { $0 > zoom * 1.001 } : steps.last { $0 < zoom * 0.999 }
    }

    var body: some View {
        GeometryReader { geometry in
            if let zoom {
                // macOS 14's ScrollPosition and onScrollGeometryChange have no macOS 12 equivalent, so the zoomed
                // preview is an NSScrollView that owns its own offset and can also be dragged.
                ZoomedExportPreview(
                    image: image,
                    pointSize: CGSize(width: CGFloat(pixelWidth) / max(1, displayScale),
                                      height: CGFloat(pixelHeight) / max(1, displayScale)),
                    zoom: zoom,
                    onToggle: { self.zoom = nil })
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .background { Self.checkerboard }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { self.zoom = 1 }
            }
        }
    }

    /// The canvas's checkerboard behind the image, 10-point squares of two grays, so a transparent PNG shows where its
    /// edges are and what's see-through. A small tile repeated, however far the preview is zoomed.
    private static let checkerboard: some View = Image(nsImage: {
        let tile = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor(white: 0.30, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 20, height: 20).fill()
            NSColor(white: 0.35, alpha: 1).setFill()
            NSRect(x: 0, y: 10, width: 10, height: 10).fill()
            NSRect(x: 10, y: 0, width: 10, height: 10).fill()
            return true
        }
        return tile
    }()).resizable(resizingMode: .tile)
}

/// The zoomed export: an NSScrollView around a document view that draws the image (nearest-neighbor at 100% and
/// above) over the checkerboard. Dragging pans; double-click returns to Fit. Zooming keeps the middle of the
/// viewport on the same part of the image, as the canvas does.
@MainActor
private struct ZoomedExportPreview: NSViewRepresentable {
    let image: CGImage
    /// The image's size at 100%, in points.
    let pointSize: CGSize
    let zoom: Double
    let onToggle: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = ZoomedExportDocumentView()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? ZoomedExportDocumentView else { return }
        document.image = image
        document.onToggle = onToggle
        let target = CGSize(width: pointSize.width * zoom, height: pointSize.height * zoom)
        let old = document.frame.size
        guard abs(document.currentZoom - zoom) > 1e-9 || old != target else { return }

        let clip = scroll.contentView
        let visible = clip.bounds.size
        var fraction = CGPoint(x: 0.5, y: 0.5)
        if old.width > 1, old.height > 1 {
            fraction = CGPoint(x: (clip.bounds.origin.x + visible.width / 2) / old.width,
                               y: (clip.bounds.origin.y + visible.height / 2) / old.height)
        }
        document.currentZoom = zoom
        document.setFrameSize(target)
        document.needsDisplay = true
        let x = min(max(0, fraction.x * target.width - visible.width / 2), max(0, target.width - visible.width))
        let y = min(max(0, fraction.y * target.height - visible.height / 2), max(0, target.height - visible.height))
        clip.scroll(to: NSPoint(x: x, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

private final class ZoomedExportDocumentView: NSView {
    var image: CGImage?
    var onToggle: (() -> Void)?
    var currentZoom: Double = 0
    private var dragOrigin: NSPoint?
    private var startOrigin = NSPoint.zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let square: CGFloat = 10
        NSColor(white: 0.30, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.35, alpha: 1).setFill()
        var y = floor(dirtyRect.minY / square) * square
        while y < dirtyRect.maxY {
            var x = floor(dirtyRect.minX / square) * square
            while x < dirtyRect.maxX {
                if (Int(x / square) + Int(y / square)) % 2 == 0 {
                    NSRect(x: x, y: y, width: square, height: square).fill()
                }
                x += square
            }
            y += square
        }
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Nearest-neighbor from 100% up, so each pixel of the export and its artifacts shows as it is.
        context.interpolationQuality = bounds.width >= CGFloat(image.width) ? .none : .high
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggle?()
            return
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
        startOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let clip = enclosingScrollView?.contentView else { return }
        let point = convert(event.locationInWindow, from: nil)
        clip.scroll(to: NSPoint(x: startOrigin.x - (point.x - dragOrigin.x),
                                y: startOrigin.y - (point.y - dragOrigin.y)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
