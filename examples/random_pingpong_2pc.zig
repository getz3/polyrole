const std = @import("std");
const Io = std.Io;
const polyrole = @import("polyrole");
const Data = polyrole.Data;
const pingpong = @import("./protocols/pingpong.zig");
const mk2pc = @import("./protocols/two_phase_commit.zig").mk2pc;
const channel = @import("channel.zig");
const runner = polyrole.runner;
const Codec = polyrole.Codec;

const MvarChannelMap = channel.MvarChannelMap(AllRole);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var ctx: Context = .{
        .alice = .{},
        .bob = .{},
        .charlie = .{},
        .selector = .{},
    };

    var ctx1: Context = .{
        .alice = .{},
        .bob = .{},
        .charlie = .{},
        .selector = .{},
    };

    var scheduler: runner.PrototypeScheduler = undefined;
    scheduler.init(allocator);
    defer scheduler.deinit(allocator);
    try scheduler.append_protocol(
        allocator,
        @fromBackingInt(0),
        100,
        Codec,
        &ctx,
        EnterFsmState,
    );

    try scheduler.append_protocol(
        allocator,
        @fromBackingInt(1),
        100,
        Codec,
        &ctx1,
        EnterFsmState,
    );

    try scheduler.run(allocator, Codec);
}

//
const AllRole = enum { selector, alice, bob, charlie };

const AliceContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const BobContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const CharlieContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const SelectorContext = struct {
    times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
};

const Context = struct {
    alice: AliceContext,
    bob: BobContext,
    charlie: CharlieContext,
    selector: SelectorContext,
};

pub const EnterFsmState = Start;

pub const Runner = polyrole.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

fn PingPong(client: AllRole, server: AllRole, Next: type) type {
    return pingpong.MkPingPong(
        AllRole,
        client,
        server,
        Context,
        .pingpong_client,
        .pingpong_server,
        Next,
    );
}

fn CAB(Next: type) type {
    return mk2pc(AllRole, .charlie, .alice, .bob, Context, Next, polyrole.Exit);
}
fn ABC(Next: type) type {
    return mk2pc(AllRole, .alice, .bob, .charlie, Context, Next, polyrole.Exit);
}
fn BAC(Next: type) type {
    return mk2pc(AllRole, .bob, .alice, .charlie, Context, Next, polyrole.Exit);
}

pub const Start = union(enum) {
    charlie_as_coordinator: Data(void, PingPong(.alice, .bob, PingPong(.bob, .charlie, PingPong(
        .charlie,
        .alice,
        CAB(@This()).Begin,
    ).Ping).Ping).Ping),
    alice_as_coordinator: Data(void, PingPong(.charlie, .bob, ABC(@This()).Begin).Ping),
    bob_as_coordinator: Data(void, PingPong(.alice, .charlie, BAC(@This()).Begin).Ping),
    exit: Data(void, polyrole.Exit),

    pub const info: polyrole.ProtocolInfo(
        "random_pingpong_and_2pc",
        AllRole,
        Context,
        &.{ .selector, .charlie, .alice, .bob },
        &.{},
    ) = .{
        .name = "Start",
        .sender = .selector,
        .receiver = &.{ .charlie, .alice, .bob },
    };

    pub fn process(ctx: *SelectorContext) !@This() {
        ctx.times += 1;
        std.debug.print("times: {d}\n", .{ctx.times});
        if (ctx.times > 300) {
            return .{ .exit = .{ .data = {} } };
        }

        const random: std.Random = ctx.xoshiro256.random();
        const res = random.intRangeAtMost(u8, 0, 2);
        switch (res) {
            0 => return .{ .charlie_as_coordinator = .{ .data = {} } },
            1 => return .{ .alice_as_coordinator = .{ .data = {} } },
            2 => return .{ .bob_as_coordinator = .{ .data = {} } },
            else => unreachable,
        }
    }
};
