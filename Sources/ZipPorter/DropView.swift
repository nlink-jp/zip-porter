import AppKit

@MainActor
protocol DropViewDelegate: AnyObject {
    func dropView(_ view: DropView, didReceive urls: [URL])
}

/// The main drop target: a dashed rounded area that accepts files/folders
/// (pack) and .zip archives (unpack).
@MainActor
final class DropView: NSView {
    weak var delegate: DropViewDelegate?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 24, dy: 24)
        let path = NSBezierPath(roundedRect: inset, xRadius: 16, yRadius: 16)
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
        }
        path.stroke()
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        delegate?.dropView(self, didReceive: urls)
        return true
    }
}
