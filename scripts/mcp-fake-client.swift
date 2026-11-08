// A stand-in AI app for scripts/live-mcp-check.sh: starts the command it is
// given (`Pharos --mcp`) as its own child, with its stdin and stdout, and
// waits for it. Pharos then names the app that launched the bridge by this
// binary — ad-hoc signed, so by its path — whatever shell or terminal ran
// the script, which keeps the check's approvals the same on every Mac.
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { exit(2) }
var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
var pid: pid_t = 0
guard posix_spawn(&pid, args[0], nil, nil, &argv, environ) == 0 else { exit(127) }
var status: Int32 = 0
waitpid(pid, &status, 0)
exit((status >> 8) & 0xff)
