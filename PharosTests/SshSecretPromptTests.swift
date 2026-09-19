// Standalone test for `SshTunnelAuthError` and `SshSecretPrompt` — the marker
// the core puts in front of a tunnel authentication failure, and the rule that
// decides what to do about one.
//
// `PasswordPromptCoordinator` reaches `AppStateManager` and through it the
// whole FFI, so it cannot be compiled by a `swiftc` harness. The DECISION
// therefore lives in a value type and the coordinator only applies it; these
// tests pin the decision.
//
// The marker string is a CONTRACT with `pharos-core`'s
// `db::ssh_tunnel::TUNNEL_AUTH_MARKER`. It is written out literally here, so a
// change on either side shows up as a failure rather than as a prompt that
// silently stops appearing.
import AppKit
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ n: String) {
    if a == b { print("PASS \(n)") } else { failures += 1; print("FAIL \(n) — got \(a), wanted \(b)") }
}

/// Exactly what `tagged_tunnel_message` builds for `TunnelError::AuthFailed`.
private let taggedAuthFailure = "[SSH AUTH] SSH authentication failed for root@bastion.example.com."

func runTests() {
    // MARK: The marker

    // 1. The literal contract. If `TUNNEL_AUTH_MARKER` is ever renamed in the
    // core, this line is what says so.
    expectEqual(SshTunnelAuthError.marker, "[SSH AUTH]", "the marker matches the core's")

    expect(SshTunnelAuthError.isAuthFailure(taggedAuthFailure),
           "a tagged message is read as an auth failure")
    expect(!SshTunnelAuthError.isAuthFailure("SSH host bastion not found."),
           "an untagged tunnel failure is not an auth failure")
    expect(!SshTunnelAuthError.isAuthFailure(nil),
           "no failure at all is not an auth failure")
    expect(!SshTunnelAuthError.isAuthFailure(""),
           "an empty failure is not an auth failure")

    // 2. The marker is for the app, never for the reader. What is shown is the
    // core's sentence, whole.
    expectEqual(SshTunnelAuthError.humanised(taggedAuthFailure),
                "SSH authentication failed for root@bastion.example.com.",
                "the marker is taken off before the message is shown")
    // Every other message crosses byte for byte, exactly as it did before the
    // marker existed.
    for message in ["SSH host bastion not found.",
                    "SSH host bastion:2222 did not answer.",
                    "The SSH tunnel stopped without a reason.",
                    "connection refused"] {
        expectEqual(SshTunnelAuthError.humanised(message), message,
                    "an untagged message is unchanged: \(message)")
    }

    // MARK: The decision

    // 3. Only an auth failure raises the sheet. Every other reason a tunnel or
    // a pool fails is about the host, the port or the server, and a secret
    // sheet in front of one would be a wrong answer confidently given.
    for message in ["SSH host bastion not found.",
                    "SSH tunnel failed: ssh: some other reason",
                    "connection refused"] {
        expectEqual(SshSecretPrompt.decide(failure: message, auth: .password,
                                           requiresAuthentication: false, gateIsFresh: false),
                    .ignore, "no sheet for: \(message)")
    }
    expectEqual(SshSecretPrompt.decide(failure: nil, auth: .password,
                                       requiresAuthentication: false, gateIsFresh: false),
                .ignore, "no failure, no sheet")

    // 4. A connection with no tunnel cannot be asked for a tunnel secret,
    // whatever the message happens to contain.
    expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: nil,
                                       requiresAuthentication: false, gateIsFresh: false),
                .ignore, "a connection with no tunnel is never asked for one's secret")

    // 5. The agent holds its own keys. `ssh` can still refuse us — a locked
    // agent, no key loaded — but nothing typed into a sheet would change that,
    // and asking would imply Pharos keeps a secret it does not have.
    expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: .agent,
                                       requiresAuthentication: false, gateIsFresh: false),
                .ignore, "an agent tunnel is never asked for a secret")

    // 6. The two modes that DO have a secret both ask.
    for auth in [SshAuthMethod.keyFile, .password] {
        expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: auth,
                                           requiresAuthentication: false, gateIsFresh: false),
                    .prompt, "a \(auth.rawValue) tunnel asks for its secret")
    }

    // 7. The Touch ID gate comes FIRST for a gated record. The sheet must
    // never become a way to open a gated connection without proving the
    // device owner is present.
    expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: .password,
                                       requiresAuthentication: true, gateIsFresh: false),
                .authenticateThenPrompt, "a gated record proves the owner before the sheet")

    // 8. A gate this connection passed moments ago still counts — one connect
    // can reach here more than once, and gating each step would show several
    // system prompts for one action while proving nothing the first did not.
    expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: .password,
                                       requiresAuthentication: true, gateIsFresh: true),
                .prompt, "a fresh gate stands in for a second one")

    // 9. A fresh gate on an UNGATED record changes nothing: there was no gate
    // to be fresh.
    expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: .password,
                                       requiresAuthentication: false, gateIsFresh: true),
                .prompt, "an ungated record just asks")

    // 10. A WRONG secret fails the same way a missing one does, and must raise
    // the same question — this is the case that lets a user correct a secret
    // they mistyped, instead of being stuck with a red badge.
    expectEqual(SshSecretPrompt.decide(failure: taggedAuthFailure, auth: .keyFile,
                                       requiresAuthentication: false, gateIsFresh: false),
                .prompt, "a wrong secret asks again, exactly as a missing one does")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
