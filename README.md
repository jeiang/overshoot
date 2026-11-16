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

`overshoot-cli render --camera canon|nikon --input <image> --output <jpg>` renders a photo through the core pipeline; `overshoot-cli stats <image>...` prints the tone statistics used for calibration.

Zig code follows [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md).

## License

`docs/TIGER_STYLE.md` is under the Apache License 2.0; see [`docs/TIGER_STYLE.LICENSE`](docs/TIGER_STYLE.LICENSE).
