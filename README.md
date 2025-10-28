# mcp-notify

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

## Locking

If multiple processes try to talk at once, they wait their turn instead of talking over each other.

Uses `File::lock()` at `~/.notify-lock/say.lock`:
- Process 1 speaks → locks file
- Process 2 tries → waits
- Process 1 done → unlocks
- Process 2 speaks → your turn

## Install

Add to Claude Code MCP config:

```json
{
  "mcpServers": {
    "mcp-notify": {
      "command": "/path/to/mcp-notify"
    }
  }
}
```

## Usage

Claude automatically uses it via:
```
mcp__mcp-notify__say "your text here"
```

That's it.
