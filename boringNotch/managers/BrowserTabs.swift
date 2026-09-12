//
//  BrowserTabs.swift
//  boringNotch
//
//  Finds an already-open browser tab and brings it to the front, so "open
//  youtube music" switches to the tab you already have rather than stacking
//  another copy.
//
//  Chrome and Safari expose tabs through incompatible AppleScript dialects, so
//  each gets its own script. Only browsers that are already running are asked —
//  looking for a tab must never launch a browser.
//
//  Requires Automation consent for each browser (System Settings > Privacy &
//  Security > Automation) and the matching bundle id in
//  boringNotch.entitlements, since the app is sandboxed.
//

import AppKit
import Foundation

enum BrowserTabs {

    private struct Browser {
        let name: String
        let bundleID: String
        /// `$NEEDLE` is substituted with the sanitised search string.
        let script: String
    }

    private static let browsers: [Browser] = [
        Browser(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            script: """
            tell application "Google Chrome"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if (URL of t contains "$NEEDLE") then
                            set active tab index of w to i
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "no"
            """
        ),
        Browser(
            name: "Safari",
            bundleID: "com.apple.Safari",
            script: """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t contains "$NEEDLE") then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "no"
            """
        ),
    ]

    /// Returns the browser name if a matching tab was focused, else nil.
    static func focusTab(matching host: String) async -> String? {
        guard let needle = sanitize(host) else { return nil }

        for browser in browsers where isRunning(browser.bundleID) {
            let script = browser.script.replacingOccurrences(of: "$NEEDLE", with: needle)
            do {
                let result = try await AppleScriptHelper.execute(script)
                if result?.stringValue == "ok" { return browser.name }
            } catch {
                // Most likely Automation consent not granted yet. Try the next
                // browser; the caller falls back to just opening the URL.
                NSLog("[voice] tab lookup in \(browser.name) failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Titles of every open tab across running scriptable browsers.
    static func listOpenTabs() async -> [String] {
        let scripts: [(bundleID: String, script: String)] = [
            ("com.google.Chrome", """
             set out to ""
             tell application "Google Chrome"
                 repeat with w in windows
                     repeat with t in tabs of w
                         set out to out & (title of t) & linefeed
                     end repeat
                 end repeat
             end tell
             return out
             """),
            ("com.apple.Safari", """
             set out to ""
             tell application "Safari"
                 repeat with w in windows
                     repeat with t in tabs of w
                         set out to out & (name of t) & linefeed
                     end repeat
                 end repeat
             end tell
             return out
             """),
        ]

        var titles: [String] = []
        for entry in scripts where isRunning(entry.bundleID) {
            // `try?` flattens the optional here, so `result` is non-optional.
            guard let result = try? await AppleScriptHelper.execute(entry.script),
                  let raw = result.stringValue else { continue }
            titles += raw
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return titles
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The needle is interpolated into an AppleScript string literal, so keep it
    /// to characters that cannot terminate the literal or inject statements.
    private static func sanitize(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_/")
        let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned))
        return result.isEmpty ? nil : result
    }
}
