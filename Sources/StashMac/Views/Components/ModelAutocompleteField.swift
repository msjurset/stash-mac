import SwiftUI
import AppKit

/// Auto-suggest / autocomplete model selection field for settings.
/// Integrates with the existing `FilterField` keyboard interceptor.
struct ModelAutocompleteField: View {
    let placeholder: String
    @Binding var text: String
    let isMultiValue: Bool
    let providerID: AIProviderID
    var onCommit: (() -> Void)? = nil

    @State private var activeIndex = 0
    @State private var dropdownOpen = false

    private var allModels: [String] {
        switch providerID {
        case .gemini:
            return [
                "gemini-2.5-flash",
                "gemini-2.5-pro",
                "gemini-2.5-flash-lite",
                "gemini-3.1-flash",
                "gemini-3.1-pro",
                "gemini-3.1-flash-lite",
                "gemini-3.5-flash",
                "gemini-1.5-flash",
                "gemini-1.5-pro"
            ]
        case .claude:
            return [
                "claude-3-5-sonnet-latest",
                "claude-3-5-sonnet-20241022",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest",
                "claude-3-haiku-20240307"
            ]
        }
    }

    private var currentToken: String {
        if isMultiValue {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            return (parts.last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        } else {
            return text.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    private var enteredModels: Set<String> {
        if isMultiValue {
            let parts = text.split(separator: ",").dropLast(text.hasSuffix(",") ? 0 : 1)
            return Set(parts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        } else {
            return Set()
        }
    }

    private var filtered: [String] {
        let query = currentToken
        return allModels
            .filter { model in
                let lower = model.lowercased()
                return (query.isEmpty || lower.contains(query)) && !enteredModels.contains(lower)
            }
    }

    private var showSuggestions: Bool { dropdownOpen && !filtered.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterField(
                placeholder: placeholder,
                text: $text,
                isBordered: true,
                backgroundColor: .textBackgroundColor,
                onSubmit: {
                    if showSuggestions, activeIndex < filtered.count {
                        commitSelection(filtered[activeIndex])
                    } else {
                        onCommit?()
                        dropdownOpen = false
                    }
                },
                onKey: { key in
                    switch key {
                    case .tab:      return handleTab(reverse: false)
                    case .shiftTab: return handleTab(reverse: true)
                    case .arrowDown: return handleArrow(reverse: false)
                    case .arrowUp:   return handleArrow(reverse: true)
                    case .escape:
                        if dropdownOpen {
                            dropdownOpen = false
                            return true
                        }
                        return false
                    default:
                        return false
                    }
                },
                onBeginEditing: {
                    dropdownOpen = !filtered.isEmpty
                    activeIndex = 0
                },
                onEndEditing: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        dropdownOpen = false
                    }
                }
            )
            .frame(height: 22)
            .onChange(of: text) { _, _ in
                let isFocused = NSApp.keyWindow?.firstResponder is NSTextView
                if isFocused {
                    dropdownOpen = !filtered.isEmpty
                    activeIndex = 0
                }
            }

            if showSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element) { index, model in
                        HStack {
                            Image(systemName: "cpu")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model)
                                .font(.body)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == activeIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            commitSelection(model)
                            onCommit?()
                        }
                    }
                }
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .padding(.top, 4)
                .zIndex(1)
            }
        }
    }

    private func handleTab(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        if filtered.count == 1 {
            commitSelection(filtered[0])
            return true
        }
        activeIndex = clamp(reverse ? activeIndex - 1 : activeIndex + 1, filtered.count)
        return true
    }

    private func handleArrow(reverse: Bool) -> Bool {
        if !dropdownOpen {
            if filtered.isEmpty { return false }
            dropdownOpen = true
            activeIndex = reverse ? filtered.count - 1 : 0
            return true
        }
        activeIndex = clamp(reverse ? activeIndex - 1 : activeIndex + 1, filtered.count)
        return true
    }

    private func clamp(_ i: Int, _ count: Int) -> Int {
        if count == 0 { return 0 }
        return min(max(i, 0), count - 1)
    }

    private func commitSelection(_ name: String) {
        if isMultiValue {
            var parts = text.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.isEmpty {
                text = name + ", "
            } else {
                parts[parts.count - 1] = name
                text = parts.joined(separator: ", ") + ", "
            }
        } else {
            text = name
        }
        dropdownOpen = false
        activeIndex = 0
    }
}
