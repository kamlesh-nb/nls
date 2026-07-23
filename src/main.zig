const std = @import("std");
const Io = std.Io;

const lsp = @import("lsp");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    std.debug.print("NLS starting...\n", .{});

    const gpa = init.gpa;
    const io = init.io;

    var read_buffer: [256]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler: server.Handler = server.Handler.init(gpa, io, transport);
    defer handler.deinit();

    try lsp.basic_server.run(
        io,
        gpa,
        transport,
        &handler,
        std.log.err,
    );
}
