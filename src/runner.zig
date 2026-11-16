const std = @import("std");
const meta = std.meta;
const root = @import("root.zig");
const StateMap = root.StateMap;
const Exit = root.Exit;
const Notify = root.Notify;
const Data = root.Data;

pub fn Runner(
    comptime State_: type,
) type {
    return struct {
        pub const Role = @TypeOf(State_.info).Role;
        pub const state_map: StateMap = .init(State_);
        pub const StateId = state_map.StateId;

        pub fn idFromState(comptime State: type) StateId {
            return state_map.idFromState(State);
        }

        pub fn StateFromId(comptime state_id: StateId) type {
            return state_map.StateFromId(state_id);
        }

        ///Runs every role of the protocol in a single thread, without any channel.
        ///The sender executes `process` to produce this round's message, then each
        ///receiver executes `preprocess_N` for its position in `receiver`, and the
        ///state machine advances until `Exit` is reached. Roles that take no part
        ///in the current state execute nothing, just like in `symmetric_run`.
        ///
        ///`Notify` plays no part here. `symmetric_run` uses it to tell the roles
        ///outside `internal_roles` which state to jump to when the protocol ends or
        ///hands over to an `extern_state`; here every role shares the same loop and
        ///the same `curr_id`, so that hand-over is simply the next iteration and no
        ///role is left waiting. What `simulate` drops is the notification, not the
        ///synchronization it stands for: it follows a single execution path, so it
        ///neither models who is waiting nor checks that every role reaches `Exit`.
        pub fn simulate(Ctx: type, context: *Ctx, curr_id: StateId) !void {
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (comptime State == Exit) return;

                    const info = comptime State.info;
                    const sender: Role = comptime info.sender;
                    const receiver: []const Role = comptime info.receiver;

                    comptime std.debug.assert(Ctx == @TypeOf(info).Context);

                    //The sender produces the message of this round.
                    const result = try State.process(&@field(context, @tagName(sender)));

                    //The receiver's handler function is chosen by its position in `receiver`,
                    //the same convention `symmetric_run` follows.
                    inline for (receiver, 0..) |recv_role, idx| {
                        const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                        if (@hasDecl(State, fn_name)) {
                            try @field(State, fn_name)(&@field(context, @tagName(recv_role)), result);
                        }
                    }

                    switch (result) {
                        inline else => |next| {
                            const NewState = @TypeOf(next).State;
                            continue :sw comptime idFromState(NewState);
                        },
                    }
                },
            }
        }

        pub fn symmetric_run(
            comptime curr_role: Role,
            ctx: *State_.info.Ctx(curr_role),
            channels: anytype,
            curr_id: StateId,
        ) !void {
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (comptime State == Exit) return;

                    const info = comptime State.info;
                    const sender: Role = comptime info.sender;
                    const receiver: []const Role = comptime info.receiver;
                    const internal_roles = comptime @TypeOf(info).internal_roles;
                    const extern_state = comptime @TypeOf(info).extern_state;

                    if (comptime std.mem.indexOfScalar(Role, internal_roles, curr_role) == null) {
                        //curr_role does not participate in the current protocol, so it waits for notification directly.
                        //The person who notifies it is determined to be `internal_role[0]`.
                        //The determinism here is very important.
                        //It ensures that the sender and receiver of the notification can be determined by the state machine.
                        const notify: Notify = try channels.recv(curr_role, internal_roles[0], state_id, Notify);

                        const next_state_id: StateId = @fromBackingInt(@intCast(notify.polyrole_notify));
                        continue :sw next_state_id;
                    } else if (comptime curr_role == sender) {
                        //The current role is the sender, which sends messages to all receivers.
                        const result = try State.process(ctx);
                        inline for (receiver) |recv_role| {
                            try channels.send(curr_role, recv_role, state_id, result);
                        }

                        switch (result) {
                            inline else => |next| {
                                const NewState = @TypeOf(next).State;
                                const notify_roles = comptime extern_targets(
                                    curr_role,
                                    NewState,
                                    internal_roles,
                                    extern_state,
                                );
                                for (notify_roles) |target_role| {
                                    try channels.send(curr_role, target_role, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
                                }
                                continue :sw comptime idFromState(NewState);
                            },
                        }
                    } else {
                        if (comptime std.mem.indexOfScalar(Role, receiver, curr_role)) |idx| {
                            //curr_role is the receiver
                            const result = try channels.recv(curr_role, sender, state_id, State);

                            //The receiver's handler function is called based on the receiver's position in `receiver`.
                            // This is a convention that needs to be met when writing code and provides type safety.
                            const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                            if (@hasDecl(State, fn_name)) {
                                try @field(State, fn_name)(ctx, result);
                            }

                            switch (result) {
                                inline else => |next| {
                                    const NewState = @TypeOf(next).State;
                                    const notify_roles = comptime extern_targets(
                                        curr_role,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                    );
                                    for (notify_roles) |target_role| {
                                        try channels.send(curr_role, target_role, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
                                    }
                                    continue :sw comptime idFromState(NewState);
                                },
                            }
                        } else {
                            switch (@typeInfo(State)) {
                                .@"union" => |U| {
                                    //The current round of communication for this protocol does not involve curr_role.
                                    // However, it still needs to check whether to notify external roles.
                                    comptime std.debug.assert(U.field_names.len == 1);
                                    const NewState = U.field_types[0].State;
                                    const notify_roles = comptime extern_targets(
                                        curr_role,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                    );
                                    for (notify_roles) |target_role| {
                                        try channels.send(curr_role, target_role, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
                                    }
                                    continue :sw comptime idFromState(NewState);
                                },
                                else => unreachable,
                            }
                        }
                    }
                },
            }
        }

        ///Builds a channel-free runner for one role: `run` decodes the
        ///state the scheduler hands it, runs one step, and returns a plain-data
        ///`Outcome` describing the messages that have to move.
        pub fn RoleRunner(
            comptime curr_role: Role,
            comptime Codec: type,
        ) type {
            const Ctx = State_.info.Ctx(curr_role);
            return struct {
                pub fn run(
                    context: *anyopaque,
                    buffer: []u8,
                    raw_state_id: u32,
                    resume_from: Resume,
                ) !Outcome {
                    @setEvalBranchQuota(10_000_000);
                    const curr_id: StateId = @fromBackingInt(@intCast(raw_state_id));
                    const ctx: *Ctx = @ptrCast(@alignCast(context));
                    switch (curr_id) {
                        inline else => |state_id| {
                            const State = StateFromId(state_id);
                            if (comptime State == Exit) return .{
                                .curr_id = raw_state_id,
                                .action = .done,
                            };

                            const info = comptime State.info;
                            const sender: Role = comptime info.sender;
                            const receiver: []const Role = comptime info.receiver;
                            const internal_roles = comptime @TypeOf(info).internal_roles;
                            const extern_state = comptime @TypeOf(info).extern_state;

                            switch (resume_from) {
                                .continue_recv => |received| {
                                    var reader = std.Io.Reader.fixed(received.payload);
                                    const result = try Codec.decode(&reader, state_id, State);
                                    const receiver_index = comptime std.mem.indexOfScalar(Role, receiver, curr_role) orelse 10000;
                                    const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{receiver_index});
                                    if (@hasDecl(State, fn_name)) {
                                        try @field(State, fn_name)(ctx, result);
                                    }
                                    switch (result) {
                                        inline else => |next| {
                                            const NewState = @TypeOf(next).State;
                                            const notify_roles = comptime extern_targets(
                                                curr_role,
                                                NewState,
                                                internal_roles,
                                                extern_state,
                                            );
                                            const new_state_id: u32 = @backingInt(idFromState(NewState));
                                            return .{ .curr_id = raw_state_id, .action = .{
                                                .send_notify = .{
                                                    .new_state_id = new_state_id,
                                                    .notify_roles = comptime roleIds(notify_roles),
                                                },
                                            } };
                                        },
                                    }
                                },
                                .start => {
                                    if (comptime std.mem.indexOfScalar(Role, internal_roles, curr_role) == null) {
                                        return .{
                                            .curr_id = raw_state_id,
                                            .action = .{ .recv_notify_from_role = @backingInt(internal_roles[0]) },
                                        };
                                    } else if (comptime curr_role == sender) {
                                        const result = try State.process(ctx);
                                        var writer = std.Io.Writer.fixed(buffer);
                                        try Codec.encode(&writer, state_id, result);
                                        switch (result) {
                                            inline else => |next| {
                                                const NewState = @TypeOf(next).State;
                                                const notify_roles = comptime extern_targets(
                                                    curr_role,
                                                    NewState,
                                                    internal_roles,
                                                    extern_state,
                                                );
                                                const new_state_id: u32 = @backingInt(idFromState(NewState));

                                                return .{ .curr_id = raw_state_id, .action = .{
                                                    .send_result = .{
                                                        .result = writer.buffered(),
                                                        .receiver_roles = comptime roleIds(receiver),
                                                        .new_state_id = new_state_id,
                                                        .notify_roles = comptime roleIds(notify_roles),
                                                    },
                                                } };
                                            },
                                        }
                                    } else {
                                        if (comptime std.mem.indexOfScalar(Role, receiver, curr_role)) |_| {
                                            return .{
                                                .curr_id = raw_state_id,
                                                .action = .{ .recv_result_from_role = @backingInt(sender) },
                                            };
                                        } else {
                                            switch (@typeInfo(State)) {
                                                .@"union" => |U| {
                                                    comptime std.debug.assert(U.field_names.len == 1);
                                                    const NewState = U.field_types[0].State;
                                                    const notify_roles = comptime extern_targets(
                                                        curr_role,
                                                        NewState,
                                                        internal_roles,
                                                        extern_state,
                                                    );
                                                    const new_state_id: u32 = @backingInt(idFromState(NewState));
                                                    return .{ .curr_id = raw_state_id, .action = .{
                                                        .send_notify = .{
                                                            .new_state_id = new_state_id,
                                                            .notify_roles = comptime roleIds(notify_roles),
                                                        },
                                                    } };
                                                },
                                                else => unreachable,
                                            }
                                        }
                                    }
                                },
                            }
                        },
                    }
                }
            };
        }

        ///Encodes a list of roles as their backing integers, which is the form
        ///the plain-data `Outcome` exposes to a scheduler.
        pub fn roleIds(comptime roles: []const Role) []const u32 {
            var ids: []const u32 = &.{};
            inline for (roles) |role| {
                ids = ids ++ &[_]u32{@backingInt(role)};
            }
            return ids;
        }

        fn extern_targets(
            comptime curr_role: Role,
            comptime NewState: type,
            comptime internal_roles: []const Role,
            comptime extern_state: []const type,
        ) []const Role {
            //Checks if the new state is an external state (or `Exit`, since the end of a protocol
            //must be synchronized too) and the current role is `internal_roles[0]`.
            if ((comptime std.mem.indexOfScalar(type, extern_state, NewState) != null or NewState == Exit) and
                curr_role == internal_roles[0])
            {
                //It turns out that all roles that do not belong to internal_roles must be notified.
                //This is equivalent to synchronizing the status once each protocol ends.
                var targets: []const Role = &.{};
                inline for (0..@typeInfo(Role).@"enum".field_names.len) |i| {
                    const role: Role = @fromBackingInt(@intCast(i));
                    if (comptime std.mem.indexOfScalar(Role, internal_roles, role) == null) {
                        targets = targets ++ &[_]Role{role};
                    }
                }
                return targets;
            }
            return &.{};
        }
    };
}

///One step of a role's state machine, as seen by the scheduler: the state the
///role was in, plus the messages it needs to send or receive next.
pub const Outcome = struct {
    curr_id: u32,
    action: union(enum) {
        done: void,
        recv_notify_from_role: u32,
        send_result: struct {
            result: []const u8,
            receiver_roles: []const u32,
            new_state_id: u32,
            notify_roles: []const u32,
        },
        recv_result_from_role: u32,
        send_notify: struct {
            new_state_id: u32,
            notify_roles: []const u32,
        },
    },

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.print("Outcome{{ curr_id: {d}, action: ", .{self.curr_id});
        switch (self.action) {
            .done => try w.writeAll("done"),
            .recv_notify_from_role => |role| try w.print("recv_notify_from_role({d})", .{role}),
            .recv_result_from_role => |role| try w.print("recv_result_from_role({d})", .{role}),
            .send_notify => |notify| try w.print("send_notify{{ new_state_id: {d}, notify_roles: {any} }}", .{ notify.new_state_id, notify.notify_roles }),
            .send_result => |send| {
                try w.print("send_result{{ receiver_roles: {any}, new_state_id: {d}, notify_roles: {any}, result: {d} bytes }}", .{
                    send.receiver_roles,
                    send.new_state_id,
                    send.notify_roles,
                    send.result.len,
                });
            },
        }
        try w.writeAll(" }");
    }
};

///Where a role's runner should pick up: a fresh state, or an already received
///payload that still needs decoding and preprocessing.
pub const Resume = union(enum) {
    start: void,
    continue_recv: struct {
        payload: []const u8,
    },
};

pub const ProtocolId = u32;
pub const Key = struct {
    pid: ProtocolId,
    role: u32,
};

///Cooperative scheduler: queues one `Action` per role and drains the queue,
///routing encoded messages between role inboxes.
pub const Scheduler = struct {
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
        key: Key,
        state_id: u32,
        resume_from: Resume,
    };

    pub const ProtocolMap = std.AutoHashMap(Key, RoleContext);

    pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
        self.protocols = .init(gpa);
        self.actions = .empty;
    }

    pub fn append_protocol(
        self: *@This(),
        gpa: std.mem.Allocator,
        pid: u32,
        buff_size: usize,
        Codec: type,
        ctx: anytype,
        EnterState: type,
    ) !void {
        const ProtocolRunner = Runner(EnterState);
        const start_id = ProtocolRunner.idFromState(EnterState);
        const Role: type = ProtocolRunner.Role;
        const len = @typeInfo(Role).@"enum".field_names.len;
        inline for (@typeInfo(Role).@"enum".field_names, 0..) |name, idx| {
            const RoleRun = ProtocolRunner.RoleRunner(@fromBackingInt(idx), Codec);
            var role_ctx: RoleContext = .{
                .context = &@field(ctx, name),
                .buffer = try gpa.alloc(u8, buff_size),
                .entry = &RoleRun.run,
                .inbox = try .initCapacity(gpa, len),
            };
            for (0..len) |_| {
                role_ctx.inbox.appendAssumeCapacity(.empty);
            }
            const key: Key = .{ .pid = pid, .role = @intCast(idx) };
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

        fn pingpong_info(
            StateName: []const u8,
            sender: PingPong,
            receiver: []const PingPong,
        ) root.ProtocolInfo(
            "pingpong",
            PingPong,
            Context,
            &.{ .a, .b },
            &.{root.Exit},
        ) {
            return .{
                .name = StateName,
                .sender = sender,
                .receiver = receiver,
            };
        }

        const Ping = union(enum) {
            ping: Data(void, Pong),
            next: Data(void, root.Exit),

            pub const info = pingpong_info("Ping", .a, &.{.b});

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

            pub const info = pingpong_info("Ping", .b, &.{.a});

            pub fn process(_: *info.Ctx(.b)) !@This() {
                return .pong;
            }
        };
    };

    var ctx: Prot.Context = .{ .a = 0, .b = {} };
    var ctx1: Prot.Context = .{ .a = 0, .b = {} };
    const testing = std.testing;
    const allocator = testing.allocator;

    var scheduler: Scheduler = undefined;
    scheduler.init(allocator);
    defer scheduler.deinit(allocator);

    const Codec = @import("Codec.zig");
    try scheduler.append_protocol(allocator, 0, 100, Codec, &ctx, Prot.Ping);
    try scheduler.append_protocol(allocator, 1, 100, Codec, &ctx1, Prot.Ping);

    try scheduler.run(allocator, Codec);

    try testing.expectEqual(ctx.a, 10);
    try testing.expectEqual(ctx1.a, 10);
}
