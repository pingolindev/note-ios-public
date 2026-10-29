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

import XCTest
import PingolinNoteSDK
@testable import Note

/// Sign-in and reauth use nothing from a step-2 reply unless the server's
/// proof M2 checks out for this attempt's A, M1 and K (minimal encoding: the
/// SDK's client). The vectors come from the server's own proof check — one
/// full length, one with a leading zero in A, one with a leading zero in S.
final class ServerProofTests: XCTestCase {

    /// (name, A, M1, S, the server's M2)
    private let vectors: [(String, String, String, String, String)] = [
        ("minimal_full_length", "O7RdahpZcyewafz7esdlOT1vjjktEqIWf9e0p/KAkuJjG+Lp0nYYhHqZd5qLJLY8mUI15c8NqAB9NAIq7YcGLB+Zi/QqkZo2HGiU6uK5KSyauE9bdxHPRAPFKBfDDUxVCHV2c6f+2UxnjTgoexqrbgm7qAezV82/vddCkx2BgEEi7gRC4Ae4ZtUBbLr5cexHSx38z9IkyzORGTSSmy0X5el6epoykN905DBQZD0T/PO2ldRlVd1ev+PwR5GW+AxJxy9OkwA8/R0j+HE0Z9Bni5XqCD/tV403llDV+8EmBslz/nVdiNvA/fOEMiV8gp3TquuIa1IY/aQre2ZqRIYF6A==",
         "ybO4N41Z/qJ+3/X7y6Gq+r/yngMxSVQ/Atyc1JWfMtw=",
         "XyCMSpZFJEtop+KknJbpzICbssE4tIggUaIM0GxN2J/+rltNgc+cg23CqjZeqhi/ww/j8uBQCRK8nnpjGO4+uzO0MGH+r2exZc17kFkxBbbhvQ2jAXhSa8LqMjIWCxB8Zhs0TvAJTipKh5sY2fqeAgm0S6C7hvEdJ4lIujxnmEzHMJ+8egikgBBUjYf3qqmG/m5ewQL58lTq2MGa74udxARb+M+kzRsThdegwdaBu6QKKXsqK9wnm8hga/gnVfgGuDJ5/9oBrvHrte/Ks87FEi+i3zZR6X5WT78AthH36MmqUisdO1wOjtjtZyWoTPp48ig7hmZTwinYduZPX7K0WQ==",
         "R7dqhvMkDeuB2LtgjhlNAQQ4Wp5kiE4Ys6Mz8qAJvjg="),
        ("minimal_short_a", "ixMLQ2gfaXTfmxvmaXjsy7wujkY46iHC2n964etQU5u8JVaDzqoeaVVl0+1+A2v05UGh9aIyQccQ99PkFnK8jke91F7G9JboEQlh4b38mPEP3aMopXcqGpTbCSsxSZzdkUBzJoib+M7NDSkgz3hoeeKfAcCJmp3lIfp2MD12svRO5ThpQuPmrNpbGrkA4NqVR5ujiC066J6XS3Nf21xSbt7pB1RKu5io2ow4YOaGpkVQ89hTsnDgvpPYsZLahRNnllxXSw39vpaPbjnCiaz7SSN4LHnZLbtrZpSvURwesIpQ3dJofHOf03TyOQs1n+ltqm0pQqgpmsJs470M8oF2",
         "a9HmCfgRCQC+zq/g/m5pmUKXn21101hdFQ8p9YtBU50=",
         "Ymmhb+X4yKBoij1vDBz0unNOrCA0BvlFjc2n/vgg7tgMNXnibzQNYD05Cc7cFst0JU7Z6Uq2rm4jdK9HYrPSl2ft4AN6hiFkRUES8nNQvB8P6wEpNcu0AtuczYiT2MmWuy+V8Vw8mVxwMnFDhM+eu/gZsz/MnPFwYUU1fkMcadp+5MgVBRYNNwwS2hkkaM69aLFssVXoWeDxuPWtujFomKHmjHVR1EO8Yq6jww3vjcGEHL8TupPkEu69GAwVG0QLjAoxO21btst779SJnp0/uTJKaBD5pdQ17d3cX3kwcLorYDzfby0BvazZL1PnAyHZdOtriSh2YyO0evgSeINT3A==",
         "DqECA5Zm/9QW8+EYRqUGUYXt2sFEmI4jXB4/gxxkmGo="),
        ("minimal_short_s", "qQrJPtCnLVzCtKk2LyTegsKkkqLNfJVtBHFu5ZQQFXmqIPxFx/cljiDaSawyhP5n+7amdLcJ2cPQof1uSXQoKfjZnIoHBDOXL8rBHtBXDk2nL5Zy3hQlCYjh8vKe2qEvoD9qdycMP5jZ6WpQGK0NxmXQon+NYMtOInJtHmQTHfZbc2RdHO2XrAOlEn95kdmTuRk0cNYt6zKfL26zJVyqerGqQEBL7IFrrZqvwnAw70J6vQ9G4LFADHYtjqKHfcPyvMcOcPIj+GDXKFK/gBsSK+dWFkYA6F8/UjuF+ashcFbfSKlCS1Xme0gANbwRunV0xLBE/ioTDeVhf+mWD2qrKQ==",
         "xaaj1HimZzaqVJPSEQQ1729AULZyaAMpKLs/wNqQX4s=",
         "BNcC4xzdjit63Y1IUJdbw2qvbJztkQXlqGF/tevkHL0pe0YtGhDnn0BG5HgT4ddVfz1D7DkLvnrj072JswRnRTsKP28+90ymMVMyin4LrzdwQYwOGmrMCWNeLat8mVlVjEiKg8Gy0YJkahuGpsaK/4EyQZPARaJoKaK/lpcjKUXfu/bTQdl3KxXqbmR/e23VwuAkz4NgBAG2o/J2XiNCUGH0lS1nqIcXyP/lRUwNz+osVQ5fHzWlAkYvv2zED6yIKAik9DdnaXjmISegD4yk0OLCoBTkDp+LbQXcF8y3E2/SyRP0OplYkHn0PZOCpCB6FbY9Z4rKVuAjL4EEcgpz",
         "joh/2cWSX1GrMglxSG4JKYqfCskARMtAEkG+fFftE+Q="),
    ]

    private func proof(_ v: (String, String, String, String, String)) -> SrpLoginProof {
        SrpLoginProof(clientPublic: v.1, clientProof: v.2, sessionKey: v.3)
    }

    func testTheServersProofChecksOut() {
        for v in vectors {
            XCTAssertTrue(AuthManager.serverProofMatches(proof(v), serverProof: v.4), v.0)
        }
    }

    func testAWrongProofIsRefused() throws {
        for v in vectors {
            var bytes = try XCTUnwrap(Data(base64Encoded: v.4))
            bytes[0] ^= 0x01
            XCTAssertFalse(AuthManager.serverProofMatches(proof(v), serverProof: bytes.base64EncodedString()), v.0)
            XCTAssertFalse(AuthManager.serverProofMatches(proof(v), serverProof: nil), v.0)
            XCTAssertFalse(AuthManager.serverProofMatches(proof(v), serverProof: ""), v.0)
        }
        // Another attempt's M2 does not prove this one.
        XCTAssertFalse(AuthManager.serverProofMatches(proof(vectors[0]), serverProof: vectors[1].4))
    }

    func testOurOwnMalformedValuesCountAsAFailure() {
        let broken = SrpLoginProof(clientPublic: "!!!", clientProof: vectors[0].2, sessionKey: vectors[0].3)
        XCTAssertFalse(AuthManager.serverProofMatches(broken, serverProof: vectors[0].4))
    }

    func testTheRefusalIsNotCalledAWrongPassword() {
        XCTAssertEqual(AuthManager.AuthError.serverProofRejected.errorDescription, "Couldn't sign in. Please try again.")
        XCTAssertEqual(AuthManager.AuthError.reauthServerProofRejected.errorDescription, "Couldn't check your password just now.")
    }
}
