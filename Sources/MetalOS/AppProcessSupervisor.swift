import Foundation
import Darwin

/// Keeps subprocesses launched by the app in their own process groups so that
/// app shutdown can also stop descendants such as Wine services.
enum AppProcessSupervisor {
    private static let lock = NSLock()
    private static var processGroups = Set<pid_t>()
    private static var processes: [pid_t: Process] = [:]
    private static var pruneTimer: DispatchSourceTimer?

    @discardableResult
    static func run(_ process: Process) throws -> pid_t {
        var processGroupEstablished = false
        if let target = process.executableURL, let runner = processRunnerURL() {
            let arguments = process.arguments ?? []
            process.executableURL = runner
            process.arguments = [target.path] + arguments
            processGroupEstablished = true
        }
        try process.run()

        let pid = process.processIdentifier
        let joinedNewGroup = processGroupEstablished || setpgid(pid, pid) == 0

        lock.lock()
        processes[pid] = process
        if joinedNewGroup {
            processGroups.insert(pid)
        }
        startPruneTimerIfNeeded()
        lock.unlock()
        return pid
    }

    static func terminate(groupID: pid_t) {
        pruneExitedProcesses()

        lock.lock()
        let isManagedGroup = processGroups.contains(groupID)
        let process = processes[groupID]
        lock.unlock()
        guard isManagedGroup || process?.isRunning == true else { return }

        if isManagedGroup { _ = kill(-groupID, SIGTERM) }
        process?.terminate()

        for _ in 0..<10 {
            if !isManagedGroup || kill(-groupID, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isManagedGroup { _ = kill(-groupID, SIGKILL) }
        if process?.isRunning == true { _ = kill(groupID, SIGKILL) }

        pruneExitedProcesses()
    }

    static func terminateAll() {
        pruneExitedProcesses()
        lock.lock()
        let groups = processGroups
        let running = processes.values.filter(\.isRunning)
        lock.unlock()

        // Signal whole groups first, which includes runtime helpers spawned by
        // Wine and other managed tools.
        for group in groups { _ = kill(-group, SIGTERM) }
        for process in running { process.terminate() }

        Thread.sleep(forTimeInterval: 0.5)

        for group in groups { _ = kill(-group, SIGKILL) }
        for process in running where process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func startPruneTimerIfNeeded() {
        guard pruneTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { pruneExitedProcesses() }
        pruneTimer = timer
        timer.resume()
    }

    private static func processRunnerURL() -> URL? {
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NXProcessRunner")
        if FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }

        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("NXProcessRunner")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    private static func pruneExitedProcesses() {
        lock.lock()
        processes = processes.filter { $0.value.isRunning }
        processGroups = processGroups.filter { group in
            if kill(-group, 0) == 0 { return true }
            return errno != ESRCH
        }
        lock.unlock()
    }
}
