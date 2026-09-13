# ClaudeUsageBar Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn `leffen/ClaudeUsageBar` into a private hardened build that stores the Claude session credential in the login keychain, asks for no permission it does not need, and accepts no author-controlled text from the network.

**Architecture:** The app is one 2,358-line Swift file compiled by `swiftc` in `app/build.sh`. We extract two pure, testable units into their own files (`CredentialStore.swift`, `CookieSanitizer.swift`), compile them into both the app and a standalone test binary, then rewire `UsageManager` to use them. Everything else is deletion: the Accessibility prompt, the remote announcement channel, and the plaintext `UserDefaults` cookie path.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit + Carbon (hotkey), Security.framework (keychain), plain `swiftc` builds — no Xcode project, no SwiftPM, no XCTest.

**Decisions taken (2026-09-13):**
- Private hardened build. No upstream PR, no compatibility constraints.
- Remote message channel removed entirely; version-number check kept.
- `status.claude.com` polling kept.

**Baseline:** `a4c7784`, byte-identical to upstream `Artzainnn/ClaudeUsageBar` HEAD. The app has never been installed on this machine (`ls ~/Library/Preferences | grep usagebar` is empty, nothing in `/Applications`), so **no migration code is needed** — nothing exists to migrate. Do not write any.

---

## Threat model being fixed

| # | Finding | Fixed by |
|---|---|---|
| 1 | Session cookie in plaintext at `~/Library/Preferences/com.claude.usagebar.plist`, readable by any process running as you | Task 3, 5, 6 |
| 2 | Entire `Cookie:` header stored when only two values are used | Task 4, 5 |
| 3 | Accessibility permission prompted but not required by `RegisterEventHotKey` | Task 7 |
| 4 | Remote-controlled notification text + buttons from upstream's repo | Task 8 |
| 5 | Bundle ID `com.claude.usagebar` squats Anthropic's namespace | Task 9 |
| 6 | `build.sh` hard-codes a Developer ID cert we do not have | Task 2 |

---

## Task 1: Branch and land the plan

**Files:**
- Create: `docs/plans/2026-09-13-harden-claudeusagebar.md` (this file)

**Step 1: Branch**

```bash
cd /Users/leffen/p/ClaudeUsageBar
git checkout -b harden
```

**Step 2: Commit the plan**

```bash
git add docs/plans/2026-09-13-harden-claudeusagebar.md
git commit -m "docs: plan for hardening the fork before install"
```

---

## Task 2: Make the app buildable locally

`build.sh:75` signs with `Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)` and hard-exits when that fails. We have no such certificate, so nothing can be built or verified until this is fixed. Ad-hoc signing (`--sign -`) is correct for a build that never leaves this machine: it satisfies the hardened runtime and lets macOS run it, it just carries no distributable identity.

**Files:**
- Modify: `app/build.sh:73-88` (signing block), `app/build.sh:91-93` (auto-launch)
- Create: `app/.gitignore`

**Step 1: Replace the signing block**

Replace everything from `DEVELOPER_ID="Developer ID...` through the closing `fi` with:

```bash
# Ad-hoc signature. This build is for this machine only and is never
# distributed, so there is no Developer ID and no notarization step.
# --options runtime still enables the hardened runtime.
if codesign --force --deep --options runtime --sign - "$APP_PATH"; then
    echo "✅ App ad-hoc signed"
    codesign --verify --verbose=2 "$APP_PATH" || { echo "❌ Signature verification failed" >&2; exit 1; }
else
    echo "❌ Ad-hoc signing failed" >&2
    exit 1
fi
```

**Step 2: Drop the auto-launch**

Delete the final two lines (`echo "Launching app..."` and `open "$APP_PATH"`). A build script that launches a menu bar app leaves stray copies running and makes "is the new binary the one in my menu bar?" unanswerable.

**Step 3: Ignore build output**

```bash
cat > app/.gitignore << 'EOF'
build/
dmg_temp/
*.dmg
EOF
```

**Step 4: Verify the baseline builds**

```bash
cd app && ./build.sh
```
Expected: `Build successful!` and `App bundle created at: build/ClaudeUsageBar.app`. Swift 6.4 may emit warnings from this Swift-5-era source; warnings are fine, errors are not.

**Step 5: Commit**

```bash
git add app/build.sh app/.gitignore
git commit -m "build: ad-hoc sign locally, don't auto-launch"
```

---

## Task 3: CredentialStore (TDD)

There is no test target in this repo and adding Xcode/SwiftPM for two pure functions is not worth it. Instead: put the testable units in their own files and compile them into a second, tiny executable whose exit code is the test result.

**Files:**
- Create: `app/CredentialStore.swift`
- Create: `app/tests/main.swift`
- Create: `app/run-tests.sh`

**Step 1: Write the failing test**

`app/tests/main.swift` — top-level code, so the file must be called `main.swift`:

```swift
import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

// MARK: - CredentialStore

// A service name distinct from the app's, so tests never touch the real item.
let testService = "com.leffen.claudeusagebar.tests"

print("CredentialStore")
CredentialStore.delete(service: testService, account: "roundtrip")

check(CredentialStore.load(service: testService, account: "roundtrip") == nil,
      "load returns nil when no item exists")

check(CredentialStore.save("sessionKey=abc123", service: testService, account: "roundtrip"),
      "save succeeds")

check(CredentialStore.load(service: testService, account: "roundtrip") == "sessionKey=abc123",
      "load returns what save stored")

check(CredentialStore.save("sessionKey=replaced", service: testService, account: "roundtrip"),
      "save over an existing item succeeds")

check(CredentialStore.load(service: testService, account: "roundtrip") == "sessionKey=replaced",
      "save overwrites rather than duplicating")

check(CredentialStore.delete(service: testService, account: "roundtrip"),
      "delete succeeds")

check(CredentialStore.load(service: testService, account: "roundtrip") == nil,
      "load returns nil after delete")

check(CredentialStore.delete(service: testService, account: "roundtrip"),
      "delete is idempotent when nothing is there")

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
```

`app/run-tests.sh`:

```bash
#!/bin/bash
set -e
mkdir -p build
swiftc -o build/tests \
    CredentialStore.swift \
    CookieSanitizer.swift \
    tests/main.swift \
    -framework Foundation \
    -framework Security
# Ad-hoc sign so the keychain sees a stable identity and doesn't prompt
# on every run for items the binary created itself.
codesign --force --sign - build/tests
./build/tests
```

```bash
chmod +x app/run-tests.sh
```

**Step 2: Run it to verify it fails**

```bash
cd app && ./run-tests.sh
```
Expected: compile error, `cannot find 'CredentialStore' in scope` (and `no such file: CookieSanitizer.swift`). That is the failing state.

**Step 3: Write the implementation**

`app/CredentialStore.swift`:

```swift
import Foundation
import Security

/// Stores the Claude session credential in the login keychain.
///
/// The upstream app kept it in UserDefaults, which lands in
/// ~/Library/Preferences/<bundle-id>.plist as readable text: any process
/// running as this user can read it with no prompt and no TCC gate, and it
/// rides along into every Time Machine backup. The keychain is gated per-item
/// by code signature and is not swept up by backup tooling the same way.
enum CredentialStore {
    static let defaultService = "com.leffen.claudeusagebar"
    static let defaultAccount = "claude-session"

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ value: String,
                     service: String = defaultService,
                     account: String = defaultAccount) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete-then-add rather than SecItemUpdate: one code path, and it
        // cannot leave a duplicate item behind.
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)

        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        // ThisDeviceOnly: never syncs to iCloud Keychain, never restores onto
        // another machine from a backup. A session cookie should not travel.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String = defaultService,
                     account: String = defaultAccount) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    static func delete(service: String = defaultService,
                       account: String = defaultAccount) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
```

**Step 4: Run the tests to verify they pass**

```bash
cd app && ./run-tests.sh
```
Expected: eight `ok` lines and `All tests passed.`, exit 0. (`CookieSanitizer.swift` does not exist yet — create it empty for now with `touch CookieSanitizer.swift`, Task 4 fills it in.)

**If macOS shows a keychain prompt:** allow it once. It appears because the ad-hoc signature changes on each rebuild, so the item's ACL no longer matches. If it becomes noisy during development, add `security delete-generic-password -s com.leffen.claudeusagebar.tests` before the run.

**Step 5: Commit**

```bash
git add app/CredentialStore.swift app/CookieSanitizer.swift app/tests/main.swift app/run-tests.sh
git commit -m "feat: keychain-backed CredentialStore with a standalone test runner"
```

---

## Task 4: CookieSanitizer (TDD)

The setup instructions say to paste the whole `Cookie:` header. The app only ever needs two values from it: `sessionKey` (the credential) and `lastActiveOrg` (the org UUID used to build the usage URL). Everything else — `__cf_bm`, `activitySessionId`, analytics IDs — is stored for no reason. Storing less is the cheapest security win available here.

**Files:**
- Modify: `app/CookieSanitizer.swift`
- Modify: `app/tests/main.swift` (append)

**Step 1: Write the failing tests**

Append to `app/tests/main.swift`, before the final `print`/`exit` lines:

```swift
// MARK: - CookieSanitizer

print("\nCookieSanitizer")

check(CookieSanitizer.minimize("sessionKey=sk-ant-sid01-xyz; lastActiveOrg=org-uuid; __cf_bm=junk; ajs_user_id=123")
        == "sessionKey=sk-ant-sid01-xyz; lastActiveOrg=org-uuid",
      "keeps only sessionKey and lastActiveOrg")

check(CookieSanitizer.minimize("__cf_bm=junk; lastActiveOrg=org-uuid; sessionKey=sk-ant-sid01-xyz")
        == "sessionKey=sk-ant-sid01-xyz; lastActiveOrg=org-uuid",
      "normalises order regardless of input order")

check(CookieSanitizer.minimize("  sessionKey=sk-ant-sid01-xyz ;  __cf_bm=junk  ")
        == "sessionKey=sk-ant-sid01-xyz",
      "tolerates surrounding whitespace")

check(CookieSanitizer.minimize("sk-ant-sid01-barevalue")
        == "sessionKey=sk-ant-sid01-barevalue",
      "wraps a bare session key that was pasted without its name")

check(CookieSanitizer.minimize("") == "",
      "empty input yields empty output")

check(CookieSanitizer.minimize("__cf_bm=junk; ajs_user_id=123") == "",
      "input with no session key yields empty output")

check(CookieSanitizer.minimize("sessionKey=abc=def; lastActiveOrg=o1")
        == "sessionKey=abc=def; lastActiveOrg=o1",
      "keeps '=' characters inside the value")
```

**Step 2: Run to verify they fail**

```bash
cd app && ./run-tests.sh
```
Expected: `cannot find 'CookieSanitizer' in scope`.

**Step 3: Implement**

`app/CookieSanitizer.swift`:

```swift
import Foundation

/// Reduces a pasted `Cookie:` header to the only two values this app uses.
///
/// The paste from DevTools carries the full header — Cloudflare tokens,
/// analytics IDs, whatever else claude.ai set. None of it is needed to read
/// usage, so none of it is worth keeping around.
enum CookieSanitizer {
    /// Order matters: output is normalised to this order so the stored string
    /// is stable regardless of how the browser happened to order the header.
    private static let keptKeys = ["sessionKey", "lastActiveOrg"]

    static func minimize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var found: [String: String] = [:]
        for part in trimmed.components(separatedBy: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<eq])
            guard keptKeys.contains(name) else { continue }
            // Split on the FIRST '=' only; session key values can contain more.
            found[name] = String(pair[pair.index(after: eq)...])
        }

        // Someone who pastes only the session key value, with no name in front
        // of it, still gets a working config.
        if found["sessionKey"] == nil,
           !trimmed.contains("="),
           !trimmed.contains(";") {
            found["sessionKey"] = trimmed
        }

        guard found["sessionKey"] != nil else { return "" }

        return keptKeys.compactMap { key in
            found[key].map { "\(key)=\($0)" }
        }.joined(separator: "; ")
    }

    /// The org UUID, if the cookie carries one.
    static func organizationId(from cookie: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            if pair.hasPrefix("lastActiveOrg=") {
                let value = String(pair.dropFirst("lastActiveOrg=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
```

**Step 4: Run to verify they pass**

```bash
cd app && ./run-tests.sh
```
Expected: all 15 checks `ok`, exit 0.

**Step 5: Commit**

```bash
git add app/CookieSanitizer.swift app/tests/main.swift
git commit -m "feat: keep only sessionKey and lastActiveOrg from the pasted cookie"
```

---

## Task 5: Route the app through CredentialStore

**Files:**
- Modify: `app/ClaudeUsageBar.swift:431-436` (`loadSessionCookie`)
- Modify: `app/ClaudeUsageBar.swift:504-510` (`saveSessionCookie`)
- Modify: `app/ClaudeUsageBar.swift:512-517` (`clearSessionCookie`, top of it)
- Modify: `app/ClaudeUsageBar.swift:546-580` (`fetchOrganizationId`)
- Modify: `app/build.sh` (both `swiftc` invocations)

**Step 1: Add the new files to the build**

In `app/build.sh`, both `swiftc` invocations currently list `ClaudeUsageBar.swift` alone. Change each to:

```bash
    ClaudeUsageBar.swift \
    CredentialStore.swift \
    CookieSanitizer.swift \
```

and append `-framework Security` to both, next to the existing `-framework` flags.

**Step 2: Replace `loadSessionCookie`**

```swift
    func loadSessionCookie() {
        sessionCookie = CredentialStore.load() ?? ""
    }
```

**Step 3: Replace `saveSessionCookie`**

```swift
    func saveSessionCookie(_ cookie: String) {
        let minimized = CookieSanitizer.minimize(cookie)
        guard !minimized.isEmpty else {
            errorMessage = "That doesn't look like a Claude cookie — no sessionKey in it."
            return
        }
        sessionCookie = minimized
        if CredentialStore.save(minimized) {
            NSLog("ClaudeUsage: credential stored in keychain")
        } else {
            errorMessage = "Could not write to the keychain."
        }
    }
```

Note the removed `NSLog` calls: upstream logged the cookie's length on every save. Length is a weak oracle but it is free to not log it.

**Step 4: Fix the top of `clearSessionCookie`**

Replace the first four lines of the body:

```swift
    func clearSessionCookie() {
        sessionCookie = ""
        CredentialStore.delete()
```

Leave the rest of the method (the field resets) exactly as it is.

**Step 5: Fix `fetchOrganizationId`**

Two changes. Use the shared parser, and fix a latent bug: line 566 sends `sessionKey=\(sessionCookie)` where `sessionCookie` is already a full `name=value; name=value` string, producing `Cookie: sessionKey=sessionKey=...`. It goes unnoticed because `lastActiveOrg` is almost always present so the bootstrap path is never reached — but after minimization a Pro user without `lastActiveOrg` would hit it.

```swift
    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        if let orgId = CookieSanitizer.organizationId(from: sessionCookie) {
            completion(orgId)
            return
        }

        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")
        ...
```

Keep the rest of the method unchanged, but delete the `NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")` and `NSLog("📋 Found org ID in cookie: \(orgId)")` lines — the org UUID identifies the account in the system log.

**Step 6: Build and verify**

```bash
cd app && ./build.sh
```
Expected: `Build successful!`. Verified for real in Task 10; this step only proves it compiles.

**Step 7: Commit**

```bash
git add app/ClaudeUsageBar.swift app/build.sh
git commit -m "feat: store the session credential in the keychain, not UserDefaults"
```

---

## Task 6: Close the last plaintext read

`ClaudeUsageBar.swift:1527` reads the cookie straight out of `UserDefaults` to prefill the settings field with a 20-character preview. Left alone it both breaks (the key no longer exists) and re-opens the thing we just closed.

**Files:**
- Modify: `app/ClaudeUsageBar.swift:1526-1529`

**Step 1: Replace the `.onAppear` body**

```swift
            .onAppear {
                if usageManager.hasStoredCredential {
                    sessionCookieInput = "•••••••••••••••••••• (stored in keychain)"
                }
                usageManager.updatePercentages()
            }
```

**Step 2: Add the flag it reads**

In `UsageManager`, next to the other computed helpers:

```swift
    /// True when a credential is on file. Deliberately does not expose the
    /// value itself — the UI has no reason to hold it.
    var hasStoredCredential: Bool { !sessionCookie.isEmpty }
```

Showing a fixed-width dot mask rather than a real prefix means the settings pane never renders any part of the credential, so a screen share or screenshot of the popup leaks nothing.

**Step 3: Build**

```bash
cd app && ./build.sh
```
Expected: `Build successful!`

**Step 4: Verify no read path survives**

```bash
grep -n "claude_session_cookie" app/ClaudeUsageBar.swift
```
Expected: **no output.** If anything prints, that line is still reading or writing the plaintext key.

**Step 5: Commit**

```bash
git add app/ClaudeUsageBar.swift
git commit -m "fix: settings pane no longer reads or displays the credential"
```

---

## Task 7: Stop asking for Accessibility

`RegisterEventHotKey` (Carbon, line 220) registers a system-wide hotkey without Accessibility. The `addGlobalMonitorForEvents` at line 283 watches `.leftMouseDown`/`.rightMouseDown` to dismiss the popover, which also works untrusted. So the prompt at startup asks for the strongest permission on macOS short of Full Disk Access — the ability to observe and synthesise events in every running app — for a feature that does not use it.

**Files:**
- Modify: `app/ClaudeUsageBar.swift:139-142` (`setupKeyboardShortcut`)
- Delete: `app/ClaudeUsageBar.swift:157-180` (`checkAccessibilityPermissions`)
- Delete: `app/ClaudeUsageBar.swift:412` (`isAccessibilityEnabled`), `:425` (init call), `:428-430` (`checkAccessibilityStatus`)
- Modify: `app/ClaudeUsageBar.swift:2147-2158` (settings button)

**Step 1: Strip the startup prompt**

```swift
    func setupKeyboardShortcut() {
        // No Accessibility check: RegisterEventHotKey does not require it.
        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }
```

Then delete the whole `checkAccessibilityPermissions()` function.

**Step 2: Remove the published flag**

Delete `@Published var isAccessibilityEnabled: Bool = false`, the `checkAccessibilityStatus()` call in `init`, and the `checkAccessibilityStatus()` function.

**Step 3: Replace the settings block**

Delete the `if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled { ... }` block (button + caption) entirely. Nothing replaces it.

**Step 4: Verify no references remain**

```bash
grep -n "AXIsProcessTrusted\|isAccessibilityEnabled\|Privacy_Accessibility\|checkAccessibility" app/ClaudeUsageBar.swift
```
Expected: **no output.**

**Step 5: Build**

```bash
cd app && ./build.sh
```
Expected: `Build successful!`

**Step 6: Commit**

```bash
git add app/ClaudeUsageBar.swift
git commit -m "fix: drop the Accessibility prompt — the Carbon hotkey doesn't need it"
```

The hotkey is verified for real in Task 10. If it turns out Cmd+U does not fire, that is a finding worth knowing before granting anything: the fix is to keep the permission *optional* and never prompt at launch, not to restore the modal.

---

## Task 8: Remove the remote message channel

`UpdateManager` accepts, from a file in someone else's GitHub repo: a notification title, a notification body, banner heading/title/body, and a list of labelled buttons with URLs. The comment at line 1247 states it plainly — *"Every field author-controlled, including the notification title."* That is a ready-made phishing channel into a native macOS notification, gated only by an allowlist that permits any repository on `github.com`.

After this task the only thing that crosses the network from that file is three integers.

**Files:**
- Delete: `app/ClaudeUsageBar.swift:1146-1151` (`BannerButton`), `:1165-1174` (`Announcement`)
- Modify: `app/ClaudeUsageBar.swift:1153-1163` (`AvailableUpdate`)
- Rewrite: `app/ClaudeUsageBar.swift:1176-1345` (`UpdateManager`)
- Modify: `app/ClaudeUsageBar.swift:1550-1590` (announcement banner), `:1592-1624` (update banner)
- Delete: `app/ClaudeUsageBar.swift:2317-2336` (`bannerButton`)
- Modify: `app/tests/main.swift` (append)

**Step 1: Write the failing test for `isNewer`**

`isNewer` is the one piece of logic worth keeping, and it is pure. Move it out of the class so it is testable — append to `app/tests/main.swift`:

```swift
// MARK: - VersionCompare

print("\nVersionCompare")

check(VersionCompare.isNewer(remote: "1.3.4", than: "1.3.3"), "patch bump is newer")
check(VersionCompare.isNewer(remote: "1.10.0", than: "1.9.0"), "10 > 9, not string order")
check(VersionCompare.isNewer(remote: "2.0", than: "1.9.9"), "shorter major wins")
check(!VersionCompare.isNewer(remote: "1.3.3", than: "1.3.3"), "equal is not newer")
check(!VersionCompare.isNewer(remote: "1.3.2", than: "1.3.3"), "older is not newer")
check(!VersionCompare.isNewer(remote: "garbage", than: "1.3.3"), "unparseable is not newer")
```

**Step 2: Run to verify it fails**

```bash
cd app && ./run-tests.sh
```
Expected: `cannot find 'VersionCompare' in scope`.

**Step 3: Create `app/VersionCompare.swift`**

```swift
import Foundation

enum VersionCompare {
    static func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
```

Add it to both `swiftc` lines in `build.sh` and to `run-tests.sh`.

**Step 4: Run to verify it passes**

```bash
cd app && ./run-tests.sh
```
Expected: all 21 checks `ok`.

**Step 5: Replace `UpdateManager` wholesale**

Delete `BannerButton`, `Announcement`, and everything from `class UpdateManager` to its closing brace, and put this in their place:

```swift
struct AvailableUpdate: Equatable {
    let version: String
}

/// Checks whether upstream has published a newer version. Reads exactly one
/// field — `version` — and ignores everything else in the file.
///
/// Upstream's latest.json also carries a free-form `message` object whose
/// title, body and buttons are rendered by the stock app, notification
/// included. This build does not read it: a remote party should not be able
/// to put arbitrary text in front of us, in a native notification, on demand.
class UpdateManager: ObservableObject {
    @Published var available: AvailableUpdate?

    private let endpoint = URL(string: "https://raw.githubusercontent.com/Artzainnn/ClaudeUsageBar/main/website/latest.json")!

    /// Fixed, compiled-in. Never taken from the payload.
    static let releasesURL = URL(string: "https://github.com/Artzainnn/ClaudeUsageBar/releases")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  // Reject anything that isn't a plain dotted number.
                  version.range(of: "^[0-9]{1,4}(\\.[0-9]{1,4}){0,3}$", options: .regularExpression) != nil
            else { return }

            DispatchQueue.main.async {
                guard VersionCompare.isNewer(remote: version, than: self.currentVersion) else {
                    self.available = nil
                    return
                }
                guard UserDefaults.standard.string(forKey: "dismissed_update_version") != version else { return }
                self.available = AvailableUpdate(version: version)
            }
        }.resume()
    }

    func dismissCurrent() {
        if let v = available?.version {
            UserDefaults.standard.set(v, forKey: "dismissed_update_version")
        }
        available = nil
    }
}
```

Note there is no longer a system notification on this path at all — the banner appears in the popup when you open it, which is enough for a build you compile yourself.

**Step 6: Replace both banners with one**

Delete the announcement banner block (`if let ann = updateManager.announcement { ... }`) and replace the update banner block with:

```swift
            if let update = updateManager.available {
                HStack(spacing: 6) {
                    Text("⬆️")
                    Text("Version \(update.version) is available upstream")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Releases") {
                        NSWorkspace.shared.open(UpdateManager.releasesURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(action: { updateManager.dismissCurrent() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color.secondaryText)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }
```

Every string there is compiled in. Then delete the `bannerButton(_:)` helper.

**Step 7: Verify nothing references the removed types**

```bash
grep -n "announcement\|Announcement\|BannerButton\|isSafeURL\|parseButtons\|NSUserNotification(" app/ClaudeUsageBar.swift
```
Expected: only the `NSUserNotification(` hits inside `UsageManager` (usage thresholds) and `StatusManager` (incidents) — those are locally generated text and stay. No `announcement`/`BannerButton`/`isSafeURL` hits at all.

**Step 8: Build and test**

```bash
cd app && ./run-tests.sh && ./build.sh
```
Expected: all tests pass, `Build successful!`

**Step 9: Commit**

```bash
git add app/ClaudeUsageBar.swift app/VersionCompare.swift app/tests/main.swift app/build.sh app/run-tests.sh
git commit -m "fix: update check reads only a version number, no remote text or URLs"
```

---

## Task 9: Take a bundle identity of our own

`com.claude.usagebar` claims Anthropic's reverse-DNS namespace for a third-party app. It also collides conceptually with the real `com.anthropic.claudefordesktop` already installed on this machine. Nothing has ever run under the old ID here, so this is free.

**Files:**
- Modify: `app/Info.plist`

**Step 1: Change the identifier and mark the build**

```bash
cd app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.leffen.claudeusagebar" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 8-hardened" Info.plist
```

`CredentialStore.defaultService` is already `com.leffen.claudeusagebar`, so the keychain item and the bundle now agree.

**Step 2: Drop the dead ATS exception**

`Info.plist` carries an `NSExceptionDomains` entry for `anthropic.com`. The app never contacts `anthropic.com` — it uses `claude.ai`, `status.claude.com` and `raw.githubusercontent.com`. Remove the whole `NSExceptionDomains` dict and keep `NSAllowsArbitraryLoads = false`, so every connection is held to App Transport Security defaults with no carve-outs.

```bash
/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSExceptionDomains" Info.plist
```

**Step 3: Verify**

```bash
plutil -p Info.plist | grep -A4 -E "CFBundleIdentifier|NSAppTransportSecurity"
```
Expected: `com.leffen.claudeusagebar`, and an `NSAppTransportSecurity` dict containing only `NSAllowsArbitraryLoads => 0`.

**Step 4: Commit**

```bash
git add app/Info.plist
git commit -m "chore: own bundle identifier, drop the unused ATS exception"
```

---

## Task 10: Build, install, and verify against the real thing

Everything above is unverified until the app runs. This task is the actual security verification — do not skip it and do not report the work as done without its output.

**Step 1: Clean build and full test run**

```bash
cd /Users/leffen/p/ClaudeUsageBar/app
./run-tests.sh && ./build.sh
```
Expected: `All tests passed.` then `Build successful!`

**Step 2: Install**

```bash
rm -rf /Applications/ClaudeUsageBar.app
cp -R build/ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

**Step 3: Confirm no Accessibility prompt**

Expected: the app appears in the menu bar with **no** permission dialog. If a dialog appears, Task 7 is incomplete.

**Step 4: Set the cookie**

Open the popup → Settings → paste the cookie from claude.ai DevTools → *Save Cookie & Fetch*. Expected: usage percentages appear within a few seconds.

**Step 5: Prove the credential is in the keychain**

```bash
security find-generic-password -s com.leffen.claudeusagebar -a claude-session
```
Expected: an item description printed. **Do not pass `-w`** — that prints the secret to the terminal and into shell history.

**Step 6: Prove it is not in the preferences plist**

```bash
defaults read com.leffen.claudeusagebar 2>/dev/null | grep -ci "cookie\|sessionKey\|sk-ant"
ls ~/Library/Preferences/com.claude.usagebar.plist 2>&1
```
Expected: `0`, and `No such file or directory`.

**Step 7: Prove nothing leaked to the system log**

```bash
log show --predicate 'process == "ClaudeUsageBar"' --last 10m 2>/dev/null | grep -ci "sk-ant\|sessionKey="
```
Expected: `0`.

**Step 8: Confirm the hotkey works without Accessibility**

Check System Settings → Privacy & Security → Accessibility: ClaudeUsageBar should not be listed, or should be listed and off. Then press ⌘U from another app. Expected: the popup toggles.

If it does not: record the finding in this plan, disable the shortcut in Settings, and decide about the permission deliberately. Do not reinstate the launch-time modal.

**Step 9: Confirm the network footprint**

With the app running and freshly refreshed:

```bash
lsof -i -a -p "$(pgrep -x ClaudeUsageBar)" -nP 2>/dev/null
```
Expected: connections only to Cloudflare/GitHub/Anthropic-fronted addresses for `claude.ai`, `status.claude.com`, `raw.githubusercontent.com`. Anything else is a finding.

**Step 10: Tag the verified build**

```bash
cd /Users/leffen/p/ClaudeUsageBar
git tag -a v1.3.3-hardened -m "Hardened local build: keychain credential, no Accessibility prompt, no remote message channel"
git log --oneline main..harden
```

---

## What this plan does NOT fix

Worth stating so it is a decision rather than an oversight:

- **The trust model is unchanged.** The app still holds a bearer credential for a Claude account. Hardening the storage narrows who can read it; it does not remove the credential from the machine.
- **Upstream code is still upstream's.** We reviewed `a4c7784` and build from it. Any future `git pull` brings in code nobody has reviewed — re-read the diff before merging, particularly `UpdateManager` and anything touching `CredentialStore`.
- **Work vs. personal account.** If the cookie comes from a Fjord Line Claude account, it is a corporate credential and the decision to put it in a third-party app belongs to whoever owns that policy, regardless of how well the app stores it. Use a personal account here unless that has been cleared.
- **Revocation.** Signing out of claude.ai everywhere is what invalidates the cookie. That, not deleting the app, is the response if this machine is ever suspect.
