const std = @import("std");
const amity = @import("amity");
const mach = @import("mach").core;

pub const App = @This();

engine: amity.Engine,

pub fn init(app: *App) !void {
    try mach.init(.{});

    app.* = .{
        .engine = try amity.Engine.init(.{
            .renderer = true,
        }),
    };
}

pub fn deinit(app: *App) void {
    app.engine.deinit();
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

    return app.engine.update(mach.delta_time);
}
