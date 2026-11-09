import Foundation

/// The watchdog that keeps llama-server from outliving the app (SPEC 7.1).
///
/// The engine is started through `/bin/sh`, not directly, because a process
/// cannot clean up after itself when it is killed with `kill -9`. The shell
/// stops llama-server as soon as the app is gone,
/// whether it exited normally or was force quit.
///
/// The shell learns that the app is gone from a pipe, not by polling its pid:
/// the earlier `kill -0` loop started `sleep` twice a second for as long as the
/// engine ran, about 1% of a core while idle (perf review 2026-11-09).
enum EngineWatchdog {
    static let script = """
    #!/bin/sh
    # Started by Yaku. $1 is the app's pid (kept for the log), $2 is where the
    # llama-server pid is written, and the rest is the llama-server command.
    #
    # stdin is a pipe whose only writer is the app, so it reads end-of-file the
    # moment the app is gone, however it went (kill -9 included). Nothing here
    # polls: the shell blocks in `wait` and the reader blocks in `read`.
    # When llama-server exits on its own the shell exits with the same status,
    # so the app's log says how it died (for example 137 for SIGKILL).
    pid_file="$2"
    shift 2

    exec 3<&0 0</dev/null
    "$@" 3<&- &
    server_pid=$!
    printf '%s\\n' "$server_pid" > "$pid_file"

    shutdown() {
        kill -TERM "$server_pid" 2>/dev/null
        waited=0
        while kill -0 "$server_pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
            sleep 0.25
            waited=$((waited + 1))
        done
        kill -KILL "$server_pid" 2>/dev/null
        kill "$reader_pid" 2>/dev/null
        exit 0
    }
    trap shutdown TERM INT HUP

    { while read -r _; do :; done <&3; kill -TERM $$ 2>/dev/null; } &
    reader_pid=$!
    exec 3<&-

    wait "$server_pid"
    status=$?
    kill "$reader_pid" 2>/dev/null
    exit "$status"

    """

    /// Writes the script next to the other runtime files and returns its path.
    static func install() -> String? {
        let url = AppPaths.watchdogScript
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        } catch {
            AppLog.write("watchdog: could not write \(url.path) (\(error))")
            return nil
        }
    }

    /// The pid of the llama-server the watchdog started, once it has reported it.
    static func serverPid() -> pid_t? {
        guard let text = try? String(contentsOf: AppPaths.watchdogPidFile, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func clearPidFile() {
        try? FileManager.default.removeItem(at: AppPaths.watchdogPidFile)
    }

    /// Waits up to `timeout` for the shell to write the server's pid.
    static func waitForServerPid(timeout: TimeInterval = 3) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = serverPid(), pid > 0 { return pid }
            usleep(100_000)
        }
        return nil
    }
}
