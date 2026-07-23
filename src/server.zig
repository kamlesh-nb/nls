const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const types = lsp.types.flat;
const compiler = @import("compiler");
const parser = compiler.parser;
const formatter = compiler.formatter;
const ast = compiler.ast;
const analysis = @import("analysis.zig");

const CItem = lsp.types.completion.Item;

pub const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    files: std.StringHashMapUnmanaged([]u8),
    offset_encoding: lsp.offsets.Encoding,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Handler {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .files = .empty,
            .offset_encoding = .@"utf-16",
        };
    }

    pub fn deinit(self: *Handler) void {
        var file_it = self.files.iterator();
        while (file_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.files = undefined;
    }

    pub fn initialize(
        self: *Handler,
        _: std.mem.Allocator,
        request: types.InitializeParams,
    ) types.InitializeResult {
        std.log.debug("Received 'initialize' message", .{});

        const client_capabilities: types.ClientCapabilities = request.capabilities;

        if (client_capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                self.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }

        const server_capabilities: types.ServerCapabilities = .{
            .positionEncoding = switch (self.offset_encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .documentFormattingProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{ ".", ":" } },
            .hoverProvider = .{ .bool = true },
            .definitionProvider = .{ .bool = true },
            .documentSymbolProvider = .{ .bool = true },
            .signatureHelpProvider = .{ .triggerCharacters = &.{ "(", "," } },
        };

        if (builtin.mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Handler, server_capabilities);
        }

        return .{
            .serverInfo = .{
                .name = "Nova Language Server",
                .version = "0.2.0",
            },
            .capabilities = server_capabilities,
        };
    }

    pub fn initialized(
        _: *Handler,
        _: std.mem.Allocator,
        _: types.InitializedParams,
    ) void {
        std.log.debug("Received 'initialized' notification", .{});
    }

    pub fn shutdown(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) ?void {
        std.log.debug("Received 'shutdown' request", .{});
        return null;
    }

    pub fn exit(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) void {
        std.log.debug("Received 'exit' notification", .{});
    }

    pub fn @"textDocument/didOpen"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DidOpenTextDocumentParams,
    ) !void {
        const uri = params.textDocument.uri;
        const text = params.textDocument.text;

        const new_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(new_text);

        const gop = try self.files.getOrPut(self.allocator, uri);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, uri);
        }
        gop.value_ptr.* = new_text;

        try self.runDiagnostics(arena, uri, new_text);
    }

    pub fn @"textDocument/didChange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DidChangeTextDocumentParams,
    ) !void {
        const uri = params.textDocument.uri;
        const current_text = self.files.getPtr(uri) orelse return;

        if (params.contentChanges.len == 0) return;
        const change = params.contentChanges[0];

        const new_text = try self.allocator.dupe(u8, change.text_document_content_change_whole_document.text);
        self.allocator.free(current_text.*);
        current_text.* = new_text;

        try self.runDiagnostics(arena, uri, new_text);
    }

    pub fn @"textDocument/didClose"(
        self: *Handler,
        _: std.mem.Allocator,
        params: types.DidCloseTextDocumentParams,
    ) !void {
        const entry = self.files.fetchRemove(params.textDocument.uri) orelse return;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    fn runDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, source: []const u8) !void {
        var p = parser.Parser.init(arena, source, uri, false) catch |err| {
            std.log.err("Parser init failed: {any}", .{err});
            return;
        };
        defer p.deinit();

        _ = p.parseProgram() catch {
            const err_token = p.tokens[@min(p.pos, p.tokens.len - 1)];
            const line = err_token.line - 1;
            const column = err_token.column - 1;

            const msg = try std.fmt.allocPrint(arena, "Syntax error: unexpected token '{s}'", .{err_token.lexeme});

            const diag = types.Diagnostic{
                .range = .{
                    .start = .{ .line = @intCast(line), .character = @intCast(column) },
                    .end = .{ .line = @intCast(line), .character = @intCast(column + err_token.lexeme.len) },
                },
                .severity = .Error,
                .message = msg,
            };

            const diag_list = try arena.alloc(types.Diagnostic, 1);
            diag_list[0] = diag;

            const publish_params = types.PublishDiagnosticsParams{
                .uri = uri,
                .diagnostics = diag_list,
            };
            try self.transport.writeNotification(self.io, arena, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams, publish_params, .{});
            return;
        };

        // No errors, clear diagnostics
        const publish_params = types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = &.{},
        };
        try self.transport.writeNotification(self.io, arena, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams, publish_params, .{});
    }

    fn getDocumentEnd(text: []const u8) types.Position {
        var line: u32 = 0;
        var character: u32 = 0;
        for (text) |c| {
            if (c == '\n') {
                line += 1;
                character = 0;
            } else {
                character += 1;
            }
        }
        return .{ .line = line, .character = character };
    }

    pub fn @"textDocument/formatting"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DocumentFormattingParams,
    ) !?[]const types.TextEdit {
        const uri = params.textDocument.uri;
        const source = self.files.get(uri) orelse return null;

        var p = parser.Parser.init(arena, source, uri, false) catch return null;
        defer p.deinit();

        const program = p.parseProgram() catch return null;

        var f = formatter.Formatter.init(arena, source);
        defer f.deinit();

        const formatted = f.formatProgram(program) catch return null;

        const end_pos = getDocumentEnd(source);
        const full_range = types.Range{
            .start = .{ .line = 0, .character = 0 },
            .end = end_pos,
        };

        const edit = types.TextEdit{
            .range = full_range,
            .newText = formatted,
        };

        const edits = try arena.alloc(types.TextEdit, 1);
        edits[0] = edit;
        return edits;
    }

    // ------------------------------------------------------------------
    // Completion
    // ------------------------------------------------------------------

    const CompletionContext = union(enum) {
        /// `receiver.` — the dotted segment chain BEFORE the trailing dot.
        member: []const []const u8,
        /// Typing a bare identifier.
        identifier,
    };

    pub fn @"textDocument/completion"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.completion.Params,
    ) !?lsp.types.completion.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);

        // The context (receiver chain / bare-word) is read from the ORIGINAL buffer.
        const ctx = analyzeCompletionContext(arena, source, index);

        // The buffer is usually mid-edit and won't parse (a dangling `.` or a bare
        // word with no `;`); parseBest falls back to blanking the cursor's line so
        // the rest of the file still yields declarations and the enclosing scope.
        const program = parseBest(arena, params.textDocument.uri, source, index) orelse
            ast.Program{ .declarations = &.{}, .span = undefined };

        var items = std.ArrayList(CItem).empty;

        switch (ctx) {
            .member => |segments| try self.memberCompletions(arena, program, source, index, segments, &items),
            .identifier => try self.identifierCompletions(arena, program, source, index, &items),
        }

        return .{ .completion_items = try items.toOwnedSlice(arena) };
    }

    /// Parse `source`; if it doesn't parse (the usual mid-edit case), retry with
    /// the cursor's line blanked. Prefers the real parse so a completion/signature
    /// request on an already-valid buffer isn't degraded by the repair. Offsets are
    /// preserved either way, so spans stay valid against `index`.
    fn parseBest(arena: std.mem.Allocator, uri: []const u8, source: []const u8, index: usize) ?ast.Program {
        if (parser.Parser.init(arena, source, uri, false)) |*p_ok| {
            var p = p_ok.*;
            if (p.parseProgram()) |program| {
                return program;
            } else |_| {}
        } else |_| {}

        const repaired = repairLine(arena, source, index) catch return null;
        var p = parser.Parser.init(arena, repaired, uri, false) catch return null;
        return p.parseProgram() catch null;
    }

    /// Blank the line containing `index` (spaces), keeping `{`/`}` so brace
    /// nesting stays balanced. Same length as the input, so every byte offset —
    /// and thus every AST span — is preserved.
    fn repairLine(arena: std.mem.Allocator, source: []const u8, index: usize) ![]u8 {
        const buf = try arena.dupe(u8, source);
        var ls = @min(index, buf.len);
        while (ls > 0 and buf[ls - 1] != '\n') ls -= 1;
        var le = @min(index, buf.len);
        while (le < buf.len and buf[le] != '\n') le += 1;
        for (buf[ls..le]) |*c| {
            if (c.* != '{' and c.* != '}' and c.* != '\r') c.* = ' ';
        }
        return buf;
    }

    fn analyzeCompletionContext(arena: std.mem.Allocator, source: []const u8, index: usize) CompletionContext {
        // Back over the partial identifier under the cursor.
        var i = @min(index, source.len);
        while (i > 0 and isIdentChar(source[i - 1])) i -= 1;
        if (i == 0 or source[i - 1] != '.') return .identifier;

        // We're completing a member. Collect the receiver chain before the dot.
        var end = i - 1; // at the '.'
        while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
        var start = end;
        while (start > 0 and (isIdentChar(source[start - 1]) or source[start - 1] == '.')) start -= 1;
        const chain = std.mem.trim(u8, source[start..end], " \t");

        var segs = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, chain, '.');
        while (it.next()) |seg| {
            const s = std.mem.trim(u8, seg, " \t");
            if (s.len > 0) segs.append(arena, s) catch {};
        }
        return .{ .member = segs.toOwnedSlice(arena) catch &.{} };
    }

    fn memberCompletions(
        _: *Handler,
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        index: usize,
        segments: []const []const u8,
        items: *std.ArrayList(CItem),
    ) !void {
        // Build the local scope so `foo.` can be resolved.
        var locals = std.ArrayList(analysis.Local).empty;
        const enc = analysis.enclosingFunction(program, index);
        if (enc) |e| try analysis.collectLocals(arena, program, e, index, &locals);

        const receiver = analysis.resolveChain(segments, locals.items, enc, program);
        if (receiver) |r| {
            try appendTypeMembers(arena, program, source, r, items);
            if (items.items.len > 0) return;
        }
        // Unresolved receiver → offer the union of all members so the user still
        // gets useful suggestions (a good LSP degrades, it doesn't go blank).
        try appendAllMembers(arena, program, source, items);
    }

    fn appendTypeMembers(
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        receiver: analysis.Receiver,
        items: *std.ArrayList(CItem),
    ) !void {
        const decl = analysis.findTypeDecl(program, receiver.type_name) orelse return;
        switch (decl) {
            .struct_decl => |sd| {
                if (!receiver.is_static) {
                    for (sd.fields) |f| {
                        try items.append(arena, .{
                            .label = f.name,
                            .kind = .Field,
                            .detail = try fieldDetail(arena, sd.name, f),
                        });
                    }
                }
                for (sd.methods) |md| {
                    if (md.is_static != receiver.is_static) continue;
                    if (std.mem.eql(u8, md.decl.name, "init")) continue;
                    try items.append(arena, try methodItem(arena, source, sd.name, md));
                }
            },
            .enum_decl => |ed| {
                if (receiver.is_static) {
                    for (ed.variants) |v| {
                        try items.append(arena, .{
                            .label = v.name,
                            .kind = .EnumMember,
                            .detail = try std.fmt.allocPrint(arena, "{s}.{s}", .{ ed.name, v.name }),
                        });
                    }
                }
                for (ed.methods) |md| {
                    if (md.is_static != receiver.is_static) continue;
                    try items.append(arena, try methodItem(arena, source, ed.name, md));
                }
            },
        }
    }

    fn appendAllMembers(
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        items: *std.ArrayList(CItem),
    ) !void {
        var seen = std.StringHashMap(void).init(arena);
        for (program.declarations) |decl| {
            switch (decl) {
                .struct_decl => |sd| {
                    for (sd.fields) |f| {
                        if ((try seen.getOrPut(f.name)).found_existing) continue;
                        try items.append(arena, .{ .label = f.name, .kind = .Field, .detail = try fieldDetail(arena, sd.name, f) });
                    }
                    for (sd.methods) |md| {
                        if (std.mem.eql(u8, md.decl.name, "init")) continue;
                        if ((try seen.getOrPut(md.decl.name)).found_existing) continue;
                        try items.append(arena, try methodItem(arena, source, sd.name, md));
                    }
                },
                .enum_decl => |ed| {
                    for (ed.methods) |md| {
                        if ((try seen.getOrPut(md.decl.name)).found_existing) continue;
                        try items.append(arena, try methodItem(arena, source, ed.name, md));
                    }
                },
                else => {},
            }
        }
    }

    fn identifierCompletions(
        _: *Handler,
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        index: usize,
        items: *std.ArrayList(CItem),
    ) !void {
        // Locals + params first (most relevant, sort them to the top).
        var locals = std.ArrayList(analysis.Local).empty;
        if (analysis.enclosingFunction(program, index)) |e| {
            try analysis.collectLocals(arena, program, e, index, &locals);
            if (e.container != null) {
                try items.append(arena, .{ .label = "self", .kind = .Variable, .detail = e.container.?, .sortText = "0000self" });
            }
        }
        for (locals.items) |l| {
            const detail = if (l.type_name) |t|
                try std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ if (l.is_const) "const" else "let", l.name, t })
            else
                try std.fmt.allocPrint(arena, "{s} {s}", .{ if (l.is_param) "param" else if (l.is_const) "const" else "let", l.name });
            try items.append(arena, .{
                .label = l.name,
                .kind = if (l.is_param) .Variable else .Variable,
                .detail = detail,
                .sortText = try std.fmt.allocPrint(arena, "0001{s}", .{l.name}),
            });
        }

        // Top-level declarations.
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| try items.append(arena, .{
                    .label = fd.name,
                    .kind = .Function,
                    .detail = try formatSignature(arena, fd.name, fd.params, fd.ret_type, null),
                    .documentation = try docMarkup(arena, source, fd.span.start),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{fd.name}),
                }),
                .struct_decl => |sd| try items.append(arena, .{
                    .label = sd.name,
                    .kind = .Struct,
                    .detail = try std.fmt.allocPrint(arena, "struct {s}", .{sd.name}),
                    .documentation = try docMarkup(arena, source, sd.span.start),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{sd.name}),
                }),
                .enum_decl => |ed| try items.append(arena, .{
                    .label = ed.name,
                    .kind = .Enum,
                    .detail = try std.fmt.allocPrint(arena, "enum {s}", .{ed.name}),
                    .documentation = try docMarkup(arena, source, ed.span.start),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{ed.name}),
                }),
                .const_decl => |cd| try items.append(arena, .{
                    .label = cd.name,
                    .kind = .Constant,
                    .detail = try std.fmt.allocPrint(arena, "const {s}", .{cd.name}),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{cd.name}),
                }),
                .trait_decl => |td| try items.append(arena, .{
                    .label = td.name,
                    .kind = .Interface,
                    .detail = try std.fmt.allocPrint(arena, "trait {s}", .{td.name}),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{td.name}),
                }),
                .import_decl => |id| {
                    for (id.items) |item| {
                        const name = item.alias orelse item.name;
                        try items.append(arena, .{ .label = name, .kind = .Module, .detail = try std.fmt.allocPrint(arena, "import {s}", .{id.module}), .sortText = try std.fmt.allocPrint(arena, "0003{s}", .{name}) });
                    }
                },
                else => {},
            }
        }

        // Primitive types.
        for (analysis.primitive_types) |t| {
            try items.append(arena, .{ .label = t, .kind = .TypeParameter, .detail = "builtin type", .sortText = try std.fmt.allocPrint(arena, "0008{s}", .{t}) });
        }
        // Keywords last.
        for (analysis.keywords) |kw| {
            try items.append(arena, .{ .label = kw, .kind = .Keyword, .sortText = try std.fmt.allocPrint(arena, "0009{s}", .{kw}) });
        }
    }

    fn fieldDetail(arena: std.mem.Allocator, owner: []const u8, f: ast.Field) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        try list.appendSlice(arena, owner);
        try list.appendSlice(arena, ".");
        try list.appendSlice(arena, f.name);
        try list.appendSlice(arena, ": ");
        try writeTypeRef(arena, &list, f.type_name);
        return list.toOwnedSlice(arena);
    }

    fn methodItem(arena: std.mem.Allocator, source: []const u8, owner: []const u8, md: ast.MethodDecl) !CItem {
        return .{
            .label = md.decl.name,
            .kind = .Method,
            .detail = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, owner),
            .documentation = try docMarkup(arena, source, md.decl.span.start),
        };
    }

    fn docMarkup(arena: std.mem.Allocator, source: []const u8, start: usize) !?lsp.types.Documentation {
        const doc = try getDocComment(source, start, arena) orelse return null;
        return .{ .markup_content = .{ .kind = .markdown, .value = doc } };
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    // ------------------------------------------------------------------
    // Hover
    // ------------------------------------------------------------------

    pub fn @"textDocument/hover"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.Hover.Params,
    ) !?types.Hover {
        const current_source = self.files.get(params.textDocument.uri) orelse return null;
        const source_index = lsp.offsets.positionToIndex(current_source, params.position, self.offset_encoding);

        const hovered_word = getWordAtIndex(current_source, source_index) orelse return null;

        // Builtin type keyword?
        for (analysis.primitive_types) |t| {
            if (std.mem.eql(u8, t, hovered_word)) {
                return markdownHover(arena, try std.fmt.allocPrint(arena, "```nova\n{s}\n```\nNova builtin primitive type.", .{t}));
            }
        }

        // Local variable / parameter in the enclosing function?
        {
            var p = parser.Parser.init(arena, current_source, params.textDocument.uri, false) catch null;
            if (p) |*pp| {
                defer pp.deinit();
                if (pp.parseProgram()) |program| {
                    if (analysis.enclosingFunction(program, source_index)) |enc| {
                        var locals = std.ArrayList(analysis.Local).empty;
                        try analysis.collectLocals(arena, program, enc, source_index, &locals);
                        // Prefer a binding whose own span does NOT enclose the cursor
                        // (i.e. a use site) but fall back to any match.
                        for (locals.items) |l| {
                            if (!std.mem.eql(u8, l.name, hovered_word)) continue;
                            const kind = if (l.is_param) "param" else if (l.is_const) "const" else "let";
                            const body = if (l.type_name) |t|
                                try std.fmt.allocPrint(arena, "```nova\n{s} {s}: {s}\n```", .{ kind, l.name, t })
                            else
                                try std.fmt.allocPrint(arena, "```nova\n{s} {s}\n```", .{ kind, l.name });
                            return markdownHover(arena, body);
                        }
                    }
                } else |_| {}
            }
        }

        // Top-level / member declarations across all open files.
        var file_iter = self.files.iterator();
        while (file_iter.next()) |entry| {
            const file_uri = entry.key_ptr.*;
            const file_source = entry.value_ptr.*;

            var p = parser.Parser.init(arena, file_source, file_uri, false) catch continue;
            defer p.deinit();

            const program = p.parseProgram() catch continue;

            if (try hoverForDecl(arena, program, file_source, hovered_word)) |h| return h;
        }

        return null;
    }

    fn hoverForDecl(arena: std.mem.Allocator, program: ast.Program, source: []const u8, word: []const u8) !?types.Hover {
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| {
                    if (std.mem.eql(u8, fd.name, word)) {
                        const sig = try formatSignature(arena, fd.name, fd.params, fd.ret_type, null);
                        return codeHover(arena, source, sig, fd.span.start);
                    }
                },
                .const_decl => |cd| {
                    if (std.mem.eql(u8, cd.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "const {s}", .{cd.name});
                        return codeHover(arena, source, sig, cd.span.start);
                    }
                },
                .trait_decl => |td| {
                    if (std.mem.eql(u8, td.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "trait {s}", .{td.name});
                        return codeHover(arena, source, sig, td.span.start);
                    }
                },
                .struct_decl => |sd| {
                    if (std.mem.eql(u8, sd.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "struct {s}", .{sd.name});
                        return codeHover(arena, source, sig, sd.span.start);
                    }
                    for (sd.fields) |f| {
                        if (std.mem.eql(u8, f.name, word)) {
                            var list = std.ArrayList(u8).empty;
                            try list.appendSlice(arena, sd.name);
                            try list.appendSlice(arena, ".");
                            try list.appendSlice(arena, f.name);
                            try list.appendSlice(arena, ": ");
                            try writeTypeRef(arena, &list, f.type_name);
                            return codeHover(arena, source, try list.toOwnedSlice(arena), f.span.start);
                        }
                    }
                    for (sd.methods) |md| {
                        if (std.mem.eql(u8, md.decl.name, word)) {
                            const sig = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, sd.name);
                            return codeHover(arena, source, sig, md.decl.span.start);
                        }
                    }
                },
                .enum_decl => |ed| {
                    if (std.mem.eql(u8, ed.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "enum {s}", .{ed.name});
                        return codeHover(arena, source, sig, ed.span.start);
                    }
                    for (ed.variants) |v| {
                        if (std.mem.eql(u8, v.name, word)) {
                            const sig = try std.fmt.allocPrint(arena, "{s}.{s}", .{ ed.name, v.name });
                            return codeHover(arena, source, sig, v.span.start);
                        }
                    }
                    for (ed.methods) |md| {
                        if (std.mem.eql(u8, md.decl.name, word)) {
                            const sig = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, ed.name);
                            return codeHover(arena, source, sig, md.decl.span.start);
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Hover rendering a `nova` code fence plus any `///` doc comment above `start`.
    fn codeHover(arena: std.mem.Allocator, source: []const u8, sig: []const u8, start: usize) !?types.Hover {
        var md = std.ArrayList(u8).empty;
        try md.appendSlice(arena, "```nova\n");
        try md.appendSlice(arena, sig);
        try md.appendSlice(arena, "\n```\n");
        if (try getDocComment(source, start, arena)) |doc| {
            try md.appendSlice(arena, doc);
            try md.appendSlice(arena, "\n");
        }
        return markdownHover(arena, try md.toOwnedSlice(arena));
    }

    fn markdownHover(_: std.mem.Allocator, value: []const u8) types.Hover {
        return .{ .contents = .{ .markup_content = .{ .kind = .markdown, .value = value } } };
    }

    // ------------------------------------------------------------------
    // Go-to-definition
    // ------------------------------------------------------------------

    pub fn @"textDocument/definition"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.Definition.Params,
    ) !?types.Definition.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        // Local binding in the enclosing function wins — jump to its declaration.
        {
            var p = parser.Parser.init(arena, source, params.textDocument.uri, false) catch null;
            if (p) |*pp| {
                defer pp.deinit();
                if (pp.parseProgram()) |program| {
                    if (analysis.enclosingFunction(program, index)) |enc| {
                        var locals = std.ArrayList(analysis.Local).empty;
                        try analysis.collectLocals(arena, program, enc, index, &locals);
                        for (locals.items) |l| {
                            if (std.mem.eql(u8, l.name, word) and l.span.start != index) {
                                return locationResult(arena, source, params.textDocument.uri, l.span, word);
                            }
                        }
                    }
                } else |_| {}
            }
        }

        // Otherwise search every open file for the declaration.
        var it = self.files.iterator();
        while (it.next()) |entry| {
            const file_uri = entry.key_ptr.*;
            const file_source = entry.value_ptr.*;
            var p = parser.Parser.init(arena, file_source, file_uri, false) catch continue;
            defer p.deinit();
            const program = p.parseProgram() catch continue;
            if (declSpanFor(program, word)) |span| {
                return locationResult(arena, file_source, file_uri, span, word);
            }
        }
        return null;
    }

    fn declSpanFor(program: ast.Program, word: []const u8) ?ast.Span {
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| if (std.mem.eql(u8, fd.name, word)) return fd.span,
                .const_decl => |cd| if (std.mem.eql(u8, cd.name, word)) return cd.span,
                .trait_decl => |td| if (std.mem.eql(u8, td.name, word)) return td.span,
                .struct_decl => |sd| {
                    if (std.mem.eql(u8, sd.name, word)) return sd.span;
                    for (sd.fields) |f| if (std.mem.eql(u8, f.name, word)) return f.span;
                    for (sd.methods) |md| if (std.mem.eql(u8, md.decl.name, word)) return md.decl.span;
                },
                .enum_decl => |ed| {
                    if (std.mem.eql(u8, ed.name, word)) return ed.span;
                    for (ed.variants) |v| if (std.mem.eql(u8, v.name, word)) return v.span;
                    for (ed.methods) |md| if (std.mem.eql(u8, md.decl.name, word)) return md.decl.span;
                },
                else => {},
            }
        }
        return null;
    }

    /// Build a Definition result pointing at `word` within `span` (the name's
    /// own range when we can find it, else the declaration start).
    fn locationResult(arena: std.mem.Allocator, source: []const u8, uri: []const u8, span: ast.Span, word: []const u8) !?types.Definition.Result {
        _ = arena;
        const range = nameRange(source, span, word);
        return .{ .definition = .{ .location = .{ .uri = uri, .range = range } } };
    }

    // ------------------------------------------------------------------
    // Signature help (parameter hints while typing a call)
    // ------------------------------------------------------------------

    pub fn @"textDocument/signatureHelp"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.SignatureHelp.Params,
    ) !?types.SignatureHelp {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);

        const call = findEnclosingCall(arena, source, index) orelse return null;
        if (call.segments.len == 0) return null;

        // Prefer the real parse; fall back to blanking the cursor's line when the
        // half-typed call breaks the file. Receiver types resolve against the
        // locals declared on earlier lines.
        const program = parseBest(arena, params.textDocument.uri, source, index) orelse return null;

        var locals = std.ArrayList(analysis.Local).empty;
        const enc = analysis.enclosingFunction(program, index);
        if (enc) |e| try analysis.collectLocals(arena, program, e, index, &locals);

        const callable = resolveCallable(program, locals.items, enc, call.segments) orelse return null;
        const owner = callable.owner;
        const fd = callable.decl;

        const label = try formatSignature(arena, fd.name, fd.params, fd.ret_type, owner);

        var infos = std.ArrayList(types.ParameterInformation).empty;
        for (fd.params) |prm| {
            const plabel = if (prm.type_name) |t|
                try std.fmt.allocPrint(arena, "{s}: {s}", .{ prm.name, try typeRefString(arena, t) })
            else
                prm.name;
            try infos.append(arena, .{ .label = .{ .string = plabel } });
        }

        const sig = types.SignatureInformation{
            .label = label,
            .documentation = try docMarkup(arena, source, fd.span.start),
            .parameters = try infos.toOwnedSlice(arena),
            .activeParameter = call.active,
        };
        const sigs = try arena.alloc(types.SignatureInformation, 1);
        sigs[0] = sig;
        return .{ .signatures = sigs, .activeSignature = 0, .activeParameter = call.active };
    }

    const CallInfo = struct {
        segments: []const []const u8,
        active: u32,
    };

    /// Locate the call whose argument list the cursor is inside: the callee's
    /// dotted name and the zero-based index of the argument being typed.
    fn findEnclosingCall(arena: std.mem.Allocator, source: []const u8, index: usize) ?CallInfo {
        var i = @min(index, source.len);
        var depth: i32 = 0;
        var commas: u32 = 0;
        var open: ?usize = null;
        while (i > 0) {
            const c = source[i - 1];
            switch (c) {
                ')', ']' => depth += 1,
                '(' => {
                    if (depth == 0) {
                        open = i - 1;
                        break;
                    }
                    depth -= 1;
                },
                '[' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => if (depth == 0) {
                    commas += 1;
                },
                ';', '{', '}' => return null, // statement boundary — not in a call
                else => {},
            }
            i -= 1;
        }
        const op = open orelse return null;

        // The callee is the identifier chain immediately before `(`.
        var end = op;
        while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
        var start = end;
        while (start > 0 and (isIdentChar(source[start - 1]) or source[start - 1] == '.')) start -= 1;
        const chain = std.mem.trim(u8, source[start..end], " \t");
        if (chain.len == 0) return null;

        var segs = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, chain, '.');
        while (it.next()) |seg| {
            const s = std.mem.trim(u8, seg, " \t");
            if (s.len > 0) segs.append(arena, s) catch {};
        }
        return .{ .segments = segs.toOwnedSlice(arena) catch &.{}, .active = commas };
    }

    const Callable = struct {
        decl: ast.FunctionDecl,
        owner: ?[]const u8,
    };

    /// Resolve a (possibly dotted) callee name to its declaration: a free
    /// function, or a static/instance method on a resolved receiver type.
    fn resolveCallable(program: ast.Program, locals: []const analysis.Local, enc: ?analysis.Enclosing, segments: []const []const u8) ?Callable {
        if (segments.len == 1) {
            for (program.declarations) |decl| {
                if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, segments[0])) {
                    return .{ .decl = decl.fn_decl, .owner = null };
                }
            }
            return null;
        }
        // `recv.method` — resolve the receiver chain (all but the last segment).
        const method_name = segments[segments.len - 1];
        const recv = analysis.resolveChain(segments[0 .. segments.len - 1], locals, enc, program) orelse return null;
        const decl = analysis.findTypeDecl(program, recv.type_name) orelse return null;
        const methods = switch (decl) {
            .struct_decl => |sd| sd.methods,
            .enum_decl => |ed| ed.methods,
        };
        for (methods) |md| {
            if (std.mem.eql(u8, md.decl.name, method_name)) {
                return .{ .decl = md.decl, .owner = recv.type_name };
            }
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Document symbols (outline)
    // ------------------------------------------------------------------

    pub fn @"textDocument/documentSymbol"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DocumentSymbol.Params,
    ) !?types.DocumentSymbol.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        var p = parser.Parser.init(arena, source, params.textDocument.uri, false) catch return null;
        defer p.deinit();
        const program = p.parseProgram() catch return null;

        var syms = std.ArrayList(types.DocumentSymbol).empty;
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| try syms.append(arena, .{
                    .name = fd.name,
                    .detail = try formatSignature(arena, fd.name, fd.params, fd.ret_type, null),
                    .kind = .Function,
                    .range = fullRange(source, fd.span),
                    .selectionRange = nameRange(source, fd.span, fd.name),
                }),
                .const_decl => |cd| try syms.append(arena, .{
                    .name = cd.name,
                    .kind = .Constant,
                    .range = fullRange(source, cd.span),
                    .selectionRange = nameRange(source, cd.span, cd.name),
                }),
                .trait_decl => |td| try syms.append(arena, .{
                    .name = td.name,
                    .kind = .Interface,
                    .range = fullRange(source, td.span),
                    .selectionRange = nameRange(source, td.span, td.name),
                }),
                .struct_decl => |sd| {
                    var children = std.ArrayList(types.DocumentSymbol).empty;
                    for (sd.fields) |f| try children.append(arena, .{
                        .name = f.name,
                        .detail = try typeRefString(arena, f.type_name),
                        .kind = .Field,
                        .range = fullRange(source, f.span),
                        .selectionRange = nameRange(source, f.span, f.name),
                    });
                    for (sd.methods) |md| try children.append(arena, .{
                        .name = md.decl.name,
                        .detail = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, sd.name),
                        .kind = if (md.is_static) .Function else .Method,
                        .range = fullRange(source, md.decl.span),
                        .selectionRange = nameRange(source, md.decl.span, md.decl.name),
                    });
                    try syms.append(arena, .{
                        .name = sd.name,
                        .kind = .Struct,
                        .range = fullRange(source, sd.span),
                        .selectionRange = nameRange(source, sd.span, sd.name),
                        .children = try children.toOwnedSlice(arena),
                    });
                },
                .enum_decl => |ed| {
                    var children = std.ArrayList(types.DocumentSymbol).empty;
                    for (ed.variants) |v| try children.append(arena, .{
                        .name = v.name,
                        .kind = .EnumMember,
                        .range = fullRange(source, v.span),
                        .selectionRange = nameRange(source, v.span, v.name),
                    });
                    for (ed.methods) |md| try children.append(arena, .{
                        .name = md.decl.name,
                        .detail = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, ed.name),
                        .kind = if (md.is_static) .Function else .Method,
                        .range = fullRange(source, md.decl.span),
                        .selectionRange = nameRange(source, md.decl.span, md.decl.name),
                    });
                    try syms.append(arena, .{
                        .name = ed.name,
                        .kind = .Enum,
                        .range = fullRange(source, ed.span),
                        .selectionRange = nameRange(source, ed.span, ed.name),
                        .children = try children.toOwnedSlice(arena),
                    });
                },
                else => {},
            }
        }
        return .{ .document_symbols = try syms.toOwnedSlice(arena) };
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    fn getWordAtIndex(source: []const u8, index: usize) ?[]const u8 {
        if (index > source.len) return null;

        var start = index;
        while (start > 0) {
            const c = source[start - 1];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                start -= 1;
            } else {
                break;
            }
        }

        var end = index;
        while (end < source.len) {
            const c = source[end];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                end += 1;
            } else {
                break;
            }
        }

        if (start == end) return null;
        return source[start..end];
    }

    fn getDocComment(source: []const u8, start_offset: usize, allocator: std.mem.Allocator) !?[]const u8 {
        var idx = @min(start_offset, source.len);
        while (idx > 0 and source[idx - 1] != '\n') : (idx -= 1) {}

        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(allocator);

        var current_line_end = idx;
        while (current_line_end > 0) {
            var current_line_start = current_line_end - 1;
            while (current_line_start > 0 and source[current_line_start - 1] != '\n') : (current_line_start -= 1) {}

            const raw_line = source[current_line_start..current_line_end];
            const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "///")) {
                const doc = std.mem.trim(u8, trimmed[3..], " ");
                try lines.append(allocator, doc);
            } else {
                break;
            }
            current_line_end = current_line_start;
        }

        if (lines.items.len == 0) return null;

        var i: usize = 0;
        while (i < lines.items.len / 2) : (i += 1) {
            std.mem.swap([]const u8, &lines.items[i], &lines.items[lines.items.len - 1 - i]);
        }

        var joined = std.ArrayList(u8).empty;
        defer joined.deinit(allocator);
        for (lines.items, 0..) |line, j| {
            try joined.appendSlice(allocator, line);
            if (j + 1 < lines.items.len) {
                try joined.append(allocator, '\n');
            }
        }
        return try joined.toOwnedSlice(allocator);
    }

    /// The LSP Range covering the whole declaration span.
    fn fullRange(source: []const u8, span: ast.Span) types.Range {
        return .{
            .start = lsp.offsets.indexToPosition(source, @min(span.start, source.len), .@"utf-16"),
            .end = lsp.offsets.indexToPosition(source, @min(span.end, source.len), .@"utf-16"),
        };
    }

    /// The Range of `name` inside `span` (its declaration site). Falls back to a
    /// zero-width range at the span start if the name isn't found textually.
    fn nameRange(source: []const u8, span: ast.Span, name: []const u8) types.Range {
        const lo = @min(span.start, source.len);
        // span.end is unreliable for a declaration whose body-closing token is the
        // last in the file (its span derives from an EOF lexeme at offset 0). When
        // it's missing or behind the start, scan a bounded forward window from the
        // declaration start — the name always appears on the first line or two.
        const hi = if (span.end > span.start) @min(span.end, source.len) else @min(source.len, lo + 200);
        if (lo < hi) {
            if (std.mem.indexOfPos(u8, source[0..hi], lo, name)) |pos| {
                return .{
                    .start = lsp.offsets.indexToPosition(source, pos, .@"utf-16"),
                    .end = lsp.offsets.indexToPosition(source, pos + name.len, .@"utf-16"),
                };
            }
        }
        const p = lsp.offsets.indexToPosition(source, lo, .@"utf-16");
        return .{ .start = p, .end = p };
    }

    fn typeRefString(arena: std.mem.Allocator, tr: ast.TypeRef) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        try writeTypeRef(arena, &list, tr);
        return list.toOwnedSlice(arena);
    }

    fn writeTypeRef(arena: std.mem.Allocator, list: *std.ArrayList(u8), tr: ast.TypeRef) !void {
        switch (tr) {
            .ident => |id| try list.appendSlice(arena, id),
            .optional => |opt| {
                try writeTypeRef(arena, list, opt.*);
                try list.appendSlice(arena, "?");
            },
            .error_union => |eu| {
                try writeTypeRef(arena, list, eu.ok.*);
                try list.appendSlice(arena, " | ");
                try writeTypeRef(arena, list, eu.err.*);
            },
            .fixed_array => |fa| {
                try writeTypeRef(arena, list, fa.element.*);
                try list.appendSlice(arena, "[");
                var buf: [32]u8 = undefined;
                const len_str = try std.fmt.bufPrint(&buf, "{d}", .{fa.length});
                try list.appendSlice(arena, len_str);
                try list.appendSlice(arena, "]");
            },
            .generic => |g| {
                try list.appendSlice(arena, g.name);
                try list.appendSlice(arena, "<");
                for (g.params, 0..) |param, idx| {
                    try writeTypeRef(arena, list, param);
                    if (idx + 1 < g.params.len) try list.appendSlice(arena, ", ");
                }
                try list.appendSlice(arena, ">");
            },
            .func => |f| {
                try list.appendSlice(arena, "(");
                for (f.params, 0..) |param, idx| {
                    try writeTypeRef(arena, list, param);
                    if (idx + 1 < f.params.len) try list.appendSlice(arena, ", ");
                }
                try list.appendSlice(arena, ") -> ");
                try writeTypeRef(arena, list, f.ret.*);
            },
            .tuple => |t| {
                try list.appendSlice(arena, "(");
                for (t, 0..) |param, idx| {
                    try writeTypeRef(arena, list, param);
                    if (idx + 1 < t.len) try list.appendSlice(arena, ", ");
                }
                try list.appendSlice(arena, ")");
            },
        }
    }

    fn formatSignature(arena: std.mem.Allocator, name: []const u8, params: []const ast.Param, ret_type: ?ast.TypeRef, struct_name_opt: ?[]const u8) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(arena);

        if (struct_name_opt) |s_name| {
            try list.appendSlice(arena, "fn ");
            try list.appendSlice(arena, s_name);
            try list.appendSlice(arena, ".");
            try list.appendSlice(arena, name);
        } else {
            try list.appendSlice(arena, "fn ");
            try list.appendSlice(arena, name);
        }
        try list.appendSlice(arena, "(");
        for (params, 0..) |p, i| {
            try list.appendSlice(arena, p.name);
            if (p.type_name) |t| {
                try list.appendSlice(arena, ": ");
                try writeTypeRef(arena, &list, t);
            }
            if (i + 1 < params.len) {
                try list.appendSlice(arena, ", ");
            }
        }
        try list.appendSlice(arena, ")");
        if (ret_type) |ret| {
            try list.appendSlice(arena, ": ");
            try writeTypeRef(arena, &list, ret);
        } else {
            try list.appendSlice(arena, ": void");
        }
        return try list.toOwnedSlice(arena);
    }

    pub fn onResponse(
        _: *Handler,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        std.log.warn("received unexpected response from client with id '{?}'!", .{response.id});
    }
};

test "Hover documentation comments" {
    const allocator = std.heap.page_allocator;

    var handler = Handler{
        .allocator = allocator,
        .io = undefined,
        .transport = undefined,
        .files = .empty,
        .offset_encoding = .@"utf-16",
    };
    defer handler.deinit();

    const source =
        \\pub struct Watcher {
        \\    pub handle: i32,
        \\
        \\    /// Create a new Watcher monitoring the specified directory path.
        \\    init(path: string) {
        \\        self.handle = 123;
        \\    }
        \\
        \\    /// Wait cooperatively for the next file modification event.
        \\    /// Returns the full path of the modified/created/deleted file.
        \\    pub fn nextEvent(self: Watcher): string {
        \\        return "event";
        \\    }
        \\}
    ;

    const uri = "file:///mock.nova";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const init_index = std.mem.indexOf(u8, source, "init").?;
    const init_pos = lsp.offsets.indexToPosition(source, init_index, handler.offset_encoding);

    const hover_params = types.Hover.Params{
        .textDocument = .{ .uri = uri },
        .position = init_pos,
    };

    const hover_res = try handler.@"textDocument/hover"(allocator, hover_params);
    try std.testing.expect(hover_res != null);

    const hover_val = hover_res.?.contents.markup_content.value;
    try std.testing.expect(std.mem.indexOf(u8, hover_val, "Create a new Watcher monitoring the specified directory path.") != null);

    const next_index = std.mem.indexOf(u8, source, "nextEvent").?;
    const next_pos = lsp.offsets.indexToPosition(source, next_index, handler.offset_encoding);

    const hover_params2 = types.Hover.Params{
        .textDocument = .{ .uri = uri },
        .position = next_pos,
    };

    const hover_res2 = try handler.@"textDocument/hover"(allocator, hover_params2);
    try std.testing.expect(hover_res2 != null);

    const hover_val2 = hover_res2.?.contents.markup_content.value;
    try std.testing.expect(std.mem.indexOf(u8, hover_val2, "Wait cooperatively for the next file modification event.") != null);
}

test "member completion resolves receiver type" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\struct Conn {
        \\    pub host: string,
        \\    pub port: int,
        \\    pub fn ping(self: Conn): bool { return true; }
        \\}
        \\
        \\fn use() {
        \\    let c = Conn{ host: "a", port: 1 };
        \\    c.
        \\}
    ;
    const uri = "file:///m.nova";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const dot = std.mem.indexOf(u8, source, "c.").? + 2;
    const pos = lsp.offsets.indexToPosition(source, dot, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/completion"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    const items = res.?.completion_items;

    var saw_host = false;
    var saw_ping = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "host")) saw_host = true;
        if (std.mem.eql(u8, it.label, "ping")) saw_ping = true;
    }
    try std.testing.expect(saw_host);
    try std.testing.expect(saw_ping);
}

test "identifier completion offers top-level symbols and locals" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn helper(): int { return 1; }
        \\
        \\fn main() {
        \\    let total = 0;
        \\    t
        \\}
    ;
    const uri = "file:///m.nova";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const at = std.mem.indexOf(u8, source, "    t\n").? + 5;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/completion"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);

    var saw_helper = false;
    var saw_total = false;
    for (res.?.completion_items) |it| {
        if (std.mem.eql(u8, it.label, "helper")) saw_helper = true;
        if (std.mem.eql(u8, it.label, "total")) saw_total = true;
    }
    try std.testing.expect(saw_helper);
    try std.testing.expect(saw_total);
}

test "signature help reports params and active index" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn add(a: int, b: int): int { return a + b; }
        \\fn main() { let s = add(1, 2); }
    ;
    const uri = "file:///m.nova";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor after the comma → second argument (active index 1).
    const comma = std.mem.indexOf(u8, source, "add(1, 2)").? + 6;
    const pos = lsp.offsets.indexToPosition(source, comma, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/signatureHelp"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    try std.testing.expectEqual(@as(usize, 1), res.?.signatures.len);
    const sig = res.?.signatures[0];
    try std.testing.expect(std.mem.indexOf(u8, sig.label, "fn add(a: int, b: int): int") != null);
    try std.testing.expectEqual(@as(usize, 2), sig.parameters.?.len);
    try std.testing.expectEqual(@as(u32, 1), res.?.activeParameter.?);
}

test "go to definition finds a function span" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn target(): int { return 42; }
        \\fn caller() { let x = target(); }
    ;
    const uri = "file:///m.nova";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const use = std.mem.indexOf(u8, source, "target()").?;
    const pos = lsp.offsets.indexToPosition(source, use + 1, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/definition"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    const loc = res.?.definition.location;
    // The definition is the `target` on line 0, not the call on line 1.
    try std.testing.expectEqual(@as(u32, 0), loc.range.start.line);
}
