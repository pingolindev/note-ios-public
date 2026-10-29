# Third-party licences

Pingolin Note for iOS is licensed under the GNU General Public License,
version 3 or later (see [LICENSE](LICENSE)). It links the third-party components
below, each under its own licence. Nothing here is vendored into the
repository — Swift Package Manager fetches every entry at the exact revision
pinned in [`project.yml`](project.yml).

| Component | Pinned revision | Licence | Project |
|---|---|---|---|
| Swift-Sodium | `cfd195c7` | ISC | <https://github.com/jedisct1/swift-sodium> |
| GRDB + SQLCipher (DuckDuckGo distribution) | `46098847` (release 3.0.0) | MIT (GRDB) and BSD-3-Clause (SQLCipher) | <https://github.com/duckduckgo/GRDB.swift> |

Two of these bundle further code, so their notices cover more than the wrapper
repository:

- **Swift-Sodium** bundles [libsodium](https://github.com/jedisct1/libsodium),
  ISC-licensed by the same author.
- **The GRDB package is a binary distribution.** The DuckDuckGo repository
  contains only a Swift Package definition and release scripts — no GRDB or
  SQLCipher source — and attaches a prebuilt `GRDB.xcframework` to its GitHub
  releases. Version `3.0.0` of that package ships **GRDB 7.4.1** (MIT) compiled
  against **SQLCipher 4.7.0** (BSD-3-Clause). SQLCipher in turn embeds SQLite,
  which is public domain. All three notices are reproduced below.

## The Pingolin FFI XCFramework

`lib/PingolinFFI.xcframework` is **not** third-party code and is **not**
committed here — it is Pingolin's own Rust code (the `mobile-sdk` and
`note-collab-sdk` crates), compiled locally by [`build-ios.sh`](build-ios.sh)
(see the README for how). It does carry its own tree of transitive Rust
dependencies, and those are inventoried in the `mobile-sdk` repository rather
than duplicated here:

- <https://github.com/pingolindev/mobile-sdk-public> — see its `THIRD_PARTY_LICENSES.md`

## How this list was verified

Each licence was taken from the dependency's own repository, not from a
third-party licence database:

- **Swift-Sodium** — `LICENSE` on the `master` branch reads "ISC License /
  Copyright (c) 2014-2026, Frank Denis". GitHub's repository metadata reports
  `spdx_id: ISC`.
- **libsodium** — `LICENSE` on the `master` branch reads "ISC License /
  Copyright (c) 2013-2026 / Frank Denis".
- **GRDB + SQLCipher** — GitHub's metadata for `duckduckgo/GRDB.swift` reports
  no detected licence, because the fork carries no `LICENSE` file of its own.
  Its `README.md` states the composition verbatim — "This Package: *3.0.0*",
  "GRDB: *7.4.1*", "SQLCipher: *4.7.0*" — and the `v3.0.0` tag exists in that
  repository, which is what SPM resolves `exactVersion: "3.0.0"` to. The
  licences were then read from the upstream projects: `groue/GRDB.swift`
  `LICENSE` is the MIT text with "Copyright (C) 2015-2025 Gwendal Roué"
  (`spdx_id: MIT`), and `sqlcipher/sqlcipher` `LICENSE.md` is the BSD-3-Clause
  text with "Copyright (c) 2025, ZETETIC LLC" (`spdx_id: BSD-3-Clause`).

There is currently no in-app licences screen in Settings; this file is the
canonical notice.

---

## Swift-Sodium — ISC

<https://github.com/jedisct1/swift-sodium>

```
ISC License

Copyright (c) 2014-2026, Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## libsodium — ISC

<https://github.com/jedisct1/libsodium>

```
ISC License

Copyright (c) 2013-2026
Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## GRDB.swift — MIT

<https://github.com/groue/GRDB.swift>

```
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## SQLCipher — BSD-3-Clause

<https://github.com/sqlcipher/sqlcipher>

```
Copyright (c) 2025, ZETETIC LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the ZETETIC LLC nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY ZETETIC LLC ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL ZETETIC LLC BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## SQLite — public domain

<https://sqlite.org/copyright.html>

SQLCipher is built on SQLite, whose source code is released into the public
domain by its authors: "The authors have submitted written affidavits releasing
their work to the public for any use."
