import Cocoa

// A non-interactive menu row rendered as a custom NSMenuItem.view, used for the
// status and plan-usage readout lines. Two reasons it isn't a plain NSMenuItem:
//
//   • a standard *enabled* item takes the blue hover highlight, which makes a
//     readout look clickable when it isn't;
//   • a standard *disabled* item is drawn faded by AppKit, with no opt-out, so
//     the text reads too dim (the brightest appearance-safe colour still lands
//     at roughly half strength after the fade).
//
// A custom view sidesteps both: the menu neither highlights nor fades it, so we
// draw the icon and text ourselves at full strength. The actual controls stay
// standard NSMenuItems, so they keep the native highlight and fire their actions.
//
// Geometry (imageX / textX / height) is supplied by the caller so the icon and
// text columns line up with the standard rows above and below — see AppDelegate's
// infoRow* constants.
@MainActor
final class InfoRowView: NSView {
    // A vertical connector drawn in the icon column. Because each row draws it at
    // its own full height and every row is the same height, the segments of
    // stacked rows butt together into one continuous line — tying a parent row
    // ("Remote Control: Active") to its child rows (the session projects) with no
    // text indentation: the line and the small child node live entirely in the
    // leading icon column, so the text column never moves. `top`/`bottom` are the
    // segments above/below the node; `node` draws the small dot at the column
    // centre (the parent supplies its own larger dot as `leading` instead).
    struct Connector {
        var top: Bool
        var bottom: Bool
        var node: Bool
        var color: NSColor
    }

    private let leading: NSImage?       // a pre-composed slot-sized icon, or nil
    private let attributed: NSAttributedString
    private let imageX: CGFloat
    private let textX: CGFloat
    private let slotSize: NSSize
    private let connector: Connector?

    init(leading: NSImage?, attributed: NSAttributedString, width: CGFloat,
         height: CGFloat, imageX: CGFloat, textX: CGFloat, slotSize: NSSize,
         connector: Connector? = nil) {
        self.leading = leading
        self.attributed = attributed
        self.imageX = imageX
        self.textX = textX
        self.slotSize = slotSize
        self.connector = connector
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // A custom view replaces the menu item's title for VoiceOver, so expose the
        // row's text ourselves as static text — otherwise these readout lines (the
        // status and plan-usage numbers) would be silently skipped. The leading
        // icon is decorative; the string already carries its meaning.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(attributed.string)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Connector first, so the parent's leading dot (drawn below) sits on top of
        // its descending segment and the line appears to emanate from the dot.
        drawConnector()
        // Leading icon (status dot, pie, cup…), vertically centred in its slot.
        // It is already slot-sized, so this blits 1:1 with no scaling.
        if let leading {
            let y = ((bounds.height - slotSize.height) / 2).rounded()
            leading.draw(in: NSRect(x: imageX, y: y,
                                    width: slotSize.width, height: slotSize.height))
        }
        // Text, vertically centred. draw(at:) lays out a single line and honours
        // the attributed string's right-aligned tab stop (the reset column), so a
        // plan row's "in 37m" / "Sat 07:00" value lands in its column.
        let y = ((bounds.height - attributed.size().height) / 2).rounded()
        attributed.draw(at: NSPoint(x: textX, y: y))
    }

    // Draw the vertical connector centred on the icon column (the same x the
    // leading dot is centred on, so line and dots share one column). Segments run
    // to the row's top/bottom edges so adjacent rows join seamlessly; the node is
    // a small filled dot — deliberately smaller than the parent's dot so the
    // parent stays the anchor.
    private func drawConnector() {
        guard let c = connector else { return }
        let cx = imageX + slotSize.width / 2
        let cy = bounds.midY
        c.color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1.5
        if c.top {
            line.move(to: NSPoint(x: cx, y: bounds.maxY))
            line.line(to: NSPoint(x: cx, y: cy))
        }
        if c.bottom {
            line.move(to: NSPoint(x: cx, y: cy))
            line.line(to: NSPoint(x: cx, y: bounds.minY))
        }
        line.stroke()
        if c.node {
            let d: CGFloat = 6
            c.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2,
                                        width: d, height: d)).fill()
        }
    }
}
