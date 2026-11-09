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

    func testEveryStateIsTemplateSizedAndAccessible() throws {
        for appearance in DictateStatusAppearance.allCases {
            let image = DictateStatusIcon.image(for: appearance)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 18))
            XCTAssertFalse(appearance.accessibilityValue.isEmpty)
            XCTAssertEqual(image.accessibilityDescription, "ForIT Dictate")
            XCTAssertNotNil(NSImage(systemSymbolName: appearance.symbolName, accessibilityDescription: nil))
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var visiblePixels = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    if (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                        visiblePixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(visiblePixels, 0, "A valid image container must not hide a blank microphone.")
        }
    }

    func testRecordingAndProgressHaveDistinctImageShapes() throws {
        let data = try DictateStatusAppearance.allCases.map {
            try XCTUnwrap(DictateStatusIcon.image(for: $0).tiffRepresentation)
        }
        XCTAssertEqual(Set(data).count, 4, "Recording, preparing and processing must not look idle.")
        XCTAssertEqual(DictateStatusAppearance.recording.symbolName, "mic.fill")
        XCTAssertEqual(DictateStatusAppearance.idle.symbolName, "mic")
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
        for dark in [false, true] {
            let nativeAppearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            let sheet = NSImage(size: NSSize(width: 680, height: 220), flipped: false) { rect in
                nativeAppearance.performAsCurrentDrawingAppearance {
                    (dark ? NSColor.black : .white).setFill()
                    rect.fill()
                    let ink = dark ? NSColor.white : .black
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink]
                    ("ForIT Dictate - native template specimens (not Ben's desktop)" as NSString)
                        .draw(at: NSPoint(x: 20, y: 192), withAttributes: attributes)
                    for (index, appearance) in DictateStatusAppearance.allCases.enumerated() {
                        let x = CGFloat(20 + index * 125)
                        let target = NSRect(x: x, y: 145, width: 24, height: 18)
                        let image = DictateStatusIcon.image(for: appearance)
                        // Source-in applies the system's semantic template ink.
                        let tinted = NSImage(size: image.size, flipped: false) { bounds in
                            image.draw(in: bounds)
                            ink.setFill()
                            bounds.fill(using: .sourceIn)
                            return true
                        }
                        tinted.draw(in: target)
                        (appearance.rawValue as NSString).draw(at: NSPoint(x: x, y: 120), withAttributes: attributes)
                        // Enlarged alpha view supplements the actual 24x18 point image.
                        tinted.draw(in: NSRect(x: x, y: 48, width: 72, height: 54))
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
            try png.write(to: folder.appendingPathComponent(dark ? "status-dark.png" : "status-light.png"), options: .atomic)
        }
        print("FORIT_STATUS_ICON_SPECIMENS: status-light.png,status-dark.png; template24x18pt; synthetic states; no live desktop capture")
    }
}
