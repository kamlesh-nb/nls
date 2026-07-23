# CLAUDE.md — nls (Nova Language Server)

## What this is

**nls** is the **Language Server Protocol (LSP)** implementation for the **Nova** language, written in
**Zig**. It gives editors (via the Nova VSCode **extension**, a separate repo) IDE features over Nova
source: completion, hover, go-to-definition, document symbols, signature help, and diagnostics.

It is a standalone LSP server (stdio transport). Nova (the `lang` repo) is the compiler; `nls` reuses
Nova's lexer/parser-level understanding to answer LSP requests.

## Build / install / run

**nls reuses the Nova COMPILER's parser/analysis** — its `build.zig` compiles the compiler's
`src/root.zig` as the `compiler` module. So the **`nova` repo must be present as a sibling folder**:

```bash
# clone nova + nls side by side
git clone https://github.com/kamlesh-nb/nova.git
git clone https://github.com/kamlesh-nb/nls.git
cd nls
zig build                 # default: uses ../nova/src/root.zig; installs to $HOME/.nova/bin/nls

# If the compiler folder is named differently (e.g. a mono-repo where it's `lang/`), override:
zig build -Dnova-src=../lang/src/root.zig
```
The editor client (VS Code extension) launches `~/.nova/bin/nls` over stdio. Because it pulls in the
compiler, nls also links LLVM (needs Homebrew LLVM, same as the `nova` build).

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
