import AppKit

final class ReviewMinimap: NSView {
    weak var original: ReviewTextView?
    weak var modified: ReviewTextView?
    private(set) var renders = 0
    private var image: NSImage?
    private var grab: CGFloat?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 80, height: NSView.noIntrinsicMetric)
    }

    private var mapping: (scale: CGFloat, slope: CGFloat, clip: NSRect)? {
        guard let modified, let clip = modified.enclosingScrollView?.contentView.bounds, modified.frame.height > 0 else { return nil }

        let scale = min(2 / modified.rowHeight, 8000 / modified.frame.height)
        let isTaller = modified.frame.height * scale > bounds.height && modified.frame.height > clip.height
        return (scale, isTaller ? (bounds.height - clip.height * scale) / (modified.frame.height - clip.height) : scale, clip)
    }

    func invalidate() {
        image = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let modified, let mapping else { return }

        modified.style.background.setFill()
        bounds.fill()
        let image = image ?? render(scale: mapping.scale)
        self.image = image
        image?.draw(in: NSRect(x: 0, y: -mapping.clip.minY * (mapping.scale - mapping.slope), width: bounds.width, height: image?.size.height ?? 0), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        modified.style.foreground.withAlphaComponent(0.1).setFill()
        NSRect(x: 0, y: mapping.clip.minY * mapping.slope, width: bounds.width, height: mapping.clip.height * mapping.scale).fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) {
        guard let mapping else { return }

        let y = convert(event.locationInWindow, from: nil).y
        let top = mapping.clip.minY * mapping.slope
        let height = mapping.clip.height * mapping.scale
        grab = (top...(top + height)).contains(y) ? y - top : height / 2
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let mapping else { return }
        modified?.scrollVertically(to: (convert(event.locationInWindow, from: nil).y - grab) / mapping.slope)
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
    }

    override func scrollWheel(with event: NSEvent) {
        modified?.enclosingScrollView?.scrollWheel(with: event)
    }

    private func render(scale: CGFloat) -> NSImage? {
        guard let modified, let original else { return nil }

        let backing = window?.backingScaleFactor ?? 2
        let size = NSSize(width: bounds.width, height: (modified.frame.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: Int(size.width * backing), height: Int(size.height * backing), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        renders += 1
        context.scaleBy(x: backing, y: -backing)
        context.translateBy(x: 0, y: -size.height)
        let rowHeight = modified.rowHeight * scale
        let added = modified.changedRows
        for (rows, color) in [(original.changedRows.subtracting(added), modified.style.removedWord), (added, modified.style.addedWord)] {
            context.setFillColor(color.withAlphaComponent(0.6).cgColor)
            for row in rows {
                context.fill(CGRect(x: 0, y: modified.top(ofRow: row) * scale, width: size.width, height: rowHeight))
            }
        }

        let units = Array(modified.string.utf16)
        let rows = modified.side?.rows ?? []
        let runs = modified.syntaxRuns
        let foreground = modified.style.foreground
        var run = 0
        context.setAlpha(0.6)
        for (line, start) in modified.lineStarts.enumerated() {
            let end = line + 1 < modified.lineStarts.count ? modified.lineStarts[line + 1] - 1 : units.count
            let y = modified.top(ofRow: rows.indices.contains(line) ? rows[line] : line) * scale + rowHeight * 0.15
            var segment: (column: Int, color: NSColor)?
            var column = 0
            for offset in start...max(start, end) {
                let unit = offset < end ? units[offset] : 0x20
                while run < runs.count, NSMaxRange(runs[run].range) <= offset { run += 1 }
                let isBlank = unit == 0x20 || unit == 0x09 || unit == 0x0D
                let color = isBlank ? nil : run < runs.count && runs[run].range.location <= offset ? modified.style.color(forCapture: runs[run].capture) : foreground
                if let current = segment, current.color !== color {
                    context.setFillColor(current.color.cgColor)
                    context.fill(CGRect(x: 4 + CGFloat(current.column), y: y, width: CGFloat(column - current.column), height: rowHeight * 0.7))
                    segment = nil
                }
                if let color, segment == nil { segment = (column, color) }
                column += unit == 0x09 ? 4 - column % 4 : 1
            }
        }

        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}

final class ReviewOverviewRuler: NSView {
    weak var original: ReviewTextView?
    weak var modified: ReviewTextView?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 10, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let modified, let original, let clip = modified.enclosingScrollView?.contentView.bounds, modified.frame.height > 0 else { return }

        modified.style.background.setFill()
        bounds.fill()
        modified.style.commentBorder.setFill()
        NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: bounds.height).fill()

        let factor = bounds.height / modified.frame.height
        for (lane, rows, color) in [(0, original.changedRows, modified.style.removedWord), (1, modified.changedRows, modified.style.addedWord)] {
            color.withAlphaComponent(1).setFill()
            for range in rows.rangeView {
                let top = modified.top(ofRow: range.lowerBound) * factor
                let bottom = modified.top(ofRow: range.upperBound) * factor
                NSRect(x: 1.5 + CGFloat(lane) * 4, y: top, width: 3.5, height: max(bottom - top, 2)).fill()
            }
        }
        modified.style.foreground.withAlphaComponent(0.12).setFill()
        NSRect(x: 0, y: clip.minY * factor, width: bounds.width, height: max(clip.height * factor, 4)).fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let modified, let clip = modified.enclosingScrollView?.contentView.bounds, bounds.height > 0 else { return }
        modified.scrollVertically(to: convert(event.locationInWindow, from: nil).y / bounds.height * modified.frame.height - clip.height / 2)
    }

    override func scrollWheel(with event: NSEvent) {
        modified?.enclosingScrollView?.scrollWheel(with: event)
    }
}
