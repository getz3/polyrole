const std = @import("std");
const polyrole = @import("root.zig");

arena: std.heap.ArenaAllocator,
name: []const u8,
clusters: ProtocolClusterMap,
edges: std.ArrayListUnmanaged(Edge),

const Graph = @This();

///All states that belong to one protocol, rendered as one subgraph.
const ProtocolCluster = struct {
    label: []const u8,
    nodes: std.ArrayList(Node),
};

const ProtocolClusterMap = std.AutoHashMap(u64, ProtocolCluster);

const colors: []const []const u8 = &.{
    "red",       "green",    "blue",
    "brown",     "navy",     "teal",
    "cyan",      "magenta",  "darkred",
    "darkgreen", "darkblue", "orange",
    "purple",
};

pub const Node = struct {
    state_description: []const u8,
    id: u32,
    sender: []const u8,
};

pub const Edge = struct {
    from: u32,
    to: u32,
    label: []const u8,
};

pub fn generateDot(
    self: @This(),
    writer: anytype,
) !void {
    try writer.writeAll(
        \\digraph fsm_state_graph {
        \\
    );

    { //state graph
        try writer.writeAll(
            \\  subgraph cluster_transitions {
            \\    label = "State Transitions";
            \\
        );

        var cluster_iter = self.clusters.iterator();
        while (cluster_iter.next()) |entry| {
            const cluster_id = entry.key_ptr.*;
            const cluster = entry.value_ptr;

            // Start new subgraph
            try writer.print(
                \\    subgraph cluster_fsm_{d} {{
                \\      label = "{s}";
                \\
            , .{ cluster_id, cluster.label });

            for (cluster.nodes.items) |node| {
                // Add the state to its protocol cluster
                try writer.print(
                    \\      {d}[shape=rect,  label="[{d}] {s}", color = "{s}"];
                    \\
                ,
                    .{
                        node.id,
                        node.id,
                        node.state_description,
                        colors[@as(usize, @intCast(node.id)) % colors.len],
                    },
                );
            }

            try writer.writeAll(
                \\    }
                \\
            );
        }

        // Add edges
        for (self.edges.items) |edge| {
            try writer.print(
                \\    {d} -> {d} [label = "{s}", color = "{s}", fontcolor = "{s}"];
                \\
            , .{
                edge.from,
                edge.to,
                edge.label,
                colors[@as(usize, @intCast(edge.from)) % colors.len],
                colors[@as(usize, @intCast(edge.from)) % colors.len],
            });
        }

        try writer.writeAll(
            \\  }
            \\
        );
    }

    try writer.writeAll(
        \\}
        \\
    );

    try writer.flush();
}

pub fn initWithFsm(allocator: std.mem.Allocator, comptime State_: type) !Graph {
    @setEvalBranchQuota(2000000);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    var clusters: ProtocolClusterMap = .init(arena_allocator);
    var edges: std.ArrayListUnmanaged(Edge) = .empty;

    const state_map: polyrole.StateMap = comptime .init(State_);

    inline for (state_map.states, 0..) |State, state_idx| {
        const info_type_name = @typeName(@TypeOf(State.info));
        const cluster_key = std.hash_map.hashString(info_type_name);
        const node: Node = .{
            .state_description = if (State == polyrole.Exit) "Exit" else try std.fmt.allocPrint(
                arena_allocator,
                "{s} .{t} -> {any}",
                .{ State.info.name, State.info.sender, State.info.receiver },
            ),
            .id = @intCast(state_idx),
            .sender = if (State == polyrole.Exit) "" else try std.fmt.allocPrint(arena_allocator, "{t}", .{State.info.sender}),
        };

        if (clusters.getPtr(cluster_key)) |cluster| {
            try cluster.nodes.append(arena_allocator, node);
        } else {
            var cluster_nodes: std.ArrayList(Node) = .empty;
            try cluster_nodes.append(arena_allocator, node);

            const protocol_name = @TypeOf(State.info).ProtocolName;
            try clusters.put(cluster_key, .{
                .label = if (State == polyrole.Exit) protocol_name else try std.fmt.allocPrint(
                    arena_allocator,
                    "{s}: {any}",
                    .{ protocol_name, @TypeOf(State.info).internal_roles },
                ),
                .nodes = cluster_nodes,
            });
        }

        switch (@typeInfo(State)) {
            .@"union" => |un| {
                inline for (un.field_types, un.field_names) |ty, name| {
                    const NextState = ty.State;

                    const next_state_idx: u32 = @backingInt(state_map.idFromState(NextState));

                    try edges.append(arena_allocator, .{
                        .from = @intCast(state_idx),
                        .to = next_state_idx,
                        .label = name,
                    });
                }
            },
            else => @compileError("Only support tagged union!"),
        }
    }

    return .{
        .arena = arena,
        .edges = edges,
        .name = @TypeOf(State_.info).ProtocolName,
        .clusters = clusters,
    };
}

pub fn deinit(self: *Graph) void {
    self.arena.deinit();
}
