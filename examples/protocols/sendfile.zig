const std = @import("std");
const polyrole = @import("polyrole");
const Data = polyrole.Data;

pub const SendContext = struct {
    send_buff: [1024 * 4]u8 = @splat(0),
    reader: *std.Io.Reader,
    send_size: usize = 0,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub const RecvContext = struct {
    writer: *std.Io.Writer,
    recved_hash: ?u64 = null,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub fn MkSendFile(
    comptime Role: type,
    comptime sender: Role,
    comptime receiver: Role,
    comptime Context: type,
    comptime batch_size: usize,
    comptime sender_ctx_field: std.meta.FieldEnum(@FieldType(Context, @tagName(sender))),
    comptime recver_ctx_field: std.meta.FieldEnum(@FieldType(Context, @tagName(receiver))),
    comptime Successed: type,
    comptime Failed: type,
) type {
    return struct {
        const Info = polyrole.ProtocolInfo(
            "sendfile",
            Role,
            Context,
            &.{ sender, receiver },
        );

        pub const Send = union(enum) {
            // zig fmt: off
            send  : Data([]const u8                          , @This()),
            check : Data(u64                                 , CheckHash(@This(), Failed)),
            final : Data(struct {str: []const u8, hash: u64,}, CheckHash(Successed, Failed)),
            // zig fmt: on

            pub const info: Info = .{
                .name = "Send",
                .sender = sender,
                .receiver = &.{receiver},
            };

            pub fn process(parent_ctx: *info.Ctx(sender)) !@This() {
                const ctx = sender_ctxFromParent(parent_ctx);
                if (ctx.send_size >= batch_size) {
                    ctx.send_size = 0;
                    const curr_hash = ctx.hasher.final();
                    ctx.hasher = std.hash.XxHash3.init(0);
                    return .{ .check = .{ .data = curr_hash } };
                }

                const n = try ctx.reader.readSliceShort(&ctx.send_buff);
                ctx.send_size += n;

                if (n < ctx.send_buff.len) {
                    ctx.hasher.update(ctx.send_buff[0..n]);
                    return .{ .final = .{ .data = .{
                        .str = ctx.send_buff[0..n],
                        .hash = ctx.hasher.final(),
                    } } };
                } else {
                    ctx.hasher.update(&ctx.send_buff);
                    return .{ .send = .{ .data = &ctx.send_buff } };
                }
            }

            pub fn preprocess_0(parent_ctx: *info.Ctx(receiver), msg: @This()) !void {
                const ctx = recver_ctxFromParent(parent_ctx);
                switch (msg) {
                    .send => |val| {
                        ctx.hasher.update(val.data);
                        try ctx.writer.writeAll(val.data);
                    },
                    .final => |val| {
                        ctx.recved_hash = val.data.hash;
                        const str = val.data.str;
                        ctx.hasher.update(str);
                        try ctx.writer.writeAll(str);
                        try ctx.writer.flush();
                    },
                    .check => |val| {
                        ctx.recved_hash = val.data;
                    },
                }
            }
        };

        pub fn CheckHash(A: type, B: type) type {
            return union(enum) {
                succeeded: Data(void, A),
                failed: Data(void, B),

                pub const info: Info = .{
                    .name = "CheckHash",
                    .sender = receiver,
                    .receiver = &.{sender},
                };

                pub fn process(parent_ctx: *info.Ctx(receiver)) !@This() {
                    const ctx = recver_ctxFromParent(parent_ctx);
                    const curr_hash = ctx.hasher.final();
                    ctx.hasher = std.hash.XxHash3.init(0);
                    if (curr_hash == ctx.recved_hash) {
                        std.debug.print("successed: {d}\n", .{curr_hash});
                        return .{ .succeeded = .{ .data = {} } };
                    } else {
                        return .{ .failed = .{ .data = {} } };
                    }
                }
                pub fn preprocess_0(parent_ctx: *info.Ctx(sender), msg: @This()) !void {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    _ = ctx;
                    switch (msg) {
                        .failed => {},
                        .succeeded => {},
                    }
                }
            };
        }

        fn sender_ctxFromParent(parent_ctx: *@FieldType(Context, @tagName(sender))) *SendContext {
            return &@field(parent_ctx, @tagName(sender_ctx_field));
        }

        fn recver_ctxFromParent(parent_ctx: *@FieldType(Context, @tagName(receiver))) *RecvContext {
            return &@field(parent_ctx, @tagName(recver_ctx_field));
        }
    };
}
