const std = @import("std");
const polyrole = @import("polyrole");
const Data = polyrole.Data;
const channel = @import("channel.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var counter: std.atomic.Value(usize) = .init(0);
    var mvar_channel_map: MvarChannelMap = .init(io, false, &counter);
    defer mvar_channel_map.deinit(gpa);

    try mvar_channel_map.generate_all_MvarChannel(gpa, 64);

    //`a` drives the protocol. `b`, `c` and `d` never take part in it:
    // they are external roles, so they just wait for the `Notify`
    // that `a` sends when the protocol exits.
    const a = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var ctx: i32 = 0;
            try Runner.symmetric_run(.a, mcm, curr_id, &ctx);
        }
    };
    const b = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var ctx: i32 = 0;
            try Runner.symmetric_run(.b, mcm, curr_id, &ctx);
        }
    };
    const c = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var ctx: i32 = 0;
            try Runner.symmetric_run(.c, mcm, curr_id, &ctx);
        }
    };
    const d = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var ctx: i32 = 0;
            try Runner.symmetric_run(.d, mcm, curr_id, &ctx);
        }
    };

    var a_future = try io.concurrent(a.run, .{&mvar_channel_map});
    var b_future = try io.concurrent(b.run, .{&mvar_channel_map});
    var c_future = try io.concurrent(c.run, .{&mvar_channel_map});
    var d_future = try io.concurrent(d.run, .{&mvar_channel_map});

    try a_future.await(io);
    try b_future.await(io);
    try c_future.await(io);
    try d_future.await(io);
}

pub const EnterFsmState = A;

pub const Runner = polyrole.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

const Role = enum { a, b, c, d };
const MvarChannelMap = channel.MvarChannelMap(Role);

const Context = struct {
    a: i32,
    b: i32,
    c: i32,
    d: i32,
};

fn mk_info(
    StateName: []const u8,
) polyrole.ProtocolInfo("counter", Role, Context, &.{.a}, &.{}) {
    //`internal_roles` is 1, which is equivalent to `polystate`.
    return .{ .name = StateName, .sender = .a, .receiver = &.{} };
}

const A = union(enum) {
    to_b: Data(void, B),
    exit: Data(void, polyrole.Exit),

    pub const info = mk_info("A");

    pub fn process(ctx: *i32) !@This() {
        std.debug.print("ctx: {d}\n", .{ctx.*});
        if (ctx.* > 10) return .{ .exit = .{ .data = {} } };
        return .{ .to_b = .{ .data = {} } };
    }
};
const B = union(enum) {
    to_b: Data(void, A),

    pub const info = mk_info("B");

    pub fn process(ctx: *i32) !@This() {
        ctx.* += 1;
        return .{ .to_b = .{ .data = {} } };
    }
};
