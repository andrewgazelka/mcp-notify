<p align="center">
  <img src=".github/header.svg" alt="notify" width="360">
</p>

Speak short status updates on macOS with `say`.

## Install

```bash
cargo install --path .
```

```bash
nix profile install github:andrewgazelka/notify#notify
```

## Use

```bash
notify "build finished"
```

Messages do not overlap. They wait their turn using a lock at `~/.notify-lock/say.lock`.
