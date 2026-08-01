import Foundation

/// Parsed CLI invocation. The GUI executable doubles as the CLI: argv is
/// routed here before any AppKit machinery starts (single-binary pattern).
enum CLICommand: Equatable {
    case version
    case pack(args: [String])
    case unpack(args: [String])
    case inspect(args: [String])
    case gui
    case unknown(String)
}

enum CLI {
    static let usage = """
    usage: zip-porter <command> [options]

    commands:
      pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
      unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
      inspect <input.zip>

    Run with no command to launch the GUI.
    """

    /// Route argv. Unrecognized flag-style arguments (e.g. the `-psn_…` and
    /// `-NS…` arguments macOS injects at launch) fall through to the GUI;
    /// only an unrecognized bare word is an error.
    static func parse(_ arguments: [String]) -> CLICommand {
        guard arguments.count > 1 else { return .gui }
        let first = arguments[1]
        let rest = Array(arguments.dropFirst(2))
        switch first {
        case "--version": return .version
        case "pack": return .pack(args: rest)
        case "unpack": return .unpack(args: rest)
        case "inspect": return .inspect(args: rest)
        default: return first.hasPrefix("-") ? .gui : .unknown(first)
        }
    }
}
