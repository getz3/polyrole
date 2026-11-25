const std = @import("std");
const root = @import("root.zig");
const runner = @import("runner.zig");
const Data = root.Data;
const Notify = root.Notify;
const Outcome = runner.Outcome;
const Resume = runner.Resume;

pub const ProtocolId = enum(u32) {
    _,
};

pub const Intersection = struct {
    pid: ProtocolId,
    role: u32,
};

///Prototype scheduler used to exercise `RoleRunner`: queues one `Action` per
///role and drains the queue, routing encoded messages between role inboxes.
///It validates that the single-step runner drives a protocol correctly; it is
///not meant to be the production driver.
pub const Prototype = struct {
    protocols: ProtocolMap,
    actions: std.Deque(Action),

    ///One queue per remote role; each element is an encoded message.
    pub const Inbox = std.ArrayList(std.Deque([]u8));

    pub const RoleContext = struct {
        context: *anyopaque,
        buffer: []u8,
        entry: *const fn (*anyopaque, []u8, u32, Resume) anyerror!Outcome,
        inbox: Inbox,

        pub fn run(self: @This(), raw_state_id: u32, resume_from: Resume) !Outcome {
            return try self.entry(self.context, self.buffer, raw_state_id, resume_from);
        }
    };

    pub const Action = struct {
        key: Intersection,
        state_id: u32,
        resume_from: Resume,
    };

    pub const ProtocolMap = std.AutoHashMap(Intersection, RoleContext);

    pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
        self.protocols = .init(gpa);
        self.actions = .empty;
    }

    pub fn append_protocol(
        self: *@This(),
        gpa: std.mem.Allocator,
        pid: ProtocolId,
        buff_size: usize,
        Codec: type,
        ctx: anytype,
        EnterState: type,
    ) !void {
        const ProtocolRunner = runner.Runner(EnterState);
        const start_id = ProtocolRunner.idFromState(EnterState);
        const Role: type = ProtocolRunner.Role;
        const len = @typeInfo(Role).@"enum".field_names.len;
        inline for (@typeInfo(Role).@"enum".field_names, 0..) |name, idx| {
            const RoleRun = ProtocolRunner.RoleRunner(@fromBackingInt(idx), Codec);
            var role_ctx: RoleContext = .{
                .context = &@field(ctx, name),
                .buffer = try gpa.alloc(u8, buff_size),
                .entry = &RoleRun.run_,
                .inbox = try .initCapacity(gpa, len),
            };
            for (0..len) |_| {
                role_ctx.inbox.appendAssumeCapacity(.empty);
            }
            const key: Intersection = .{ .pid = pid, .role = @intCast(idx) };
            try self.protocols.put(key, role_ctx);
            const raw_start_id: u32 = @backingInt(start_id);
            try self.actions.pushBack(gpa, .{
                .key = key,
                .state_id = raw_start_id,
                .resume_from = .start,
            });
        }
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        var iter = self.protocols.valueIterator();
        while (iter.next()) |role_ctx| {
            gpa.free(role_ctx.buffer);
            for (role_ctx.inbox.items) |*queue| {
                queue.deinit(gpa);
            }
            role_ctx.inbox.deinit(gpa);
        }
        self.protocols.deinit();
        self.actions.deinit(gpa);
    }

    pub fn run(self: *@This(), gpa: std.mem.Allocator, Codec: type) !void {
        while (self.actions.popFront()) |action| {
            const key = action.key;
            const pid = key.pid;
            const curr_role = key.role;
            const role_ctx = self.protocols.getPtr(action.key).?;
            const outcome = try role_ctx.run(action.state_id, action.resume_from);
            const curr_id = outcome.curr_id;
            switch (outcome.action) {
                .done => {},
                .recv_notify_from_role => |role| {
                    if (role_ctx.inbox.items[@intCast(role)].popFront()) |message| {
                        defer gpa.free(message);
                        var reader = std.Io.Reader.fixed(message);
                        const notify = try Codec.decode(&reader, curr_id, Notify);
                        try self.actions.pushBack(gpa, .{
                            .key = key,
                            .state_id = notify.polyrole_notify,
                            .resume_from = .start,
                        });
                    } else {
                        try self.actions.pushBack(gpa, action);
                    }
                },
                .recv_result_from_role => |role| {
                    if (role_ctx.inbox.items[@intCast(role)].popFront()) |message| {
                        defer gpa.free(message);
                        @memcpy(role_ctx.buffer[0..message.len], message);
                        try self.actions.pushBack(gpa, .{
                            .key = key,
                            .state_id = curr_id,
                            .resume_from = .{ .continue_recv = .{
                                .payload = role_ctx.buffer[0..message.len],
                            } },
                        });
                    } else {
                        try self.actions.pushBack(gpa, action);
                    }
                },
                .send_notify => |send| {
                    for (send.notify_roles) |target_role| {
                        const target_ctx = self.protocols.getPtr(.{ .pid = pid, .role = target_role }).?;
                        var allocating = std.Io.Writer.Allocating.init(gpa);
                        defer allocating.deinit();
                        const writer = &allocating.writer;
                        try Codec.encode(writer, curr_id, Notify{
                            .polyrole_notify = send.new_state_id,
                        });
                        try target_ctx.inbox.items[@intCast(curr_role)].pushBack(
                            gpa,
                            try gpa.dupe(u8, writer.buffered()),
                        );
                    }
                    try self.actions.pushBack(gpa, .{
                        .key = action.key,
                        .state_id = send.new_state_id,
                        .resume_from = .start,
                    });
                },
                .send_result => |send| {
                    for (send.receiver_roles) |receiver| {
                        const receiver_ctx = self.protocols.getPtr(.{ .pid = pid, .role = receiver }).?;
                        try receiver_ctx.inbox.items[@intCast(curr_role)].pushBack(gpa, try gpa.dupe(u8, send.result));
                    }
                    for (send.notify_roles) |target_role| {
                        const target_ctx = self.protocols.getPtr(.{ .pid = pid, .role = target_role }).?;
                        var allocating = std.Io.Writer.Allocating.init(gpa);
                        defer allocating.deinit();
                        const writer = &allocating.writer;
                        try Codec.encode(writer, curr_id, Notify{
                            .polyrole_notify = send.new_state_id,
                        });
                        try target_ctx.inbox.items[@intCast(curr_role)].pushBack(
                            gpa,
                            try gpa.dupe(u8, writer.buffered()),
                        );
                    }
                    try self.actions.pushBack(gpa, .{
                        .key = action.key,
                        .state_id = send.new_state_id,
                        .resume_from = .start,
                    });
                },
            }
        }
    }
};

test "RoleRunner" {
    const Prot = struct {
        //example
        const PingPong = enum { a, b };
        const Context = struct { a: u32, b: void };

        const Info = root.ProtocolInfo(
            "pingpong",
            PingPong,
            Context,
            &.{ .a, .b },
            &.{},
        );

        const Ping = union(enum) {
            ping: Data(void, Pong),
            next: Data(void, root.Exit),

            pub const info: Info =
                .{
                    .name = "Ping",
                    .sender = .a,
                    .receiver = &.{.b},
                };

            pub fn process(ctx: *info.Ctx(.a)) !@This() {
                if (ctx.* >= 10) {
                    return .{ .next = .{ .data = {} } };
                }
                ctx.* += 1;
                return .{ .ping = .{ .data = {} } };
            }
        };
        const Pong = union(enum) {
            pong: Data(void, Ping),

            pub const info: Info =
                .{
                    .name = "Pong",
                    .sender = .b,
                    .receiver = &.{.a},
                };

            pub fn process(_: *info.Ctx(.b)) !@This() {
                return .pong;
            }
        };
    };

    var ctx: Prot.Context = .{ .a = 0, .b = {} };
    var ctx1: Prot.Context = .{ .a = 0, .b = {} };
    const testing = std.testing;
    const allocator = testing.allocator;

    var scheduler: Prototype = undefined;
    scheduler.init(allocator);
    defer scheduler.deinit(allocator);

    const Codec = @import("Codec.zig");
    try scheduler.append_protocol(allocator, @fromBackingInt(0), 100, Codec, &ctx, Prot.Ping);
    try scheduler.append_protocol(allocator, @fromBackingInt(1), 100, Codec, &ctx1, Prot.Ping);

    try scheduler.run(allocator, Codec);

    try testing.expectEqual(ctx.a, 10);
    try testing.expectEqual(ctx1.a, 10);
}
