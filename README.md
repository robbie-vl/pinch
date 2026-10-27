<p align="center">
  <img src="Resources/logo.svg" width="128" alt="Pinch logo">
</p>

<h1 align="center">Pinch</h1>

<p align="center">Your containers, a pinch away.</p>

Pinch is a lightweight, native macOS menu bar app for Colima. See container status, CPU and memory usage, open published ports, and start, stop or restart containers without opening a terminal.

## Lightweight by design

Pinch is a single SwiftUI binary with no third-party dependencies. It only talks to Docker while its popover is open, refreshing the container list every 5 seconds and sampling usage with `docker stats`. Close the popover and that work stops, so in the background Pinch sits at about 15 MB of memory and no CPU.

## Build and run

Requires macOS 26+, Xcode 26+, [Colima](https://github.com/abiosoft/colima) and the Docker CLI.

From the Pinch directory:

```sh
./scripts/build-app.sh
open dist/Pinch.app
```

## License

[MIT](LICENSE) © 2026 Robbie Law.
