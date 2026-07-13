import Foundation

/// Everything needed to register (configure) a runner directory.
struct RegistrationRequest: Sendable {
    var directory: URL
    var target: GHTarget
    var name: String
    var labels: [String]
    var token: String
    var replace: Bool = true
    var runnerGroup: String?
    /// Disable the runner's own automatic self-update (so this app is the sole updater).
    var disableUpdate: Bool = false
    /// Take a single job, then unconfigure.
    var ephemeral: Bool = false
    /// Skip GitHub's default labels (self-hosted, OSX, Arm64). Requires custom labels.
    var noDefaultLabels: Bool = false
}

/// Optional registration flags surfaced in the UI.
struct RegisterOptions: Sendable {
    var runnerGroup: String?
    var disableUpdate: Bool = false
    var ephemeral: Bool = false
    var noDefaultLabels: Bool = false
}

/// How the runner process should be launched.
enum StartMode: String, CaseIterable, Sendable {
    /// Install/use a launchd LaunchAgent (survives app quit; the GitHub-recommended service).
    case service
    /// Run `./run.sh` detached via nohup (survives app quit but not managed by launchd).
    case supervised
}

/// Drives the runner's own scripts (`run.sh`, `svc.sh`, `config.sh`) and process signals.
struct RunnerController: Sendable {

    // MARK: - Process lifecycle

    /// Start the runner. If a launchd service is already installed, always drive it
    /// (so the two mechanisms never fight); otherwise use the chosen start mode.
    func start(_ instance: RunnerInstance, mode: StartMode) async throws {
        let dir = instance.directory
        if serviceInstalled(in: dir) {
            try await svc(dir, "start")
            return
        }
        switch mode {
        case .service:
            try await svc(dir, "install")
            try await svc(dir, "start")
        case .supervised:
            try await startSupervised(dir)
        }
    }

    /// Launch `./run.sh` detached so it outlives this app.
    ///
    /// Backgrounding with a trailing `&` makes bash exit 0 unconditionally, so we
    /// can't trust the exit code — instead we capture the backgrounded PID (`$!`)
    /// and confirm it is still alive a moment later, surfacing the log tail if not.
    private func startSupervised(_ dir: URL) async throws {
        let runScript = dir.appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: runScript.path) else {
            throw ShellError.executableNotFound("run.sh in \(dir.lastPathComponent) (missing or not executable)")
        }
        // Ensure the log directory exists so the redirection can't fail.
        let diag = dir.appendingPathComponent("_diag")
        try? FileManager.default.createDirectory(at: diag, withIntermediateDirectories: true)
        let logPath = diag.appendingPathComponent("runnermenu-stdout.log").path

        let quotedDir = shellQuote(dir.path)
        let quotedLog = shellQuote(logPath)
        // Use `cd …;` (NOT `&&`) so ONLY `nohup ./run.sh` is backgrounded: that makes
        // `$!` the real run.sh PID and lets nohup protect it from SIGHUP as the
        // launching shell exits. Backgrounding the whole `&&` list instead yields an
        // ephemeral subshell PID and can kill the runner before nohup takes effect.
        let command = "cd \(quotedDir); nohup ./run.sh >> \(quotedLog) 2>&1 & echo $!"
        let result = try await Shell.run("/bin/bash", ["-lc", command], cwd: dir)
        guard result.succeeded, let pid = Int32(result.out) else {
            let detail = result.stderr.isEmpty ? "Could not launch run.sh." : result.stderr
            throw ShellError.nonZeroExit(command: "run.sh (supervised)", code: result.exitCode, stderr: detail)
        }

        // If run.sh dies immediately (bad token, broken config), the wrapper PID
        // will be gone shortly after launch — detect that and surface the reason.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let alive = (try? await Shell.run("/bin/kill", ["-0", "\(pid)"]))?.succeeded ?? false
        if !alive {
            let tail = LogTailer.tail(URL(fileURLWithPath: logPath), maxLines: 12)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.launchFailed("run.sh exited immediately."
                + (tail.isEmpty ? "" : "\n\n\(tail)"))
        }
    }

    /// Gracefully stop the runner. Sends SIGTERM to the listener; the runner shuts
    /// down cleanly (the same signal launchd/systemd use) and the run.sh wrapper then
    /// exits. Falls back to the service stop if installed.
    ///
    /// SIGTERM — not SIGINT — because a runner we launch in the background inherits
    /// SIG_IGN for SIGINT (the shell auto-ignores INT/QUIT for async jobs), so a
    /// `kill -INT` would be silently dropped. SIGTERM is not auto-ignored.
    func stop(_ instance: RunnerInstance, pid: Int32?, force: Bool = false) async throws {
        let dir = instance.directory
        if serviceInstalled(in: dir), pid == nil {
            try await svc(dir, "stop")
            return
        }
        guard let pid else {
            // Nothing running that we can see.
            return
        }
        if serviceInstalled(in: dir) {
            // Always unload launchd first so a force-killed listener cannot restart.
            try await svc(dir, "stop")
            if force, await isAlive(pid) {
                try await sendSignal("KILL", to: pid)
            }
        } else {
            try await sendSignal(force ? "KILL" : "TERM", to: pid)
        }
    }

    private func isAlive(_ pid: Int32) async -> Bool {
        (try? await Shell.run("/bin/kill", ["-0", "\(pid)"]))?.succeeded ?? false
    }

    private func sendSignal(_ signal: String, to pid: Int32) async throws {
        let result = try await Shell.run("/bin/kill", ["-\(signal)", "\(pid)"])
        if !result.succeeded {
            // /bin/kill may not exist under that path on all systems; try `kill`.
            let fallback = try await Shell.run("kill", ["-\(signal)", "\(pid)"])
            guard fallback.succeeded else {
                throw ShellError.nonZeroExit(command: "kill -\(signal) \(pid)", code: fallback.exitCode, stderr: fallback.stderr)
            }
        }
    }

    // MARK: - Configure / register

    /// Register (configure) the runner against a GitHub target.
    func register(_ request: RegistrationRequest) async throws {
        let dir = request.directory
        var args = [
            "--url", request.target.webURLString,
            "--token", request.token,
            "--name", request.name,
            "--work", "_work",
            "--unattended"
        ]
        if !request.labels.isEmpty {
            args += ["--labels", request.labels.joined(separator: ",")]
        }
        if let group = request.runnerGroup, !group.isEmpty {
            args += ["--runnergroup", group]
        }
        if request.replace {
            args += ["--replace"]
        }
        if request.disableUpdate {
            args += ["--disableupdate"]
        }
        if request.ephemeral {
            args += ["--ephemeral"]
        }
        if request.noDefaultLabels {
            args += ["--no-default-labels"]
        }
        let configPath = dir.appendingPathComponent("config.sh").path
        let result = try await Shell.run(configPath, args, cwd: dir)
        guard result.succeeded else {
            throw ShellError.nonZeroExit(command: "config.sh", code: result.exitCode,
                                         stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Unregister the runner from GitHub. `token` is a removal token.
    func unregister(_ instance: RunnerInstance, token: String) async throws {
        let dir = instance.directory
        let configPath = dir.appendingPathComponent("config.sh").path
        let result = try await Shell.run(configPath, ["remove", "--token", token], cwd: dir)
        guard result.succeeded else {
            throw ShellError.nonZeroExit(command: "config.sh remove", code: result.exitCode,
                                         stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Clear a runner's local configuration WITHOUT contacting GitHub (`--local`).
    /// Used as a fallback when we can't obtain a removal token (e.g. no admin on the
    /// old repo). Leaves an offline runner entry on the old repo for the owner to clean up.
    func removeLocalConfig(_ directory: URL) async throws {
        let configPath = directory.appendingPathComponent("config.sh").path
        let result = try await Shell.run(configPath, ["remove", "--local"], cwd: directory)
        guard result.succeeded else {
            throw ShellError.nonZeroExit(command: "config.sh remove --local", code: result.exitCode,
                                         stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    // MARK: - launchd service

    func serviceInstalled(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".service").path)
    }

    /// `svc.sh install` + `svc.sh start` — write the LaunchAgent and load it.
    func installService(_ instance: RunnerInstance) async throws {
        try await svc(instance.directory, "install")
        try await svc(instance.directory, "start")
    }

    /// `svc.sh install` only — write the LaunchAgent without loading it yet.
    func installServiceOnly(_ instance: RunnerInstance) async throws {
        try await svc(instance.directory, "install")
    }

    /// `svc.sh start` — `launchctl load -w` the installed agent.
    func startService(_ instance: RunnerInstance) async throws {
        try await svc(instance.directory, "start")
    }

    /// `svc.sh stop` — `launchctl unload` the agent.
    func stopService(_ instance: RunnerInstance) async throws {
        try await svc(instance.directory, "stop")
    }

    func uninstallService(_ instance: RunnerInstance) async throws {
        try await svc(instance.directory, "uninstall")
    }

    /// `svc.sh status` — raw output, for display.
    func serviceStatus(_ instance: RunnerInstance) async throws -> String {
        let result = try await svc(instance.directory, "status")
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No status output." : text
    }

    /// The launchd log directory (`~/Library/Logs/<SvcName>/`), derived from the
    /// plist path recorded in the `.service` marker file.
    func serviceLogDirectory(for instance: RunnerInstance) -> URL? {
        let serviceFile = instance.directory.appendingPathComponent(".service")
        guard let contents = try? String(contentsOf: serviceFile, encoding: .utf8) else { return nil }
        let plistPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plistPath.isEmpty else { return nil }
        let svcName = URL(fileURLWithPath: plistPath).deletingPathExtension().lastPathComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(svcName)")
    }

    @discardableResult
    private func svc(_ dir: URL, _ command: String) async throws -> ShellResult {
        let svcPath = dir.appendingPathComponent("svc.sh").path
        guard FileManager.default.fileExists(atPath: svcPath) else {
            throw ShellError.executableNotFound("svc.sh in \(dir.lastPathComponent)")
        }
        let result = try await Shell.run(svcPath, [command], cwd: dir)
        guard result.succeeded else {
            throw ShellError.nonZeroExit(command: "svc.sh \(command)", code: result.exitCode,
                                         stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    // MARK: - Helpers

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
