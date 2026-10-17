import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct AudioTrack: Identifiable, Hashable {
    let id: Int          // ordinal among audio streams → used as -map 0:a:<id>
    let codec: String
    let channels: Int
    let layout: String
    let language: String
    let title: String

    var label: String {
        let lang = language.isEmpty || language == "und" ? "Track \(id + 1)" : Locale.current.localizedString(forLanguageCode: language) ?? language
        let ch: String = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
        var parts = [lang, ch, codec.uppercased()]
        if !title.isEmpty { parts.append("“\(title)”") }
        return parts.joined(separator: " · ")
    }

    /// Container that can hold this codec untouched.
    var copyExtension: String {
        switch codec {
        case "aac", "alac": "m4a"
        case "mp3": "mp3"
        case "flac": "flac"
        case "ac3": "ac3"
        case "eac3": "eac3"
        default: "mka"   // DTS, TrueHD, Opus, PCM, …
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case m4a = "M4A (AAC)"
    case mp3 = "MP3"
    case flac = "FLAC"
    case original = "Original"
    var id: String { rawValue }

    var fileExtension: String? {
        switch self {
        case .m4a: "m4a"
        case .mp3: "mp3"
        case .flac: "flac"
        case .original: nil
        }
    }

    var help: String {
        switch self {
        case .m4a: "High-quality AAC 256 kbps. Plays everywhere: Music, iPhone, QuickTime, car."
        case .mp3: "320 kbps MP3. Maximum compatibility with older players."
        case .flac: "Lossless, larger files. Great for good headphones."
        case .original: "Exact copy of the movie's audio, no re-encoding. Surround formats (AC3/DTS) may need VLC or IINA."
        }
    }
}

enum SilenceLevel: String, CaseIterable, Identifiable {
    case strict = "Strict", normal = "Normal", aggressive = "Aggressive"
    var id: String { rawValue }
    /// Below this loudness counts as silence. Movies rarely hit true digital silence, hence the range.
    var threshold: Int {
        switch self {
        case .strict: -55
        case .normal: -45
        case .aggressive: -36
        }
    }
}

enum Phase: Equatable {
    case idle, probing, ready, extracting(Double), done(URL), failed(String)
}

@MainActor
final class Extractor: ObservableObject {
    @Published var movie: URL?
    @Published var duration: Double = 0
    @Published var tracks: [AudioTrack] = []
    @Published var trackID = 0
    @Published var format: OutputFormat = .m4a
    @Published var downmix = true
    @Published var dialogueBoost = true
    @Published var nightMode = false
    @Published var removeSilence = false
    @Published var silenceLevel: SilenceLevel = .normal
    @Published var maxPause: Double = 1            // silent gaps longer than this are shortened to it (s)
    @Published var trimEnabled = false
    @Published var outputDir: URL?
    @Published var phase: Phase = .idle

    let trim = TrimModel()
    private var process: Process?
    private var currentOutput: URL?

    /// Ranges to remove from the output (empty when trimming is off).
    var activeCuts: [ClosedRange<Double>] { trimEnabled && processing ? trim.cuts : [] }

    var track: AudioTrack? { tracks.first { $0.id == trackID } }
    var isSurround: Bool { (track?.channels ?? 2) > 2 }
    var processing: Bool { format != .original }

    nonisolated static let ffmpegDir: String? = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        .first { FileManager.default.isExecutableFile(atPath: "\($0)/ffmpeg") }

    // MARK: Probe

    func load(_ url: URL) {
        movie = url
        outputDir = url.deletingLastPathComponent()
        tracks = []
        trim.reset()
        trimEnabled = false
        phase = .probing
        Task {
            do {
                let (tracks, duration) = try await Self.probe(url)
                guard movie == url else { return }
                if tracks.isEmpty { phase = .failed("This file has no audio tracks."); return }
                self.tracks = tracks
                self.duration = duration
                // Prefer the user's language, else the first track.
                let pref = Locale.current.language.languageCode?.identifier(.alpha3) ?? "eng"
                trackID = tracks.first { $0.language == pref }?.id ?? tracks[0].id
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func probe(_ url: URL) async throws -> ([AudioTrack], Double) {
        guard let dir = ffmpegDir else { throw AppError("ffmpeg not found. Install it with: brew install ffmpeg") }
        let data = try await run("\(dir)/ffprobe", ["-v", "error", "-select_streams", "a",
            "-show_entries", "stream=codec_name,channels,channel_layout:stream_tags=language,title:format=duration",
            "-of", "json", url.path])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Couldn't read this file.")
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let tracks = streams.enumerated().map { i, s in
            let tags = s["tags"] as? [String: Any] ?? [:]
            return AudioTrack(id: i,
                              codec: s["codec_name"] as? String ?? "?",
                              channels: s["channels"] as? Int ?? 2,
                              layout: s["channel_layout"] as? String ?? "",
                              language: tags["language"] as? String ?? "",
                              title: tags["title"] as? String ?? "")
        }
        let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        return (tracks, duration)
    }

    nonisolated static func run(_ exe: String, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 { cont.resume(returning: data) }
                else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(throwing: AppError(msg.isEmpty ? "ffprobe failed" : msg))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    func prepareTrimIfNeeded() {
        guard trimEnabled, let movie, let track else { return }
        trim.prepare(movie: movie, track: track.id, duration: duration)
    }

    // MARK: Extract

    func outputURL(for track: AudioTrack) -> URL {
        let base = movie!.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension ?? track.copyExtension
        let lang = track.language.isEmpty || track.language == "und" ? "" : " [\(track.language)]"
        let dir = outputDir ?? movie!.deletingLastPathComponent()
        var url = dir.appendingPathComponent("\(base) - Audio\(lang).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) - Audio\(lang) \(n).\(ext)")
            n += 1
        }
        return url
    }

    func ffmpegArgs(input: URL, output: URL, track: AudioTrack) -> [String] {
        let cuts = activeCuts
        let silence = removeSilence && processing
        // Chapter times are meaningless once the timeline is edited.
        let keepChapters = cuts.isEmpty && !silence
        var args = ["-hide_banner", "-nostdin", "-nostats", "-y", "-i", input.path,
                    "-map", "0:a:\(track.id)", "-vn", "-sn", "-dn",
                    "-map_metadata", "0", "-map_chapters", keepChapters ? "0" : "-1"]

        if format == .original {
            return args + ["-c:a", "copy", "-progress", "pipe:1", output.path]
        }

        var filters: [String] = []
        if !cuts.isEmpty {
            // Drop every frame inside a cut, then close the gaps in the timeline.
            let expr = cuts.map { String(format: "between(t,%.3f,%.3f)", $0.lowerBound, $0.upperBound) }
                .joined(separator: "+")
            filters.append("aselect='not(\(expr))'")
            filters.append("asetpts=N/SR/TB")
        }

        // MP3 can't carry surround, so always fold it down.
        let stereo = track.channels > 2 && (downmix || format == .mp3)
        if stereo {
            if dialogueBoost && (track.channels == 6 || track.channels == 8) {
                // Standard order: c0 FL, c1 FR, c2 FC (dialogue), c3 LFE, c4/c5 rear or side, c6/c7 side.
                // Lift the centre channel above the usual 0.707 downmix so voices sit on top of effects.
                let extraL = track.channels == 8 ? "+0.5*c6" : ""
                let extraR = track.channels == 8 ? "+0.5*c7" : ""
                filters.append("pan=stereo|FL<1.3*c2+c0+0.5*c4\(extraL)+0.2*c3|FR<1.3*c2+c1+0.5*c5\(extraR)+0.2*c3")
            } else {
                args += ["-ac", "2"]
            }
        }
        if silence {
            // Any silent gap longer than maxPause is shortened to exactly maxPause; leading silence
            // is trimmed too. (In ffmpeg 7+, a long gap is cut down to stop_duration + stop_silence.)
            let db = silenceLevel.threshold
            filters.append("silenceremove=start_periods=1:start_threshold=\(db)dB:start_silence=0.3" +
                           ":stop_periods=-1:stop_threshold=\(db)dB:stop_duration=\(maxPause)" +
                           ":detection=rms:window=0.05")
        }
        if nightMode {
            // Evens out whisper-quiet dialogue vs. loud explosions.
            filters.append("dynaudnorm=f=150:g=15:p=0.9:m=10")
        }
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }

        let surroundOut = track.channels > 2 && !stereo
        switch format {
        case .m4a: args += ["-c:a", "aac_at", "-b:a", surroundOut ? "448k" : "256k", "-movflags", "+faststart"]
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"]
        case .flac: args += ["-c:a", "flac", "-compression_level", "5"]
        case .original: break
        }
        return args + ["-progress", "pipe:1", output.path]
    }

    func extract() {
        guard let movie, let track, let dir = Self.ffmpegDir else { return }
        let output = outputURL(for: track)
        currentOutput = output
        trim.stopPlayback()
        phase = .extracting(0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "\(dir)/ffmpeg")
        p.arguments = ffmpegArgs(input: movie, output: output, track: track)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        // Progress is measured on the output timeline. (With silence removal the output ends up
        // shorter than expected, so the bar may jump to done before reaching 100%.)
        let duration = self.duration - activeCuts.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let text = String(data: h.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard duration > 0, let us = Double(line.dropFirst(12)) else { continue }
                let frac = min(max(us / 1_000_000 / duration, 0), 1)
                Task { @MainActor in
                    if case .extracting = self?.phase { self?.phase = .extracting(frac) }
                }
            }
        }
        // Keep only the tail of stderr for error reporting.
        let errBuf = ErrorBuffer()
        err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }

        p.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus, reason = p.terminationReason
            let tail = errBuf.tail
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                if status == 0 {
                    self.phase = .done(output)
                } else {
                    try? FileManager.default.removeItem(at: output)
                    self.phase = reason == .uncaughtSignal ? .ready : .failed(tail)
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() { process?.terminate() }
}

final class ErrorBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.withLock { data.append(d); if data.count > 8000 { data = data.suffix(4000) } } }
    var tail: String {
        let s = lock.withLock { String(decoding: data, as: UTF8.self) }
        return s.split(separator: "\n").suffix(4).joined(separator: "\n")
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errorDescription: String? { message }
}

// MARK: - UI

struct RootView: View {
    var body: some View {
        TabView {
            AudioView().tabItem { Label("Extract Audio", systemImage: "waveform") }
            UpscaleView().tabItem { Label("Upscale Video", systemImage: "4k.tv") }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 560, idealHeight: 780)
    }
}

struct AudioView: View {
    @StateObject private var x = Extractor()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            dropZone
            if !x.tracks.isEmpty { options }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .onChange(of: x.trimEnabled) { x.prepareTrimIfNeeded() }
        .onChange(of: x.trackID) { x.prepareTrimIfNeeded() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in x.load(url) } }
            }
            return true
        }
        .disabled(isBusy)
    }

    private var isBusy: Bool { if case .extracting = x.phase { true } else { false } }

    @ViewBuilder private var dropZone: some View {
        if let movie = x.movie {
            // Compact header once a movie is loaded, to leave room for the editor.
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    if x.duration > 0 {
                        Text(formatTime(x.duration)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Button("Choose Another…", action: chooseMovie)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        } else {
            emptyDropZone
        }
    }

    private var emptyDropZone: some View {
        Button(action: chooseMovie) {
            VStack(spacing: 8) {
                if x.movie == nil {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                }
                if let movie = x.movie {
                    Text(movie.lastPathComponent).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                    if x.duration > 0 {
                        Text(Duration.seconds(x.duration).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text("Drop a movie here").font(.headline)
                    Text("or click to choose a file").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5)))
            .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Color.accentColor.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
    }

    private var options: some View {
        Form {
            if x.tracks.count > 1 {
                Picker("Audio track", selection: $x.trackID) {
                    ForEach(x.tracks) { Text($0.label).tag($0.id) }
                }
            } else if let t = x.track {
                LabeledContent("Audio track", value: t.label)
            }

            Picker("Format", selection: $x.format) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(x.format.help).font(.caption).foregroundStyle(.secondary)

            if x.processing {
                if x.isSurround {
                    Toggle("Stereo for headphones & phones", isOn: $x.downmix)
                        .disabled(x.format == .mp3)
                    Toggle("Boost dialogue", isOn: $x.dialogueBoost)
                        .disabled(!(x.downmix || x.format == .mp3) || ![6, 8].contains(x.track?.channels ?? 0))
                }
                Toggle("Night mode (even out quiet voices & loud action)", isOn: $x.nightMode)
            }

            if x.processing {
                Section {
                    Toggle("Remove silent gaps", isOn: $x.removeSilence)
                    if x.removeSilence {
                        Picker("Silence detection", selection: $x.silenceLevel) {
                            ForEach(SilenceLevel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Stepper(value: $x.maxPause, in: 0.5...5, step: 0.5) {
                            Text("Shorten pauses to \(x.maxPause, format: .number) s")
                        }
                        Text("Any pause longer than this is cut down to it, so speech keeps a natural rhythm. Movies have background noise — if little is removed, try Aggressive.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Trim parts of the audio", isOn: $x.trimEnabled)
                    if x.trimEnabled { TrimEditorView(trim: x.trim) }
                }
            } else {
                Text("Choose M4A, MP3 or FLAC to remove silence or trim.").font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Save to") {
                HStack {
                    Text(x.outputDir?.lastPathComponent ?? "—").lineLimit(1).truncationMode(.middle)
                    Button("Change…", action: chooseFolder).controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var footer: some View {
        switch x.phase {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().controlSize(.small)
        case .ready:
            Button(action: x.extract) {
                Label("Extract Audio", systemImage: "waveform").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
        case .extracting(let p):
            VStack(spacing: 8) {
                ProgressView(value: p) { Text("Extracting…") } currentValueLabel: {
                    Text(p, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                Button("Cancel", role: .cancel, action: x.cancel).disabled(false)
            }
        case .done(let url):
            VStack(spacing: 10) {
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                HStack {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Play", systemImage: "play.fill") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    Button("Extract Another…") { x.phase = .ready }
                }
            }
        case .failed(let msg):
            VStack(spacing: 8) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(5).multilineTextAlignment(.center)
                if !x.tracks.isEmpty { Button("Try Again") { x.phase = .ready } }
            }
        }
    }

    private func chooseMovie() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.message = "Choose a movie to extract its soundtrack"
        if panel.runModal() == .OK, let url = panel.url { x.load(url) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = x.outputDir
        if panel.runModal() == .OK, let url = panel.url { x.outputDir = url }
    }
}

@main
struct MovieAudioApp: App {
    var body: some Scene {
        WindowGroup("Movie Audio") {
            RootView()
                .onAppear {
                    if Extractor.ffmpegDir == nil {
                        let a = NSAlert()
                        a.messageText = "ffmpeg is required"
                        a.informativeText = "Install it with Homebrew:\n\nbrew install ffmpeg"
                        a.runModal()
                    }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
