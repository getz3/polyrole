const std = @import("std");
const meta = std.meta;
pub const Graph = @import("Graph.zig");
pub const runner = @import("runner.zig");
pub const Runner = runner.Runner;

//The Exit status is unique.
pub const Exit = union(enum) {
    pub const info: Info = .{};

    pub const Info = struct {
        pub const ProtocolName = "polyrole_exit";
        pub const Role = void;
        pub const Context = void;
    };
};

//When switching protocols, all roles that were not in the previous protocol are notified and informed of the next status.
pub const Notify = struct { polyrole_notify: u32 };

pub fn Data(Data_: type, State_: type) type {
    return struct {
        data: Data_,

        pub const Data = Data_;
        pub const State = State_;
    };
}

pub fn ProtocolInfo(
    comptime ProtocolName_: []const u8,
    comptime Role_: type,
    comptime context_: anytype,
    comptime internal_roles_: []const Role_,
    comptime extern_state_: []const type,
) type {
    comptime {
        switch (@typeInfo(Role_)) {
            .@"enum" => |E| {
                for (E.field_names) |name| {
                    if (@hasField(@TypeOf(context_), name)) {} else {
                        @compileError(std.fmt.comptimePrint("{any} does not contain field {s}", .{ context_, name }));
                    }
                }
            },
            else => @compileError("Role only support enum!"),
        }
    }

    return struct {
        name: []const u8 = "Nameless",
        sender: Role_,
        receiver: []const Role_,

        pub const ProtocolName = ProtocolName_;
        pub const Role = Role_;
        pub const context = context_;
        pub const internal_roles: []const Role_ = internal_roles_;
        pub const extern_state: []const type = extern_state_;

        pub fn Ctx(_: @This(), r: Role_) type {
            return @field(context_, @tagName(r));
        }
    };
}

fn TypeSet(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count][]const type,

        const Self = @This();

        pub const init: Self = .{
            .buckets = @splat(&.{}),
        };

        pub fn insert(comptime self: *Self, comptime Type: type) void {
            comptime {
                const hash = std.hash_map.hashString(@typeName(Type));

                self.buckets[hash % bucket_count] = self.buckets[hash % bucket_count] ++ &[_]type{Type};
            }
        }

        pub fn has(comptime self: Self, comptime Type: type) bool {
            comptime {
                const hash = std.hash_map.hashString(@typeName(Type));

                return std.mem.indexOfScalar(type, self.buckets[hash % bucket_count], Type) != null;
            }
        }

        pub fn items(comptime self: Self) []const type {
            comptime {
                var res: []const type = &.{};

                for (&self.buckets) |bucket| {
                    res = res ++ bucket;
                }

                return res;
            }
        }
    };
}

pub fn reachableStates(comptime State: type) struct { states: []const type, state_machine_names: []const []const u8 } {
    comptime {
        var states: []const type = &.{State};
        var state_machine_names: []const []const u8 = &.{@TypeOf(State.info).ProtocolName};
        var states_stack: []const type = &.{State};
        var states_set: TypeSet(128) = .init;
        const ExpectedContext = @TypeOf(State.info).context;

        states_set.insert(State);

        reachableStatesDepthFirstSearch(&states, &state_machine_names, &states_stack, &states_set, ExpectedContext);

        return .{ .states = states, .state_machine_names = state_machine_names };
    }
}

fn reachableStatesDepthFirstSearch(
    comptime states: *[]const type,
    comptime state_machine_names: *[]const []const u8,
    comptime states_stack: *[]const type,
    comptime states_set: *TypeSet(128),
    comptime ExpectedContext: anytype, //Context type
) void {
    @setEvalBranchQuota(20_000_000);

    comptime {
        if (states_stack.len == 0) {
            return;
        }

        const CurrentState = states_stack.*[states_stack.len - 1];
        states_stack.* = states_stack.*[0 .. states_stack.len - 1];

        if (CurrentState != Exit) {
            const info = CurrentState.info;
            const Info = @TypeOf(CurrentState.info);
            const Role = Info.Role;
            const internal_roles = Info.internal_roles;

            //The sender must belong to internal_roles
            if (std.mem.indexOfScalar(Role, internal_roles, info.sender) == null) {
                @compileError(std.fmt.comptimePrint(
                    "{any}\nsender .{t} does not belog to internal_roles {any}",
                    .{ CurrentState, info.sender, internal_roles },
                ));
            }

            //The receivers must belong to internal_roles
            for (info.receiver) |role| {
                if (std.mem.indexOfScalar(Role, internal_roles, role) == null) {
                    @compileError(std.fmt.comptimePrint(
                        "{any}\nreceiver .{t} does not belog to internal_roles {any}",
                        .{ CurrentState, role, internal_roles },
                    ));
                }
            }

            //The receivers cannot contain the sender
            if (std.mem.indexOfScalar(Role, info.receiver, info.sender) != null) {
                @compileError(std.fmt.comptimePrint(
                    "{any}\nreceivers {any} contain sender .{t}",
                    .{ CurrentState, info.receiver, info.sender },
                ));
            }

            //The receivers cannot be empty
            // If the internal_roles len is 1, then the receiver can be empty;
            // this is for compatibility with polystate.
            if (Info.internal_roles.len > 1 and info.receiver.len == 0) {
                @compileError(std.fmt.comptimePrint(
                    "{any}\nreceivers is empty",
                    .{CurrentState},
                ));
            }

            //There cannot be duplicate roles in the receivers
            // this is for compatibility with polystate.
            if (Info.internal_roles.len > 1) {
                for (0..info.receiver.len - 1) |i| {
                    if (std.mem.indexOfScalar(Role, info.receiver[i + 1 ..], info.receiver[i]) != null) {
                        @compileError(std.fmt.comptimePrint(
                            "{any}\nthere are repeated characters in receivers {any}",
                            .{ CurrentState, info.receiver },
                        ));
                    }
                }
            }
            //If the state has a branch, then the conditions must be met: 1 + receivers.len = internal_roles.len
            if (@typeInfo(CurrentState).@"union".field_names.len > 1) {
                if (info.receiver.len + 1 != internal_roles.len) {
                    @compileError(std.fmt.comptimePrint(
                        "{any}\nIn branch State, {d} roles have not been notified",
                        .{ CurrentState, internal_roles.len - (info.receiver.len + 1) },
                    ));
                }
            }
        }

        switch (@typeInfo(CurrentState)) {
            .@"union" => |un| {
                for (un.field_types) |ty| {
                    const NextState = ty.State;

                    if (!states_set.has(NextState)) {
                        // Validate that the handler context type matches (skip for special states like Exit)
                        if (NextState != Exit) {
                            const Info = @TypeOf(NextState.info);
                            const NextContext = Info.context;
                            const Role = Info.Role;
                            const is_equal: bool = blk: {
                                for (@typeInfo(Role).@"enum".field_names) |name| {
                                    if (@field(NextContext, name) != @field(ExpectedContext, name)) {
                                        break :blk false;
                                    }
                                }
                                break :blk true;
                            };
                            if (!is_equal) {
                                @compileError(std.fmt.comptimePrint(
                                    "Context type mismatch: State {any}\nhas context type {any}\nbut expected {any}",
                                    .{ NextState, NextContext, ExpectedContext },
                                ));
                            }
                        }

                        states.* = states.* ++ &[_]type{NextState};
                        state_machine_names.* = state_machine_names.* ++ &[_][]const u8{@TypeOf(NextState.info).ProtocolName};
                        states_stack.* = states_stack.* ++ &[_]type{NextState};
                        states_set.insert(NextState);

                        reachableStatesDepthFirstSearch(states, state_machine_names, states_stack, states_set, ExpectedContext);
                    }
                }
            },
            else => @compileError("Only support tagged union!"),
        }
    }
}

pub const StateMap = struct {
    states: []const type,
    state_machine_names: []const []const u8,
    StateId: type,

    pub fn init(comptime State_: type) StateMap {
        @setEvalBranchQuota(200_000_000);

        comptime {
            const result = reachableStates(State_);
            const TagInt = std.math.IntFittingRange(0, result.states.len - 1);

            return .{
                .states = result.states,
                .state_machine_names = result.state_machine_names,
                .StateId = @Enum(
                    TagInt,
                    .exhaustive,
                    field_names: {
                        var names: [result.states.len][]const u8 = undefined;
                        for (result.states, 0..) |S, i| names[i] = @typeName(S);
                        break :field_names &names;
                    },
                    field_values: {
                        var values: [result.states.len]TagInt = undefined;
                        for (result.states, 0..) |_, i| values[i] = i;
                        break :field_values &values;
                    },
                ),
            };
        }
    }

    pub fn StateFromId(comptime self: StateMap, comptime state_id: self.StateId) type {
        return self.states[@backingInt(state_id)];
    }

    pub fn idFromState(comptime self: StateMap, comptime State: type) self.StateId {
        if (!@hasField(self.StateId, @typeName(State))) @compileError(std.fmt.comptimePrint(
            "Can't find State {s}",
            .{@typeName(State)},
        ));
        return @field(self.StateId, @typeName(State));
    }
};
