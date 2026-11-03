import AppKit
import Foundation
import ForITCommon
import SwiftUI
import XCTest

private let fixtureCaption = "Alternate-host native rendering • nonprivate fixture"
private let commonRevision = "352f567e839b8faf61b6df5840c5275b016addce"

private enum RenderFailure: LocalizedError {
    case arguments(String)
    case appearance(String)
    case noImage(String)
    case noPNG(String)

    var errorDescription: String? {
        switch self {
        case .arguments(let detail): return detail
        case .appearance(let name): return "The native drawing appearance is unavailable for \(name)."
        case .noImage(let name): return "ImageRenderer produced no native image for \(name)."
        case .noPNG(let name): return "The native image could not be encoded as PNG for \(name)."
        }
    }
}

private struct Options: Sendable {
    let output: URL
    let source: String
    let version: String
    let build: String

    init(arguments: [String]) throws {
        let expected: Set<String> = ["--output", "--source", "--reference-version", "--reference-build"]
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard expected.contains(key), values[key] == nil, index + 1 < arguments.count else {
                throw RenderFailure.arguments("Supply --output DIR --source FULLSHA --reference-version VERSION --reference-build BUILD once each.")
            }
            let value = arguments[index + 1]
            guard !value.isEmpty, !value.hasPrefix("--"),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RenderFailure.arguments("Each argument requires a nonempty value without control characters.")
            }
            values[key] = value
            index += 2
        }
        guard values.count == expected.count,
              let directory = values["--output"], let source = values["--source"],
              let version = values["--reference-version"], let build = values["--reference-build"],
              source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw RenderFailure.arguments("All four arguments are required; --source must be a full lowercase 40-character commit SHA.")
        }
        self.output = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        self.source = source
        self.version = version
        self.build = build
    }

    var reference: ForITAppInfo {
        ForITAppInfo(name: "ForIT Dictate", bundleId: "io.forit.dictate", version: version, build: build)
    }

    var referenceCaption: String {
        "Reference build \(reference.versionAndBuild); not installed-app readback"
    }
}

private struct FixtureFooter: View {
    let options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fixtureCaption)
            Text("Rendered on: \(ProcessInfo.processInfo.hostName)")
            Text(options.referenceCaption)
            Text("Reference source: \(options.source)")
                .font(.system(.caption, design: .monospaced))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuMarkFixture: View {
    let options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictate menu label • rendering fixture").font(.headline)
            // GeneratedMenuLabel.swift supplies this view from the shipped label
            // source. This is a standalone native view, not an NSStatusItem.
            ShippedMenuLabel()
                .frame(height: 30)
            Text("Shipped glyph sizes; standalone surface, not a captured menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            FixtureFooter(options: options)
        }
        .padding(24)
        .frame(width: 760, height: 240, alignment: .topLeading)
        .background(ForITBrand.screenBackground)
    }
}

private struct IdentityFixture: View {
    let options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictate identity • rendering fixture").font(.headline)
            HStack(spacing: 16) {
                ForITMark(size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(options.reference.versionLine).font(.title2)
                    Text(options.reference.bundleId).font(.body)
                }
            }
            Text("Shared ForIT mark and supplied reference identity; not an About window.")
                .font(.caption)
                .foregroundStyle(.secondary)
            FixtureFooter(options: options)
        }
        .padding(24)
        .frame(width: 760, height: 280, alignment: .topLeading)
        .background(ForITBrand.screenBackground)
    }
}

private struct ImageRecord: Encodable {
    let filename: String
    let fixture: String
    let colorScheme: String
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Double
    let logicalHeight: Double
    let requestedScale: Double
    let byteCount: Int
}

private struct RenderRecord: Encodable {
    let schema = "forit.dictate.alternate-host-native-render.v1"
    let status = "rendered-fixtures-only"
    let generatedAtUTC: String
    let host: String
    let operatingSystem: String
    let processID: Int32
    let sourceArgument: String
    let referenceVersion: String
    let referenceBuild: String
    let referenceBundleID = "io.forit.dictate"
    let commonDependencyRevision = commonRevision
    let renderer = "SwiftUI.ImageRenderer → NSImage → NSBitmapImageRep PNG"
    let visibleCaption = fixtureCaption
    let fixturesOnly = true
    let installedAppReadback = false
    let desktopCapturePerformed = false
    let windowCreated = false
    let appLaunchedOrActivated = false
    let privateDataRead = false
    let sourceAttribution = "FORIT_RENDER_SOURCE is a declared reference; the preparer separately binds generated label source."
    let limitations = [
        "Standalone SwiftUI fixtures on the recorded host and process; no installed Dictate process was inspected.",
        "Menu glyph appearance does not prove NSStatusItem layout, highlighting, accessibility behavior or the user's visible desktop.",
        "Identity text is supplied reference metadata, not an installed bundle version or a captured About window.",
    ]
    let images: [ImageRecord]
}

final class DictateOffscreenProofTests: XCTestCase {
    func testRenderFixtures() async throws {
        let environment = ProcessInfo.processInfo.environment
        let mapping = [
            ("--output", "FORIT_RENDER_OUTPUT"),
            ("--source", "FORIT_RENDER_SOURCE"),
            ("--reference-version", "FORIT_RENDER_REFERENCE_VERSION"),
            ("--reference-build", "FORIT_RENDER_REFERENCE_BUILD"),
        ]
        var arguments: [String] = []
        for (option, key) in mapping {
            guard let value = environment[key], !value.isEmpty else {
                throw RenderFailure.arguments("Required environment value is missing: \(key).")
            }
            arguments.append(contentsOf: [option, value])
        }
        let options = try Options(arguments: arguments)
        try await MainActor.run {
            try DictateOffscreenRenderer.renderFixtures(options: options)
        }
    }
}

@MainActor
private enum DictateOffscreenRenderer {
    static func renderFixtures(options: Options) throws {
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let receiptURL = options.output.appendingPathComponent("native-render.json")
        // A failed rerun must not leave a previous completed receipt looking current.
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try FileManager.default.removeItem(at: receiptURL)
        }
        var images: [ImageRecord] = []
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            images.append(try render(
                MenuMarkFixture(options: options), filename: "menu-mark-\(name).png",
                fixture: "shipped-menu-label-on-standalone-surface", scheme: scheme,
                schemeName: name, output: options.output
            ))
            images.append(try render(
                IdentityFixture(options: options), filename: "identity-\(name).png",
                fixture: "shared-brand-reference-identity", scheme: scheme,
                schemeName: name, output: options.output
            ))
        }
        let process = ProcessInfo.processInfo
        let record = RenderRecord(
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            host: process.hostName, operatingSystem: process.operatingSystemVersionString,
            processID: process.processIdentifier, sourceArgument: options.source,
            referenceVersion: options.version, referenceBuild: options.build, images: images
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: receiptURL, options: .atomic)
        print("Wrote four alternate-host native fixtures and native-render.json; no installed-app or desktop proof is claimed.")
    }

    private static func render<Content: View>(
        _ content: Content, filename: String, fixture: String,
        scheme: ColorScheme, schemeName: String, output: URL
    ) throws -> ImageRecord {
        guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) else {
            throw RenderFailure.appearance(schemeName)
        }
        var renderedImage: NSImage?
        var renderedBitmap: CGImage?
        // Shared adaptive colors use NSColor's current AppKit appearance. Scope
        // native evaluation and image extraction as well as SwiftUI's scheme.
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
            renderer.scale = 2
            renderer.isOpaque = true
            renderedImage = renderer.nsImage
            renderedBitmap = renderedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let nativeImage = renderedImage, let bitmap = renderedBitmap,
              bitmap.width > 0, bitmap.height > 0 else {
            throw RenderFailure.noImage(filename)
        }
        let representation = NSBitmapImageRep(cgImage: bitmap)
        guard let png = representation.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw RenderFailure.noPNG(filename)
        }
        try png.write(to: output.appendingPathComponent(filename), options: .atomic)
        return ImageRecord(
            filename: filename, fixture: fixture, colorScheme: schemeName,
            pixelWidth: bitmap.width, pixelHeight: bitmap.height,
            logicalWidth: Double(nativeImage.size.width), logicalHeight: Double(nativeImage.size.height),
            requestedScale: 2, byteCount: png.count
        )
    }
}
