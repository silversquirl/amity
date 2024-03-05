const std = @import("std");
const amity = @import("amity");
const mach = @import("mach").core;

pub const App = @This();

world: amity.World,
bench: ?Bench = null,

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
    if (app.bench) |*bench| {
        bench.data.append(mach.delta_time) catch {
            try app.printBenchResults();
            mach.setVSync(bench.vsync);
            app.bench = null;
        };
    } else {
        var events = mach.pollEvents();
        while (events.next()) |ev| {
            switch (ev) {
                .close => return true,
                .key_press => |key| switch (key.key) {
                    .m => app.world.mod.amity_renderer.state.deferred_render_mode.cycle(),
                    .v => {
                        const vsync: mach.VSyncMode = switch (mach.vsync()) {
                            .none => .triple,
                            else => .none,
                        };
                        mach.setVSync(vsync);
                        std.log.debug("vsync: {s}", .{@tagName(vsync)});
                    },

                    .b => {
                        // Run benchmark
                        app.bench = .{ .vsync = mach.vsync() };
                        mach.setVSync(.none);
                        std.log.info("Starting benchmark in {s} mode", .{
                            @tagName(app.world.mod.amity_renderer.state.deferred_render_mode),
                        });
                    },

                    else => {},
                },
                else => {},
            }
        }
    }

    try app.world.send(null, .tick, .{mach.delta_time});
    return false;
}

const Bench = struct {
    vsync: mach.VSyncMode,
    data: std.BoundedArray(f32, 10000) = .{},
};

fn printBenchResults(app: *App) !void {
    const data = app.bench.?.data.slice();
    std.sort.block(f32, data, {}, std.sort.asc(f32));

    const count: f32 = @floatFromInt(data.len);

    var mean: f32 = 0.0;
    for (data) |x| {
        mean += x;
    }
    mean /= count;

    var sdev: f32 = 0.0;
    for (data) |x| {
        const d = x - mean;
        sdev += d * d;
    }
    sdev = @sqrt(sdev / count);

    const iqr = data[data.len / 4 .. data.len * 3 / 4];
    var iqm: f32 = 0.0;
    for (iqr) |x| {
        iqm += x;
    }
    iqm /= @floatFromInt(iqr.len);

    const median = data[data.len / 2];

    std.debug.print("median: {d:.4}ms (σ={d:.4})\n", .{ median * 1000.0, sdev * 1000.0 });
    std.debug.print("mean: {d:.4}ms\n", .{mean * 1000.0});
    std.debug.print("interquartile mean: {d:.4}ms\n", .{iqm * 1000.0});

    var buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "bench_{s}.npy", .{
        @tagName(app.world.mod.amity_renderer.state.deferred_render_mode),
    });
    const f = try std.fs.cwd().createFile(filename, .{});
    defer f.close();

    var bw = std.io.bufferedWriter(f.writer());
    try @import("npy.zig").write(f32, bw.writer(), data, .{});
    try bw.flush();
}
