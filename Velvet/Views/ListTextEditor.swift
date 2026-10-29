import AppKit
import SwiftUI

/// Mehrzeiliges Textfeld, das zusätzlich .txt-Dateien per Drag & Drop annimmt.
struct ListTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isDropTargeted: Bool
    var onFileDrop: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DropTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onFileDrop = { url in context.coordinator.parent.onFileDrop(url) }
        textView.onDragStateChange = { targeted in context.coordinator.parent.isDropTargeted = targeted }

        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let selection = textView.selectedRanges
        textView.string = text
        let length = (text as NSString).length
        textView.selectedRanges = selection.map { value in
            let range = value.rangeValue
            return NSValue(range: NSRange(location: min(range.location, length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ListTextEditor

        init(_ parent: ListTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Sorgt dafür, dass das Textfeld immer die ganze Fläche ausfüllt – ein Klick irgendwo setzt den Cursor.
private final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let height = contentSize.height
        if textView.minSize.height != height {
            textView.minSize = NSSize(width: 0, height: height)
            textView.sizeToFit()
        }
    }
}

private final class DropTextView: NSTextView {
    var onFileDrop: ((URL) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    private func textFiles(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter(TextFileLoader.isSupported)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !textFiles(in: sender).isEmpty {
            onDragStateChange?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !textFiles(in: sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragStateChange?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !textFiles(in: sender).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragStateChange?(false)
        let files = textFiles(in: sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        files.forEach { onFileDrop?($0) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDragStateChange?(false)
        super.concludeDragOperation(sender)
    }
}
