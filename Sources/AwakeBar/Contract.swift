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

// MARK: - Plan-usage API contract
//
// The undocumented bits AwakeBar needs to read Claude Code's *plan* usage (the
// `/usage` screen: 5-hour / weekly limit utilisation + reset times). Unlike the
// hook Contract above this is app↔Anthropic, not app↔hook — so there is NO shell
// mirror; these literals live only here. Same discipline though: they're an
// undocumented private interface Claude Code uses for its own `/usage`, so a
// rename upstream is a one-line fix in this enum. See PlanLimits.swift.
enum UsageAPI {
    // Read-only usage endpoint that backs Claude Code's `/usage`. We hit this and
    // never `/v1/messages` — it spends no generation quota and returns every bar.
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Where the "Plan Usage" header links — the plan-usage page on the web.
    // Best-guess deep link; adjust here if Anthropic moves the settings path.
    static let webUsageURL = URL(string: "https://claude.ai/settings/usage")!

    // The OAuth token lives in the login Keychain under this generic-password
    // service, stored as a JSON blob ({ claudeAiOauth: { accessToken, … } }).
    static let keychainService = "Claude Code-credentials"

    // Headers that make the request look like Claude Code's own usage check.
    // The beta opts the OAuth token into the messages/usage surface; the
    // User-Agent is load-bearing — without a `claude-code/<ver>` UA the endpoint
    // drops you into an aggressively rate-limited bucket that 429s for 30+ min.
    static let betaHeader = "oauth-2025-04-20"

    // Track the installed Claude Code version when it drifts; only the
    // `claude-code/` prefix is what keeps us out of the punitive bucket, so an
    // approximate version is fine. (Follow-up: read it from the newest transcript's
    // `version` field instead of hardcoding.)
    static let clientVersion = "2.1.157"
    static var userAgent: String { "claude-code/\(clientVersion)" }
}
