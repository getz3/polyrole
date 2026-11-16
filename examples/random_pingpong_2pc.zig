const std = @import("std");
const Io = std.Io;
const polyrole = @import("polyrole");
const Data = polyrole.Data;
const pingpong = @import("./protocols/pingpong.zig");
const mk2pc = @import("./protocols/two_phase_commit.zig").mk2pc;
const channel = @import("channel.zig");
const runner = polyrole.runner;

const MvarChannelMap = channel.MvarChannelMap(AllRole);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var ctx: Context = .{
        .alice = .{},
        .bob = .{},
        .charlie = .{},
        .selector = .{},
    };

    var run_context: runner.RunContext = .{
        .pmap = .init(allocator),
        .actions = .empty,
    };
    defer run_context.deinit(allocator);

    const Rpp2pc = runner.Runner(EnterFsmState);
    const Codec = polyrole.Codec;

    const AliceR = Rpp2pc.MakeRunner(.alice, Codec);
    const BobR = Rpp2pc.MakeRunner(.bob, Codec);
    const CharlieR = Rpp2pc.MakeRunner(.charlie, Codec);
    const SelectorR = Rpp2pc.MakeRunner(.selector, Codec);

    var buff_alice: [100]u8 = undefined;
    const rc_alice: runner.RoleContext = .{
        .ctx = &ctx.alice,
        .buff = &buff_alice,
        .fun = &AliceR.symmetric_run,
    };

    var buff_bob: [100]u8 = undefined;
    const rc_bob: runner.RoleContext = .{
        .ctx = &ctx.bob,
        .buff = &buff_bob,
        .fun = &BobR.symmetric_run,
    };

    var buff_charlie: [100]u8 = undefined;
    const rc_charlie: runner.RoleContext = .{
        .ctx = &ctx.charlie,
        .buff = &buff_charlie,
        .fun = &CharlieR.symmetric_run,
    };

    var buff_selector: [100]u8 = undefined;
    const rc_selector: runner.RoleContext = .{
        .ctx = &ctx.selector,
        .buff = &buff_selector,
        .fun = &SelectorR.symmetric_run,
    };

    const key_alice: runner.Key = .{ .pid = 0, .role = @backingInt(AllRole.alice) };
    const key_bob: runner.Key = .{ .pid = 0, .role = @backingInt(AllRole.bob) };
    const key_charlie: runner.Key = .{ .pid = 0, .role = @backingInt(AllRole.charlie) };
    const key_selector: runner.Key = .{ .pid = 0, .role = @backingInt(AllRole.selector) };

    try run_context.pmap.put(key_alice, rc_alice);
    try run_context.pmap.put(key_bob, rc_bob);
    try run_context.pmap.put(key_charlie, rc_charlie);
    try run_context.pmap.put(key_selector, rc_selector);

    const start_id: u32 = @backingInt(curr_id);

    try run_context.actions.pushBack(allocator, .{
        .key = key_alice,
        .curr_id_ = start_id,
        .enter_point = .start,
    });

    try run_context.actions.pushBack(allocator, .{
        .key = key_bob,
        .curr_id_ = start_id,
        .enter_point = .start,
    });

    try run_context.actions.pushBack(allocator, .{
        .key = key_charlie,
        .curr_id_ = start_id,
        .enter_point = .start,
    });

    try run_context.actions.pushBack(allocator, .{
        .key = key_selector,
        .curr_id_ = start_id,
        .enter_point = .start,
    });

    try run_context.run(allocator);
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
