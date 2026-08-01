import Foundation
import ZipPorterCore

/// Parsed option sets for the three subcommands. Parsing is pure (testable);
/// the run* functions do I/O and exit codes.
struct PackArguments: Equatable {
    var inputs: [String] = []
    var output: String?
    var askPassword = false
    var cp932 = false
    var zipCrypto = false
    var noClean = false
}

struct UnpackArguments: Equatable {
    var input: String = ""
    var output: String?
    var askPassword = false
    var encoding: String = "auto"
}

struct InspectArguments: Equatable {
    var input: String = ""
}

struct CLIParseError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum CLIParse {
    static func pack(_ args: [String]) -> Result<PackArguments, CLIParseError> {
        var parsed = PackArguments()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-o", "--output":
                guard i + 1 < args.count else { return .failure(CLIParseError("\(a) requires a value")) }
                parsed.output = args[i + 1]
                i += 1
            case "--password": parsed.askPassword = true
            case "--cp932": parsed.cp932 = true
            case "--zipcrypto": parsed.zipCrypto = true
            case "--no-clean": parsed.noClean = true
            default:
                if a.hasPrefix("-") { return .failure(CLIParseError("unknown option '\(a)'")) }
                parsed.inputs.append(a)
            }
            i += 1
        }
        guard !parsed.inputs.isEmpty else { return .failure(CLIParseError("pack requires at least one input")) }
        if parsed.inputs.count > 1 && parsed.output == nil {
            return .failure(CLIParseError("multiple inputs require -o <output.zip>"))
        }
        if parsed.zipCrypto && !parsed.askPassword {
            return .failure(CLIParseError("--zipcrypto requires --password"))
        }
        return .success(parsed)
    }

    static func unpack(_ args: [String]) -> Result<UnpackArguments, CLIParseError> {
        var parsed = UnpackArguments()
        var inputs: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-o", "--output":
                guard i + 1 < args.count else { return .failure(CLIParseError("\(a) requires a value")) }
                parsed.output = args[i + 1]
                i += 1
            case "--password": parsed.askPassword = true
            case "--encoding":
                guard i + 1 < args.count else { return .failure(CLIParseError("--encoding requires a value")) }
                let value = args[i + 1]
                guard ["auto", "utf8", "cp932"].contains(value) else {
                    return .failure(CLIParseError("--encoding must be auto, utf8, or cp932"))
                }
                parsed.encoding = value
                i += 1
            default:
                if a.hasPrefix("-") { return .failure(CLIParseError("unknown option '\(a)'")) }
                inputs.append(a)
            }
            i += 1
        }
        guard inputs.count == 1 else { return .failure(CLIParseError("unpack requires exactly one input ZIP")) }
        parsed.input = inputs[0]
        return .success(parsed)
    }

    static func inspect(_ args: [String]) -> Result<InspectArguments, CLIParseError> {
        let inputs = args.filter { !$0.hasPrefix("-") }
        if let flag = args.first(where: { $0.hasPrefix("-") }) {
            return .failure(CLIParseError("unknown option '\(flag)'"))
        }
        guard inputs.count == 1 else { return .failure(CLIParseError("inspect requires exactly one input ZIP")) }
        return .success(InspectArguments(input: inputs[0]))
    }
}

enum CLIRun {
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("zip-porter: \(message)\n".utf8))
        exit(code)
    }

    static func usageError(_ message: String) -> Never {
        FileHandle.standardError.write(Data("zip-porter: \(message)\n\n\(CLI.usage)\n".utf8))
        exit(64)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("zip-porter: warning: \(message)\n".utf8))
    }

    // MARK: - pack

    static func pack(_ rawArgs: [String]) -> Never {
        let parsed: PackArguments
        switch CLIParse.pack(rawArgs) {
        case .failure(let error): usageError(error.message)
        case .success(let p): parsed = p
        }

        var options = Packer.Options()
        options.nameEncoding = parsed.cp932 ? .cp932 : .utf8
        options.clean = !parsed.noClean
        if parsed.askPassword {
            guard let password = PasswordPrompt.readNew() else {
                fail("passwords did not match (or no terminal available)")
            }
            if parsed.zipCrypto {
                warn("ZipCrypto is weak encryption; use it only when the recipient can extract with Windows Explorer alone")
                options.encryption = .zipCrypto(password: password)
            } else {
                options.encryption = .aes256(password: password)
            }
        }

        let inputs = parsed.inputs.map { URL(fileURLWithPath: $0) }
        let output: URL
        if let o = parsed.output {
            output = URL(fileURLWithPath: o)
        } else {
            let single = inputs[0]
            output = single.deletingLastPathComponent()
                .appendingPathComponent(single.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("zip")
        }

        do {
            let result = try Packer.pack(inputs: inputs, output: output, options: options)
            for junk in result.skippedJunk { warn("excluded junk: \(junk)") }
            for link in result.skippedSymlinks { warn("skipped symlink: \(link)") }
            print("\(result.outputURL.path): \(result.fileCount) files, \(result.directoryCount) directories")
            exit(0)
        } catch let error as Packer.Failure {
            switch error {
            case .inputNotFound(let path): fail("input not found: \(path)")
            case .nothingToPack: fail("nothing to pack (all inputs were excluded)")
            }
        } catch let error as ZipWriterError {
            switch error {
            case .nameNotEncodable(let name):
                fail("'\(name)' cannot be encoded as CP932; rename it or drop --cp932")
            case .duplicateName(let name):
                fail("duplicate entry name: \(name)")
            case .randomFailure, .ioError:
                fail("write failed: \(error)")
            }
        } catch {
            fail("\(error.localizedDescription)")
        }
    }

    // MARK: - unpack

    static func unpack(_ rawArgs: [String]) -> Never {
        let parsed: UnpackArguments
        switch CLIParse.unpack(rawArgs) {
        case .failure(let error): usageError(error.message)
        case .success(let p): parsed = p
        }

        var options = Unpacker.Options()
        if let o = parsed.output {
            options.destination = URL(fileURLWithPath: o)
        }
        switch parsed.encoding {
        case "utf8": options.forcedEncoding = .utf8
        case "cp932": options.forcedEncoding = .cp932
        default: break
        }
        if parsed.askPassword {
            guard let password = PasswordPrompt.read("Password: ") else {
                fail("no terminal available for password entry")
            }
            options.password = password
        }

        let zipURL = URL(fileURLWithPath: parsed.input)
        do {
            let result = try runUnpack(zipURL: zipURL, options: options)
            for name in result.skippedUnsafe { warn("skipped unsafe path: \(name)") }
            for name in result.skippedSymlinks { warn("skipped symlink: \(name)") }
            print("\(result.root.path): \(result.extractedFiles) files (names: \(result.detectedEncoding.rawValue))")
            exit(0)
        } catch let error as ZipReaderError {
            switch error {
            case .passwordRequired: fail("archive is encrypted — re-run with --password")
            case .wrongPassword: fail("wrong password")
            case .authenticationFailed(let name): fail("authentication failed for '\(name)' (wrong password or corrupted data)")
            case .crcMismatch(let name): fail("CRC mismatch for '\(name)' (corrupted archive)")
            case .notAZipFile: fail("'\(parsed.input)' is not a ZIP archive")
            case .unsupportedMethod(let m): fail("unsupported compression method \(m)")
            case .unsupportedFeature(let f): fail("unsupported feature: \(f)")
            case .corrupt(let detail): fail("corrupted archive (\(detail))")
            }
        } catch let error as Unpacker.Failure {
            switch error {
            case .emptyArchive: fail("archive contains no extractable entries")
            case .destinationNotADirectory(let path): fail("destination is not a directory: \(path)")
            }
        } catch {
            fail("\(error.localizedDescription)")
        }
    }

    /// Prompt-on-demand: when the archive turns out to be encrypted and no
    /// --password was given, ask interactively once and retry.
    private static func runUnpack(zipURL: URL, options: Unpacker.Options) throws -> Unpacker.Result {
        do {
            return try Unpacker.unpack(zipURL: zipURL, options: options)
        } catch let error as ZipReaderError where error == .passwordRequired && options.password == nil {
            guard let password = PasswordPrompt.read("Password: ") else { throw error }
            var retry = options
            retry.password = password
            return try Unpacker.unpack(zipURL: zipURL, options: retry)
        }
    }

    // MARK: - inspect

    static func inspect(_ rawArgs: [String]) -> Never {
        let parsed: InspectArguments
        switch CLIParse.inspect(rawArgs) {
        case .failure(let error): usageError(error.message)
        case .success(let p): parsed = p
        }

        do {
            let reader = try ZipReader(url: URL(fileURLWithPath: parsed.input))
            let junkFilter = JunkFilter()
            var junk: [String] = []
            var utf8Flagged = 0
            var encrypted: Set<String> = []
            print("entries: \(reader.entries.count)")
            print("name encoding (unflagged entries): \(reader.detectedEncoding.rawValue)")
            print("")
            for entry in reader.entries {
                let name = reader.name(of: entry)
                if entry.flags.contains(.utf8Name) { utf8Flagged += 1 }
                if junkFilter.isJunk(name) { junk.append(name) }
                let method: String
                switch entry.method {
                case .store: method = "store"
                case .deflate: method = "deflate"
                case .aes: method = "aes"
                case .other(let m): method = "method#\(m)"
                }
                let enc: String
                switch entry.encryption {
                case .none: enc = "-"
                case .zipCrypto:
                    enc = "zipcrypto"
                    encrypted.insert("zipcrypto")
                case .aes(let strength, let vendor, _):
                    enc = "aes\(strength.keyBytes * 8)/ae-\(vendor)"
                    encrypted.insert("aes")
                }
                let flag = entry.flags.contains(.utf8Name) ? "utf8" : "-"
                print("\(String(format: "%10d", entry.uncompressedSize))  \(method)\t\(enc)\t\(flag)\t\(name)")
            }
            print("")
            print("utf8-flagged names: \(utf8Flagged)/\(reader.entries.count)")
            print("encryption: \(encrypted.isEmpty ? "none" : encrypted.sorted().joined(separator: ", "))")
            if !junk.isEmpty {
                print("junk entries (macOS metadata): \(junk.count)")
                for j in junk { print("  \(j)") }
            }
            exit(0)
        } catch let error as ZipReaderError {
            if case .notAZipFile = error { fail("'\(parsed.input)' is not a ZIP archive") }
            fail("cannot read archive: \(error)")
        } catch {
            fail("\(error.localizedDescription)")
        }
    }
}
