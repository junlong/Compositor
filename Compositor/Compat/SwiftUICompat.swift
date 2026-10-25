import SwiftUI

// SwiftUI compatibility for macOS 12.
//
// The app was written against macOS 26. These shims cover modifiers and
// types that SwiftUI only grew later. Where a modifier cannot be reproduced
// on macOS 12 (scroll position, pointer style) it is a no-op here; the
// component that needs it has its own AppKit implementation.

// MARK: - onChange with the old value

extension View {
    /// macOS 14's `onChange(of:) { oldValue, newValue in }`.
    func compatOnChange<Value: Equatable>(of value: Value, _ action: @escaping (Value, Value) -> Void) -> some View {
        modifier(OnChangeCompatModifier(value: value, action: action))
    }
}

@MainActor
private struct OnChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var previous: Value?

    func body(content: Content) -> some View {
        content
            .onAppear { previous = value }
            .onChange(of: value) { newValue in
                if let previous { action(previous, newValue) }
                previous = newValue
            }
    }
}

// MARK: - Geometry reporting

extension View {
    /// macOS 26's `onGeometryChange(for:of:action:)`.
    func onGeometryChange<Value: Equatable>(for type: Value.Type,
                                            of transform: @escaping (GeometryProxy) -> Value,
                                            action: @escaping (Value) -> Void) -> some View {
        modifier(GeometryChangeModifier(transform: transform, action: action))
    }
}

@MainActor
private struct GeometryChangeModifier<Value: Equatable>: ViewModifier {
    let transform: (GeometryProxy) -> Value
    let action: (Value) -> Void
    @State private var last: Value?

    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            let value = transform(proxy)
            Color.clear
                .onAppear { report(value) }
                .onChange(of: value) { report($0) }
        })
    }

    private func report(_ value: Value) {
        guard last != value else { return }
        last = value
        action(value)
    }
}

// MARK: - Scroll indicators

/// The visibility values SwiftUI added with macOS 13's `scrollIndicators`.
enum ScrollIndicatorVisibility {
    case automatic, visible, hidden, never
}

extension View {
    func scrollIndicators(_ visibility: ScrollIndicatorVisibility) -> some View {
        self
    }
}

// MARK: - Pointer style

/// macOS 15's pointer styles; macOS 12 has no way to ask for them, so these
/// only keep the modifier call sites readable.
struct PointerStyle {
    let name: String

    static let `default` = PointerStyle(name: "default")
    static let grabIdle = PointerStyle(name: "grab")
    static let grabActive = PointerStyle(name: "grabbing")
    static let columnResize = PointerStyle(name: "column-resize")
    static let rowResize = PointerStyle(name: "row-resize")
}

@MainActor
private struct PointerStyleModifier: ViewModifier {
    let style: PointerStyle
    func body(content: Content) -> some View { content }
}

extension View {
    func pointerStyle(_ style: PointerStyle) -> some View { modifier(PointerStyleModifier(style: style)) }
}

// MARK: - Layout proposals

/// macOS 13's `ProposedViewSize`. NSViewRepresentable's `sizeThatFits` that
/// takes it is likewise newer than macOS 12, so this only lets the methods
/// exist; AppKit views size themselves through their intrinsic content size.
struct ProposedViewSize {
    var width: CGFloat?
    var height: CGFloat?

    init(width: CGFloat? = nil, height: CGFloat? = nil) {
        self.width = width
        self.height = height
    }
}

// MARK: - Points as dictionary keys

extension CGPoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}
