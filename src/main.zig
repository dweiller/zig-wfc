const std = @import("std");

const wfc = @import("wfc.zig");
const pnm = @import("pnm.zig");

const Mode = union(enum) {
    @"test",
    image: ImageOptions,
};

const GenericOptions = struct {
    seed: usize = 0,
    size: u32 = 64,
    help: bool = false,
};

const ImageOptions = struct {
    @"filter-size": u32 = 3,
    @"output-tiles": ?[]const u8 = null,
};

const Options = struct {
    options: GenericOptions,
    mode: ?Mode,
    positionals: []const []const u8,
};

fn parseCli(allocator: std.mem.Allocator) !Options {
    var args = try std.process.argsWithAllocator(allocator);
    std.debug.assert(args.skip());

    var options = GenericOptions{};
    var mode: ?Mode = null;

    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "--seed", arg) or std.mem.eql(u8, "-s", arg)) {
            options.seed = try std.fmt.parseInt(usize, args.next() orelse missingArg("seed"), 10);
        } else if (std.mem.eql(u8, "--size", arg) or std.mem.eql(u8, "-o", arg)) {
            options.size = try std.fmt.parseInt(u32, args.next() orelse missingArg("size"), 10);
        } else if (std.mem.eql(u8, "--help", arg) or std.mem.eql(u8, "-h", arg)) {
            options.help = true;
        } else if (std.mem.eql(u8, "image", arg)) {
            if (mode != null) unexpectedArg(arg);
            mode = .{ .image = .{} };
        } else if (std.mem.eql(u8, "test", arg)) {
            if (mode != null) unexpectedArg(arg);
            mode = .@"test";
        } else if (mode != null and mode.? == .image and std.mem.eql(u8, "--output-tiles", arg)) {
            const owned_arg = try allocator.dupe(u8, args.next() orelse missingArg("output-tiles"));
            mode.?.image.@"output-tiles" = owned_arg;
        } else if (mode != null and mode.? == .image and std.mem.eql(u8, "--filter-size", arg)) {
            const number_arg = args.next() orelse missingArg("filter-size");
            mode.?.image.@"filter-size" = try std.fmt.parseInt(u32, number_arg, 10,);
        } else {
            try positionals.append(try allocator.dupe(u8, arg));
        }
    }

    const result = Options{
        .options = options,
        .mode = mode,
        .positionals = try positionals.toOwnedSlice(),
    };
    return result;
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options = try parseCli(allocator);

    if (options.mode) |m| {
        switch (m) {
            .@"test" => try testMode(allocator, options.options),
            .image => |opts| {
                if (options.positionals.len != 2) {
                    std.debug.print("Error: 2 arguments expected\n", .{});
                    printUsageAndExit();
                }
                const in_filename = options.positionals[0];
                const out_filename = options.positionals[1];
                try imageMode(
                    allocator,
                    options.options,
                    opts,
                    in_filename,
                    out_filename,
                );
            },
        }
    } else if (options.options.help) {
        printUsage();
    }
}

const Input = struct {
    gen: wfc.GenInput,
    file: ?std.fs.File,
};

fn imageMode(
    allocator: std.mem.Allocator,
    options: GenericOptions,
    im_opts: ImageOptions,
    in_filename: []const u8,
    out_filename: []const u8,
) !void {
    const cwd = std.fs.cwd();
    const image = image: {
        const in_file = try cwd.openFile(in_filename, .{});
        defer in_file.close();
        break :image try pnm.readPNM(allocator, in_file.reader());
    };
    defer allocator.free(image.raster);

    const height = std.math.cast(u32, image.header.height) orelse return error.ImageSizeUnsupported;
    const width = std.math.cast(u32, image.header.width) orelse return error.ImageSizeUnsupported;
    const image_grid = try wfc.TileGrid.ofSlicePacked(image.raster, .{ height, width });

    var tile_set = try wfc.overlapping.overlappingTiles(allocator, image_grid, im_opts.@"filter-size");
    defer tile_set.deinit(allocator);
    const input = wfc.GenInput{
        .seed = options.seed,
        .tile_count = tile_set.count,
        .adjacency_rules = tile_set.adjacencies,
        .weights = tile_set.weight,
    };

    const tile_grid = try wfc.generateAlloc(allocator, allocator, input, .{ options.size, options.size }, 10);
    defer allocator.free(tile_grid.items);

    const colour_map = try allocator.alloc(u8, tile_set.count);
    defer allocator.free(colour_map);

    for (colour_map, 0..) |_, i| {
        colour_map[i] = image.raster[tile_set.map[i]];
    }

    const out_image = try pnm.ofGrid(allocator, colour_map, tile_grid);
    defer allocator.free(out_image.raster);

    if (im_opts.@"output-tiles") |dirname| {
        try cwd.makeDir(dirname);
        var dir = try cwd.openDir(dirname, .{});
        defer dir.close();

        const buf = try allocator.alloc(u8, out_filename.len + "-tile-xxx".len);
        defer allocator.free(buf);

        const ext_idx = std.mem.indexOfScalar(u8, out_filename, '.');
        for (tile_set.tiles, 0..) |tile, n| {
            const tile_image = pnm.PNM{
                .header = .{
                    .type = .PGM,
                    .width = tile.shape[1],
                    .height = tile.shape[0],
                    .max = 255,
                },
                .raster = tile.items,
            };

            const filename = if (ext_idx) |idx|
                try std.fmt.bufPrint(buf, "{s}-tile-{d:0>3}{s}", .{ out_filename[0..idx], n, out_filename[idx..] })
            else
                try std.fmt.bufPrint(buf, "{s}-tile-{d:0>3}", .{ out_filename, n });
            const file = try dir.createFile(filename, .{});
            defer file.close();

            try pnm.writePNM(file.writer(), tile_image);
        }

        const out_file = try dir.createFile(out_filename, .{});
        defer out_file.close();

        try pnm.writePNM(out_file.writer(), out_image);
    } else {
        const out_file = try cwd.createFile(out_filename, .{});
        defer out_file.close();

        try pnm.writePNM(out_file.writer(), out_image);
    }
}

fn testMode(allocator: std.mem.Allocator, options: GenericOptions) !void {
    const tile_count = 4;
    const tile_map = [tile_count][]const u8{ " ", "┃", "━", "╋" };
    var adj_0 = [1]wfc.TileSet{wfc.TileSet.initEmpty()} ** 4;
    adj_0[0].set(0);
    adj_0[0].set(2);
    adj_0[1].set(0);
    adj_0[1].set(1);
    adj_0[2].set(0);
    adj_0[2].set(2);
    adj_0[3].set(0);
    adj_0[3].set(1);
    var adj_1 = [1]wfc.TileSet{wfc.TileSet.initEmpty()} ** 4;
    adj_1[0].set(1);
    adj_1[0].set(3);
    adj_1[1].set(0);
    adj_1[2].set(1);
    adj_1[2].set(3);
    adj_1[3].set(0);
    var adj_2 = [1]wfc.TileSet{wfc.TileSet.initEmpty()} ** 4;
    adj_2[0].set(0);
    adj_2[1].set(2);
    adj_2[1].set(3);
    adj_2[2].set(0);
    adj_2[3].set(2);
    adj_2[3].set(3);
    var adj_3 = [1]wfc.TileSet{wfc.TileSet.initEmpty()} ** 4;
    adj_3[0].set(1);
    adj_3[1].set(2);
    adj_3[2].set(1);
    adj_3[3].set(2);
    var edges = [tile_count][4]wfc.TileSet{
        adj_0,
        adj_1,
        adj_2,
        adj_3,
    };

    const adjacency_rules = wfc.Adjacencies{ .allowed_edges = edges[0..] };

    var weights = [tile_count]wfc.Weight{ 1, 1, 1, 1 };

    const input = wfc.GenInput{
        .seed = options.seed,
        .tile_count = tile_count,
        .adjacency_rules = adjacency_rules,
        .weights = &weights,
    };
    const tile_grid = try wfc.generateAlloc(allocator, allocator, input, .{ options.size, options.size }, 10);
    defer allocator.free(tile_grid.items);

    try printGrid(tile_grid, tile_map[0..], options.size, options.size);
}

fn printGrid(tile_grid: wfc.TileGrid, tile_map: []const []const u8, rows: usize, cols: usize) !void {
    const stdout = std.io.getStdOut().writer();
    {
        try stdout.print("┌", .{});
        for (0..cols) |_| {
            try stdout.print("─", .{});
        }
        try stdout.print("┐\n", .{});
    }
    try stdout.print("│", .{});
    {
        var iter = tile_grid.iterateTo(cols);
        while (iter.next()) |tile_index| {
            try stdout.print("{s}", .{tile_map[tile_index]});
        }
    }
    try stdout.print("│\n", .{});
    for (0..rows) |row| {
        try stdout.print("│", .{});
        const row_start = row * cols;
        var iter = tile_grid.iterateRange(row_start, row_start + cols);
        while (iter.next()) |tile_index| {
            try stdout.print("{s}", .{tile_map[tile_index]});
        }
        try stdout.print("│\n", .{});
    }
    {
        try stdout.print("└", .{});
        for (0..cols) |_| {
            try stdout.print("─", .{});
        }
        try stdout.print("┘\n", .{});
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\    wfcgen test
        \\    wfcgen image [--filter-size NUM] [--output-tiles DIR] infile outfile
        \\
        \\General options:
        \\    -o, --size [NUM]          the size of output (defaults to 64)
        \\    -s, --seed [NUM]          the initial seed to use for generation (defaults to 0)
        \\
        \\Image options
        \\    --output-tiles [DIR]      set to a directory to output extracted tiles
        \\    --filter-size [NUM]       set the subtile size
        \\
    , .{});
}

fn printUsageAndExit() noreturn {
    printUsage();
    std.process.exit(1);
}

fn missingArg(param: []const u8) noreturn {
    std.debug.print("missing expected {s} parameter", .{param});
    printUsageAndExit();
}

fn unexpectedArg(param: []const u8) noreturn {
    std.debug.print("unexpected paramter: \"{s}\"", .{param});
    printUsageAndExit();
}
