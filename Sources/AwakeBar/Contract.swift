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

// MARK: - Plan-usage sources (web link + the OAuth endpoint)
//
// How the menu surfaces plan usage: the `/api/oauth/usage` endpoint below — the
// exact `/usage` numbers, reached with a token AwakeBar mints via its OWN OAuth
// login (UsageOAuth) — plus the web link the header opens.
//
// The OAuth literals live here as the single Swift-side source of truth, the way
// Contract centralises the hook literals. They're reverse-engineered (Anthropic
// doesn't document `/api/oauth/usage`) so a drift is a one-line fix here.
enum UsageAPI {
    // Where the "Plan Usage" header links — the plan-usage page on the web.
    // Best-guess deep link; adjust here if Anthropic moves the settings path.
    static let webUsageURL = URL(string: "https://claude.ai/settings/usage")!

    // MARK: OAuth (the live source)
    //
    // We reuse Claude Code's *public* OAuth client id but run our own PKCE login
    // and store our own token (see UsageOAuth / TokenStore) — AwakeBar never reads
    // `Claude Code-credentials`, so there's no macOS Keychain prompt and no
    // token-rotation race (the reason the old Keychain path was dropped).
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthAuthorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    // Manual copy/paste callback: the consent page shows a "code#state" string the
    // user pastes back. Must match byte-for-byte in the token exchange.
    static let oauthRedirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let oauthScope = "org:create_api_key user:profile user:inference"
    // The token endpoint. `api.anthropic.com/v1/oauth/token` is the live one (same
    // host as the usage GET; verified returning RFC-6749 `invalid_grant` for a bad
    // code). `console.anthropic.com/v1/oauth/token` — what the older references use
    // — now 404s. Tried in order, so a host flip doesn't break login/refresh.
    static let oauthTokenURLs = [
        URL(string: "https://api.anthropic.com/v1/oauth/token")!,
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
    ]
    static let oauthBetaHeader = "oauth-2025-04-20"
    // Sent on the usage GET; mimics the real client to dodge aggressive 429s.
    static let usageUserAgent = "claude-code/2.1.181"

    // The endpoint backing `/usage`. Bearer token + the beta header above.
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // The Keychain generic-password service AwakeBar stores ITS OWN token under —
    // deliberately not "Claude Code-credentials", so we own the item's ACL.
    static let oauthKeychainService = "io.jp7.awakebar.oauth"
}
