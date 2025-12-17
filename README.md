<p align="center">
  <img src="assets/header.svg" alt="notify" width="400">
</p>

Speaks to you using macOS `say`.

## Install

```bash
nix run github:andrewgazelka/notify -- "hello world"
```

## Usage

```bash
notify "Build complete"
notify "Tests passed"
```

## Why

Get notified without looking at your screen.

Perfect for:
- Long builds
- Background tasks
- Multitasking

## Locking

Multiple processes wait their turn instead of talking over each other.

Uses file locking at `~/.notify-lock/say.lock`.
