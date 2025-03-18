const std = @import("std");
const core = @import("core.zig");

const strided_arrays = @import("strided-arrays");
const StridedArrayView = strided_arrays.StridedArrayView;

const Allocator = std.mem.Allocator;

pub const GridImage = struct {
    tile_grid: core.TileGrid,
    max: usize,
};

const Error = error{
    BadMagic,
    MissingWhitespace,
    MaxUnsupported,
};

const Type = enum {
    PGM,
    PPM,

    pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        if (fmt.len == 0 or comptime std.mem.eql(u8, fmt, "s")) {
            const magic = switch (value) {
                .PGM => "P5",
                .PPM => "P6",
            };
            try std.fmt.format(writer, "{s}", .{magic});
        } else {
            @compileError("Unknown format specifier '" ++ fmt ++ "'");
        }
    }
};

pub const Header = struct {
    type: Type,
    width: usize,
    height: usize,
    max: u8,
};

pub const PNM = struct {
    header: Header,
    raster: []u8,
};

pub fn readPNM(allocator: Allocator, reader: anytype) !PNM {
    const bytes = try reader.readAllAlloc(allocator, 4096);
    defer allocator.free(bytes);

    const typ: Type = if (std.mem.eql(u8, bytes[0..2], "P5"))
        .PGM
    else if (std.mem.eql(u8, bytes[0..2], "P6"))
        .PPM
    else
        return Error.BadMagic;

    var index: usize = 2;

    skip(&index, bytes);
    const width = try readNumber(&index, bytes);
    skip(&index, bytes);
    const height = try readNumber(&index, bytes);
    skip(&index, bytes);
    const max_raw = try readNumber(&index, bytes);
    const max = std.math.cast(u8, max_raw) orelse
        return Error.MaxUnsupported;
    if (isWhitespace(bytes[index])) {
        index += 1;
    } else {
        return Error.MissingWhitespace;
    }

    const buf = try allocator.alloc(u8, width * height);
    const pixel_data = bytes[index..][0..buf.len];
    @memcpy(buf, pixel_data);

    return PNM{
        .header = .{
            .type = typ,
            .width = width,
            .height = height,
            .max = max,
        },
        .raster = buf,
    };
}

inline fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\n' or char == '\t' or char == '\r';
}

fn skipWhitespace(index: *usize, bytes: []const u8) void {
    while (isWhitespace(bytes[index.*])) : (index.* += 1) {}
}

fn skipRestOfLine(index: *usize, bytes: []const u8) void {
    while (bytes[index.*] != '\n') : (index.* += 1) {}
}

fn skip(index: *usize, bytes: []const u8) void {
    const last_index: usize = 0;
    while (!isDigit(bytes[index.*]) and last_index != index.*) {
        skipWhitespace(index, bytes);
        if (bytes[index.*] == '#')
            skipRestOfLine(index, bytes);
    }
}

fn isDigit(char: u8) bool {
    return switch (char) {
        '0'...'9' => true,
        else => false,
    };
}

fn readNumber(index: *usize, bytes: []const u8) !usize {
    const start = index.*;
    while (isDigit(bytes[index.*])) : (index.* += 1) {}
    return try std.fmt.parseInt(usize, bytes[start..index.*], 10);
}

pub fn writePNM(writer: anytype, pnm: PNM) !void {
    try writer.print("{[type]s}\n{[width]d} {[height]d}\n{[max]d}\n", pnm.header);
    try writer.writeAll(pnm.raster);
}

pub fn ofGrid(allocator: Allocator, colour_map: anytype, grid: core.TileGrid) !PNM {
    const MapType = @TypeOf(colour_map);
    const err_msg = "Colour map must have type []const u8 or []const [3]u8, got " ++ @typeName(MapType);
    const typ = switch (@typeInfo(MapType)) {
        .pointer => |info| switch (info.size) {
            .slice => switch (info.child) {
                u8 => Type.PGM,
                [3]u8 => Type.PPM,
                else => @compileError(err_msg),
            },
            else => @compileError(err_msg),
        },
        else => @compileError(err_msg),
    };

    const buf = try allocator.alloc(switch (typ) {
        .PGM => u8,
        .PPM => [3]u8,
    }, grid.size());

    {
        var iter = grid.iterate();
        while (iter.nextWithIndex()) |item_ind| {
            buf[item_ind.index] = colour_map[item_ind.val];
        }
    }

    const header = Header{
        .type = typ,
        .width = grid.shape[1],
        .height = grid.shape[0],
        .max = 255,
    };

    return PNM{
        .header = header,
        .raster = buf,
    };
}
