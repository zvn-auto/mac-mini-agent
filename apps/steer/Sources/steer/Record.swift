import ArgumentParser
import AppKit
import Foundation

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture rapid sequential screenshots over a time period (burst mode)."
    )

    @Option(name: .long, help: "Duration in seconds (default: 3)")
    var duration: Double = 3.0

    @Option(name: .long, help: "Frames per second, max 30 (default: 5)")
    var fps: Int = 5

    @Option(name: .long, help: "Target app name (default: frontmost)")
    var app: String?

    @Option(name: .long, help: "Screen index to capture (from 'steer screens')")
    var screen: Int?

    @Flag(name: .long, help: "Skip saving frames to disk (just output timing info)")
    var noSave = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func validate() throws {
        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }
        guard duration > 0 && duration <= 60 else {
            throw ValidationError("Duration must be between 0 and 60 seconds")
        }
    }

    func run() throws {
        let clampedFps = min(fps, 30)
        let totalFrames = Int(duration * Double(clampedFps))
        let interval: TimeInterval = 1.0 / Double(clampedFps)

        // Resolve capture target once up front
        let target: NSRunningApplication?
        let captureScreen: Int?

        if let screenIndex = screen, app == nil {
            target = nil
            captureScreen = screenIndex
        } else if let name = app {
            guard let found = AppControl.find(name) else {
                throw SteerError.appNotFound(name)
            }
            target = found
            captureScreen = nil
        } else {
            target = AppControl.frontmost()
            captureScreen = nil
        }

        // Create output directory
        let sessionId = String(UUID().uuidString.prefix(8).lowercased())
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steer")
            .appendingPathComponent("record-\(sessionId)")

        if !noSave {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        // Capture loop
        var framesCaptured = 0
        let startTime = CFAbsoluteTimeGetCurrent()

        for i in 0..<totalFrames {
            let frameStart = CFAbsoluteTimeGetCurrent()

            let image: CGImage
            if let idx = captureScreen {
                image = try ScreenCapture.captureScreen(index: idx)
            } else if let app = target {
                image = try ScreenCapture.captureApp(app)
            } else {
                image = try ScreenCapture.captureDisplay()
            }

            if !noSave {
                let frameName = String(format: "frame-%03d.jpg", i + 1)
                let frameURL = outputDir.appendingPathComponent(frameName)
                try ScreenCapture.saveJPEG(image, to: frameURL)
            }

            framesCaptured += 1

            // Sleep for remaining interval time
            let elapsed = CFAbsoluteTimeGetCurrent() - frameStart
            let sleepTime = interval - elapsed
            if sleepTime > 0 && i < totalFrames - 1 {
                Thread.sleep(forTimeInterval: sleepTime)
            }
        }

        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let actualFps = totalElapsed > 0 ? Double(framesCaptured) / totalElapsed : 0

        // Output summary
        let targetName: String
        if let idx = captureScreen {
            targetName = "screen-\(idx)"
        } else {
            targetName = target?.localizedName ?? "(display)"
        }

        if json {
            let dir = noSave ? "" : outputDir.path
            print("""
            {"session":"\(sessionId)","target":"\(targetName)","frames":\(framesCaptured),"duration":\(String(format: "%.2f", totalElapsed)),"requestedFps":\(clampedFps),"actualFps":\(String(format: "%.1f", actualFps)),"directory":"\(dir)"}
            """)
        } else {
            print("session: \(sessionId)")
            print("target: \(targetName)")
            print("frames: \(framesCaptured)")
            print("duration: \(String(format: "%.2f", totalElapsed))s")
            print("requested fps: \(clampedFps)")
            print("actual fps: \(String(format: "%.1f", actualFps))")
            if !noSave {
                print("directory: \(outputDir.path)")
            } else {
                print("(frames not saved)")
            }
        }
    }
}
