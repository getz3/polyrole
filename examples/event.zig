const std = @import("std");
const xev = @import("xev");

const max_message = 256;

///A minimal libxev TCP round trip: a client connects to a local server, sends
///"ping", and the server answers "pong". Every callback only unpacks its result
///and calls `advance`, which keeps the flow in one place per side.
pub fn main(init: std.process.Init) !void {
    _ = init;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 12346);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var server = try Server.init(address);
    defer server.deinit();

    var client = try Client.init(address);
    defer client.deinit();

    server.start(&loop);
    client.start(&loop);

    try loop.run(.until_done);
}

const Server = struct {
    const State = enum { accepting, reading, writing, done };

    listening: xev.TCP,
    connection: ?xev.TCP = null,
    state: State = .accepting,
    completion: xev.Completion = .{},
    read_buf: [max_message]u8 = undefined,

    fn init(address: std.Io.net.IpAddress) !Server {
        const tcp = try xev.TCP.init(address);
        errdefer _ = std.posix.system.close(tcp.fd);

        try tcp.bind(address);
        try tcp.listen(1);

        return .{ .listening = tcp };
    }

    fn deinit(self: *Server) void {
        if (self.connection) |connection| _ = std.posix.system.close(connection.fd);
        _ = std.posix.system.close(self.listening.fd);
    }

    fn start(self: *Server, loop: *xev.Loop) void {
        self.advance(loop);
    }

    fn advance(self: *Server, loop: *xev.Loop) void {
        switch (self.state) {
            .accepting => self.listening.accept(loop, &self.completion, Server, self, onAccept),
            .reading => self.connection.?.read(loop, &self.completion, .{ .slice = &self.read_buf }, Server, self, onRead),
            .writing => self.connection.?.write(loop, &self.completion, .{ .slice = "pong\n" }, Server, self, onWrite),
            .done => {},
        }
    }

    fn finish(self: *Server, loop: *xev.Loop) xev.CallbackAction {
        self.state = .done;
        self.advance(loop);
        return .disarm;
    }

    fn fail(self: *Server, loop: *xev.Loop, what: []const u8, err: anyerror) xev.CallbackAction {
        std.debug.print("server {s} failed: {}\n", .{ what, err });
        return self.finish(loop);
    }

    fn onAccept(
        userdata: ?*Server,
        loop: *xev.Loop,
        _: *xev.Completion,
        result: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = userdata.?;
        self.connection = result catch |err| return self.fail(loop, "accept", err);

        self.state = .reading;
        self.advance(loop);
        return .disarm;
    }

    fn onRead(
        userdata: ?*Server,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = userdata.?;
        const read = result catch |err| return self.fail(loop, "read", err);
        if (read == 0) return self.finish(loop);

        std.debug.print("server received: {s}", .{self.read_buf[0..read]});

        self.state = .writing;
        self.advance(loop);
        return .disarm;
    }

    fn onWrite(
        userdata: ?*Server,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        result: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = userdata.?;
        const written = result catch |err| return self.fail(loop, "write", err);

        std.debug.print("server sent {d} bytes\n", .{written});
        return self.finish(loop);
    }
};

const Client = struct {
    const State = enum { connecting, writing, reading, done };

    address: std.Io.net.IpAddress,
    tcp: xev.TCP,
    state: State = .connecting,
    completion: xev.Completion = .{},
    read_buf: [max_message]u8 = undefined,

    fn init(address: std.Io.net.IpAddress) !Client {
        return .{ .address = address, .tcp = try xev.TCP.init(address) };
    }

    fn deinit(self: *Client) void {
        _ = std.posix.system.close(self.tcp.fd);
    }

    fn start(self: *Client, loop: *xev.Loop) void {
        self.advance(loop);
    }

    fn advance(self: *Client, loop: *xev.Loop) void {
        switch (self.state) {
            .connecting => self.tcp.connect(loop, &self.completion, self.address, Client, self, onConnect),
            .writing => self.tcp.write(loop, &self.completion, .{ .slice = "ping\n" }, Client, self, onWrite),
            .reading => self.tcp.read(loop, &self.completion, .{ .slice = &self.read_buf }, Client, self, onRead),
            .done => {},
        }
    }

    fn finish(self: *Client, loop: *xev.Loop) xev.CallbackAction {
        self.state = .done;
        self.advance(loop);
        return .disarm;
    }

    fn fail(self: *Client, loop: *xev.Loop, what: []const u8, err: anyerror) xev.CallbackAction {
        std.debug.print("client {s} failed: {}\n", .{ what, err });
        return self.finish(loop);
    }

    fn onConnect(
        userdata: ?*Client,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        result: xev.ConnectError!void,
    ) xev.CallbackAction {
        const self = userdata.?;
        result catch |err| return self.fail(loop, "connect", err);

        self.state = .writing;
        self.advance(loop);
        return .disarm;
    }

    fn onWrite(
        userdata: ?*Client,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        result: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = userdata.?;
        const written = result catch |err| return self.fail(loop, "write", err);

        std.debug.print("client sent {d} bytes\n", .{written});

        self.state = .reading;
        self.advance(loop);
        return .disarm;
    }

    fn onRead(
        userdata: ?*Client,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = userdata.?;
        const read = result catch |err| return self.fail(loop, "read", err);
        if (read == 0) return self.finish(loop);

        std.debug.print("client received: {s}", .{self.read_buf[0..read]});
        return self.finish(loop);
    }
};
