import AppKit

/// The canonical ForIT mark above a waveform, shared with the app icon.
/// Neutral white with a navy keyline at rest; red only during actual recording.
enum DictateStatusAppearance: String, CaseIterable {
    case idle, starting, recording, processing

    init(recordingState: RecordingState) {
        switch recordingState {
        case .idle: self = .idle
        case .starting: self = .starting
        case .recording: self = .recording
        case .transcribing, .enhancing, .busy: self = .processing
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle: return String(localized: "Ready")
        case .starting: return String(localized: "Starting microphone")
        case .recording: return String(localized: "Recording")
        case .processing: return String(localized: "Processing dictation")
        }
    }

}

@MainActor
enum DictateStatusIcon {
    static let size = NSSize(width: 24, height: 18)
    private static let glyph = NSImage(data: DictateGlyphAsset.pdfData)!
    private static let neutral = color(DictateGlyphAsset.accentRGB)
    private static let recording = color(DictateGlyphAsset.recordingRGB)
    private static let outline = color(DictateGlyphAsset.inkRGB)
    private static let glyphSize = NSSize(width: 17.6, height: 16.6)
    private static let keylineGlyph = tintedGlyph(outline)
    private static let images: [DictateStatusAppearance: NSImage] =
        Dictionary(uniqueKeysWithValues: DictateStatusAppearance.allCases.map { ($0, makeImage($0)) })

    static func image(for appearance: DictateStatusAppearance) -> NSImage {
        // Every enum case is populated once from the generated master; no file or audio work.
        images[appearance]!
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    /// Tint the exact shared alpha, never redraw or substitute the ForIT logo.
    private static func tintedGlyph(_ color: NSColor) -> NSImage {
        NSImage(size: glyphSize, flipped: false) { rect in
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func makeImage(_ appearance: DictateStatusAppearance) -> NSImage {
        let ink = appearance == .recording ? recording : neutral
        let foreground = tintedGlyph(ink)
        let image = NSImage(size: size, flipped: false) { _ in
            let target = NSRect(origin: NSPoint(x: 0.7, y: 0.7), size: glyphSize)
            for direction in 0..<8 {
                let angle = Double(direction) * .pi / 4
                keylineGlyph.draw(in: target.offsetBy(dx: CGFloat(cos(angle)) * 0.35,
                                                      dy: CGFloat(sin(angle)) * 0.35))
            }
            foreground.draw(in: target)
            switch appearance {
            case .idle:
                break
            case .starting:
                // An open ring means preparing, rather than already recording.
                let ring = NSBezierPath(ovalIn: NSRect(x: 19, y: 11, width: 4, height: 4))
                outline.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
                NSColor.systemTeal.setStroke()
                ring.lineWidth = 0.6
                ring.stroke()
            case .recording:
                outline.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18, y: 10, width: 5, height: 5)).fill()
                recording.setFill()
                NSBezierPath(ovalIn: NSRect(x: 19, y: 11, width: 3, height: 3)).fill()
            case .processing:
                for y in [6.0, 10.0, 14.0] {
                    outline.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 20, y: y, width: 3, height: 3)).fill()
                    NSColor.systemTeal.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 20.75, y: y + 0.75, width: 1.5, height: 1.5)).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "ForIT Dictate"
        return image
    }
}
