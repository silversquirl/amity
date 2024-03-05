//! Simple Zig library to write NumPy .npy files
const std = @import("std");

pub const Options = struct {
    /// Shape of the array. Defaults to 1D array of the length of the slice.
    shape: ?[]const usize = null,
    orientation: Orientation = .row_major,
    endian: std.builtin.Endian = native_endian,
};
pub const Orientation = enum {
    row_major,
    column_major,
};

pub fn write(
    comptime T: type,
    w: anytype,
    data: []const T,
    opts: Options,
) !void {
    const shape = opts.shape orelse &.{data.len};
    if (opts.shape != null) {
        var size: usize = 1;
        for (shape) |s| {
            size *= s;
        }
        std.debug.assert(size == data.len);
    }

    try w.writeAll(magic);

    const offset = magic.len + 2;
    var buf: std.BoundedArray(u8, 8 * 64 - offset) = .{};
    try buf.writer().print("{{'descr':'{c}{c}{d}','fortran_order':{s},'shape':(", .{
        switch (opts.endian) {
            .little => @as(u8, '<'),
            .big => '>',
        },
        switch (@typeInfo(T)) {
            .Float => 'f',
            .Int => |i| if (i.signedness == .Unsigned) 'u' else 'i',
            else => @compileError("Expected float or int, got " ++ @typeName(T)),
        },
        @sizeOf(T),

        switch (opts.orientation) {
            .row_major => "False",
            .column_major => "True",
        },
    });

    for (shape) |s| {
        try buf.writer().print("{d},", .{s});
    }
    try buf.writer().writeAll(")}");

    // Pad header
    const target = std.mem.alignForward(usize, buf.len + 1 + offset, 64) - offset;
    buf.appendNTimesAssumeCapacity(' ', target - buf.len -| 1);
    try buf.append('\n');
    std.log.debug("expect: {}, got: {}", .{ target, buf.len });

    try w.writeInt(u16, buf.len, .little);
    try w.writeAll(buf.slice());

    for (data) |v| {
        const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
        try w.writeInt(UT, @bitCast(v), opts.endian);
    }
}

// NPY magic, followed by version number
const magic = "\x93NUMPY\x01\x00";

const native_endian = @import("builtin").cpu.arch.endian();
