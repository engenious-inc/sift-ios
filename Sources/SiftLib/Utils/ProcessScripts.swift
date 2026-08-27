import Foundation

/// The owned-background-process shell contract, shared verbatim by the SSH and
/// local transports: a wrapper sh records its pid (its argv carries a unique
/// marker), runs the command, and writes the exit status atomically; termination
/// verifies pid + start-time identity before ever signalling.
enum ProcessScripts {

    static func inner(handle: BackgroundProcessHandle, command: String) -> String {
        """
        # sift-attempt:\(handle.attemptID)
        trap '' HUP
        umask 077
        echo $$ > \(handle.pidPath.shellQuoted)
        ( \(command)
        ) > \(handle.logPath.shellQuoted) 2>&1
        echo $? > \(handle.statusPath.shellQuoted).tmp && mv \(handle.statusPath.shellQuoted).tmp \(handle.statusPath.shellQuoted)
        """
    }

    /// Fire-and-forget launcher: no remote wait loop (macOS bash-3.2 can lose a
    /// SIGCHLD race and block in wait4 holding the exec channel open). `&` must
    /// background a SIMPLE command or sshd holds the channel until the tree dies.
    static func launcher(handle: BackgroundProcessHandle, command: String) -> String {
        // umask BEFORE mkdir: the proc/<attempt> directory itself must be born 0700.
        "umask 077; mkdir -p \(handle.directory.shellQuoted) || exit 1\n" +
        "/bin/sh -c \(inner(handle: handle, command: command).shellQuoted) > /dev/null 2>&1 < /dev/null &\n" +
        "exit 0"
    }

    /// TERM pass that snapshots the descendant tree (pid + start time per member)
    /// BEFORE signalling — a TERM-ignoring child stays reachable for KILL.
    static func terminate(handle: BackgroundProcessHandle, marker: String) -> String {
        """
        collect_tree() {
            echo "$1"
            for child in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$child"; done
        }
        PID=$(cat \(handle.pidPath.shellQuoted) 2>/dev/null)
        [ -n "$PID" ] || { echo "sift-no-pid"; exit 0; }
        ps -p "$PID" -o command= 2>/dev/null | grep -qF \(marker.shellQuoted) || { echo "sift-no-match"; exit 0; }
        for p in $(collect_tree "$PID"); do
            START=$(ps -p "$p" -o lstart= 2>/dev/null)
            [ -n "$START" ] || continue
            kill -TERM "$p" 2>/dev/null
            echo "$p|$START"
        done
        exit 0
        """
    }

    /// Signals only pids whose recorded start time still matches (a recycled pid is
    /// never touched). Signal "0" probes aliveness.
    static func signal(_ signalName: String, identities: [(pid: String, start: String)]) -> String {
        var lines = ["ALIVE=0"]
        for identity in identities {
            lines.append("START=$(ps -p \(identity.pid) -o lstart= 2>/dev/null)")
            lines.append("if [ \"$START\" = \(identity.start.shellQuoted) ]; then ALIVE=1; kill -\(signalName) \(identity.pid) 2>/dev/null; fi")
        }
        lines.append("echo \"alive=$ALIVE\"")
        return lines.joined(separator: "\n")
    }

    static func parseIdentities(fromTermOutput output: String) -> [(pid: String, start: String)] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let pid = parts[0].trimmingCharacters(in: .whitespaces)
                guard !pid.isEmpty, pid.allSatisfy(\.isNumber) else { return nil }
                return (pid, parts[1].trimmingCharacters(in: .whitespaces))
            }
    }
}
