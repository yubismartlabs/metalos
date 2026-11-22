import AppKit
import CoreGraphics
import Darwin

/// Formats the values shown in the in-game Game Bar widgets.
enum GameBarFormatting {
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }
    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }
}

struct GameProcessSample: Equatable {
    var cpuPercent: Double
    var memoryBytes: UInt64
}

/// Samples a running game's CPU use and memory footprint without attaching to or modifying it.
struct GameProcessSampler {
    private var previousCPUTime: UInt64?
    private var previousDate: Date?

    mutating func reset() {
        previousCPUTime = nil
        previousDate = nil
    }

    mutating func sample(pid: pid_t) -> GameProcessSample? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        let cpuTime = usage.ri_user_time + usage.ri_system_time
        let now = Date()
        var percent = 0.0
        if let previousCPUTime, let previousDate {
            let elapsed = now.timeIntervalSince(previousDate)
            if elapsed > 0, cpuTime >= previousCPUTime {
                percent = Double(cpuTime - previousCPUTime) / (elapsed * 1_000_000_000) * 100
            }
        }
        previousCPUTime = cpuTime
        previousDate = now
        return GameProcessSample(cpuPercent: max(0, min(percent, 999)), memoryBytes: usage.ri_phys_footprint)
    }
}

/// Saves a still of the display while the Game Bar is hidden.
@MainActor
enum GameBarCapture {
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccess() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        CGRequestScreenCaptureAccess()
    }

    static func capture() async -> Result<URL, Error> {
        let directory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalOS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = UUID().uuidString.prefix(8)
        let url = directory.appendingPathComponent("MetalOS \(formatter.string(from: Date())) \(suffix).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exit = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Int32, Error>, Never>) in
            process.terminationHandler = { finished in
                continuation.resume(returning: .success(finished.terminationStatus))
            }
            do {
                try AppProcessSupervisor.run(process)
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failure(error))
            }
        }
        switch exit {
        case .failure(let error): return .failure(error)
        case .success(0) where FileManager.default.fileExists(atPath: url.path): return .success(url)
        case .success: return .failure(CocoaError(.fileWriteUnknown))
        }
    }
}
