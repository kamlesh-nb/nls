# CLAUDE.md ,  nls (Nova Language Server)

## What this is

**nls** is the **Language Server Protocol (LSP)** implementation for the **Nova** language, written in
**Zig**. It gives editors (via the Nova VSCode **extension**, a separate repo) IDE features over Nova
source: completion, hover, go-to-definition, document symbols, signature help, and diagnostics.

It is a standalone LSP server (stdio transport). Nova (the `lang` repo) is the compiler; `nls` reuses
Nova's lexer/parser-level understanding to answer LSP requests.

## Build / install / run

**nls reuses the Nova COMPILER's parser/analysis** ,  its `build.zig` compiles the compiler's
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
The editor client (VS Code extension) launches `~/.nova/bin/nls` over stdio. nls only ever touches the
compiler's parser/formatter/ast/lexer (plus the sema modules it re-exports), none of which import `llvm`
(only codegen does, and codegen is not reachable from the LSP). So the `build.zig` deliberately does NOT
wire the `llvm` binding in: nls is a pure-Zig binary with no external link dependency, which is exactly
what lets it cross-compile to every OS/arch with the bundled Zig toolchain alone.

### Cross-compiling (host build matrix)

Pass `-Dtarget=<triple>` to build one target (installs to `zig-out/bin`), or run `zig build cross` to
build all six at once into `zig-out/cross/<triple>/` (`nls.exe` for Windows). Both work from any host
(macOS, Windows, WSL/Linux). Keep `-Dnova-src=...` if the compiler folder is not `../nova`:

```bash
zig build -Dtarget=x86_64-macos        # macOS x86_64 (intel)
zig build -Dtarget=aarch64-macos       # macOS aarch64 (arm64)
zig build -Dtarget=x86_64-windows      # Windows x86_64
zig build -Dtarget=aarch64-windows     # Windows aarch64
zig build -Dtarget=x86_64-linux-gnu    # Linux x86_64
zig build -Dtarget=aarch64-linux-gnu   # Linux aarch64
zig build cross                        # all six at once (into zig-out/cross/<triple>/)
```

Note: a plain `-Dtarget=...` build still runs the default install step, which copies the (cross) binary
over `~/.nova/bin/nls`. Prefer `zig build cross` for cross artefacts, and rebuild natively (`zig build`)
afterwards to restore the host `nls` the editor launches.

## Layout (`src/`)

- `server.zig` ,  the LSP loop: JSON-RPC over stdio, request routing (`textDocument/completion`, `hover`,
  `definition`, `documentSymbol`, `signatureHelp`, `diagnostic`).
- `analysis.zig` ,  the language analysis backing completion/hover (symbol resolution over the parsed doc).
- `main.zig`, `root.zig` ,  entry.
- `lsp-spec.zig` ,  LSP protocol types.
- `lib/`, `zig-pkg/` ,  dependencies.

## Implemented capabilities

completion · hover · go-to-definition · document symbols · signature help · diagnostics · references ·
rename (+ prepareRename) · code actions · semantic tokens · workspace symbols ,  verified e2e over LSP stdio.

**References and rename are binding-accurate for function-locals**: when the cursor sits on a parameter or a
`let`/`const`, both confine their edits to the enclosing function's brace-matched extent (in that one file),
so renaming a local `x` never touches a same-named local in another function or a global. For names that are
NOT function-locals (globals, types, functions, fields, methods, enum variants) they fall back to the
cross-file whole-word, string/comment-aware match, which is correct for a single-binding name. `braceMatchEnd`
is used instead of `span.end` because the parser's end spans are unreliable (see Gotchas). Code actions
currently cover the async await/spawn fix and the 128-bit-integer removal (replace with `long`/`i64`); the
set is keyed on stable checker message substrings and is easy to extend.

## Gotchas

- **Parser span reliability**: key IDE positioning off the **start** span (`span.start`); `span.end` has
  been unreliable historically. Confirm against real Nova-compiled positions.
- `zig build` **auto-installs** to `~/.nova/bin/nls`; the extension expects it there. Watch for a
  build-vs-launch race if you rebuild while an editor is connected.
- Zig version: matches `build.zig.zon`.

## Relationship to Nova

Pairs with the `lang` repo (the compiler/language) and the `extension` repo (the VSCode client that
spawns this server). Versions can move independently, but LSP features track Nova's syntax/semantics.
