import AppKit

/// A microphone first, with shape changes driven by the actual engine state.
/// All ink is template alpha so macOS owns light/dark and selected-menu tint.
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

    var symbolName: String { self == .recording ? "mic.fill" : "mic" }
}

@MainActor
enum DictateStatusIcon {
    static let size = NSSize(width: 24, height: 18)
    private static let images: [DictateStatusAppearance: NSImage] =
        Dictionary(uniqueKeysWithValues: DictateStatusAppearance.allCases.map { ($0, makeImage($0)) })

    static func image(for appearance: DictateStatusAppearance) -> NSImage {
        // Every enum case is populated once; no asset lookup or audio operation.
        images[appearance]!
    }

    private static func makeImage(_ appearance: DictateStatusAppearance) -> NSImage {
        let symbol = NSImage(systemSymbolName: appearance.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        let image = NSImage(size: size, flipped: false) { _ in
            symbol?.draw(in: NSRect(x: 1, y: 0, width: 16, height: 18),
                         from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.black.setFill()
            switch appearance {
            case .idle:
                break
            case .starting:
                // An open ring means preparing, rather than already recording.
                let ring = NSBezierPath(ovalIn: NSRect(x: 19, y: 11, width: 4, height: 4))
                NSColor.black.setStroke()
                ring.lineWidth = 1
                ring.stroke()
            case .recording:
                NSBezierPath(ovalIn: NSRect(x: 18, y: 10, width: 5, height: 5)).fill()
            case .processing:
                for y in [6.0, 10.0, 14.0] {
                    NSBezierPath(ovalIn: NSRect(x: 20, y: y, width: 2, height: 2)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ForIT Dictate"
        return image
    }
}
