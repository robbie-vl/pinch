<p align="center">
  <img src="Resources/logo.svg" width="128" alt="Pinch logo">
</p>

<h1 align="center">Pinch</h1>

<p align="center">Your containers, a pinch away.</p>

Pinch is a lightweight, native macOS menu bar app for Colima. See container status, CPU and memory usage, open published ports, and start, stop or restart containers without opening a terminal.

## Build and run

Requires macOS 26+, Xcode 26+, [Colima](https://github.com/abiosoft/colima) and the Docker CLI.

From the Pinch directory:

```sh
./scripts/build-app.sh
open dist/Pinch.app
```

## License

[MIT](LICENSE) © 2026 Robbie Law.
