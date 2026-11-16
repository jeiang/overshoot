# overshoot

An iPhone camera app that makes photos look like they came from a Canon PowerShot A3400 IS or a 2007 Nikon Coolpix.

## Build

Run every command inside the devshell (`nix develop -c <command>`).

```sh
zig build lint                                       # zig fmt check and TigerStyle lint
zig build test                                       # core unit tests
zig build xcframework                                # zig-out/OvershootCore.xcframework
zig build --release=safe                             # zig-out/bin/overshoot-cli
zig build app -Dapp-destination=simulator -Dapp-sign=false
zig build app                                        # signed device build
```

Signed builds use automatic signing. Pass an App Store Connect API key so Xcode can create the provisioning profiles itself:

```sh
zig build app -Dasc-key-path=<AuthKey.p8> -Dasc-key-id=<key ID> -Dasc-issuer-id=<issuer ID>
zig build testflight -Dbuild-number=$(date +%Y%m%d%H%M) -Dasc-key-path=… -Dasc-key-id=… -Dasc-issuer-id=…
```

`testflight` archives to `zig-out/Overshoot.xcarchive` and uploads the build to App Store Connect (add `-Dtestflight-upload=false` to only export `zig-out/testflight/Overshoot.ipa`). The export signs with the keychain's Apple Distribution identity and the "Overshoot App Store" provisioning profile, which must be installed in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`. The build number must grow with every upload.

`overshoot-cli render --camera canon|nikon --input <image> --output <jpg>` renders a photo through the core pipeline; `overshoot-cli stats <image>...` prints the tone statistics used for calibration.

To tune against the app's real RAW-derived input, launch a development build with `xcrun devicectl device process launch --device <udid> co.aidanpinard.overshoot -- -dumpcapture` and take photos. Each capture writes `capture-<time>.f16` (linear RGBA f16 staging input), `.args` (the matching render arguments), `.jpg` and `-preview.png` to the app's Documents. Pull them with `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier co.aidanpinard.overshoot --source Documents/<file> --destination <file>`, then reproduce the photo with `overshoot-cli render --input-f16 capture-<time>.f16 $(cat capture-<time>.args) --output out.jpg`.

Zig code follows [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md).

## License

`docs/TIGER_STYLE.md` is under the Apache License 2.0; see [`docs/TIGER_STYLE.LICENSE`](docs/TIGER_STYLE.LICENSE).
