import AppKit
import SwiftUI

/// The button labels describe the photograph; the inserted strings remain the
/// same tokens accepted by ExportNaming.stem.
enum ExportPatternTokens {
    struct Choice: Identifiable {
        let title: String
        let token: String
        var id: String { token }
    }

    static let choices: [Choice] = [
        Choice(title: "Roll name", token: "{roll}"),
        Choice(title: "Film stock", token: "{stock}"),
        Choice(title: "Date", token: "{date}"),
        Choice(title: "Frame number", token: "{frame:03}"),
        Choice(title: "Original name", token: "{original}")
    ]

    static func inserting(_ token: String, into text: String,
                          replacing selection: NSRange?) -> (text: String, caret: Int) {
        let source = text as NSString
        let end = source.length
        let requested = selection?.location ?? end
        let start = requested == NSNotFound ? end : max(0, min(requested, end))
        let length = max(0, min(selection?.length ?? 0, end - start))
        let replacement = NSRange(location: start, length: length)
        return (source.replacingCharacters(in: replacement, with: token),
                start + (token as NSString).length)
    }
}

/// Holds the editor selection after a token button takes focus away from the
/// text field. Cocoa selection offsets are UTF-16 offsets, matching NSString.
@MainActor
final class ExportPatternEditor: ObservableObject {
    weak var field: NSTextField?
    private(set) var selection: NSRange?

    func attach(_ field: NSTextField) {
        if self.field !== field { selection = nil }
        self.field = field
    }

    func remember(_ selection: NSRange) {
        if selection.location != NSNotFound { self.selection = selection }
    }

    func insert(_ token: String, into binding: Binding<String>) {
        let activeEditor = field?.currentEditor() as? NSTextView
        let current = activeEditor?.string ?? binding.wrappedValue
        let replacement = activeEditor?.selectedRange() ?? selection
        let result = ExportPatternTokens.inserting(token, into: current,
                                                   replacing: replacement)
        binding.wrappedValue = result.text
        activeEditor?.string = result.text
        field?.stringValue = result.text
        let caret = NSRange(location: result.caret, length: 0)
        selection = caret
        field?.selectText(nil)
        (field?.currentEditor() as? NSTextView)?.setSelectedRange(caret)
    }
}

/// NSTextField exposes its selection through the shared field editor. SwiftUI's
/// TextField binding does not expose a caret/selection for token insertion.
@MainActor
struct ExportPatternField: NSViewRepresentable {
    @Binding var text: String
    let editor: ExportPatternEditor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Filename pattern"
        field.bezelStyle = .roundedBezel
        field.font = NSFont(name: "Tahoma", size: 13) ?? .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Filename pattern")
        editor.attach(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        editor.attach(field)
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ExportPatternField

        init(_ parent: ExportPatternField) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionChanged(_:)),
                name: NSTextView.didChangeSelectionNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func controlTextDidBeginEditing(_ note: Notification) { rememberActiveSelection() }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            rememberActiveSelection()
        }

        func controlTextDidEndEditing(_ note: Notification) { rememberActiveSelection() }

        @objc private func selectionChanged(_ note: Notification) {
            guard let changed = note.object as? NSTextView,
                  let current = parent.editor.field?.currentEditor() as? NSTextView,
                  current === changed else { return }
            parent.editor.remember(changed.selectedRange())
        }

        private func rememberActiveSelection() {
            guard let current = parent.editor.field?.currentEditor() as? NSTextView else { return }
            parent.editor.remember(current.selectedRange())
        }
    }
}
