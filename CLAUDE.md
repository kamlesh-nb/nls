# CLAUDE.md — nls (Nova Language Server)

## What this is

**nls** is the **Language Server Protocol (LSP)** implementation for the **Nova** language, written in
**Zig**. It gives editors (via the Nova VSCode **extension**, a separate repo) IDE features over Nova
source: completion, hover, go-to-definition, document symbols, signature help, and diagnostics.

It is a standalone LSP server (stdio transport). Nova (the `lang` repo) is the compiler; `nls` reuses
Nova's lexer/parser-level understanding to answer LSP requests.

## Build / install / run

```bash
cd nls
zig build                 # builds the server AND installs it to $HOME/.nova/bin/nls (default build step)
# The editor client (VSCode extension) launches ~/.nova/bin/nls over stdio.
```

## Layout (`src/`)

- `server.zig` — the LSP loop: JSON-RPC over stdio, request routing (`textDocument/completion`, `hover`,
  `definition`, `documentSymbol`, `signatureHelp`, `diagnostic`).
- `analysis.zig` — the language analysis backing completion/hover (symbol resolution over the parsed doc).
- `main.zig`, `root.zig` — entry.
- `lsp-spec.zig` — LSP protocol types.
- `lib/`, `zig-pkg/` — dependencies.

## Implemented capabilities

completion · hover · go-to-definition · document symbols · signature help · diagnostics — verified e2e
over LSP stdio.

## Gotchas

- **Parser span reliability**: key IDE positioning off the **start** span (`span.start`); `span.end` has
  been unreliable historically. Confirm against real Nova-compiled positions.
- `zig build` **auto-installs** to `~/.nova/bin/nls`; the extension expects it there. Watch for a
  build-vs-launch race if you rebuild while an editor is connected.
- Zig version: matches `build.zig.zon`.

## Relationship to Nova

Pairs with the `lang` repo (the compiler/language) and the `extension` repo (the VSCode client that
spawns this server). Versions can move independently, but LSP features track Nova's syntax/semantics.
