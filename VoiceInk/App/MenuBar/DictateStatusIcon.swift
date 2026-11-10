import AppKit

/// The same speech/waveform master used by the app icon, with real engine-state marks.
/// Gold fill and dark structure keep the silhouette distinct from Squelch in every theme.
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
    private static let gold = color(DictateGlyphAsset.accentRGB)
    private static let outline = color(DictateGlyphAsset.inkRGB)
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

    private static func makeImage(_ appearance: DictateStatusAppearance) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: 0, width: 19, height: 18),
                       from: .zero, operation: .sourceOver, fraction: 1)
            switch appearance {
            case .idle:
                break
            case .starting:
                // An open ring means preparing, rather than already recording.
                let ring = NSBezierPath(ovalIn: NSRect(x: 19, y: 11, width: 4, height: 4))
                outline.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
                gold.setStroke()
                ring.lineWidth = 0.6
                ring.stroke()
            case .recording:
                outline.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18, y: 10, width: 5, height: 5)).fill()
                gold.setFill()
                NSBezierPath(ovalIn: NSRect(x: 19, y: 11, width: 3, height: 3)).fill()
            case .processing:
                for y in [6.0, 10.0, 14.0] {
                    outline.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 20, y: y, width: 3, height: 3)).fill()
                    gold.setFill()
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
