import AppKit
import XCTest
@testable import VoiceInk

@MainActor
final class DictateStatusIconTests: XCTestCase {
    func testEngineStatesMapToTruthfulStatus() {
        XCTAssertEqual(DictateStatusAppearance(recordingState: .idle), .idle)
        XCTAssertEqual(DictateStatusAppearance(recordingState: .starting), .starting)
        XCTAssertEqual(DictateStatusAppearance(recordingState: .recording), .recording)
        for state in [RecordingState.transcribing, .enhancing, .busy] {
            XCTAssertEqual(DictateStatusAppearance(recordingState: state), .processing)
        }
    }

    func testEveryStateIsColoredSizedAndAccessible() throws {
        for appearance in DictateStatusAppearance.allCases {
            let image = DictateStatusIcon.image(for: appearance)
            XCTAssertFalse(image.isTemplate, "Template tint would erase the recording colour.")
            XCTAssertEqual(image.size, NSSize(width: 24, height: 18))
            XCTAssertFalse(appearance.accessibilityValue.isEmpty)
            XCTAssertEqual(image.accessibilityDescription, "ForIT Dictate")
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var visiblePixels = 0
            var redPixels = 0
            var neutralPixels = 0
            var palette: [String: Int] = [:]
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    if (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                        visiblePixels += 1
                    }
                    if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.alphaComponent > 0.9 {
                        let rgb = String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                                         Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
                        palette[rgb, default: 0] += 1
                        if color.redComponent > 0.8, color.greenComponent < 0.5, color.blueComponent < 0.5 {
                            redPixels += 1
                        }
                        if color.redComponent > 0.9, color.greenComponent > 0.9, color.blueComponent > 0.9 {
                            neutralPixels += 1
                        }
                    }
                }
            }
            XCTAssertGreaterThan(visiblePixels, 0, "A valid image container must not hide a blank glyph.")
            if appearance != .recording, neutralPixels <= 8 {
                let common = palette.sorted { $0.value > $1.value }.prefix(8)
                print("FORIT_ICON_NEUTRAL_DIAGNOSTIC \(appearance.rawValue): \(common)")
                let png = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
                print("FORIT_ICON_FAILED_PNG \(appearance.rawValue): \(png.base64EncodedString())")
            }
            if appearance == .recording {
                XCTAssertGreaterThan(redPixels, 8, "The actual recording state must turn the glyph red.")
            } else {
                XCTAssertEqual(redPixels, 0, "Preparing and processing must not claim live recording.")
                XCTAssertGreaterThan(neutralPixels, 8, "The idle ForIT mark and waveform stay neutral.")
            }
        }
    }

    func testRecordingAndProgressHaveDistinctImageShapes() throws {
        let data = try DictateStatusAppearance.allCases.map {
            try XCTUnwrap(DictateStatusIcon.image(for: $0).tiffRepresentation)
        }
        XCTAssertEqual(Set(data).count, 4, "Recording, preparing and processing must not look idle.")
    }

    func testRenderNativeLightAndDarkSpecimens() throws {
        // Real AppKit rendering of the same production images. No app/window,
        // audio, clipboard or device capture. This is explicitly a specimen.
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["FORIT_STATUS_ICON_EVIDENCE"],
              let iconPath = environment["FORIT_STATUS_ICON_APPICON"] else {
            throw XCTSkip("Specimen export uses the maintained native harness; state/template checks run in ordinary Xcode tests.")
        }
        let dock = try XCTUnwrap(NSImage(contentsOfFile: iconPath))
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for variant in ["light", "dark", "selected"] {
            let dark = variant == "dark"
            let nativeAppearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            let sheet = NSImage(size: NSSize(width: 680, height: 220), flipped: false) { rect in
                nativeAppearance.performAsCurrentDrawingAppearance {
                    (variant == "selected" ? NSColor.selectedContentBackgroundColor : dark ? .black : .white).setFill()
                    rect.fill()
                    let ink = dark || variant == "selected" ? NSColor.white : .black
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink]
                    ("ForIT Dictate - native colour specimens (not Ben's desktop)" as NSString)
                        .draw(at: NSPoint(x: 20, y: 192), withAttributes: attributes)
                    for (index, appearance) in DictateStatusAppearance.allCases.enumerated() {
                        let x = CGFloat(20 + index * 125)
                        let target = NSRect(x: x, y: 145, width: 24, height: 18)
                        let image = DictateStatusIcon.image(for: appearance)
                        image.draw(in: target)
                        (appearance.rawValue as NSString).draw(at: NSPoint(x: x, y: 120), withAttributes: attributes)
                        // Enlarged alpha view supplements the actual 24x18 point image.
                        image.draw(in: NSRect(x: x, y: 48, width: 72, height: 54))
                    }
                    dock.draw(in: NSRect(x: 550, y: 90, width: 80, height: 80))
                    ("Shared app icon" as NSString).draw(at: NSPoint(x: 535, y: 67), withAttributes: attributes)
                    ("Top row: actual 24x18 pt. Bottom row: 3x detail. Engine-state fixtures; no recording started." as NSString)
                        .draw(at: NSPoint(x: 20, y: 15), withAttributes: attributes)
                }
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("status-\(variant).png"), options: .atomic)
        }
        print("FORIT_STATUS_ICON_SPECIMENS: status-light.png,status-dark.png,status-selected.png; colour24x18pt; synthetic states; no live desktop capture")
    }
}
