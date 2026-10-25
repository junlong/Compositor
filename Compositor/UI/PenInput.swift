import AppKit
import Combine

/// Whether a tablet pen has been used since the app opened, so the Brush's pressure buttons show only for someone with
/// one. A pen that comes near the tablet counts, before it touches. Nothing is remembered between launches: with the
/// tablet unplugged, the buttons stay away until a pen turns up again.
@MainActor
final class PenInput: ObservableObject {
    static let shared = PenInput()
    @Published private(set) var seen = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.tabletProximity, .tabletPoint, .leftMouseDown, .leftMouseDragged]) { event in
            if event.type == .tabletProximity || event.type == .tabletPoint || event.subtype == .tabletPoint {
                MainActor.assumeIsolated { PenInput.shared.found() }
            }
            return event
        }
    }

    /// Starts listening, at launch, so a pen brought near before the Brush is picked still counts.
    static func install() { _ = shared }

    private func found() {
        guard !seen else { return }
        seen = true
        // Once seen, it stays seen until the app quits; nothing more to listen for.
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
