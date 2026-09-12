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

**1. The working tree is clean, but six commits are unpushed.** This repo is
**public**. Nothing in that history carries a secret — the diff was scanned, and
`BoringNotchXPCHelper/credential-mirror.sh` plus the LaunchAgent plist are in
`.gitignore` and stay on disk only. Neither is referenced by any target, so
excluding them breaks no build. Push deliberately; do not `git add -A` and hope.

**2. The agent has a real shell.** Every command it generates is screened by
`BoringNotchXPCHelper/AgentGate.swift`, which writes a `PreToolUse` hook to
`~/.brow/gate.sh`. It denies by default. The gate has been broken four separate
times, each in a way that looked correct and passed a test written for it, so
**read `brow-agent/docs/04-SECURITY.md` in full before changing it** — the
failures are recorded there with the lesson, which is the point of the document.

The credential-read bypass that was open here is **closed and verified**
(2026-09-12): 34 cases pass against the generated script, and the suite was
proved able to fail by running it against a reconstructed pre-fix gate.

`--tools Bash` and `--settings <gate>` must always be passed together. If
`gate.log` stops gaining lines for real commands, the gate is not in the
execution path and `--restricted` goes back in until it is.

**3. Run the suites before committing matcher or gate changes.** A pre-commit
hook does this for you, symlinked from `brow-agent/tests/pre-commit`. If you
cloned fresh, install it:

```bash
ln -sf ~/Documents/projects/brow-agent/tests/pre-commit .git/hooks/pre-commit
```

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
