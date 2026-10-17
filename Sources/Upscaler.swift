import SwiftUI
import AppKit

// MARK: - Model

struct VideoInfo {
    let width: Int
    let height: Int
    let fps: String          // exact rational from ffprobe, e.g. "24000/1001"
    let fpsValue: Double
    let duration: Double
    let audioCodecs: [String]
    let sar: Double          // pixel shape; DVDs use non-square pixels (e.g. 32:27 for 16:9)
    let interlaced: Bool
    let colorMatrix: String  // swscale name of the source matrix: bt709 or bt601

    var displayAspect: Double { Double(width) * sar / Double(max(height, 1)) }
    var isSD: Bool { height <= 576 }
}

enum UpscaleMethod: String, CaseIterable, Identifiable {
    case standard = "Standard", ai = "AI (Real-ESRGAN)"
    var id: String { rawValue }
}

enum UpscaleTarget: String, CaseIterable, Identifiable {
    case hd1080 = "1080p", uhd4k = "4K"
    var id: String { rawValue }
    var box: (w: Int, h: Int) { self == .hd1080 ? (1920, 1080) : (3840, 2160) }
    /// Standard mode: seconds of work per second of video on an M1 (measured; dominated by output size).
    var standardCost: Double { self == .hd1080 ? 0.55 : 1.45 }
}

enum UpscaleQuality: String, CaseIterable, Identifiable {
    case balanced = "Balanced", high = "High"
    var id: String { rawValue }
    func mbps(for target: UpscaleTarget) -> Int {
        switch (self, target) {
        case (.balanced, .hd1080): 6
        case (.high, .hd1080): 10
        case (.balanced, .uhd4k): 14
        case (.high, .uhd4k): 24
        }
    }
}

enum UpscalePhase: Equatable {
    case idle, probing, ready
    case working(title: String, progress: Double?, detail: String)
    case done(URL)
    case failed(String)
}

@MainActor
final class Upscaler: ObservableObject {
    @Published var input: URL?
    @Published var info: VideoInfo?
    @Published var method: UpscaleMethod = .standard {
        didSet {
            // AI is only practical on short clips, so start with a 30-second range.
            if method == .ai, !useRange, let info {
                useRange = true
                startText = "0:00"
                endText = formatTime(min(30, info.duration))
            }
        }
    }
    @Published var quality: UpscaleQuality = .balanced
    @Published var resolution: UpscaleTarget = .uhd4k
    @Published var useRange = false
    @Published var startText = "0:00"
    @Published var endText = ""
    @Published var outputDir: URL?
    @Published var phase: UpscalePhase = .idle
    @Published var engineInstalled = FileManager.default.isExecutableFile(atPath: Upscaler.engineBinary.path)
    @Published var installingEngine = false
    @Published var engineError: String?

    private var current: Process?
    private var cancelled = false
    private var activity: NSObjectProtocol?

    // Measured on an M1: Real-ESRGAN (realesr-animevideov3 ×2) ≈ 3.8 s per 1080p frame, cost scales with
    // input pixels (480p ×4 ≈ 0.75 s). Standard mode cost lives on UpscaleTarget.
    // standard lanczos + HEVC hardware encode ≈ 1.4× real time.
    static let aiSecondsPerFrame1080 = 3.8
    static let chunkFrames = 64

    // MARK: Derived

    var range: (start: Double, length: Double)? {
        guard let info else { return nil }
        guard useRange else { return (0, info.duration) }
        guard let s = parseTime(startText), let e = parseTime(endText), s < info.duration, e > s else { return nil }
        return (s, min(e, info.duration) - s)
    }

    /// Fit inside the target box at the true display shape: for 4K, 16:9 → 3840×2160, 4:3 → 2880×2160,
    /// scope → 3840×1600 (1080p is the same at half size).
    var target: (w: Int, h: Int)? {
        guard let info, info.width > 0, info.height > 0 else { return nil }
        let even = { (x: Double) in Int((x / 2).rounded()) * 2 }
        let dar = info.displayAspect, box = resolution.box
        return dar >= Double(box.w) / Double(box.h) ? (box.w, even(Double(box.w) / dar)) : (even(Double(box.h) * dar), box.h)
    }

    var alreadyAtTarget: Bool {
        guard let info else { return false }
        return info.width >= resolution.box.w || info.height >= resolution.box.h
    }

    /// Real-ESRGAN scale (its video model comes in ×2, ×3, ×4); ffmpeg covers the remainder.
    var aiScale: Int {
        guard let info, let target else { return 2 }
        let factor = Double(target.h) / Double(info.height)
        return factor >= 3.5 ? 4 : factor >= 2.5 ? 3 : 2
    }

    /// Filters applied to the source before any scaling.
    private func cleanupFilters(_ info: VideoInfo, denoise: Bool) -> String {
        var f: [String] = []
        if info.interlaced { f.append("bwdif=mode=send_frame") }
        if denoise && info.isSD { f.append("hqdn3d=1.5:1.5:6:6") }   // stop compression noise being magnified
        return f.map { $0 + "," }.joined()
    }

    private var pixelFactor: Double {
        guard let info else { return 1 }
        return Double(info.width * info.height) / (1920 * 1080)
    }

    var estimatedSeconds: Double? {
        guard let info, let r = range else { return nil }
        switch method {
        case .standard: return r.length * resolution.standardCost
        case .ai: return r.length * info.fpsValue * Self.aiSecondsPerFrame1080 * pixelFactor * (aiScale == 4 ? 1.2 : 1)
        }
    }

    /// Final file plus, for AI, the temporary JPEG frames (~0.6 MB each) and one chunk of 4K PNGs.
    var estimatedDiskBytes: Double? {
        guard let info, let r = range else { return nil }
        var bytes = r.length * Double(quality.mbps(for: resolution)) * 1_000_000 / 8
        if method == .ai { bytes += r.length * info.fpsValue * 0.6e6 * pixelFactor + Double(Self.chunkFrames) * 20e6 }
        return bytes
    }

    var freeBytes: Double? {
        guard let dir = outputDir,
              let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return v.volumeAvailableCapacityForImportantUsage.map(Double.init)
    }

    var canStart: Bool {
        phase == .ready && range != nil && !alreadyAtTarget && (method == .standard || engineInstalled)
    }

    // MARK: Load

    func load(_ url: URL) {
        input = url
        outputDir = url.deletingLastPathComponent()
        info = nil
        phase = .probing
        Task {
            do {
                let info = try await Self.probe(url)
                guard input == url else { return }
                self.info = info
                // 480p/720p sources gain nothing visible at 4K over 1080p; larger sources go to 4K.
                resolution = info.height <= 720 ? .hd1080 : .uhd4k
                useRange = method == .ai
                startText = "0:00"
                endText = formatTime(method == .ai ? min(30, info.duration) : info.duration)
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func probe(_ url: URL) async throws -> VideoInfo {
        guard let dir = Extractor.ffmpegDir else { throw AppError("ffmpeg not found. Install it with: brew install ffmpeg") }
        let data = try await Extractor.run("\(dir)/ffprobe", ["-v", "error",
            "-show_entries", "stream=codec_type,codec_name,width,height,r_frame_rate,sample_aspect_ratio,field_order,color_space:format=duration",
            "-of", "json", url.path])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Couldn't read this file.")
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        guard let v = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            throw AppError("This file has no video.")
        }
        let fps = v["r_frame_rate"] as? String ?? "24/1"
        let parts = fps.split(separator: "/").compactMap { Double($0) }
        let fpsValue = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : (parts.first ?? 24)
        let height = v["height"] as? Int ?? 0
        let sarParts = (v["sample_aspect_ratio"] as? String ?? "1:1").split(separator: ":").compactMap { Double($0) }
        let sar = sarParts.count == 2 && sarParts[0] > 0 && sarParts[1] > 0 ? sarParts[0] / sarParts[1] : 1
        let space = v["color_space"] as? String ?? ""
        let matrix = space == "bt709" ? "bt709"
            : ["smpte170m", "bt470bg"].contains(space) ? "bt601"
            : height <= 576 ? "bt601" : "bt709"
        return VideoInfo(width: v["width"] as? Int ?? 0, height: height,
                         fps: fps, fpsValue: fpsValue,
                         duration: Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0,
                         audioCodecs: streams.filter { $0["codec_type"] as? String == "audio" }
                            .map { $0["codec_name"] as? String ?? "" },
                         sar: sar,
                         interlaced: ["tt", "bb", "tb", "bt"].contains(v["field_order"] as? String ?? ""),
                         colorMatrix: matrix)
    }

    // MARK: AI engine

    static let engineURL = URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip")!
    nonisolated static var engineDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReelKit/realesrgan", isDirectory: true)
    }

    /// Moves an engine downloaded when the app was called "Movie Audio" so it isn't fetched again.
    nonisolated static func migrateLegacyEngine() {
        let fm = FileManager.default
        let legacyRoot = engineDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MovieAudio", isDirectory: true)
        let legacy = legacyRoot.appendingPathComponent("realesrgan", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: engineDir.path) else { return }
        try? fm.createDirectory(at: engineDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: engineDir)
        if (try? fm.contentsOfDirectory(atPath: legacyRoot.path))?.isEmpty == true { try? fm.removeItem(at: legacyRoot) }
    }
    nonisolated static var engineBinary: URL { engineDir.appendingPathComponent("realesrgan-ncnn-vulkan") }

    func installEngine() {
        installingEngine = true
        engineError = nil
        Task {
            defer { installingEngine = false }
            do {
                let fm = FileManager.default
                let (zip, response) = try await URLSession.shared.download(from: Self.engineURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("Download failed.") }
                let staging = fm.temporaryDirectory.appendingPathComponent("realesrgan-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: staging); try? fm.removeItem(at: zip) }
                _ = try await Extractor.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
                guard fm.fileExists(atPath: staging.appendingPathComponent("realesrgan-ncnn-vulkan").path) else {
                    throw AppError("Unexpected download contents.")
                }
                // Drop the demo media that ships in the zip.
                for junk in ["onepiece_demo.mp4", "input.jpg", "input2.jpg"] {
                    try? fm.removeItem(at: staging.appendingPathComponent(junk))
                }
                try? fm.removeItem(at: Self.engineDir)
                try fm.createDirectory(at: Self.engineDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staging, to: Self.engineDir)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.engineBinary.path)
                _ = try? await Extractor.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Self.engineDir.path])
                engineInstalled = fm.isExecutableFile(atPath: Self.engineBinary.path)
            } catch {
                engineError = error.localizedDescription
            }
        }
    }

    // MARK: Run

    func outputURL() -> URL {
        let base = input!.deletingPathExtension().lastPathComponent
        let tag = resolution.rawValue + (method == .ai ? " AI" : "")
        let dir = outputDir ?? input!.deletingLastPathComponent()
        var url = dir.appendingPathComponent("\(base) \(tag).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(tag) \(n).mp4")
            n += 1
        }
        return url
    }

    func start() {
        guard canStart, let input, let info, let range, let target else { return }
        let output = outputURL()
        cancelled = false
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Upscaling video")
        phase = .working(title: "Starting…", progress: nil, detail: "")
        Task {
            do {
                switch method {
                case .standard: try await runStandard(input, info, range, target, output)
                case .ai: try await runAI(input, info, range, target, output)
                }
                phase = .done(output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                phase = cancelled ? .ready : .failed(error.localizedDescription)
            }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    func cancel() {
        cancelled = true
        current?.terminate()
    }

    private var videoEncodeArgs: [String] {
        ["-c:v", "hevc_videotoolbox", "-b:v", "\(quality.mbps(for: resolution))M", "-tag:v", "hvc1",
         "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
    }

    /// Copy audio that MP4 can hold; convert anything else (DTS, TrueHD, PCM…) to AAC.
    private func audioArgs(_ info: VideoInfo) -> [String] {
        info.audioCodecs.enumerated().flatMap { i, codec in
            ["aac", "ac3", "eac3", "alac", "mp3", "opus"].contains(codec)
                ? ["-c:a:\(i)", "copy"]
                : ["-c:a:\(i)", "aac", "-b:a:\(i)", "256k"]
        }
    }

    private func runStandard(_ input: URL, _ info: VideoInfo, _ r: (start: Double, length: Double),
                             _ t: (w: Int, h: Int), _ output: URL) async throws {
        let ff = "\(Extractor.ffmpegDir!)/ffmpeg"
        let started = Date()
        let length = r.length
        try await run(ff, ["-hide_banner", "-nostdin", "-nostats", "-v", "error", "-y",
                           "-ss", String(format: "%.3f", r.start), "-t", String(format: "%.3f", r.length),
                           "-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-sn",
                           "-vf", cleanupFilters(info, denoise: true)
                                + "scale=\(t.w):\(t.h):flags=lanczos:in_color_matrix=\(info.colorMatrix):out_color_matrix=bt709,setsar=1,cas=strength=0.4"]
                      + videoEncodeArgs + audioArgs(info)
                      + ["-movflags", "+faststart", "-progress", "pipe:1", output.path]) { [weak self] line in
            guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), length > 0 else { return }
            let done = min(max(us / 1_000_000 / length, 0), 1)
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                self.phase = .working(title: "Upscaling…", progress: done, detail: Self.eta(done: done, since: started))
            }
        }
    }

    private func runAI(_ input: URL, _ info: VideoInfo, _ r: (start: Double, length: Double),
                       _ t: (w: Int, h: Int), _ output: URL) async throws {
        let fm = FileManager.default
        let ff = "\(Extractor.ffmpegDir!)/ffmpeg"
        let work = fm.temporaryDirectory.appendingPathComponent("ReelKit-upscale-\(UUID().uuidString)")
        let frames = work.appendingPathComponent("frames"), chunkIn = work.appendingPathComponent("in")
        let chunkOut = work.appendingPathComponent("out"), segments = work.appendingPathComponent("seg")
        for d in [frames, chunkIn, chunkOut, segments] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: work) }

        // 1. Decode the clip to JPEG frames. JPEG decoders assume BT.601 full range, so convert to
        //    exactly that; the upscaled frames are converted back to BT.709 when encoding.
        phase = .working(title: "Extracting frames…", progress: nil, detail: "")
        try await run(ff, ["-hide_banner", "-nostdin", "-v", "error", "-y",
                           "-ss", String(format: "%.3f", r.start), "-t", String(format: "%.3f", r.length),
                           "-i", input.path, "-map", "0:v:0",
                           "-vf", cleanupFilters(info, denoise: false)
                                + "fps=\(info.fps),scale=in_color_matrix=\(info.colorMatrix):in_range=tv:out_color_matrix=bt601:out_range=pc,format=yuvj420p",
                           "-q:v", "2", frames.appendingPathComponent("%06d.jpg").path])
        let all = try fm.contentsOfDirectory(atPath: frames.path).filter { $0.hasSuffix(".jpg") }.sorted()
        guard !all.isEmpty else { throw AppError("No frames could be read from this part of the video.") }

        // 2. Upscale in small chunks so disk use stays low, encoding each chunk to an HEVC segment.
        let started = Date()
        let scale = aiScale
        var segmentList = ""
        let chunks = stride(from: 0, to: all.count, by: Self.chunkFrames).map { Array(all[$0..<min($0 + Self.chunkFrames, all.count)]) }
        for (ci, chunk) in chunks.enumerated() {
            if cancelled { throw CancellationError() }
            for name in try fm.contentsOfDirectory(atPath: chunkOut.path) { try fm.removeItem(at: chunkOut.appendingPathComponent(name)) }
            for name in chunk { try fm.moveItem(at: frames.appendingPathComponent(name), to: chunkIn.appendingPathComponent(name)) }

            let doneBefore = ci * Self.chunkFrames
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    let n = (try? fm.contentsOfDirectory(atPath: chunkOut.path).count) ?? 0
                    let done = Double(doneBefore + n) / Double(all.count)
                    self?.phase = .working(title: "AI upscaling frame \(doneBefore + n + 1) of \(all.count)…",
                                           progress: done, detail: Self.eta(done: done, since: started))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { poll.cancel() }
            try await run(Self.engineBinary.path, ["-i", chunkIn.path, "-o", chunkOut.path,
                                                   "-n", "realesr-animevideov3", "-s", "\(scale)",
                                                   "-m", Self.engineDir.appendingPathComponent("models").path, "-f", "png"])
            poll.cancel()
            if cancelled { throw CancellationError() }

            let seg = segments.appendingPathComponent(String(format: "%05d.mp4", ci))
            try await run(ff, ["-hide_banner", "-nostdin", "-v", "error", "-y",
                               "-framerate", info.fps, "-pattern_type", "glob",
                               "-i", chunkOut.appendingPathComponent("*.png").path,
                               "-vf", "scale=\(t.w):\(t.h):flags=lanczos:out_color_matrix=bt709:out_range=tv,setsar=1,format=yuv420p"]
                          + videoEncodeArgs + [seg.path])
            segmentList += "file '\(seg.path)'\n"
            for name in chunk { try? fm.removeItem(at: chunkIn.appendingPathComponent(name)) }
        }

        // 3. Join the segments and add the original audio for the same range.
        phase = .working(title: "Finishing…", progress: 1, detail: "")
        let list = work.appendingPathComponent("segments.txt")
        try segmentList.write(to: list, atomically: true, encoding: .utf8)
        try await run(ff, ["-hide_banner", "-nostdin", "-v", "error", "-y",
                           "-f", "concat", "-safe", "0", "-i", list.path,
                           "-ss", String(format: "%.3f", r.start), "-t", String(format: "%.3f", r.length), "-i", input.path,
                           "-map", "0:v", "-map", "1:a?", "-c:v", "copy"]
                      + audioArgs(info) + ["-movflags", "+faststart", output.path])
    }

    /// Runs a tool, streaming stdout lines to `onLine`; throws with the tail of stderr on failure.
    private func run(_ exe: String, _ args: [String], onLine: (@Sendable (Substring) -> Void)? = nil) async throws {
        if cancelled { throw CancellationError() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let errBuf = ErrorBuffer()
        err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
        out.fileHandleForReading.readabilityHandler = { h in
            guard let onLine, let text = String(data: h.availableData, encoding: .utf8) else { return }
            text.split(separator: "\n").forEach(onLine)
        }
        current = p
        defer { current = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 { cont.resume() }
                else if p.terminationReason == .uncaughtSignal { cont.resume(throwing: CancellationError()) }
                else { cont.resume(throwing: AppError(errBuf.tail.isEmpty ? "\(URL(fileURLWithPath: exe).lastPathComponent) failed" : errBuf.tail)) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    nonisolated static func eta(done: Double, since start: Date) -> String {
        let elapsed = Date().timeIntervalSince(start)
        guard done > 0.01, elapsed > 5 else { return "Estimating time left…" }
        return "About \(formatDuration(elapsed / done - elapsed)) left"
    }
}

/// Parses "1:02:03.5", "2:30" or "90" into seconds.
func parseTime(_ s: String) -> Double? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
    return parts.reduce(0) { $0 * 60 + $1! }
}

/// "45 s", "12 min", "3 h 20 min", "2 days 4 h"
func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(max(s, 1)) s" }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) h \(s / 60 % 60) min" }
    return "\(s / 86400) day\(s >= 172800 ? "s" : "") \(s / 3600 % 24) h"
}

// MARK: - View

struct UpscaleView: View {
    @StateObject private var u = Upscaler()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            header
            if u.info != nil { options }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in u.load(url) } }
            }
            return true
        }
        .disabled(isBusy)
    }

    private var isBusy: Bool { if case .working = u.phase { true } else { false } }

    @ViewBuilder private var header: some View {
        if let input = u.input {
            HStack(spacing: 12) {
                Image(systemName: "film").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(input.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let i = u.info, let t = u.target {
                        Text("\(i.width)×\(i.height)\(i.interlaced ? "i" : "") · \(i.fpsValue, format: .number.precision(.fractionLength(0...3))) fps · \(formatTime(i.duration))  →  \(t.w)×\(t.h)")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Button("Choose Another…", action: chooseVideo)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        } else {
            Button(action: chooseVideo) {
                VStack(spacing: 8) {
                    Image(systemName: "4k.tv").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Drop a 480p, 720p or 1080p video here").font(.headline)
                    Text("or click to choose a file").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5)))
            }
            .buttonStyle(.plain)
        }
    }

    private var options: some View {
        Form {
            Picker("Resolution", selection: $u.resolution) {
                ForEach(UpscaleTarget.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if u.alreadyAtTarget {
                Label("This video is already \(u.resolution.rawValue) or larger.", systemImage: "info.circle").foregroundStyle(.secondary)
            } else if let i = u.info, i.height <= 720 {
                Text(u.resolution == .hd1080
                     ? "Recommended for this source: same visible detail as 4K, about half the size, and plays everywhere. A 4K TV scales 1080p up cleanly."
                     : "4K adds little visible detail over 1080p for this source. Worth it if your TV's own upscaling looks poor, or for YouTube uploads.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Method", selection: $u.method) {
                ForEach(UpscaleMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(u.method == .standard
                 ? "High-quality resize with edge sharpening, using your Mac's video hardware. Fast enough for whole movies; it makes the picture cleaner on a big screen but can't add real detail."
                 : "An AI model redraws each frame at 2–4× the resolution, restoring sharper edges and texture. Very slow — best for short clips. It's tuned for animation; on live action, faces and skin can look slightly painted.")
                .font(.caption).foregroundStyle(.secondary)

            if let i = u.info, i.isSD {
                Text("Low-resolution source\(i.interlaced ? " (interlaced — will be deinterlaced)" : ""). This is where AI helps most: it uses its ×\(u.aiScale) model. Standard will look soft.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if u.method == .ai && !u.engineInstalled {
                LabeledContent("AI engine") {
                    if u.installingEngine {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                    } else {
                        Button("Download (50 MB)", action: u.installEngine)
                    }
                }
                if let e = u.engineError { Text(e).font(.caption).foregroundStyle(.red) }
            }

            Picker("Quality", selection: $u.quality) {
                ForEach(UpscaleQuality.allCases) { Text("\($0.rawValue) (\($0.mbps(for: u.resolution)) Mbps)").tag($0) }
            }

            Toggle("Only part of the video", isOn: $u.useRange)
            if u.useRange {
                HStack {
                    // Labels hidden: inside a grouped Form they would otherwise stack above the fields.
                    TextField("Start", text: $u.startText).labelsHidden().frame(width: 90)
                    Text("to")
                    TextField("End", text: $u.endText).labelsHidden().frame(width: 90)
                    Text("h:mm:ss").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let r = u.range { Text(formatTime(r.length)).monospacedDigit().foregroundStyle(.secondary) }
                    else { Text("Invalid range").foregroundStyle(.red) }
                }
                .textFieldStyle(.roundedBorder)
            }

            estimate

            LabeledContent("Save to") {
                HStack {
                    Text(u.outputDir?.lastPathComponent ?? "—").lineLimit(1).truncationMode(.middle)
                    Button("Change…", action: chooseFolder).controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var estimate: some View {
        if let secs = u.estimatedSeconds, let bytes = u.estimatedDiskBytes {
            let tooLong = secs > 12 * 3600
            let tooBig = (u.freeBytes ?? .infinity) < bytes * 1.1
            LabeledContent("Estimate") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("≈ \(formatDuration(secs))").foregroundStyle(tooLong ? .orange : .primary)
                    Text("needs ≈ \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                         + (u.freeBytes.map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) free" } ?? ""))
                        .font(.caption).foregroundStyle(tooBig ? .red : .secondary)
                }
            }
            if tooLong && u.method == .ai {
                Text("That's a long time for AI upscaling. Try a shorter range, or use Standard for whole movies.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if tooBig {
                Text("Not enough free disk space. Free some space, pick another folder, or shorten the range.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch u.phase {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().controlSize(.small)
        case .ready:
            Button(action: u.start) {
                Label("Upscale to \(u.resolution.rawValue)", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!u.canStart)
        case .working(let title, let progress, let detail):
            VStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress) { Text(title) } currentValueLabel: {
                        HStack {
                            Text(progress, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                            Spacer()
                            Text(detail)
                        }
                    }
                } else {
                    ProgressView { Text(title) }.progressViewStyle(.linear)
                }
                Text("Your Mac will stay awake until this finishes.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel, action: u.cancel)
            }
            .disabled(false)
        case .done(let url):
            VStack(spacing: 10) {
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                HStack {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Play", systemImage: "play.fill") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    Button("Upscale Another…") { u.phase = .ready }
                }
            }
        case .failed(let msg):
            VStack(spacing: 8) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(5).multilineTextAlignment(.center)
                if u.info != nil { Button("Try Again") { u.phase = .ready } }
            }
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.message = "Choose a video to upscale"
        if panel.runModal() == .OK, let url = panel.url { u.load(url) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = u.outputDir
        if panel.runModal() == .OK, let url = panel.url { u.outputDir = url }
    }
}
