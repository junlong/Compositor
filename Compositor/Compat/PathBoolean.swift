import CoreGraphics

// `CGPath.union/intersection/subtracting(_:using:)` arrived with macOS 13.
// Composing selections still needs them on macOS 12, so these versions rasterize
// the two paths at document resolution, combine the coverage, and trace the
// result back into an outline with the same tracer the Magic Wand uses. The
// result is the pixel-exact outline the rest of the selection code expects.

extension CGPath {
    func union(_ other: CGPath, using rule: CGPathFillRule) -> CGPath {
        PathBoolean.combine(self, other, operation: .union, rule: rule)
    }

    func intersection(_ other: CGPath, using rule: CGPathFillRule) -> CGPath {
        PathBoolean.combine(self, other, operation: .intersection, rule: rule)
    }

    func subtracting(_ other: CGPath, using rule: CGPathFillRule) -> CGPath {
        PathBoolean.combine(self, other, operation: .subtraction, rule: rule)
    }
}

private enum PathBoolean {
    enum Operation {
        case union, intersection, subtraction
    }

    /// Booleans run on at most this many pixels along the long side; a 30,000-pixel
    /// canvas would need a gigabyte of mask otherwise.
    private static let maximumSide = 8192

    static func combine(_ first: CGPath, _ second: CGPath, operation: Operation, rule: CGPathFillRule) -> CGPath {
        var bounds = first.boundingBoxOfPath.union(second.boundingBoxOfPath).integral
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 1, bounds.height >= 1 else {
            return CGMutablePath()
        }
        // One pixel of room so an edge lying exactly on the bound is still filled.
        bounds = bounds.insetBy(dx: -1, dy: -1)

        let scale = min(1, CGFloat(maximumSide) / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let firstMask = mask(for: first, bounds: bounds, scale: scale, width: width, height: height, rule: rule),
              let secondMask = mask(for: second, bounds: bounds, scale: scale, width: width, height: height, rule: rule)
        else { return CGMutablePath() }

        var combined = [UInt8](repeating: 0, count: width * height)
        for index in 0..<combined.count {
            let a = firstMask[index] >= 128
            let b = secondMask[index] >= 128
            let keep: Bool
            switch operation {
            case .union: keep = a || b
            case .intersection: keep = a && b
            case .subtraction: keep = a && !b
            }
            combined[index] = keep ? 255 : 0
        }

        guard let traced = try? MagicWand.outline(of: combined, width: width, height: height) else {
            return CGMutablePath()
        }
        var transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            .translatedBy(x: bounds.minX * scale, y: bounds.minY * scale)
        return traced.copy(using: &transform) ?? CGMutablePath()
    }

    private static func mask(for path: CGPath, bounds: CGRect, scale: CGFloat,
                             width: Int, height: Int, rule: CGPathFillRule) -> [UInt8]? {
        guard let context = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path)
        context.fillPath(using: rule == .winding ? .winding : .evenOdd)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = bytes[y * context.bytesPerRow + x]
            }
        }
        return out
    }
}
