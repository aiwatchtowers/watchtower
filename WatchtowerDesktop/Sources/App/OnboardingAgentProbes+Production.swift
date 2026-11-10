import Darwin
import Foundation
import WatchtowerCore

extension OnboardingAgentProbes {
    /// The real probes. One binary, one lookup: `locate` asks Go
    /// (`watchtower ai which`), Swift never searches PATH for an agent.
    /// `watchtower` overrides the CLI binary and `helpTimeout` the probe's
    /// 5 s (tests).
    @MainActor
    static func production(
        config: ConfigService,
        policy: ManagedPolicy,
        watchtower: String? = nil,
        helpTimeout: TimeInterval = 5
    ) -> OnboardingAgentProbes {
        OnboardingAgentProbes(
            configuredProvider: config.aiProvider,
            allowed: { policy.providerAllowed($0.rawValue) },
            locate: { await WatchtowerAIService.which(provider: $0.rawValue, watchtower: watchtower) },
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            help: { agent, executable in
                let env = await Constants.resolvedEnvironmentAsync()
                return await helpText(agent, executable: executable, environment: env, timeout: helpTimeout)
            },
            test: { provider, cliPath in
                await WatchtowerAIService.testResult(provider: provider, cliPath: cliPath, watchtower: watchtower)
            },
            home: NSHomeDirectory()
        )
    }

    /// `<executable> auth --help` (claude) / `login --help` (codex): stdout and
    /// stderr together. The child runs in its own process group; on timeout
    /// the whole group is killed and the answer is nil.
    static func helpText(
        _ agent: OnboardingAgentChoice.Agent,
        executable: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> String? {
        let args = agent == .claude ? ["auth", "--help"] : ["login", "--help"]
        return await ProcessPipes.offPool {
            spawnCapturing(executable, args, environment: environment, timeout: timeout)
        }
    }

    private static func spawnCapturing(
        _ executable: String,
        _ args: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ([executable] + args).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(writeFD)
        guard spawned == 0 else {
            close(readFD)
            return nil
        }
        defer { close(readFD) }

        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var eof = false
        while !eof {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remaining)
            if ready == 0 { return abandon(pid) }
            if ready < 0 {
                if errno == EINTR { continue }
                return abandon(pid)
            }
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count) } else if count == 0 || errno != EINTR { eof = true }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() >= deadline { return abandon(pid) }
            usleep(10_000)
        }
        // No killpg here: the child is reaped, its pid may be recycled. A
        // straggler holding the pipe would have blocked EOF until the deadline.
        return String(decoding: data, as: UTF8.self)
    }

    /// The timeout path: the whole group dies, the child is reaped, nil.
    private static func abandon(_ pid: pid_t) -> String? {
        _ = killpg(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return nil
    }
}
