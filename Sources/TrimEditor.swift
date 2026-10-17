import SwiftUI
import AVFoundation

// MARK: - Model

/// Builds a waveform + low-bitrate preview of one audio track, plays it, and tracks the ranges the user cuts out.
@MainActor
final class TrimModel: ObservableObject {
    enum State: Equatable { case idle, analyzing(Double), ready, failed(String) }

    static let sampleRate = 2000          // waveform analysis rate (Hz)
    static let bucketSeconds = 0.05       // one peak per 50 ms

    @Published var state: State = .idle
    @Published var peaks: [Float] = []
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var selection: ClosedRange<Double>?
    @Published var cuts: [ClosedRange<Double>] = []
    @Published var zoom: Double = 1 { didSet { centerView(on: selection?.lowerBound ?? currentTime) } }
    @Published var viewStart: Double = 0

    private var player: AVAudioPlayer?
    private var process: Process?
    private var timer: Timer?
    private var previewURL: URL?
    private var preparedKey: String?

    var span: Double { duration / zoom }
    var totalCut: Double { cuts.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
    var finalDuration: Double { max(duration - totalCut, 0) }

    func reset() {
        process?.terminate()
        process = nil
        stopPlayback()
        removePreview()
        preparedKey = nil
        state = .idle
        peaks = []
        cuts = []
        selection = nil
        currentTime = 0
        viewStart = 0
        zoom = 1
    }

    // MARK: Analysis

    func prepare(movie: URL, track: Int, duration: Double) {
        let key = "\(movie.path)#\(track)"
        guard key != preparedKey, let dir = Extractor.ffmpegDir else { return }
        process?.terminate()
        stopPlayback()
        removePreview()
        preparedKey = key
        self.duration = duration
        peaks = []
        state = .analyzing(0)

        let preview = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReelKit-preview-\(UUID().uuidString).m4a")
        previewURL = preview

        // One decode pass, two outputs: a small mono preview for playback, and raw PCM for the waveform.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "\(dir)/ffmpeg")
        p.arguments = ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", movie.path,
                       "-map", "0:a:\(track)", "-vn", "-ac", "1", "-c:a", "aac_at", "-b:a", "64k", preview.path,
                       "-map", "0:a:\(track)", "-vn", "-ac", "1", "-ar", "\(Self.sampleRate)", "-f", "s16le", "pipe:1"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let errBuf = ErrorBuffer()
        err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
        do { try p.run() } catch { state = .failed(error.localizedDescription); return }
        process = p

        let acc = PeakAccumulator(samplesPerBucket: Int(Double(Self.sampleRate) * Self.bucketSeconds),
                                  expectedBuckets: duration / Self.bucketSeconds)
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                if let progress = acc.add(data) {
                    Task { @MainActor in
                        if self?.preparedKey == key, case .analyzing = self?.state { self?.state = .analyzing(progress) }
                    }
                }
            }
            p.waitUntilExit()
            err.fileHandleForReading.readabilityHandler = nil
            let ok = p.terminationStatus == 0
            let peaks = acc.finish()
            let tail = errBuf.tail
            Task { @MainActor in
                guard let self, self.preparedKey == key else { return }
                self.process = nil
                guard ok else { self.state = .failed(tail.isEmpty ? "Couldn't analyse the audio." : tail); return }
                self.peaks = peaks
                self.player = try? AVAudioPlayer(contentsOf: preview)
                self.player?.prepareToPlay()
                self.state = .ready
            }
        }
    }

    private func removePreview() {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
        player = nil
    }

    // MARK: Playback

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            stopPlayback()
        } else {
            if currentTime >= duration - 0.1 { seek(0) }
            player.currentTime = currentTime
            player.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    func stopPlayback() {
        player?.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func seek(_ t: Double) {
        currentTime = min(max(t, 0), duration)
        player?.currentTime = currentTime
        if currentTime < viewStart || currentTime > viewStart + span { centerView(on: currentTime) }
    }

    func skip(_ seconds: Double) { seek(currentTime + seconds) }

    private func tick() {
        guard let player else { return }
        var t = player.currentTime
        // Preview what the final file will sound like: jump over cut ranges.
        if let cut = cuts.first(where: { $0.contains(t) }) {
            t = cut.upperBound
            if t >= duration - 0.05 { stopPlayback(); currentTime = duration; return }
            player.currentTime = t
        }
        currentTime = t
        if t > viewStart + span || t < viewStart { viewStart = clampedStart(t - span * 0.05) }
        if !player.isPlaying { stopPlayback() }
    }

    // MARK: View window

    func centerView(on t: Double) { viewStart = clampedStart(t - span / 2) }
    private func clampedStart(_ s: Double) -> Double { min(max(s, 0), max(duration - span, 0)) }

    // MARK: Editing

    func markStart() {
        let t = currentTime
        if let s = selection, t < s.upperBound { selection = t...s.upperBound }
        else { selection = t...min(t + 10, duration) }
    }

    func markEnd() {
        let t = currentTime
        if let s = selection, t > s.lowerBound { selection = s.lowerBound...t }
        else { selection = max(t - 10, 0)...t }
    }

    func cutSelection() {
        guard let s = selection, s.upperBound - s.lowerBound > 0.05 else { return }
        cuts = Self.merge(cuts + [s])
        selection = nil
    }

    func keepOnlySelection() {
        guard let s = selection, s.upperBound - s.lowerBound > 0.05 else { return }
        var outside: [ClosedRange<Double>] = []
        if s.lowerBound > 0.05 { outside.append(0...s.lowerBound) }
        if duration - s.upperBound > 0.05 { outside.append(s.upperBound...duration) }
        cuts = Self.merge(cuts + outside)
        selection = nil
        seek(s.lowerBound)
    }

    func removeCut(_ cut: ClosedRange<Double>) { cuts.removeAll { $0 == cut } }

    static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, r.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                result.append(r)
            }
        }
        return result
    }
}

/// Collects peak amplitude per bucket from a stream of s16le mono PCM. Used from a background thread.
final class PeakAccumulator: @unchecked Sendable {
    private let samplesPerBucket: Int
    private let expectedBuckets: Double
    private var peaks: [Float] = []
    private var current: Int16 = 0
    private var inBucket = 0
    private var leftover: UInt8?
    private var lastReported = 0.0

    init(samplesPerBucket: Int, expectedBuckets: Double) {
        self.samplesPerBucket = samplesPerBucket
        self.expectedBuckets = max(expectedBuckets, 1)
        peaks.reserveCapacity(Int(expectedBuckets) + 16)
    }

    /// Returns a progress fraction when it has advanced by ≥1%, otherwise nil.
    func add(_ data: Data) -> Double? {
        var bytes = [UInt8](data)
        if let l = leftover { bytes.insert(l, at: 0); leftover = nil }
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        bytes.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) {
                let v = Int16(littleEndian: s)
                let a = v == .min ? .max : abs(v)
                if a > current { current = a }
                inBucket += 1
                if inBucket == samplesPerBucket {
                    peaks.append(Float(current) / Float(Int16.max))
                    current = 0
                    inBucket = 0
                }
            }
        }
        let progress = min(Double(peaks.count) / expectedBuckets, 1)
        guard progress - lastReported >= 0.01 else { return nil }
        lastReported = progress
        return progress
    }

    /// Normalised peaks, lifted with a square root so quiet dialogue is still visible.
    func finish() -> [Float] {
        if inBucket > 0 { peaks.append(Float(current) / Float(Int16.max)) }
        let loud = peaks.sorted(by: >).dropFirst(peaks.count / 500).first ?? 1   // ignore the loudest 0.2%
        let scale = loud > 0 ? 1 / loud : 1
        return peaks.map { min(($0 * scale).squareRoot(), 1) }
    }
}

func formatTime(_ t: Double, tenths: Bool = false) -> String {
    let total = max(t, 0)
    let h = Int(total) / 3600, m = Int(total) / 60 % 60, s = Int(total) % 60
    let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    return tenths ? base + String(format: ".%d", Int(total * 10) % 10) : base
}

// MARK: - Views

struct TrimEditorView: View {
    @ObservedObject var trim: TrimModel

    var body: some View {
        switch trim.state {
        case .idle:
            EmptyView()
        case .analyzing(let p):
            ProgressView(value: p) { Text("Reading the soundtrack…").font(.caption) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .ready:
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformView(trim: trim).frame(height: 96)

            HStack {
                Text(formatTime(trim.viewStart))
                Spacer()
                if trim.zoom > 1 {
                    Slider(value: $trim.viewStart, in: 0...max(trim.duration - trim.span, 0.001)).controlSize(.mini)
                    Spacer()
                }
                Text(formatTime(trim.viewStart + trim.span))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)

            // Transport + zoom
            HStack(spacing: 6) {
                Button { trim.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button { trim.togglePlay() } label: {
                    Image(systemName: trim.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { trim.skip(10) } label: { Image(systemName: "goforward.10") }
                Text("\(formatTime(trim.currentTime, tenths: true)) / \(formatTime(trim.duration))")
                    .font(.callout.monospacedDigit()).padding(.leading, 6)
                Spacer()
                Button { trim.zoom = max(trim.zoom / 2, 1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(trim.zoom <= 1)
                Button { trim.zoom = min(trim.zoom * 2, 1024) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(trim.span < 10)
            }
            .buttonStyle(.borderless)

            // Selection
            HStack(spacing: 8) {
                Button("Start ⟦", action: trim.markStart).keyboardShortcut("i", modifiers: [])
                    .help("Set selection start at the playhead (I)")
                Button("⟧ End", action: trim.markEnd).keyboardShortcut("o", modifiers: [])
                    .help("Set selection end at the playhead (O)")
                if let s = trim.selection {
                    Text("\(formatTime(s.lowerBound, tenths: true)) – \(formatTime(s.upperBound, tenths: true))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: trim.cutSelection) { Label("Cut", systemImage: "scissors") }
                        .keyboardShortcut(.delete, modifiers: [])
                        .help("Remove this part (Delete)")
                    Button(action: trim.keepOnlySelection) { Label("Keep Only", systemImage: "crop") }
                        .help("Remove everything outside this part")
                } else {
                    Text("Drag on the waveform to select").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .controlSize(.small)

            // Cut list
            if !trim.cuts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(trim.cuts, id: \.self) { cut in
                        HStack {
                            Image(systemName: "scissors").foregroundStyle(.red)
                            Button("\(formatTime(cut.lowerBound, tenths: true)) – \(formatTime(cut.upperBound, tenths: true))") {
                                trim.seek(cut.lowerBound)
                            }
                            .buttonStyle(.link)
                            Text("(\(formatTime(cut.upperBound - cut.lowerBound)))").foregroundStyle(.secondary)
                            Spacer()
                            Button { trim.removeCut(cut) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Restore this part")
                        }
                    }
                    HStack {
                        Text("Final length: \(formatTime(trim.finalDuration))").bold()
                        Spacer()
                        Button("Restore All") { trim.cuts = [] }.buttonStyle(.link)
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

struct WaveformView: View {
    @ObservedObject var trim: TrimModel
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                draw(ctx, size)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let start = time(at: g.startLocation.x, width: w)
                    if abs(g.translation.width) > 3 {
                        dragStart = start
                        let end = time(at: g.location.x, width: w)
                        trim.selection = min(start, end)...max(start, end)
                    }
                }
                .onEnded { g in
                    if dragStart == nil {
                        trim.selection = nil
                        trim.seek(time(at: g.location.x, width: w))
                    } else if let s = trim.selection {
                        trim.seek(s.lowerBound)
                    }
                    dragStart = nil
                })
        }
    }

    private func time(at x: Double, width: Double) -> Double {
        min(max(trim.viewStart + x / width * trim.span, 0), trim.duration)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let span = trim.span, start = trim.viewStart
        guard span > 0 else { return }
        func x(_ t: Double) -> Double { (t - start) / span * size.width }
        let mid = size.height / 2

        // Waveform: one bar per 2pt column, taking the loudest bucket in that column.
        let peaks = trim.peaks
        let bucket = TrimModel.bucketSeconds
        var wave = Path()
        let step = 2.0
        var px = 0.0
        while px < size.width {
            let t0 = start + px / size.width * span, t1 = start + (px + step) / size.width * span
            let b0 = Int(t0 / bucket), b1 = max(Int(t1 / bucket), b0 + 1)
            var m: Float = 0
            if b0 < peaks.count { for i in b0..<min(b1, peaks.count) { m = max(m, peaks[i]) } }
            let h = max(Double(m) * (size.height - 8) / 2, 0.5)
            wave.addRect(CGRect(x: px, y: mid - h, width: step - 0.6, height: h * 2))
            px += step
        }
        ctx.fill(wave, with: .color(.accentColor))

        // Cut ranges.
        for cut in trim.cuts where cut.upperBound > start && cut.lowerBound < start + span {
            let r = CGRect(x: x(cut.lowerBound), y: 0, width: x(cut.upperBound) - x(cut.lowerBound), height: size.height)
            ctx.fill(Path(r), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.7)))
            ctx.fill(Path(r), with: .color(.red.opacity(0.22)))
            var line = Path(); line.move(to: CGPoint(x: r.minX, y: mid)); line.addLine(to: CGPoint(x: r.maxX, y: mid))
            ctx.stroke(line, with: .color(.red.opacity(0.7)), lineWidth: 1.5)
        }

        // Selection.
        if let s = trim.selection {
            let r = CGRect(x: x(s.lowerBound), y: 0, width: max(x(s.upperBound) - x(s.lowerBound), 1), height: size.height)
            ctx.fill(Path(r), with: .color(.yellow.opacity(0.25)))
            ctx.stroke(Path(r), with: .color(.yellow), lineWidth: 1.5)
        }

        // Playhead.
        let ph = x(trim.currentTime)
        if ph >= 0 && ph <= size.width {
            ctx.fill(Path(CGRect(x: ph - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
        }
    }
}
