//! analysis.zig — the semantic core of the Kyte language server.
//!
//! The LSP handlers (server.zig) are thin: they turn an LSP request into a
//! cursor offset, call into here, and marshal the result back. Everything that
//! needs to understand Kyte code — resolving the type of a receiver, gathering
//! the locals in scope, finding where a name is declared — lives here so it can
//! be unit-tested without a running transport.
//!
//! It works off the parser AST (arena-allocated per request). There is no full
//! type checker in the loop: instead a lightweight, best-effort type environment
//! (params + `let` bindings + `self`) resolves the common cases a developer hits
//! while typing. When it can't resolve precisely it degrades to a useful global
//! set rather than to nothing — the standard behaviour of a good LSP.

const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;
const parser = compiler.parser;

/// The primitive type NAMES Kyte recognises (kept in sync with
/// codegen/types.zig `cgPrim` + `isPrimitiveTypeName`). Used for hover on a
/// type keyword and to seed identifier completion.
pub const primitive_types = [_][]const u8{
    "int",    "i32",  "uint", "u32",    "long",   "i64",  "ulong", "u64",
    "short",  "i16",  "ushort", "u16",  "byte",   "i8",   "u8",    "sbyte",
    "float",  "f32",  "double", "f64",  "decimal", "bool", "string", "char",
    "ptr",    "void", "any",
};

/// Kyte keywords offered in identifier-position completion.
pub const keywords = [_][]const u8{
    "let",    "const",  "fn",     "struct", "enum",   "union",  "trait",  "impl",
    "import", "export", "pub",    "return", "if",     "else",   "while",  "for",
    "switch", "case",   "default","try",    "catch",  "match",  "break",  "continue",
    "defer",  "async",  "await",  "spawn",  "extern", "true",   "false",  "null",
    "undefined",
};

/// A binding visible at the cursor: a parameter or a `let`.
pub const Local = struct {
    name: []const u8,
    /// Base type name if we could determine it (`let x: Foo` or `let x = Foo{}`).
    type_name: ?[]const u8,
    is_const: bool,
    is_param: bool,
    span: ast.Span,
};

/// The function (or method) body that encloses the cursor.
pub const Enclosing = struct {
    decl: ast.FunctionDecl,
    /// The struct/enum the method belongs to, so `self` resolves. Null for a
    /// free function.
    container: ?[]const u8,
};

/// What a receiver expression (`foo` in `foo.`) resolves to.
pub const Receiver = struct {
    type_name: []const u8,
    /// true → `TypeName.` (static/associated access): offer static methods and,
    /// for an enum, its variants. false → `value.` (instance access): offer
    /// fields and instance methods.
    is_static: bool,
};

/// Base name of a type reference — the identifier you'd resolve a struct/enum by.
/// `Foo` → "Foo", `Foo?` → "Foo", `List<T>` → "List", `T | E` → ok side.
pub fn typeRefName(tr: ast.TypeRef) ?[]const u8 {
    return switch (tr) {
        .ident => |id| id,
        .optional => |opt| typeRefName(opt.*),
        .error_union => |eu| typeRefName(eu.ok.*),
        .generic => |g| g.name,
        .fixed_array => |fa| typeRefName(fa.element.*),
        .func, .tuple => null,
    };
}

/// Best-effort type of the value a `let` binds — from its annotation, else its
/// initializer's shape.
pub fn inferLetType(program: ast.Program, ls: ast.LetStmt) ?[]const u8 {
    if (ls.type_name) |tn| return typeRefName(tn);
    if (ls.init) |init| return inferExprType(program, init);
    return null;
}

/// Best-effort type name of an expression. Deliberately shallow, but resolves the
/// patterns a developer actually assigns from: a struct/enum literal, a cast, a
/// literal, and — the important one for `let c = Conn.open(); c.` — the return
/// type of a call to a known free function or static/instance method.
pub fn inferExprType(program: ast.Program, e: ast.Expression) ?[]const u8 {
    return switch (e.kind) {
        .struct_init => |si| si.type_name,
        .enum_init => |ei| ei.enum_name,
        .cast => |c| typeRefName(c.target_type),
        .call => |c| inferCallReturn(program, c.callee.*),
        .generic_call => |c| inferCallReturn(program, c.callee.*),
        .literal => |lit| switch (lit) {
            .string => "string",
            .integer => "int",
            .float => "double",
            .decimal => "decimal",
            .bool => "bool",
            else => null,
        },
        else => null,
    };
}

/// The declared return type name of the function/method a callee names.
/// Handles `foo(...)` (free function) and `Type.method(...)` (static method).
fn inferCallReturn(program: ast.Program, callee: ast.Expression) ?[]const u8 {
    switch (callee.kind) {
        .ident => |name| {
            for (program.declarations) |decl| {
                if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, name)) {
                    return if (decl.fn_decl.ret_type) |rt| typeRefName(rt) else null;
                }
            }
        },
        .field_access => |fa| {
            // `Type.method(...)` — a static/associated method on a named type.
            if (fa.object.kind == .ident) {
                const type_name = fa.object.kind.ident;
                const decl = findTypeDecl(program, type_name) orelse return null;
                const methods = switch (decl) {
                    .struct_decl => |sd| sd.methods,
                    .enum_decl => |ed| ed.methods,
                };
                for (methods) |md| {
                    if (std.mem.eql(u8, md.decl.name, fa.field)) {
                        return if (md.decl.ret_type) |rt| typeRefName(rt) else null;
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Find the function/method that encloses `offset`.
///
/// This deliberately keys off span.START only. A declaration's span.END is
/// unreliable: the parser derives byte offsets from a token's lexeme pointer, and
/// the token that closes a body (the one AFTER `}`) is EOF for the last
/// declaration in a file — whose empty lexeme yields offset 0, corrupting the
/// end. So instead of "the scope whose range contains the cursor" we take "the
/// function-like scope with the greatest start <= cursor", which is the enclosing
/// one whenever the cursor sits inside a body (the next scope starts later).
pub fn enclosingFunction(program: ast.Program, offset: usize) ?Enclosing {
    var best: ?Enclosing = null;
    var best_start: usize = 0;
    const consider = struct {
        fn f(decl: ast.FunctionDecl, container: ?[]const u8, off: usize, b: *?Enclosing, bs: *usize) void {
            if (decl.span.start <= off and (b.* == null or decl.span.start >= bs.*)) {
                b.* = .{ .decl = decl, .container = container };
                bs.* = decl.span.start;
            }
        }
    }.f;
    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |fd| consider(fd, null, offset, &best, &best_start),
            .struct_decl => |sd| for (sd.methods) |md| consider(md.decl, sd.name, offset, &best, &best_start),
            .enum_decl => |ed| for (ed.methods) |md| consider(md.decl, ed.name, offset, &best, &best_start),
            else => {},
        }
    }
    return best;
}

/// Gather every parameter and `let` binding visible at `cursor` inside `fn_decl`.
/// Over-approximates scope (does not prune sibling blocks) but never surfaces a
/// binding declared textually after the cursor.
pub fn collectLocals(
    arena: std.mem.Allocator,
    program: ast.Program,
    enc: Enclosing,
    cursor: usize,
    out: *std.ArrayList(Local),
) !void {
    for (enc.decl.params) |p| {
        try out.append(arena, .{
            .name = p.name,
            .type_name = if (p.type_name) |t| typeRefName(t) else null,
            .is_const = false,
            .is_param = true,
            .span = p.span,
        });
    }
    try collectLocalsBlock(arena, program, enc.decl.body, cursor, out);
}

fn collectLocalsBlock(arena: std.mem.Allocator, program: ast.Program, block: ast.Block, cursor: usize, out: *std.ArrayList(Local)) std.mem.Allocator.Error!void {
    for (block.statements) |stmt| try collectLocalsStmt(arena, program, stmt, cursor, out);
}

fn collectLocalsStmt(arena: std.mem.Allocator, program: ast.Program, stmt: ast.Statement, cursor: usize, out: *std.ArrayList(Local)) std.mem.Allocator.Error!void {
    switch (stmt) {
        .let_stmt => |ls| {
            if (ls.span.start > cursor) return;
            if (ls.names) |names| {
                for (names) |n| try out.append(arena, .{ .name = n, .type_name = null, .is_const = ls.is_const, .is_param = false, .span = ls.span });
            } else {
                try out.append(arena, .{ .name = ls.name, .type_name = inferLetType(program, ls), .is_const = ls.is_const, .is_param = false, .span = ls.span });
            }
        },
        .block => |b| try collectLocalsBlock(arena, program, b, cursor, out),
        .if_stmt => |i| {
            try collectLocalsStmt(arena, program, i.then_branch.*, cursor, out);
            if (i.else_branch) |e| try collectLocalsStmt(arena, program, e.*, cursor, out);
        },
        .while_stmt => |w| try collectLocalsStmt(arena, program, w.body.*, cursor, out),
        .for_stmt => |f| {
            if (f.iterator) |it| {
                switch (it.binding) {
                    .item => |name| try out.append(arena, .{ .name = name, .type_name = null, .is_const = false, .is_param = false, .span = f.span }),
                    .destructure => |d| {
                        try out.append(arena, .{ .name = d.key, .type_name = null, .is_const = false, .is_param = false, .span = f.span });
                        try out.append(arena, .{ .name = d.value, .type_name = null, .is_const = false, .is_param = false, .span = f.span });
                    },
                }
            }
            if (f.initializer) |init| try collectLocalsStmt(arena, program, init.*, cursor, out);
            try collectLocalsStmt(arena, program, f.body.*, cursor, out);
        },
        .switch_stmt => |s| {
            for (s.cases) |c| try collectLocalsStmt(arena, program, c.body.*, cursor, out);
            if (s.default_case) |d| try collectLocalsStmt(arena, program, d.*, cursor, out);
        },
        else => {},
    }
}

/// Resolve the type of a single receiver identifier: `self`, a local/param, or a
/// bare type name used for static access.
pub fn resolveReceiver(
    name: []const u8,
    locals: []const Local,
    enc: ?Enclosing,
    program: ast.Program,
) ?Receiver {
    if (std.mem.eql(u8, name, "self")) {
        if (enc) |e| if (e.container) |c| return .{ .type_name = c, .is_static = false };
    }
    // Last binding wins (shadowing).
    var i: usize = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) {
            if (locals[i].type_name) |tn| return .{ .type_name = tn, .is_static = false };
            return null; // known binding, unknown type — don't fall through to static
        }
    }
    // Not a value in scope: maybe a type name used statically (`Color.`).
    if (findTypeDecl(program, name) != null) return .{ .type_name = name, .is_static = true };
    return null;
}

/// Follow a dotted receiver chain (`a.b.c`) to the type of the final segment.
/// `segments` is the chain BEFORE the trailing dot the user just typed.
pub fn resolveChain(
    segments: []const []const u8,
    locals: []const Local,
    enc: ?Enclosing,
    program: ast.Program,
) ?Receiver {
    if (segments.len == 0) return null;
    var cur = resolveReceiver(segments[0], locals, enc, program) orelse return null;
    var idx: usize = 1;
    while (idx < segments.len) : (idx += 1) {
        // Every hop after the first is an instance field access.
        const field_type = fieldType(program, cur.type_name, segments[idx]) orelse return null;
        cur = .{ .type_name = field_type, .is_static = false };
    }
    return cur;
}

/// The declared type name of `field` on struct `type_name`, if any.
pub fn fieldType(program: ast.Program, type_name: []const u8, field: []const u8) ?[]const u8 {
    for (program.declarations) |decl| {
        if (decl == .struct_decl and std.mem.eql(u8, decl.struct_decl.name, type_name)) {
            for (decl.struct_decl.fields) |f| {
                if (std.mem.eql(u8, f.name, field)) return typeRefName(f.type_name);
            }
        }
    }
    return null;
}

pub const TypeDecl = union(enum) {
    struct_decl: ast.StructDecl,
    enum_decl: ast.EnumDecl,
};

pub fn findTypeDecl(program: ast.Program, name: []const u8) ?TypeDecl {
    for (program.declarations) |decl| {
        switch (decl) {
            .struct_decl => |sd| if (std.mem.eql(u8, sd.name, name)) return .{ .struct_decl = sd },
            .enum_decl => |ed| if (std.mem.eql(u8, ed.name, name)) return .{ .enum_decl = ed },
            else => {},
        }
    }
    return null;
}

test "typeRefName unwraps optional and generic" {
    const inner = try std.testing.allocator.create(ast.TypeRef);
    defer std.testing.allocator.destroy(inner);
    inner.* = .{ .ident = "Foo" };
    const opt: ast.TypeRef = .{ .optional = inner };
    try std.testing.expectEqualStrings("Foo", typeRefName(opt).?);
    try std.testing.expectEqualStrings("List", typeRefName(.{ .generic = .{ .name = "List", .params = &.{} } }).?);
}
