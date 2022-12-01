const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const core = @import("core.zig");
const TileGrid = core.TileGrid;
const Adjacencies = core.Adjacencies;
const Weight = core.Weight;

const strided_arrays = @import("strided-arrays");
const StridedArrayView = strided_arrays.StridedArrayView;

const Coord = TileGrid.Indices;
const Shape = TileGrid.Indices;
const TileIndex = core.TileIndex;

pub const TileInfo = struct {
    count: TileIndex,
    adjacencies: Adjacencies,
    map: []TileIndex,
    weight: []Weight,
    tiles: []TileGrid,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.map);
        allocator.free(self.weight);
        allocator.free(self.adjacencies.allowed_edges);
        for (self.tiles) |tile| {
            allocator.free(tile.items);
        }
        allocator.free(self.tiles);
        self.adjacencies = undefined;
        self.map = undefined;
        self.weight = undefined;
    }
};

fn extractTileAt(buf: []TileIndex, tile_grid: TileGrid, coord: Coord, size: u32) void {
    assert(buf.len >= size * size);
    var iter = tile_grid.iterateWrap(coord, .{ size, size });
    var i: usize = 0;
    while (iter.next()) |item| : (i += 1) {
        buf[i] = item;
    }
}

const Tile = struct {
    index: TileIndex,
    map_index: TileIndex,
    count: Weight,
};

//WARNING: depends on TileIndex = u8
const TilesMap = std.StringHashMap(Tile);

fn tilesCompatible(tile: TileGrid, other: TileGrid, direction: core.Direction) bool {
    std.debug.assert(tile.shape[0] == other.shape[0]);
    std.debug.assert(tile.shape[1] == other.shape[1]);
    const width = if (tile.shape[1] > 1) tile.shape[1] - 1 else 1;
    const height = if (tile.shape[0] > 1) tile.shape[0] - 1 else 1;
    const shape = Shape{ height, width };
    var sub_tile: TileGrid = undefined;
    var oth_tile: TileGrid = undefined;
    switch (direction) {
        .down => {
            sub_tile = tile.slice(.{ 1, 0 }, shape);
            oth_tile = other.slice(.{ 0, 0 }, shape);
        },
        .right => {
            sub_tile = tile.slice(.{ 0, 1 }, shape);
            oth_tile = other.slice(.{ 0, 0 }, shape);
        },
        .up => {
            sub_tile = tile.slice(.{ 0, 0 }, shape);
            oth_tile = other.slice(.{ 1, 0 }, shape);
        },
        .left => {
            sub_tile = tile.slice(.{ 0, 0 }, shape);
            oth_tile = other.slice(.{ 0, 1 }, shape);
        },
    }

    var same = true;
    var iter = sub_tile.iterate();
    while (iter.nextWithCoord()) |item| {
        same = same and item.val == oth_tile.get(item.coord);
    }
    return same;
}

fn buildAdjacency(adjacencies: Adjacencies, tiles: []TileGrid) void {
    for (tiles) |first, first_index| {
        for (tiles) |second, second_index| {
            for (core.directions) |direction| {
                if (tilesCompatible(first, second, direction)) {
                    adjacencies.set(@intCast(TileIndex, first_index), direction, @intCast(TileIndex, second_index));
                }
            }
        }
    }
}

/// caller own returned memory; call deinit() to free
pub fn overlappingTiles(allocator: Allocator, tile_grid: TileGrid, size: u32) !TileInfo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_a = arena.allocator();
    var tiles = TilesMap.init(arena_a);

    var tile_index: TileIndex = 0;

    var extracted_tiles = std.ArrayList(TileGrid).init(allocator);

    {
        var iter = tile_grid.iterate();
        while (iter.nextWithBoth()) |item| {
            const extract_buf = try allocator.alloc(TileIndex, size * size);
            extractTileAt(extract_buf, tile_grid, item.coord, size);

            const gop = try tiles.getOrPut(extract_buf);
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
                allocator.free(extract_buf);
            } else {
                gop.value_ptr.* = Tile{
                    .index = tile_index,
                    .count = 1,
                    .map_index = @intCast(TileIndex, item.index),
                };
                try extracted_tiles.append(TileGrid.ofSlicePacked(extract_buf, .{ size, size }) catch unreachable);
                tile_index += 1;
            }
        }
    }

    const count = std.math.cast(TileIndex, tiles.count()) orelse
        return error.TooManyUniqueTiles;

    const adjacencies = try core.Adjacencies.init(allocator, count);

    buildAdjacency(adjacencies, extracted_tiles.items);

    var map = try allocator.alloc(TileIndex, count);
    var weight = try allocator.alloc(Weight, count);

    var iter = tiles.valueIterator();
    while (iter.next()) |tile| {
        map[tile.index] = tile.map_index;
        weight[tile.index] = tile.count;
    }

    return TileInfo{
        .count = count,
        .adjacencies = adjacencies,
        .map = map,
        .weight = weight,
        .tiles = extracted_tiles.toOwnedSlice(),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "extractTileAt" {
    const allocator = std.testing.allocator;
    const tile_size: usize = 3;

    const grid_shape = Shape{ tile_size * 3, tile_size * 3 };
    const grid_size = TileGrid.sizeOf(grid_shape);

    const grid_buf = try allocator.alloc(TileIndex, grid_size);
    defer allocator.free(grid_buf);

    const grid = TileGrid.ofSlicePacked(grid_buf, grid_shape) catch unreachable;

    for (grid.items) |*tile_index, i| {
        tile_index.* = @intCast(TileIndex, i);
    }

    const tile_el_count = tile_size * tile_size;
    const tile_buf = try allocator.alloc(TileIndex, tile_el_count);
    defer allocator.free(tile_buf);

    {
        extractTileAt(tile_buf, grid, Coord{ 0, 0 }, 3);
        const expected = [tile_el_count]TileIndex{ 0, 1, 2, 9, 10, 11, 18, 19, 20 };
        try std.testing.expectEqualSlices(TileIndex, expected[0..], tile_buf);
    }
    {
        extractTileAt(tile_buf, grid, Coord{ 3, 4 }, 3);
        const expected = [tile_el_count]TileIndex{ 31, 32, 33, 40, 41, 42, 49, 50, 51 };
        try std.testing.expectEqualSlices(TileIndex, expected[0..], tile_buf);
    }
    {
        extractTileAt(tile_buf, grid, Coord{ 0, 8 }, 3);
        const expected = [tile_el_count]TileIndex{ 8, 0, 1, 17, 9, 10, 26, 18, 19 };
        try std.testing.expectEqualSlices(TileIndex, expected[0..], tile_buf);
    }
    {
        extractTileAt(tile_buf, grid, Coord{ 8, 0 }, 3);
        const expected = [tile_el_count]TileIndex{ 72, 73, 74, 0, 1, 2, 9, 10, 11 };
        try std.testing.expectEqualSlices(TileIndex, expected[0..], tile_buf);
    }
    {
        extractTileAt(tile_buf, grid, Coord{ 8, 8 }, 3);
        const expected = [tile_el_count]TileIndex{ 80, 72, 73, 8, 0, 1, 17, 9, 10 };
        try std.testing.expectEqualSlices(TileIndex, expected[0..], tile_buf);
    }
}
