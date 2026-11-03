import Foundation

/// Turns Tunnelblick configurations into self-contained `.ovpn` text.
/// Shared configurations are root-only (`0700 root:wheel`), so the app reads them through one
/// administrator-authorized shell command whose output `parseDump` splits back into files.
public enum TunnelblickImport {
    public struct Source: Sendable, Hashable, Identifiable {
        public let name: String
        /// The `.tblk` folder (its `Contents/Resources`) or a bare `.ovpn`/`.conf` file.
        public let path: String
        /// Shared configurations need administrator rights to read.
        public let needsAdmin: Bool
        public var id: String { path }
    }

    public static let marker = "@@@BURROW-FILE "

    public static func sources(home: String = NSHomeDirectory()) -> [Source] {
        var sources: [Source] = []
        let shared = "/Library/Application Support/Tunnelblick/Shared"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: shared)) ?? [] where name.hasSuffix(".tblk") {
            sources.append(Source(name: String(name.dropLast(5)), path: "\(shared)/\(name)/Contents/Resources", needsAdmin: true))
        }
        let personal = "\(home)/Library/Application Support/Tunnelblick/Configurations"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: personal)) ?? [] {
            if name.hasSuffix(".tblk") {
                sources.append(Source(name: String(name.dropLast(5)), path: "\(personal)/\(name)/Contents/Resources", needsAdmin: false))
            } else if name.hasSuffix(".ovpn") || name.hasSuffix(".conf") {
                sources.append(Source(name: (name as NSString).deletingPathExtension, path: "\(personal)/\(name)", needsAdmin: false))
            }
        }
        return sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Shell command that prints every file of a `.tblk` Resources folder, each after a marker line.
    public static func dumpCommand(for folder: String) -> String {
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && for f in *; do [ -f \"$f\" ] || continue; echo \"\(marker)$f\"; cat \"$f\"; echo; done"
    }

    public static func parseDump(_ text: String) -> [String: String] {
        var files: [String: String] = [:]
        var current: String?
        var lines: [Substring] = []
        func flush() {
            guard let current else { return }
            var body = lines
            if body.last?.isEmpty == true { body.removeLast() } // the `echo` after each file
            files[current] = body.joined(separator: "\n") + "\n"
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(marker) {
                flush()
                current = String(line.dropFirst(marker.count))
                lines = []
            } else {
                lines.append(line)
            }
        }
        flush()
        return files
    }

    /// Chooses the config file in a `.tblk` (config.ovpn, else the first .ovpn/.conf) and inlines the files it names.
    public static func configuration(fromFiles files: [String: String]) -> String? {
        let name = files.keys.first { $0 == "config.ovpn" }
            ?? files.keys.sorted().first { $0.hasSuffix(".ovpn") || $0.hasSuffix(".conf") }
        guard let name, let text = files[name] else { return nil }
        return inline(text, files: files)
    }

    /// Replaces `ca file`, `cert file`, `key file`, `tls-auth file [dir]`, `tls-crypt file`, `tls-crypt-v2 file`
    /// and `extra-certs file` with inline blocks when the file is available.
    public static func inline(_ config: String, files: [String: String]) -> String {
        let inlinable: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs"]
        var output: [String] = []
        var inBlock: String?
        for raw in config.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let block = inBlock {
                output.append(raw)
                if line == "</\(block)>" { inBlock = nil }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                inBlock = String(line.dropFirst().dropLast())
                output.append(raw)
                continue
            }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let keyword = words.first, inlinable.contains(keyword), words.count >= 2,
               let body = files[Self.unquote(words[1])] ?? files[(Self.unquote(words[1]) as NSString).lastPathComponent] {
                output.append("<\(keyword)>")
                output.append(body.trimmingCharacters(in: .newlines))
                output.append("</\(keyword)>")
                if keyword == "tls-auth", words.count >= 3 { output.append("key-direction \(words[2])") }
            } else {
                output.append(raw)
            }
        }
        return output.joined(separator: "\n")
    }

    /// Inlines the files a plain `.ovpn` names from the folder it was imported from (the tunnel can't read them).
    public static func inline(_ config: String, from directory: URL) -> String {
        var files: [String: String] = [:]
        for name in OVPNSummary(config).missingFiles {
            let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : directory.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap {
                $0.isRegularFile == true ? $0.fileSize : nil
            }
            // Certificates and keys are a few KB; don't swallow anything else by mistake.
            guard let size, size < 256 * 1024, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files[name] = text
        }
        return files.isEmpty ? config : inline(config, files: files)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return text }
        return String(text.dropFirst().dropLast())
    }
}
