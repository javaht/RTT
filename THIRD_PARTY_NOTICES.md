# Third-Party Notices

This document describes third-party files distributed in the RTT repository. The licenses below apply only to the named components and do not grant a license to RTT's original source code.

## GNU Awk 5.4.1

- Bundled file: `Sources/RTT/Resources/gawk`
- Version: GNU Awk 5.4.1, Apple Silicon (`arm64`)
- License: GNU General Public License, version 3 or any later version (`GPL-3.0-or-later`)
- Full license text: [`LICENSES/GPL-3.0-or-later.txt`](LICENSES/GPL-3.0-or-later.txt)
- Bundled binary SHA-256: `0ccfca873093cc01c380dd05106383ef474031b24ae6807027cf4d31a676d9a5`

The bundled binary is an unmodified copy of the Homebrew GNU Awk 5.4.1 installation at `/opt/homebrew/bin/gawk`. It was installed using Homebrew formula revision [`6eacc500f51dfa11b6518409688b9d8a9e72beb5`](https://github.com/Homebrew/homebrew-core/blob/6eacc500f51dfa11b6518409688b9d8a9e72beb5/Formula/g/gawk.rb). That formula applies no patches to GNU Awk.

### Corresponding source

Download the exact upstream source archive used by the Homebrew formula:

```text
https://ftp.gnu.org/gnu/gawk/gawk-5.4.1.tar.xz
```

Verify it with:

```bash
curl -LO https://ftp.gnu.org/gnu/gawk/gawk-5.4.1.tar.xz
echo "07f6f7342b7febe4313fc2c2542ad93d64fe20ad8717200109f105a826f5fd37  gawk-5.4.1.tar.xz" | shasum -a 256 -c -
```

The upstream signature is available at:

```text
https://ftp.gnu.org/gnu/gawk/gawk-5.4.1.tar.xz.sig
```

Homebrew's exact build recipe can be downloaded with:

```bash
curl -LO https://raw.githubusercontent.com/Homebrew/homebrew-core/6eacc500f51dfa11b6518409688b9d8a9e72beb5/Formula/g/gawk.rb
```

The binary dynamically links to Homebrew's `gettext`, `readline`, `mpfr`, and `gmp` libraries. RTT users can install GNU Awk and all required runtime libraries with `brew install gawk`.

GNU Awk is Copyright (C) the Free Software Foundation and other contributors. It is provided without warranty under the terms in the included GPL file.

## Translate Shell 0.9.7.1

- Bundled file: `Sources/RTT/Resources/trans`
- Upstream: <https://github.com/soimort/translate-shell>
- License: public-domain dedication / The Unlicense
- Bundled script SHA-256: `5a408ad5cfa21663a96f654e3caf6c3199f8b16e54545e2892e4793513d0a9a5`
- License text: [`LICENSES/Translate-Shell-UNLICENSE.txt`](LICENSES/Translate-Shell-UNLICENSE.txt)
- Copyright waiver: [`LICENSES/Translate-Shell-WAIVER.md`](LICENSES/Translate-Shell-WAIVER.md)

Translate Shell is provided without warranty under the terms in its included license and waiver.
