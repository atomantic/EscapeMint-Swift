import SwiftUI

// MARK: - isWide helper

/// Views that drive multi-column layouts off the horizontal size class.
///
/// `horizontalSizeClass` is valid on every platform — on macOS it is always
/// `.regular`, so the single `isWide` default below works everywhere and
/// replaces the per-view `#if os(macOS)` wrappers. Conformers just declare
/// `@Environment(\.horizontalSizeClass) var horizontalSizeClass`.
@MainActor
protocol SizeClassAware {
    var horizontalSizeClass: UserInterfaceSizeClass? { get }
}

extension SizeClassAware {
    /// True when the horizontal size class is regular (iPad landscape/split
    /// view, or macOS — which is always `.regular`).
    var isWide: Bool {
        horizontalSizeClass == .regular
    }
}

// MARK: - Toast Modifier

struct ToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    Text(message)
                        .font(.callout).fontWeight(.medium)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.mint.cornerRadius(10))
                        .shadow(radius: 4)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.3), value: isPresented)
            .onChange(of: isPresented) { _, show in
                if show {
                    toastTask?.cancel()
                    toastTask = Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        guard !Task.isCancelled else { return }
                        isPresented = false
                    }
                }
            }
    }
}

extension View {
    func toast(isPresented: Binding<Bool>, message: String) -> some View {
        modifier(ToastModifier(isPresented: isPresented, message: message))
    }
}

// MARK: - Keyboard / Input Modifiers

extension View {
    @ViewBuilder
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    /// Keyboard for numeric fields that also support formula input (+, -, *, /).
    @ViewBuilder
    func formulaKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func numberKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func noAutoCapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func uppercaseCapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }
}
