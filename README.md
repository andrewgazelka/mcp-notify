<p align="center">
  <img src="assets/header.svg" alt="mcp-notify" width="400">
</p>

## Install

### Claude Code (recommended)

```bash
claude mcp add --scope user --transport stdio notify nix run github:andrewgazelka/mcp-notify
```


MCP server that speaks to you using macOS `say`.

## Why

Claude tells you things while you're doing other stuff.

Perfect for:
- Multitasking
- Long builds
- Context switching
- Getting notified without looking

## How It Works

```bash
# Claude finishes task
claude: "Build complete" → your speakers: "Build complete"
```

Async by default. The command returns immediately while speech happens in the background.

## Locking

If multiple processes try to talk at once, they wait their turn instead of talking over each other.

Uses `File::lock()` at `~/.notify-lock/say.lock`:
- Process 1 speaks → locks file
- Process 2 tries → waits
- Process 1 done → unlocks
- Process 2 speaks → your turn

