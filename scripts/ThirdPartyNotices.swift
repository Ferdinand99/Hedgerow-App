#!/usr/bin/env swift
// Makes Hedgerow/ThirdPartyNotices.txt: the licence texts of the Swift packages that the app is
// built with, read from Package.resolved and from the checkouts that `swift package resolve` makes.
// The app shows this file in its settings (the screen reads it from the app bundle).
//
// Usage:
//   swift scripts/ThirdPartyNotices.swift [--check] [--resolved <Package.resolved>]
//       [--checkouts <folder>] [--manifest <Package.swift>] [--project <project.yml>]
//       [--output <file>]
//
// Defaults: HedgerowCore/Package.resolved, HedgerowCore/.build/checkouts, HedgerowCore/Package.swift,
// project.yml and Hedgerow/ThirdPartyNotices.txt. Run `swift package resolve` in HedgerowCore first.
// --check does not write: it fails when the file on disk differs from what would be written.
//
// It fails (exit code 1) when
//   - a package has no licence file,
//   - the licence of a package is not recognised, or is not on the allowlist below,
//   - a licence text is only a template without a copyright notice,
//   - Package.resolved is missing while the manifest lists a package from a URL,
//   - project.yml lists a package from a URL (Package.resolved of HedgerowCore would not cover it:
//     add the package to HedgerowCore, or extend this script).
//
// Every dependency of the app comes in through HedgerowCore/Package.swift today. The app itself
// is under the AGPL-3.0; the allowlist is for the packages it links.

import Foundation

/// The licences that may be linked into the app. The detection below recognises only these.
let allowed = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib"]

struct Failure: Error, CustomStringConvertible {
    let description: String
}

struct Pin {
    let identity: String
    let location: String
    let version: String
}

/// The SPDX id of a licence text, or nil when it is none of the known ones.
func detectLicense(_ raw: String) -> String? {
    let text = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    if text.contains("apache license") && text.contains("version 2.0") { return "Apache-2.0" }
    if text.contains("permission is hereby granted, free of charge, to any person obtaining a copy")
        && text.contains("the above copyright notice and this permission notice shall be included") {
        return "MIT"
    }
    if text.contains("redistribution and use in source and binary forms") {
        if text.contains("neither the name") || text.contains("the names of its contributors") { return "BSD-3-Clause" }
        return "BSD-2-Clause"
    }
    if text.contains("permission to use, copy, modify, and/or distribute this software for any purpose with or without fee") { return "ISC" }
    if text.contains("altered source versions must be plainly marked") { return "Zlib" }
    return nil
}

/// A placeholder that was never filled in. A notice has to name the copyright holder.
func hasPlaceholder(_ text: String) -> Bool {
    let pattern = "[<\\[{](year|fullname|owner|copyright holders?|name of author|organi[sz]ation)[>\\]}]"
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

func parsePins(_ data: Data) throws -> [Pin] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Failure(description: "Package.resolved is not a JSON object.")
    }
    // Versions 2 and 3 have a top-level "pins"; version 1 has "object" -> "pins".
    var list = root["pins"] as? [[String: Any]]
    if list == nil, let object = root["object"] as? [String: Any] { list = object["pins"] as? [[String: Any]] }
    guard let pins = list else { throw Failure(description: "Package.resolved has no pins.") }
    return try pins.map { pin in
        let identity = (pin["identity"] as? String) ?? (pin["package"] as? String)?.lowercased() ?? ""
        let location = (pin["location"] as? String) ?? (pin["repositoryURL"] as? String) ?? ""
        let state = pin["state"] as? [String: Any] ?? [:]
        let version = (state["version"] as? String) ?? (state["branch"] as? String) ?? String((state["revision"] as? String ?? "").prefix(12))
        if identity.isEmpty { throw Failure(description: "A pin in Package.resolved has no identity.") }
        return Pin(identity: identity, location: location, version: version)
    }.sorted { $0.identity < $1.identity }
}

func licenseFiles(in folder: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let pattern = "^(licen[cs]e|copying|notice)([-._].*)?$"
    return names.filter { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        .sorted()
        .map { folder.appendingPathComponent($0) }
}

func clean(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The whole file for the given pins. Same input, same text: no dates, no paths.
func render(pins: [Pin], checkouts: URL) throws -> String {
    var problems: [String] = []
    var sections: [String] = []
    let rule = String(repeating: "=", count: 78)
    for pin in pins {
        let folder = checkouts.appendingPathComponent(pin.identity)
        let files = licenseFiles(in: folder)
        if files.isEmpty {
            problems.append("\(pin.identity) \(pin.version): no licence file in \(folder.path) (run `swift package resolve`).")
            continue
        }
        var texts: [String] = []
        var licenceSeen = false
        for file in files {
            let text = clean((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            let name = file.lastPathComponent
            if name.lowercased().hasPrefix("notice") {
                texts.append(text)  // A NOTICE file (Apache) is copied as it is.
                continue
            }
            guard let id = detectLicense(text) else {
                problems.append("\(pin.identity) \(pin.version): the licence in \(name) is not one of \(allowed.joined(separator: ", ")).")
                continue
            }
            if !allowed.contains(id) {
                problems.append("\(pin.identity) \(pin.version): \(id) is not on the allowlist.")
                continue
            }
            if hasPlaceholder(text) {
                problems.append("\(pin.identity) \(pin.version): \(name) is a licence template without a copyright notice.")
                continue
            }
            licenceSeen = true
            texts.append(text)
        }
        if !licenceSeen && problems.isEmpty {
            problems.append("\(pin.identity) \(pin.version): only a NOTICE file, no licence text.")
        }
        let heading = "\(pin.identity) \(pin.version)" + (pin.location.isEmpty ? "" : " (\(pin.location))")
        sections.append(([rule, heading, rule, ""] + texts.flatMap { [$0, ""] }).joined(separator: "\n"))
    }
    if !problems.isEmpty { throw Failure(description: problems.joined(separator: "\n")) }

    var head = [
        "THIRD-PARTY NOTICES",
        "",
        "Hedgerow is free software under the GNU Affero General Public License, version 3.",
        "It is built with the Swift packages listed below. Each section gives the name of the",
        "package, where it comes from and its licence text.",
        "",
        "This file is made by scripts/ThirdPartyNotices.swift from Package.resolved. Do not edit it.",
        "",
    ]
    if pins.isEmpty {
        head.append("The app uses no third-party Swift packages at the moment.")
        head.append("")
    }
    return (head + sections).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
}

/// The files that pull a package from a URL: the manifest (`.package(url:`) or project.yml
/// (a `url:` key below `packages:`).
func remotePackages(manifest: URL?, projectYml: URL?) -> [String] {
    var found: [String] = []
    if let manifest, let text = try? String(contentsOf: manifest, encoding: .utf8),
       text.range(of: "\\.package\\s*\\(\\s*(url|name)\\s*:", options: .regularExpression) != nil {
        found.append(manifest.path)
    }
    if let projectYml, let text = try? String(contentsOf: projectYml, encoding: .utf8) {
        let afterPackages = text.components(separatedBy: "\npackages:").dropFirst().first ?? ""
        let block = afterPackages.components(separatedBy: "\ntargets:").first ?? ""
        if block.range(of: "(^|\\n)\\s+url\\s*:", options: .regularExpression) != nil {
            found.append(projectYml.path)
        }
    }
    return found
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var check = false
    var resolved = "HedgerowCore/Package.resolved"
    var checkouts = "HedgerowCore/.build/checkouts"
    var manifest = "HedgerowCore/Package.swift"
    var output = "Hedgerow/ThirdPartyNotices.txt"
    var projectYml = "project.yml"
    func value(_ flag: String) throws -> String {
        guard !arguments.isEmpty else { throw Failure(description: "\(flag) needs a value.") }
        return arguments.removeFirst()
    }
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        switch flag {
        case "--check": check = true
        case "--resolved": resolved = try value(flag)
        case "--checkouts": checkouts = try value(flag)
        case "--manifest": manifest = try value(flag)
        case "--project": projectYml = try value(flag)
        case "--output": output = try value(flag)
        default: throw Failure(description: "Unknown argument \(flag).")
        }
    }
    let projectURL = URL(fileURLWithPath: projectYml)
    let inProject = remotePackages(manifest: nil, projectYml: projectURL)
    if !inProject.isEmpty {
        throw Failure(description: "\(projectYml) lists a package from a URL. \(resolved) does not cover it: add the package to HedgerowCore/Package.swift, or extend this script.")
    }
    let pins: [Pin]
    if FileManager.default.fileExists(atPath: resolved) {
        pins = try parsePins(try Data(contentsOf: URL(fileURLWithPath: resolved)))
    } else {
        let remote = remotePackages(manifest: URL(fileURLWithPath: manifest), projectYml: nil)
        if !remote.isEmpty {
            throw Failure(description: "\(resolved) is missing, but \(remote.joined(separator: ", ")) lists a package from a URL. Run `swift package resolve` in HedgerowCore.")
        }
        pins = []
    }
    let text = try render(pins: pins, checkouts: URL(fileURLWithPath: checkouts))
    if check {
        let current = (try? String(contentsOfFile: output, encoding: .utf8))?.replacingOccurrences(of: "\r\n", with: "\n") ?? ""
        if current != text {
            throw Failure(description: "\(output) is out of date. Run `swift scripts/ThirdPartyNotices.swift` and commit the result.")
        }
        print("\(output) is up to date (\(pins.count) packages).")
    } else {
        try text.write(toFile: output, atomically: true, encoding: .utf8)
        print("Wrote \(output) (\(pins.count) packages).")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
