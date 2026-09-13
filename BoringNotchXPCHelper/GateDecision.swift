//
//  GateDecision.swift
//  BoringNotchXPCHelper
//
//  The decision that stands between a spoken sentence and a shell.
//
//  This is the whole of it: a pure function from a command string to a verdict,
//  with no I/O, no process spawning and no global state. It is written that way
//  so it can be tested directly. The logic used to live inside a bash script
//  emitted as a Swift string literal, where the only way to test it was to
//  regenerate the script, stub its confirm dialog, and shell out — and where
//  three of the four historical breaks were regex-semantics bugs that a real
//  language does not have.
//
//  THE ORDER IS THE SECURITY PROPERTY. Do not reorder:
//
//    1. reject anything that is not a single plain line
//    2. deny-list        — refused outright, never prompts
//    3. read-only pipeline — runs without prompting
//    4. everything else  — asks a person
//
//  Default-confirm is the point. Steps 2 and 3 are pattern matching, and
//  pattern matching on shell strings leaks; the prompt is the actual control.
//  A command that matches nothing is never assumed safe.
//
//  Read docs/04-SECURITY.md in brow-agent before changing anything here. It
//  records four breaks, each of which looked correct and passed a test written
//  for it.
//

import Foundation

enum GateDecision: Equatable {
    case allow(reason: String)
    case confirm(reason: String)
    case deny(reason: String)

    /// The value the CLI's hook protocol expects. `confirm` has no wire form —
    /// it is resolved by asking the user and becomes allow or deny.
    var wireValue: String {
        switch self {
        case .allow: return "allow"
        case .confirm: return "confirm"
        case .deny: return "deny"
        }
    }

    /// Short tag recorded in gate.log, so an auto-approved command and one a
    /// person clicked through are not indistinguishable afterwards.
    var tag: String {
        switch self {
        case .allow(let reason), .confirm(let reason), .deny(let reason):
            return reason
        }
    }
}

enum AgentGateDecider {

    // MARK: - Entry point

    /// Decides what to do with one model-generated shell command.
    static func decide(command: String) -> (decision: GateDecision, message: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)

        guard !cmd.isEmpty else {
            return (.deny(reason: "unparseable"), "Brow could not read the command.")
        }

        // ---- 1. one plain line only ----------------------------------------
        // Line-oriented matching on multi-line input is a bypass by
        // construction: "ls\nrm -rf ~" has nothing suspicious on either line
        // and starts with an allow-listed verb. Control characters go with it —
        // they are not something a spoken command ever needs.
        if cmd.unicodeScalars.contains(where: { isRejectedControl($0) }) {
            return (.deny(reason: "multiline"),
                    "Brow only runs single-line commands. Ask for one short command.")
        }

        // ---- 2. deny-list: never runs, never prompts ------------------------
        if let hit = denyListHit(cmd) {
            return (.deny(reason: "denylist"),
                    "Blocked by Brow: matches a forbidden pattern (\(hit)). Tell the user to run it themselves.")
        }

        // ---- 3. read-only pipeline: runs without prompting -------------------
        if isReadOnlyPipeline(cmd) {
            return (.allow(reason: "autoallow"), "Read-only command, auto-approved by Brow.")
        }

        // ---- 4. everything else: ask a person --------------------------------
        return (.confirm(reason: "confirm"), "Brow needs your approval to run this.")
    }

    // MARK: - 1. Shape

    private static func isRejectedControl(_ scalar: Unicode.Scalar) -> Bool {
        // Newline, carriage return, tab, and every other C0/C1 control.
        scalar.properties.generalCategory == .control
    }

    // MARK: - 2. Deny-list

    /// Substrings and shapes that are refused outright.
    ///
    /// These are plain Swift now. The bash version was a list of extended
    /// regexes, where `|` is alternation and `.` is any character — writing
    /// `curl.*|.*sh` for "curl piped to a shell" actually read as "curl
    /// anything" OR "anything containing sh", and silently denied `git push`,
    /// `cat ~/.zshrc`, and any command mentioning a Screenshot.
    /// Refused wherever they appear, because they name a thing rather than do
    /// one. A path is still a path in the middle of a word.
    private static let deniedSubstrings: [String] = [
        ".ssh", ".aws", ".gnupg", ".config/gh",
        "id_rsa", "id_ed25519", "credentials.json", "keychain",
    ]

    /// Refused only as whole words.
    ///
    /// Matched on word boundaries, NOT as substrings: "sudoku" contains "sudo"
    /// and `echo sudoku` is not privilege escalation. Over-blocking is not the
    /// safe direction to err — a denied command cannot be approved, so the
    /// agent simply fails, and break #3 was exactly this. A gate that refuses
    /// ordinary work is one the user turns off.
    private static let deniedCommandWords: [String] = [
        // Privilege escalation.
        "sudo", "doas",
        // Disk and firmware destruction.
        "mkfs", "csrutil", "nvram", "systemsetup",
        // Security and privacy subsystems.
        "spctl", "tccutil", "launchctl",
    ]

    private static let deniedPatterns: [(name: String, pattern: String)] = [
        ("su", #"(^|[^[:alnum:]])su[[:space:]]"#),
        ("rm -rf /", #"rm[[:space:]]+-[a-zA-Z]*[rRfd][a-zA-Z]*[[:space:]]+/([[:space:]]|$)"#),
        ("disk erase", #"diskutil[[:space:]]+erase"#),
        ("dd", #"dd[[:space:]]+(if|of)="#),
        ("fork bomb", #":[[:space:]]*\(\)[[:space:]]*\{"#),
        ("power", #"(^|[^[:alnum:]])(shutdown|reboot|halt)([[:space:]]|$)"#),
        ("security", #"(^|[^[:alnum:]])security[[:space:]]"#),
        ("dotenv", #"\.env([[:space:]]|$|/)"#),
        // Literal pipe into a shell. In Swift this says what it means.
        ("pipe to shell", #"(curl|wget)[^|]*\|[[:space:]]*(ba|z|k)?sh"#),
        ("force push", #"git[[:space:]]+push[[:space:]]+(--force|-f)([[:space:]]|$)"#),
        ("hard reset", #"git[[:space:]]+reset[[:space:]]+--hard"#),
        ("recursive chmod", #"(chmod|chown|chflags)[[:space:]]+-R"#),
        ("defaults write", #"defaults[[:space:]]+write"#),
        ("pmset -a", #"pmset[[:space:]]+-a"#),
        ("osascript shell", #"osascript.*do[[:space:]]+shell[[:space:]]+script"#),
    ]

    private static func denyListHit(_ cmd: String) -> String? {
        let lowered = cmd.lowercased()
        for fragment in deniedSubstrings where lowered.contains(fragment) {
            return fragment
        }
        for word in deniedCommandWords {
            // A shell word ends at anything that is not a name character, so
            // "ls; sudo x" and "x|sudo y" are both caught while "sudoku" is not.
            let pattern = "(^|[^a-z0-9_.-])\(NSRegularExpression.escapedPattern(for: word))($|[^a-z0-9_-])"
            if lowered.range(of: pattern, options: [.regularExpression]) != nil {
                return word
            }
        }
        // Match case-insensitively against the ORIGINAL, never against a
        // lowercased copy. Lowercasing first silently broke `chmod -R`: the
        // pattern's literal -R could not match a string that no longer
        // contained an uppercase R, so a recursive chmod fell through to a
        // prompt. Caught by the suite on its first run — which is the whole
        // argument for porting this out of bash.
        for entry in deniedPatterns {
            if cmd.range(of: entry.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return entry.name
            }
        }
        return nil
    }

    // MARK: - 3. Read-only pipeline

    /// Characters a read-only command is allowed to contain.
    ///
    /// A WHITELIST, deliberately. The bash version asked "does this contain a
    /// metacharacter?", which means every character nobody thought of was
    /// treated as safe — that is how a glob walked around the deny-list and
    /// read an OAuth token. Asking "is every character one I chose?" fails the
    /// other way, which is the right way.
    ///
    /// Note what is absent: quotes, `$`, backtick, `(`, `)`, `<`, `>`, `;`,
    /// `&`, `*`, `?`, `~`, `{`, `}`, `[`, `]`, `!`, `\`. Anything using them
    /// goes to a prompt. That includes redirections, substitutions and globs.
    private static let allowedCharacters: Set<Character> = {
        var set = Set<Character>()
        set.formUnion("abcdefghijklmnopqrstuvwxyz")
        set.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.formUnion("0123456789")
        set.formUnion(" -_./=:,%+@|&;\"'")
        return set
    }()

    /// Commands safe to run as the FIRST element of a pipeline.
    ///
    /// Deliberately absent: cat, head, tail, wc, file, stat as pipeline
    /// STARTERS -- they read arbitrary files, and the secrets on this machine
    /// are files, so an unprompted file read is the entire threat. They are
    /// permitted downstream of a pipe, where they read stdin instead. `open`
    /// is absent because `open -a Terminal script.sh` executes; `say` because
    /// `say -o file` writes; `lsof` because it enumerates the network.
    private static let allowedSources: Set<String> = [
        "ls", "pwd", "whoami", "hostname", "date", "uptime", "df", "du",
        "uname", "id", "groups", "ps", "pgrep", "echo", "printf", "which",
        "type", "sw_vers", "system_profiler", "vm_stat", "sysctl",
    ]

    /// Commands safe only DOWNSTREAM of a pipe, where their input is the
    /// previous command's output rather than a file they choose.
    ///
    /// `sed` and `awk` are deliberately absent even though they are the
    /// obvious filters. `sed -i notes.txt` edits a file in place, and awk's
    /// `system()` runs commands — neither needs a single character the
    /// whitelist rejects. A filter that can be programmed is not a filter.
    private static let allowedFilters: Set<String> = [
        "head", "tail", "wc", "sort", "uniq", "grep", "cut", "tr", "rev",
        "column", "nl", "tac",
    ]

    /// Filters that take one non-flag operand: the pattern to match.
    /// Everything else in `allowedFilters` must be given flags only.
    private static let filtersTakingAPattern: Set<String> = ["grep"]

    /// Flags that turn a specific filter into a file reader or writer.
    ///
    /// Per command, because the same letter means different things: `grep -f`
    /// reads patterns from a file, while `cut -f1` selects fields and `sort -f`
    /// folds case. A blanket list would refuse `cut -f1` — ordinary, harmless,
    /// and exactly the kind of over-block that teaches people to bypass a gate.
    private static let fileBearingFlags: [String: Set<String>] = [
        "grep": ["-f", "--file"],
        "sort": ["-o", "--output"],
    ]

    /// Subcommands that make an otherwise-unsafe tool read-only.
    private static let allowedSubcommands: [String: Set<String>] = [
        "git": ["status", "log", "diff", "branch", "show", "remote"],
        "defaults": ["read"],
        "pmset": ["-g"],
        "top": ["-l"],
    ]

    /// True when every stage only reads, and nothing in it can choose a file to
    /// read or a place to write.
    ///
    /// `|`, `&&`, `||` and `;` all mean "another command follows", and the
    /// safety argument is the same for each: if every command in the sequence
    /// is independently read-only, the sequence is read-only. `ls && rm -rf ~`
    /// is refused because `rm` is not on any list, not because `&&` is scary.
    ///
    /// The separator still matters for one thing. After a `|` the next command
    /// is fed the previous one's output, so a filter belongs there; after the
    /// others it starts fresh and must be a source in its own right.
    ///
    /// Chaining was added after watching the agent answer a two-part question
    /// with `df -h / && ps -e | wc -l` — entirely read-only, and it sat on a
    /// dialog for forty seconds before timing out.
    private static func isReadOnlyPipeline(_ cmd: String) -> Bool {
        guard cmd.allSatisfy({ allowedCharacters.contains($0) }) else { return false }

        // A single `&` backgrounds a job; only the doubled form is a separator.
        // Checked by removing every `&&` and seeing if an `&` survives.
        guard !cmd.replacingOccurrences(of: "&&", with: "").contains("&") else { return false }

        guard let stages = splitIntoStages(cmd) else { return false }
        for stage in stages {
            guard isReadOnlyStage(stage.command, isSource: stage.isSource) else { return false }
        }
        return true
    }

    private struct Stage {
        let command: String
        /// False only when the previous separator was a pipe, which means this
        /// command reads the previous one's output rather than choosing input.
        let isSource: Bool
    }

    /// Splits on the four separators, remembering which one preceded each
    /// stage. Returns nil if any stage is empty — a dangling `|` or `&&` is
    /// malformed, and malformed goes to a person.
    private static func splitIntoStages(_ cmd: String) -> [Stage]? {
        var stages: [Stage] = []
        var current = ""
        var isSource = true
        var index = cmd.startIndex
        // Quoted text is inert: `$`, backtick and `\` are not in the character
        // whitelist, so a quoted string cannot substitute or escape anything.
        // It is ordinary text, and a separator inside it is a literal
        // semicolon rather than a new command -- `echo "a; b"` prints one
        // string. Tracking this is what lets `echo "---"` auto-allow, which the
        // agent writes constantly and which used to cost a click every time.
        var quote: Character?

        func close(nextIsSource: Bool) -> Bool {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            stages.append(Stage(command: trimmed, isSource: isSource))
            current = ""
            isSource = nextIsSource
            return true
        }

        while index < cmd.endIndex {
            let character = cmd[index]
            let next = cmd.index(after: index)
            let following = next < cmd.endIndex ? cmd[next] : nil

            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                index = next
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                index = next
                continue
            }

            if character == "|" && following == "|" {
                guard close(nextIsSource: true) else { return nil }
                index = cmd.index(index, offsetBy: 2)
            } else if character == "&" && following == "&" {
                guard close(nextIsSource: true) else { return nil }
                index = cmd.index(index, offsetBy: 2)
            } else if character == "|" {
                guard close(nextIsSource: false) else { return nil }
                index = next
            } else if character == ";" {
                guard close(nextIsSource: true) else { return nil }
                index = next
            } else {
                current.append(character)
                index = next
            }
        }

        // An unterminated quote means the command is not what it appears to be.
        // Malformed goes to a person.
        guard quote == nil else { return nil }
        guard close(nextIsSource: true) else { return nil }
        return stages.isEmpty ? nil : stages
    }

    /// Splits a stage into words, keeping quoted text together and stripping
    /// the quotes. `grep "foo bar"` is one pattern, not two — counting it as
    /// two would blow the operand budget and send it to a prompt.
    private static func tokenize(_ stage: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var sawQuote = false

        for character in stage {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                sawQuote = true
            } else if character == " " {
                if !current.isEmpty || sawQuote { tokens.append(current); current = ""; sawQuote = false }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty || sawQuote { tokens.append(current) }
        return tokens
    }

    private static func isReadOnlyStage(_ stage: String, isSource: Bool) -> Bool {
        let tokens = tokenize(stage)
        guard let verb = tokens.first, !verb.isEmpty else { return false }
        let operands = Array(tokens.dropFirst())

        if let required = allowedSubcommands[verb] {
            guard let sub = operands.first, required.contains(sub) else { return false }
            // `git log --oneline` is fine; `git show ../../etc/passwd` is a
            // file read wearing a subcommand.
            return operands.dropFirst().allSatisfy { !looksLikePath($0) }
        }

        if isSource {
            guard allowedSources.contains(verb) else { return false }
            // ls and du legitimately take a directory. They list names rather
            // than reveal contents, and the deny-list already refuses the
            // credential directories by name.
            return true
        }

        guard allowedFilters.contains(verb) else { return false }

        // A flag that names a file turns a filter into a reader or a writer,
        // with no path-shaped operand for the check below to catch.
        if let dangerous = fileBearingFlags[verb],
           operands.contains(where: { dangerous.contains($0) }) {
            return false
        }

        // Count what is not a flag. `uniq out.txt` writes to out.txt, and
        // `grep x /etc/passwd` prints the file rather than the pipe — so a
        // filter gets flags only, plus exactly one pattern where a pattern is
        // what it takes. Operand budgets are checked before shape, because
        // "out.txt" is not path-shaped and would otherwise sail through.
        // Only operands that could name a file count against the budget.
        // `head -n 3` and `cut -d : -f 1` put the flag's VALUE in its own
        // token, and those values are not filenames — counting them would send
        // ordinary read-only work to a prompt, which is the failure mode this
        // whole port is meant to reduce.
        let bare = operands.filter { !$0.hasPrefix("-") && couldNameAFile($0) }
        let budget = filtersTakingAPattern.contains(verb) ? 1 : 0
        guard bare.count <= budget else { return false }

        return bare.allSatisfy { !looksLikePath($0) }
    }

    /// A token that might be a filename rather than a flag's value.
    /// Numbers and bare punctuation are values; anything with a letter, a dot
    /// or a slash might be a file.
    private static func couldNameAFile(_ token: String) -> Bool {
        token.contains(where: { $0.isLetter }) || token.contains(".") || token.contains("/")
    }

    /// Conservative: anything that could name a file on disk.
    private static func looksLikePath(_ token: String) -> Bool {
        if token.hasPrefix("-") { return false }   // a flag, e.g. -n 5
        return token.contains("/") || token.hasPrefix(".")
    }
}
