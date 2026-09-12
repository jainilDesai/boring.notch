# Handoff — read this before working on the voice agent

**The design docs for this work are NOT in this repo.** They are at:

```
~/Documents/projects/brow-agent/
```

Start with `brow-agent/README.md`, which gives a read order. Nine documents,
~8,500 words, written to be read cold.

---

## Why the docs are elsewhere

This is a **GPL-3.0 fork** of `TheBoredTeam/boring.notch`. The voice-agent code
is intended to be extracted into its own MIT-licensed Swift package
(`brow-agent`) once its interfaces settle, so the docs live with the package,
not the fork. See `brow-agent/docs/07-DECISIONS.md` (D10, D11).

## Before you touch anything

**1. Roughly half the work is uncommitted**, including the entire safety gate
and the custom-command system. `git status` will show ~20 modified/untracked
files. Commit before making changes.

**2. Do NOT `git add -A && git push`.** This repo is **public**, and
`BoringNotchXPCHelper/credential-mirror.sh` plus the LaunchAgent plist are
untracked and relate to a credential bridge. Either exclude them or make the
repo private first.

**3. There is an open security issue.** `cat ~/.claude/.credential*` was
auto-allowed by the agent gate with no prompt — a glob walks around a deny-list
that only knows literal filenames. A fix was written but **verification was
inconclusive**. Treat the gate as compromised for file reads until confirmed.
Full detail in `brow-agent/docs/04-SECURITY.md`.

**4. Release builds need an explicit team**, or the app will not launch:

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath /tmp/browrel DEVELOPMENT_TEAM=298TK2456Q \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
```

Ad-hoc signing produces a `MediaRemoteAdapter.framework` team-ID mismatch at
launch. Debug builds mask this. See `brow-agent/docs/05-PLATFORM-FINDINGS.md`.

## The files this work added

| Area | Files |
|---|---|
| Voice session | `boringNotch/managers/VoiceInputManager.swift` |
| Local commands | `managers/LocalIntentMatcher.swift`, `managers/AgentAction.swift`, `managers/BrowserTabs.swift` |
| User commands | `models/CustomCommand.swift`, `managers/CustomCommandRunner.swift`, `managers/ConfirmPrompt.swift` |
| Logging | `managers/VoiceAuditLog.swift` |
| UI | `components/Voice/VoiceOverlayView.swift`, `components/Settings/Views/{Voice,Commands}SettingsView.swift` |
| Helper (unsandboxed) | `BoringNotchXPCHelper/{AgentRunner,AgentGate,UserCommandRunner,CredentialSync}.swift` |

Runtime state and logs: `~/Library/Application Support/Brow/agent/`
(`voice.log`, `gate.log`, `agent.log`). Generated gate: `~/.brow/gate.sh`.

**`log show` returns nothing in this environment** — that is why everything logs
to files. Do not replace it with `NSLog`.

## Tests

Reconstructed at `brow-agent/tests/` with run instructions. Not yet wired into
the Xcode project — doing so is the next task. Between them these cases have
caught six real bugs, and the gate suite currently has **expected failures**
recording a live vulnerability. Do not delete those to make it green.
