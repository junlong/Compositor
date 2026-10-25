import AppKit

// AppKit pieces that arrived after macOS 12.

extension NSCursor {
    /// macOS 15's frame-resize cursor. Older systems have edge cursors only, so corners get a
    /// diagonal cursor drawn here; the direction flags make no difference to a two-headed arrow.
    enum FrameResizePosition {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    struct FrameResizeDirection: OptionSet {
        let rawValue: Int
        static let inward = FrameResizeDirection(rawValue: 1 << 0)
        static let outward = FrameResizeDirection(rawValue: 1 << 1)
    }

    static func frameResize(position: FrameResizePosition, directions: FrameResizeDirection) -> NSCursor {
        switch position {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return diagonalCursor(descending: true)
        case .topRight, .bottomLeft: return diagonalCursor(descending: false)
        }
    }

    private static func diagonalCursor(descending: Bool) -> NSCursor {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        let a = descending ? NSPoint(x: 4, y: 16) : NSPoint(x: 4, y: 4)
        let b = descending ? NSPoint(x: 16, y: 4) : NSPoint(x: 16, y: 16)
        path.move(to: a)
        path.line(to: b)
        // Arrowheads at both ends.
        path.move(to: NSPoint(x: a.x + 4, y: a.y))
        path.line(to: a)
        path.line(to: NSPoint(x: a.x, y: a.y + (descending ? -4 : 4)))
        path.move(to: NSPoint(x: b.x - 4, y: b.y))
        path.line(to: b)
        path.line(to: NSPoint(x: b.x, y: b.y + (descending ? 4 : -4)))
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
}
