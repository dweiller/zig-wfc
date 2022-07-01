const std = @import("std");

const wfc = @import("wfc.zig");
const pnm = @import("pnm.zig");

const argsParser = @import("zig-args");

const arg_spec = struct {
    seed: usize = 0,
    size: u32 = 64,
    help: bool = false,
    pub const shorthands = .{
        .s = "seed",
        .o = "size",
        .h = "help",
    };
};

const ImOpts = struct {
    @"filter-size": u32 = 3,
    @"output-tiles": ?[]const u8 = null,
    pub const shorthands = .{
        .f = "filter-size",
        .t = "output-tiles",
    };
};

const verb_spec = union(enum) {
    @"test": struct {},
    image: ImOpts,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var options = argsParser.parseWithVerbForCurrentProcess(
        arg_spec,
        verb_spec,
        allocator,
        .print,
    ) catch printUsageAndExit();
    defer options.deinit();

    if (options.verb) |verb| {
        switch (verb) {
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
    options: arg_spec,
    im_opts: ImOpts,
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

    for (colour_map) |_, i| {
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
        for (tile_set.tiles) |tile, n| {
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

fn testMode(allocator: std.mem.Allocator, options: arg_spec) !void {
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
        var i: usize = 0;
        while (i < cols) : (i += 1) {
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
    var row: usize = 1;
    while (row < rows) : (row += 1) {
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
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            try stdout.print("─", .{});
        }
        try stdout.print("┘\n", .{});
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\    wfcgen test
        \\    wfcgen image [--filter-size=NUM] [--output-tiles=DIR] infile outfile
        \\
        \\General options:
        \\    -o, --size=[NUM]          the size of output (defaults to 64)
        \\    -s, --seed=[NUM]          the initial seed to use for generation (defaults to 0)
        \\
        \\Image options
        \\    --output-tiles=[DIR]      set to a directory to output extracted tiles
        \\    --filter-size=[NUM]       set the subtile size
        \\
    , .{});
}

fn printUsageAndExit() noreturn {
    printUsage();
    std.process.exit(1);
}
