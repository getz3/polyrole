const std = @import("std");
const meta = std.meta;
const root = @import("root.zig");
const StateMap = root.StateMap;
const Exit = root.Exit;
const Notify = root.Notify;

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

        pub fn symmetric_run(
            comptime curr_role: Role,
            comptime enter_fn: ?fn (*State_.info.Ctx(curr_role), type) void,
            comptime mult_channel_static_index_role: bool,
            mult_channel: anytype,
            curr_id: StateId,
            ctx: *State_.info.Ctx(curr_role),
        ) !void {
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (comptime State == Exit) return;

                    //if enter_fn exist, run it!
                    if (enter_fn) |fun| fun(ctx, State);

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
                        const notify: Notify =
                            if (mult_channel_static_index_role)
                                try @field(mult_channel, @tagName(internal_roles[0])).recv(state_id, Notify)
                            else
                                try mult_channel.recv(curr_role, internal_roles[0], state_id, Notify);

                        const next_state_id: StateId = @fromBackingInt(@intCast(notify.polyrole_notify));
                        continue :sw next_state_id;
                    } else if (comptime curr_role == sender) {
                        //The current role is the sender, which sends messages to all receivers.
                        const result = try State.process(ctx);
                        inline for (receiver) |rvr| {
                            if (mult_channel_static_index_role)
                                try @field(mult_channel, @tagName(rvr)).send(state_id, result)
                            else
                                try mult_channel.send(curr_role, rvr, state_id, result);
                        }
                        switch (result) {
                            inline else => |new_fsm_state_wit| {
                                const NewState = @TypeOf(new_fsm_state_wit).State;
                                try check_then_notify_extern_roles(
                                    curr_role,
                                    mult_channel_static_index_role,
                                    state_id,
                                    NewState,
                                    internal_roles,
                                    extern_state,
                                    mult_channel,
                                );
                                continue :sw comptime idFromState(NewState);
                            },
                        }
                    } else {
                        if (comptime std.mem.indexOfScalar(Role, receiver, curr_role)) |idx| {
                            //curr_role is the receiver
                            const result =
                                if (mult_channel_static_index_role)
                                    try @field(mult_channel, @tagName(sender)).recv(state_id, State)
                                else
                                    try mult_channel.recv(curr_role, sender, state_id, State);

                            //If the receiver needs to notify an external actor,
                            // it should do so as soon as possible,
                            // so that the external actor is notified before it executes its own handler function.
                            switch (result) {
                                inline else => |new_fsm_state_wit| {
                                    const NewState = @TypeOf(new_fsm_state_wit).State;
                                    try check_then_notify_extern_roles(
                                        curr_role,
                                        mult_channel_static_index_role,
                                        state_id,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                        mult_channel,
                                    );
                                },
                            }

                            //The receiver's handler function is called based on the receiver's position in `receiver`.
                            // This is a convention that needs to be met when writing code and provides type safety.
                            const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                            if (@hasDecl(State, fn_name)) {
                                try @field(State, fn_name)(ctx, result);
                            }

                            switch (result) {
                                inline else => |new_fsm_state_wit| {
                                    const NewState = @TypeOf(new_fsm_state_wit).State;
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
                                    try check_then_notify_extern_roles(
                                        curr_role,
                                        mult_channel_static_index_role,
                                        state_id,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                        mult_channel,
                                    );
                                    continue :sw comptime idFromState(NewState);
                                },
                                else => unreachable,
                            }
                        }
                    }
                },
            }
        }

        fn check_then_notify_extern_roles(
            comptime curr_role: Role,
            comptime mult_channel_static_index_role: bool,
            comptime state_id: StateId,
            comptime NewState: type,
            comptime internal_roles: []const Role,
            comptime extern_state: []const type,
            mult_channel: anytype,
        ) !void {
            //Checks if the new state is an external state (or `Exit`, since the end of a protocol
            //must be synchronized too) and the current role is `internal_roles[0]`.
            if ((comptime std.mem.indexOfScalar(type, extern_state, NewState) != null or NewState == Exit) and
                curr_role == internal_roles[0])
            {
                //It turns out that all roles that do not belong to internal_roles must be notified.
                //This is equivalent to synchronizing the status once each protocol ends.
                inline for (0..@typeInfo(Role).@"enum".field_names.len) |i| {
                    const role: Role = @fromBackingInt(@intCast(i));
                    if (comptime std.mem.indexOfScalar(Role, internal_roles, role) == null) {
                        if (mult_channel_static_index_role)
                            try @field(mult_channel, @tagName(role)).send(state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) })
                        else
                            try mult_channel.send(curr_role, role, state_id, Notify{ .polyrole_notify = @backingInt(idFromState(NewState)) });
                    }
                }
            }
        }
    };
}
