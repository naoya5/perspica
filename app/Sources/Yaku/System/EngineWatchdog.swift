import Foundation

/// The watchdog that keeps llama-server from outliving the app (SPEC 7.1).
///
/// The engine is started through `/bin/sh`, not directly, because a process
/// cannot clean up after itself when it is killed with `kill -9`. The shell
/// watches the app's pid and stops llama-server as soon as the app is gone,
/// whether it exited normally or was force quit.
///
/// The shell also stops the server when it is itself asked to terminate, so a
/// normal quit does not wait for the polling loop.
enum EngineWatchdog {
    static let script = """
    #!/bin/sh
    # Started by Yaku. $1 is the app's pid, $2 is where the llama-server pid is
    # written, and the rest is the llama-server command.
    #
    # The server is stopped when either side goes away: the app disappears
    # (including kill -9), or this shell is asked to terminate.
    app_pid="$1"
    pid_file="$2"
    shift 2

    "$@" &
    server_pid=$!
    printf '%s\\n' "$server_pid" > "$pid_file"

    stop_server() {
        kill -TERM "$server_pid" 2>/dev/null
    }

    trap 'stop_server; exit 0' TERM INT HUP

    while kill -0 "$app_pid" 2>/dev/null; do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            exit 0
        fi
        sleep 0.5
    done

    stop_server
    waited=0
    while kill -0 "$server_pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
        sleep 0.25
        waited=$((waited + 1))
    done
    kill -KILL "$server_pid" 2>/dev/null
    exit 0

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
