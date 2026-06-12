import Foundation

// MARK: - Hook contract
//
// The single Swift-side source of truth for everything AwakeBar shares with its
// Claude Code hook scripts: the /tmp marker files they exchange, the VSCode
// bridge lifecycle strings parsed out of the extension-host log, the reason
// tokens keep-awake.sh records, and the cwd → marker-key sanitiser.
//
// MIRROR: claude-hook-contract.sh holds the shell-side copy of these same
// values (sourced by keep-awake.sh and notify-attention.sh). The two files are
// the only places these literals live — keep them in step, a change here is a
// change there. They can't share a literal at build time: one is a compiled
// binary, the other is bash sourced at run time.
enum Contract {
    // Marker files exchanged via /tmp. notify-attention.sh writes the attention
    // and done markers and the per-cwd activity markers; keep-awake.sh writes the
    // pid and reason and reads the idle window AwakeBar publishes into it.
    static let attentionMarker = "/tmp/claude-attention.json"
    static let doneMarker      = "/tmp/claude-done.json"
    static let hookPidFile     = "/tmp/claude-keep-awake.pid"
    static let hookReasonFile  = "/tmp/claude-keep-awake.reason"
    static let idleWindowFile  = "/tmp/claude-keep-awake.idle"
    static let activityPrefix  = "/tmp/claude-activity-"

    // The reason keep-awake.sh records in hookReasonFile — see AwakeMonitor's
    // HookReason and AppDelegate's status line.
    static let reasonTurn   = "turn"
    static let reasonRemote = "remote"

    // VSCode bridge lifecycle markers logged by Claude Code's extension. The
    // bridge is "connected" when the last connect-class marker is newer than any
    // teardown one. (Shell mirror: CLAUDE_BRIDGE_MARKERS_RE, one grep alternation.)
    static let bridgeConnectMarkers = [
        "[bridge:sdk] State change: connected",
        "[bridge:sdk] State change: ready",
        "[remote-bridge] v2 transport connected",
        "[remote-bridge] Created session",
    ]
    static let bridgeTeardownMarkers = [
        "[remote-bridge] Torn down",
        "[remote-bridge] Archive session",
    ]
    // Looser "bridge traffic is present" prefixes — used when no lifecycle marker
    // survives in the tail (handshake scrolled off) to still treat the session as
    // connected past its handshake.
    static let bridgeTrafficPrefixes = ["[remote-bridge]", "[bridge:"]

    // The per-cwd activity marker path. The key sanitiser mirrors the hook's
    // `tr -c 'A-Za-z0-9' '_'`, so both sides name the same file for a given cwd.
    static func activityMarkerPath(forCwd cwd: String) -> String {
        activityPrefix + markerKey(forCwd: cwd)
    }

    static func markerKey(forCwd cwd: String) -> String {
        var safe = ""
        for ch in cwd { safe.append(ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "_") }
        return safe
    }
}

// MARK: - Plan-usage web link
//
// Plan usage is now estimated locally from the JSONL transcripts (UsageLedger) —
// no endpoint, no Keychain token. All that's left here is where the menu's
// "Plan Usage" header sends you for the authoritative numbers on the web.
enum UsageAPI {
    // Where the "Plan Usage" header links — the plan-usage page on the web.
    // Best-guess deep link; adjust here if Anthropic moves the settings path.
    static let webUsageURL = URL(string: "https://claude.ai/settings/usage")!
}
