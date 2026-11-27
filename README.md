# QuadernoDrive (macOS FileProvider)

Native macOS Finder integration (`NSFileProviderReplicatedExtension`) + menu-bar host app built on [libquaderno](https://github.com/sarraga/libquaderno).

## Architecture

- **`QuadernoDrive.app`** (`App/QuadernoDriveApp.swift`): Menu-bar host app (unsandboxed) that handles:
  - USB discovery and CDC-ACM → CDC-ECM switching via `libquaderno`'s `usb_macos.c` (`IOKit` + `/dev/cu.usbmodem*`).
  - PIN pairing (`quaderno_pair()`) into the shared App Group container (`group.net.santablanca.quaderno`).
  - Writing the resolved device address (`fe80::...%enX` or Wi-Fi IP) to shared defaults and signaling Finder to refresh.
- **`QuadernoFileProvider.appex`** (`Extension/FileProviderExtension.swift`): Sandboxed `NSFileProviderReplicatedExtension` mounted in Finder's sidebar (`~/Library/CloudStorage/QUADERNO`):
  - Full read/write/create/rename/move/delete for folders and PDF documents.
  - Optimistic conflict detection via `itemVersion.contentVersion` mapped to QUADERNO's `file_revision`.
  - Custom Finder right-click action: **"Open on QUADERNO"** (`quaderno_open()`).

## Prerequisites (macOS)

```bash
brew install openssl@3 xcodegen
```

## Generating & Building in Xcode

```bash
xcodegen generate
open QuadernoDrive.xcodeproj
```

> **Note:** `project.yml` fetches [`libquaderno`](https://github.com/sarraga/libquaderno) automatically via Swift Package Manager (`CQuaderno`). For local library development against an adjacent checkout, you can temporarily swap `url:`/`branch:` for `path: ../libquaderno` in `project.yml`.

In Xcode:
1. Select **both** the `QuadernoDrive` and `QuadernoFileProvider` targets → **Signing & Capabilities**.
2. Set your **Team** (a free personal Apple ID team works for local use).
3. If you change the Bundle ID / App Group (`group.net.santablanca.quaderno`), update it in:
   - `Shared/SharedConfig.swift`
   - `App/QuadernoDrive.entitlements`
   - `Extension/QuadernoFileProvider.entitlements`
   - `Extension/Info.plist` (`NSExtensionFileProviderDocumentGroup`)
4. Build and run the `QuadernoDrive` scheme (`Cmd+R`). Click the menu-bar icon to pair (or copy existing `deviceid.dat`, `privatekey.dat`, `devicecert.bin` into the App Group container) and click **Open QUADERNO in Finder**.

> **Note on OpenSSL dynamic vs. static linking**: `project.yml` links against Homebrew's `openssl@3` (`libssl`, `libcrypto`). If the sandboxed extension fails to load `libssl.3.dylib` from `/opt/homebrew`, either link the static archives (`libssl.a` + `libcrypto.a` from `$(brew --prefix openssl@3)/lib`) into both targets or embed/re-sign the dylibs in the app bundle.

## License

`QuadernoDrive` is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).
