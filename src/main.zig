const std = @import("std");
const amity = @import("amity");
const mach = @import("mach").core;

pub const App = @This();

world: amity.World,

pub fn init(app: *App) !void {
    try mach.init(.{});

    var world = try amity.World.init(mach.allocator);
    try world.send(null, .init, .{});
    app.* = .{ .world = world };
}

pub fn deinit(app: *App) void {
    app.world.send(null, .deinit, .{}) catch @compileError("deinit may not error");
    app.world.deinit();
    mach.deinit();
}

pub fn update(app: *App) !bool {
    var events = mach.pollEvents();
    while (events.next()) |ev| {
        switch (ev) {
            .close => return true,
            else => {},
        }
    }

    try app.world.send(null, .tick, .{mach.delta_time});
    return false;
}
