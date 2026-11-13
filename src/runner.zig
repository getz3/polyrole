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
                    inline for (receiver, 0..) |rvr, idx| {
                        const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                        if (@hasDecl(State, fn_name)) {
                            try @field(State, fn_name)(&@field(context, @tagName(rvr)), result);
                        }
                    }

                    switch (result) {
                        inline else => |new_fsm_state_wit| {
                            const NewState = @TypeOf(new_fsm_state_wit).State;
                            continue :sw comptime idFromState(NewState);
                        },
                    }
                },
            }
        }

        pub fn ccc(comptime roles: []const Role) []const u32 {
            var tmp: []const u32 = &.{};
            inline for (roles) |r| {
                tmp = tmp ++ &[_]u32{@as(u32, @intCast(@backingInt(r)))};
            }
            return tmp;
        }

        pub const Return = struct {
            curr_id: u32,
            point: union(enum) {
                done: void,
                recv_notify: u32, //from some role
                send_result: struct {
                    result: []const u8,
                    receiver_roles: []const u32,
                    new_state_id: u32,
                    notify_roles: []const u32,
                },
                recv_result: struct {
                    from: u32, //from some role
                    idx: u8, //idx
                },
                send_notify: struct {
                    new_state_id: u32,
                    notify_roles: []const u32,
                },
            },

            pub fn format(self: @This(), w: *std.Io.Writer) !void {
                try w.print("\ncurr_id: {d}\n", .{self.curr_id});
                try w.print("\npoint\n: {any}\n", .{self.point});
            }
        };
        pub const EnterPoint = union(enum) {
            start: void,
            continue_recv: struct {
                result_str: []const u8,
                idx: u8,
            },
        };

        pub fn MakeRunner(
            comptime curr_role: Role,
            comptime Codec: type,
        ) type {
            const Ctx = State_.info.Ctx(curr_role);
            return struct {
                pub fn symmetric_run(
                    ctx_: *anyopaque,
                    curr_id_: u32,
                    buff: []u8,
                    enter_point: *EnterPoint,
                ) !Return {
                    @setEvalBranchQuota(10_000_000);
                    const curr_id: StateId = @fromBackingInt(@intCast(curr_id_));
                    const ctx: *Ctx = @ptrCast(@alignCast(ctx_));
                    switch (curr_id) {
                        inline else => |state_id| {
                            const State = StateFromId(state_id);
                            if (comptime State == Exit) return .{
                                .curr_id = curr_id_,
                                .point = .done,
                            };

                            const info = comptime State.info;
                            const sender: Role = comptime info.sender;
                            const receiver: []const Role = comptime info.receiver;
                            const internal_roles = comptime @TypeOf(info).internal_roles;
                            const extern_state = comptime @TypeOf(info).extern_state;

                            switch (enter_point.*) {
                                .continue_recv => |continue_value| {
                                    var reader = std.Io.Reader.fixed(continue_value.result_str);

                                    const result = try Codec.decode(&reader, state_id, State);

                                    switch (continue_value.idx) {
                                        inline else => |idx| {
                                            //The receiver's handler function is called based on the receiver's position in `receiver`.
                                            // This is a convention that needs to be met when writing code and provides type safety.
                                            const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                                            if (@hasDecl(State, fn_name)) {
                                                try @field(State, fn_name)(ctx, result);
                                            }
                                            switch (result) {
                                                inline else => |new_fsm_state_wit| {
                                                    const NewState = @TypeOf(new_fsm_state_wit).State;
                                                    const roles = comptime extern_targets(
                                                        curr_role,
                                                        NewState,
                                                        internal_roles,
                                                        extern_state,
                                                    );
                                                    const nid: u32 = @backingInt(idFromState(NewState));
                                                    return .{ .curr_id = curr_id_, .point = .{
                                                        .send_notify = .{
                                                            .new_state_id = nid,
                                                            .notify_roles = comptime ccc(roles),
                                                        },
                                                    } };
                                                },
                                            }
                                        },
                                    }
                                },
                                .start => {
                                    if (comptime std.mem.indexOfScalar(Role, internal_roles, curr_role) == null) {
                                        //curr_role does not participate in the current protocol, so it waits for notification directly.
                                        //The person who notifies it is determined to be `internal_role[0]`.
                                        //The determinism here is very important.
                                        //It ensures that the sender and receiver of the notification can be determined by the state machine.

                                        //P0
                                        return .{
                                            .curr_id = curr_id_,
                                            .point = .{ .recv_notify = @intCast(@backingInt(internal_roles[0])) },
                                        };
                                    } else if (comptime curr_role == sender) {
                                        //The current role is the sender, which sends messages to all receivers.
                                        const result = try State.process(ctx);
                                        var writer = std.Io.Writer.fixed(buff);
                                        try Codec.encode(&writer, state_id, result);

                                        switch (result) {
                                            inline else => |new_fsm_state_wit| {
                                                const NewState = @TypeOf(new_fsm_state_wit).State;
                                                const roles = comptime extern_targets(
                                                    curr_role,
                                                    NewState,
                                                    internal_roles,
                                                    extern_state,
                                                );
                                                const nid: u32 = @backingInt(idFromState(NewState));

                                                return .{ .curr_id = curr_id_, .point = .{
                                                    .send_result = .{
                                                        .result = writer.buffered(),
                                                        .receiver_roles = comptime ccc(receiver),
                                                        .new_state_id = nid,
                                                        .notify_roles = comptime ccc(roles),
                                                    },
                                                } };
                                            },
                                        }
                                    } else {
                                        if (comptime std.mem.indexOfScalar(Role, receiver, curr_role)) |idx| {
                                            //curr_role is the receiver
                                            return .{
                                                .curr_id = curr_id_,
                                                .point = .{
                                                    .recv_result = .{
                                                        .from = @intCast(@backingInt(sender)),
                                                        .idx = @intCast(idx),
                                                    },
                                                },
                                            };
                                        } else {
                                            switch (@typeInfo(State)) {
                                                .@"union" => |U| {
                                                    //The current round of communication for this protocol does not involve curr_role.
                                                    // However, it still needs to check whether to notify external roles.
                                                    comptime std.debug.assert(U.field_names.len == 1);
                                                    const NewState = U.field_types[0].State;
                                                    const roles = comptime extern_targets(
                                                        curr_role,
                                                        NewState,
                                                        internal_roles,
                                                        extern_state,
                                                    );

                                                    const nid: u32 = @backingInt(idFromState(NewState));

                                                    return .{ .curr_id = curr_id_, .point = .{
                                                        .send_result = .{
                                                            .new_state_id = nid,
                                                            .notify_roles = roles,
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
                        inline for (receiver) |rvr| {
                            try channels.send(curr_role, rvr, state_id, result);
                        }

                        switch (result) {
                            inline else => |new_fsm_state_wit| {
                                const NewState = @TypeOf(new_fsm_state_wit).State;
                                const roles = comptime extern_targets(
                                    curr_role,
                                    NewState,
                                    internal_roles,
                                    extern_state,
                                );
                                for (roles) |ro| {
                                    try channels.send(curr_role, ro, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
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
                                inline else => |new_fsm_state_wit| {
                                    const NewState = @TypeOf(new_fsm_state_wit).State;
                                    const roles = comptime extern_targets(
                                        curr_role,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                    );
                                    for (roles) |ro| {
                                        try channels.send(curr_role, ro, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
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
                                    const roles = comptime extern_targets(
                                        curr_role,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                    );
                                    for (roles) |ro| {
                                        try channels.send(curr_role, ro, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
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

const PingPong = enum { a, b };
const PingPongContext = struct { a: u32, b: void };

fn pingpogn_info(
    StateName: []const u8,
    sender: PingPong,
    receiver: []const PingPong,
) root.ProtocolInfo(
    "pingpong",
    PingPong,
    PingPongContext,
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

    pub const info = pingpogn_info("Ping", .a, &.{.b});

    pub fn process(ctx: *info.Ctx(.a)) !@This() {
        std.debug.print("val: {d}\n", .{ctx.*});
        if (ctx.* >= 0) {
            return .{ .next = .{ .data = {} } };
        }
        ctx.* += 1;
        return .{ .ping = .{ .data = {} } };
    }
};
const Pong = union(enum) {
    pong: Data(void, Ping),

    pub const info = pingpogn_info("Ping", .b, &.{.a});

    pub fn process(_: *info.Ctx(.b)) !@This() {
        return .pong;
    }
};

test "MakeRunner" {
    var ctx: PingPongContext = .{ .a = 0, .b = {} };

    const PingPongRunner = Runner(Ping);

    try PingPongRunner.simulate(PingPongContext, &ctx, PingPongRunner.idFromState(Ping));

    const Codec = @import("Codec.zig");

    const ASuspendRunner = PingPongRunner.MakeRunner(.a, Codec);
    const BSuspendRunner = PingPongRunner.MakeRunner(.b, Codec);
    var buff: [100]u8 = undefined;
    var ep: PingPongRunner.EnterPoint = .start;
    const result = try ASuspendRunner.symmetric_run(
        &ctx.a,
        @intCast(@backingInt(PingPongRunner.idFromState(Ping))),
        &buff,
        &ep,
    );

    const result1 = try BSuspendRunner.symmetric_run(
        &ctx.b,
        @intCast(@backingInt(PingPongRunner.idFromState(Ping))),
        &buff,
        &ep,
    );

    ep = .{ .continue_recv = .{ .idx = 0, .result_str = result.point.send_result.result } };
    const result2 = try BSuspendRunner.symmetric_run(
        &ctx.b,
        @intCast(@backingInt(PingPongRunner.idFromState(Ping))),
        &buff,
        &ep,
    );

    std.debug.print("a, result: {f}\n", .{result});
    std.debug.print("b, result: {f}\n", .{result1});
    std.debug.print("b, result: {f}\n", .{result2});
}
