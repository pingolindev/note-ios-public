// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Note.
//
// Pingolin Note is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Note is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Note. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import UIKit
import MachO

/// Detects whether the device shows signs of having been jailbroken.
/// iOS analog of android's RootDetector — same defense-in-depth
/// rationale: every check here is bypassable by hooks (Liberty/HideJB
/// can suppress file-existence reads, for example), but together they
/// raise the bar for casual attackers and protect against off-the-shelf
/// malware that doesn't bother with anti-anti-jailbreak.
///
/// Like android, the detector is *informational*: the result is
/// surfaced in Settings as a "Device integrity" row. A caller can make
/// it a hard block on login/sync without touching this file.
enum JailbreakDetector {
    struct Result {
        let isJailbroken: Bool
        let reasons: [String]
    }

    static func check() -> Result {
        var reasons: [String] = []

        // Simulator is trivially "compromised" in the sense that it
        // bypasses code-signing, but reporting that as a real
        // jailbreak would be noise for every developer. Skip cleanly.
        #if targetEnvironment(simulator)
        return Result(isJailbroken: false, reasons: [])
        #else

        if hasJailbreakFiles() { reasons.append("Jailbreak files present") }
        if hasJailbreakURLSchemes() { reasons.append("Jailbreak URL scheme registered") }
        if canWriteOutsideSandbox() { reasons.append("System paths writable") }
        if canForkProcess() { reasons.append("fork() succeeds (sandboxed apps cannot)") }
        if hasSuspiciousDyldImages() { reasons.append("Suspicious dyld image loaded") }
        if hasOpenSSHPort() { reasons.append("OpenSSH port open") }

        return Result(isJailbroken: !reasons.isEmpty, reasons: reasons)
        #endif
    }

    /// Convenience: just the bool, for callers that don't need the
    /// reason list.
    static var isJailbroken: Bool { check().isJailbroken }

    // MARK: - Individual checks

    private static func hasJailbreakFiles() -> Bool {
        let paths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Applications/blackra1n.app",
            "/Applications/FakeCarrier.app",
            "/Applications/Icy.app",
            "/Applications/IntelliScreen.app",
            "/Applications/MxTube.app",
            "/Applications/RockApp.app",
            "/Applications/SBSettings.app",
            "/Applications/WinterBoard.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/Veency.plist",
            "/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/mobile/Library/SBSettings/Themes",
            "/private/var/stash",
            "/private/var/tmp/cydia.log",
            "/usr/bin/sshd",
            "/usr/libexec/sftp-server",
            "/usr/sbin/sshd",
            "/var/cache/apt",
            "/var/lib/apt",
            "/var/lib/cydia",
            "/var/log/syslog",
            "/var/tmp/cydia.log",
            "/bin/bash",
            "/etc/apt",
            "/etc/ssh/sshd_config",
        ]
        return paths.contains(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func hasJailbreakURLSchemes() -> Bool {
        let schemes = ["cydia://", "sileo://", "zbra://", "filza://", "undecimus://"]
        for s in schemes {
            if let url = URL(string: s), UIApplication.shared.canOpenURL(url) {
                return true
            }
        }
        return false
    }

    private static func canWriteOutsideSandbox() -> Bool {
        let path = "/private/jailbreak_check_\(UUID().uuidString).txt"
        do {
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// fork() is unavailable to App Store-distributed apps; a successful
    /// fork is therefore a strong jailbreak signal. We resolve it via
    /// dlsym so the symbol isn't pulled in statically (Apple's static
    /// analyzer would flag it).
    private static func canForkProcess() -> Bool {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "fork") else { return false }
        typealias ForkFn = @convention(c) () -> pid_t
        let forkFn = unsafeBitCast(sym, to: ForkFn.self)
        let pid = forkFn()
        if pid >= 0 {
            // Reap the child immediately to avoid a zombie.
            if pid > 0 { _ = kill(pid, SIGKILL) }
            return true
        }
        return false
    }

    /// Walks the loaded dyld image list for anything that looks like
    /// a known hooking framework.
    private static func hasSuspiciousDyldImages() -> Bool {
        let suspicious = [
            "MobileSubstrate",
            "MobileLoader",
            "SubstrateLoader",
            "TweakInject",
            "FridaGadget",
            "frida",
            "cynject",
            "libcycript",
        ]
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName)
            if suspicious.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return true
            }
        }
        return false
    }

    /// Default OpenSSH port being open is one of the canonical
    /// "I've enabled SSH on my jailbroken phone" signals.
    private static func hasOpenSSHPort() -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(22).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Non-blocking + short timeout so we don't add latency at app
        // launch.
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000) // 200ms
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
