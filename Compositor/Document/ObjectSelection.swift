import AppKit
import CoreImage
import Vision

struct ObjectSelectionSettings: Equatable, Sendable {
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = true
    /// Positive values erode the detected mask inward; negative values expand it outward.
    var edgeOffset = 0
}

/// Selects the foreground object under a clicked point using Vision's instance mask,
/// then traces that mask into the document's normal path-based selection.
enum ObjectSelection {
    enum Failure: LocalizedError {
        case unsupported
        case render

        var errorDescription: String? {
            switch self {
            case .unsupported: return "No object was found at that point."
            case .render: return "The object mask could not be rendered."
            }
        }
    }

    /// The outline, in the image's top-left pixel coordinates, of the foreground object
    /// at `point`. Nil when the point is outside the image, on background, or no object is found.
    ///
    /// macOS 14's foreground-instance matting is unavailable here, so the object is the connected
    /// region of Vision's saliency map that contains the clicked point. The panel's edge offset,
    /// the edge-preserving upscale and the outline smoothing below work on it the same way.
    static func select(in image: CGImage, at point: CGPoint, edgeOffset: Int, smoothEdges: Bool) throws -> CGPath? {
        let width = image.width, height = image.height
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return try selectAvailable(in: image, at: point, edgeOffset: edgeOffset, smoothEdges: smoothEdges)
    }

    private static func selectAvailable(in image: CGImage, at point: CGPoint, edgeOffset: Int, smoothEdges: Bool) throws -> CGPath? {
        let width = image.width, height = image.height
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try handler.perform([request])
        var observation = request.results?.first
        if observation == nil {
            let fallback = VNGenerateAttentionBasedSaliencyImageRequest()
            try handler.perform([fallback])
            observation = fallback.results?.first
        }
        guard let observation else { return nil }
        let buffer = observation.pixelBuffer
        let maskWidth = CVPixelBufferGetWidth(buffer), maskHeight = CVPixelBufferGetHeight(buffer)
        guard maskWidth > 0, maskHeight > 0 else { return nil }
        let saliency = try grayscaleBytes(from: buffer, width: maskWidth, height: maskHeight, interpolation: .none)
        let seedX = min(maskWidth - 1, max(0, Int(point.x / CGFloat(width) * CGFloat(maskWidth))))
        let seedY = min(maskHeight - 1, max(0, Int(point.y / CGFloat(height) * CGFloat(maskHeight))))
        let seed = Int(saliency[seedY * maskWidth + seedX])
        guard seed >= 20 else { return nil }
        let threshold = UInt8(max(16, seed * 3 / 5))

        // Grow the object's region from the click; saliency fades at its edges, so a threshold below the
        // clicked value follows the outline instead of stopping at the exact pixel brightness.
        var coarse = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        var visited = [Bool](repeating: false, count: maskWidth * maskHeight)
        var stack = [seedY * maskWidth + seedX]
        visited[seedY * maskWidth + seedX] = true
        while let index = stack.popLast() {
            coarse[index] = 255
            let px = index % maskWidth, py = index / maskWidth
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = px + dx, ny = py + dy
                guard nx >= 0, ny >= 0, nx < maskWidth, ny < maskHeight else { continue }
                let neighbor = ny * maskWidth + nx
                guard !visited[neighbor], saliency[neighbor] >= threshold else { continue }
                visited[neighbor] = true
                stack.append(neighbor)
            }
        }

        // Upsample the coarse mask to the image and pull it onto the image's edges.
        guard let coarseImage = grayImage(coarse, width: maskWidth, height: maskHeight) else { return nil }
        let upscaled = try grayscaleBytes(from: CIImage(cgImage: coarseImage),
                                          width: width, height: height, interpolation: .high)
        var mask: [UInt8] = upscaled.map { $0 >= 128 ? 255 : 0 }
        mask = adjusted(binaryMask: mask, width: width, height: height, edgeOffset: edgeOffset)
        guard let outline = try MagicWand.outline(of: mask, width: width, height: height) else { return nil }
        return smoothEdges ? smoothed(outline) : outline
    }

    private static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func adjusted(binaryMask: [UInt8], width: Int, height: Int, edgeOffset: Int) -> [UInt8] {
        var mask = binaryMask
        let steps = min(10, abs(edgeOffset))
        guard steps > 0, width > 0, height > 0 else { return mask }
        for _ in 0..<steps {
            mask = edgeOffset > 0 ? eroded(mask, width: width, height: height) : dilated(mask, width: width, height: height)
        }
        return mask
    }

    private static func eroded(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                var keep = true
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] == 0 {
                        keep = false
                    }
                }
                result[y * width + x] = keep ? 255 : 0
            }
        }
        return result
    }

    private static func dilated(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 0 {
                var fill = false
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] != 0 {
                        fill = true
                    }
                }
                if fill { result[y * width + x] = 255 }
            }
        }
        return result
    }

    /// Rounds off the one-pixel stair steps created by tracing a binary mask. The winding and
    /// subpath order are preserved, so holes continue to subtract from the selected region.
    private static func smoothed(_ path: CGPath) -> CGPath {
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finishCurrent() {
            guard current.count >= 3 else { current.removeAll(); return }
            subpaths.append(current)
            current.removeAll()
        }
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                finishCurrent()
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint:
                current.append(element.points[1])
            case .addCurveToPoint:
                current.append(element.points[2])
            case .closeSubpath:
                finishCurrent()
            @unknown default:
                break
            }
        }
        finishCurrent()

        let result = CGMutablePath()
        for subpath in subpaths {
            let simplified = simplifyClosed(subpath, tolerance: 1.6)
            let points = chaikin(simplified, iterations: 3)
            guard let first = points.first else { continue }
            result.move(to: first)
            result.addLines(between: Array(points.dropFirst()))
            result.closeSubpath()
        }
        return result
    }

    private static func simplifyClosed(_ input: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var points = input
        if points.first == points.last { points.removeLast() }
        guard points.count >= 4 else { return points }
        // Break at a stable extreme so the open-polyline simplifier can preserve the whole closed contour.
        let start = points.indices.min { lhs, rhs in
            points[lhs].x == points[rhs].x ? points[lhs].y < points[rhs].y : points[lhs].x < points[rhs].x
        } ?? points.startIndex
        let rotated = Array(points[start...]) + Array(points[..<start])
        var open = rotated + [rotated[0]]
        open = simplifyOpen(open, from: 0, to: open.count - 1, tolerance: tolerance)
        if open.first == open.last { open.removeLast() }
        return open.count >= 3 ? open : points
    }

    private static func simplifyOpen(_ points: [CGPoint], from first: Int, to last: Int, tolerance: CGFloat) -> [CGPoint] {
        guard last > first + 1 else { return [points[first], points[last]] }
        var farthest = first + 1
        var greatestDistance: CGFloat = 0
        for index in (first + 1)..<last {
            let distance = perpendicularDistance(points[index], toLineFrom: points[first], to: points[last])
            if distance > greatestDistance {
                greatestDistance = distance
                farthest = index
            }
        }
        guard greatestDistance > tolerance else { return [points[first], points[last]] }
        var left = simplifyOpen(points, from: first, to: farthest, tolerance: tolerance)
        let right = simplifyOpen(points, from: farthest, to: last, tolerance: tolerance)
        left.removeLast()
        return left + right
    }

    private static func perpendicularDistance(_ point: CGPoint, toLineFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        return abs(dy * point.x - dx * point.y + b.x * a.y - b.y * a.x) / length
    }

    private static func chaikin(_ input: [CGPoint], iterations: Int) -> [CGPoint] {
        var points = input
        if points.first == points.last { points.removeLast() }
        guard points.count >= 3 else { return points }
        for _ in 0..<iterations {
            var next: [CGPoint] = []
            next.reserveCapacity(points.count * 2)
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            points = next
        }
        return points
    }

    private static func grayscaleBytes(from pixelBuffer: CVPixelBuffer, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        try grayscaleBytes(from: CIImage(cvPixelBuffer: pixelBuffer), width: width, height: height, interpolation: interpolation)
    }

    private static func grayscaleBytes(from image: CIImage, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        let renderer = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cgImage = renderer.createCGImage(image, from: image.extent) else { throw Failure.render }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.saveGState()
        context.interpolationQuality = interpolation
        context.setBlendMode(.copy)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        guard let data = context.data else { throw Failure.render }
        let source = data.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = source[y * context.bytesPerRow + x]
            }
        }
        return bytes
    }
}

private struct ObjectSelectionJob: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
    let edgeOffset: Int
    let smoothEdges: Bool
}

private struct ObjectSelectionResult: @unchecked Sendable {
    let path: CGPath?
    let error: Error?
}

extension EditorSession {
    /// Object Selection: selects the Vision foreground instance under `point`, read from
    /// the active layer or every visible layer, combined with the current selection by `mode`.
    func selectObject(at point: CGPoint, mode: SelectionMode) async {
        guard canEditSelection, !isProjectBusy, selectionMoveOrigin == nil, let document,
              point.x >= 0, point.y >= 0, point.x < document.size.width, point.y < document.size.height,
              let sample = selectionSample(document, sampleAllLayers: objectSelectionSettings.sampleAllLayers) else { return }
        let job = ObjectSelectionJob(image: sample, point: point,
                                     edgeOffset: min(10, max(-10, objectSelectionSettings.edgeOffset)),
                                     smoothEdges: selectionAntialiased)
        isProjectBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> ObjectSelectionResult in
            do { return ObjectSelectionResult(path: try ObjectSelection.select(in: job.image, at: job.point, edgeOffset: job.edgeOffset, smoothEdges: job.smoothEdges), error: nil) }
            catch { return ObjectSelectionResult(path: nil, error: error) }
        }.value
        isProjectBusy = false
        if let error = result.error { brushError = error.localizedDescription; return }
        guard self.document?.id == document.id else { return }
        guard let path = result.path else {
            if mode == .replace { deselect() }
            return
        }
        if mode == .replace {
            setSelection(DocumentSelection(path: path, antialiased: selectionAntialiased), name: "Object Selection")
        } else {
            applySelection(path, mode: mode, name: "Object Selection")
        }
    }
}
