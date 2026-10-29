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

/// The tmp/ directory decrypted attachment plaintext was staged in for
/// QuickLook, and its sign-out sweep. This app stages no file there any more;
/// the sweep stays so plaintext an earlier version left behind does not
/// outlive the session.
enum AttachmentService {
    /// Dedicated tmp/ subdirectory for decrypted attachment plaintext staged
    /// for QuickLook. Kept SEPARATE from the shared temporary-directory root so
    /// the logout sweep (`clearScratch`) deletes ONLY our scratch files and
    /// never a framework's in-flight temp file.
    static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// Delete every decrypted-attachment scratch file. Called from
    /// `AuthManager.logout()`: a CRASH while a preview was open leaves the
    /// decrypted plaintext behind until iOS purges tmp/. Sweeping the dedicated
    /// scratch dir on logout keeps account A's decrypted attachment from
    /// lingering for account B on a shared device. Best-effort; a file QuickLook
    /// still holds open unlinks cleanly on the underlying filesystem.
    static func clearScratch() {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }
}
