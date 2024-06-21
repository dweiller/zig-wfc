const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const constraint = @import("constraint.zig");

const strided_arrays = @import("strided-arrays");
const StridedArrayView = strided_arrays.StridedArrayView;

const log = std.log.scoped(.@"zig-wfc");

const shape_dims = 2;

// up to 256 different tile types
pub const TileIndex = u8;
pub const Weight = u8;

pub const TileGrid = StridedArrayView(TileIndex, 2);
const Shape = TileGrid.Indices;
pub const Coord = TileGrid.Indices;

pub const Error = error{ OutOfMemory, Contradiction };

pub const SeedGrid = StridedArrayView(Cell.State, 2);

pub fn initSeedGrid(allocator: Allocator, shape: Shape) !SeedGrid {
    const buf = try allocator.alloc(Cell.State, SeedGrid.sizeOf(shape));
    return SeedGrid.ofSlicePacked(buf, shape) catch unreachable;
}

pub const CellGrid = struct {
    cells: CellArray,
    enabler_data: []EnablerCounts,

    const CellArray = StridedArrayView(Cell, 2);

    /// Initialise a CellGrid
    /// The state of cells in the grid is undefined and must be set by the caller before use
    pub fn init(
        allocator: Allocator,
        tile_count: TileIndex,
        shape: Shape,
    ) error{OutOfMemory}!CellGrid {
        const num_elts = CellArray.sizeOf(shape);

        const cell_buf = try allocator.alloc(Cell, num_elts);
        errdefer allocator.free(cell_buf);
        const enabler_data = try allocator.alloc(EnablerCounts, tile_count * num_elts);

        var cells = CellArray.ofSlicePacked(cell_buf, shape) catch unreachable;
        var iter = cells.iterate();
        while (iter.nextPtrWithIndex()) |item| {
            const start = item.index * tile_count;
            item.ptr.enablers = enabler_data[start..][0..tile_count];
        }
        return CellGrid{
            .cells = cells,
            .enabler_data = enabler_data,
        };
    }

    /// Initialise a cell grid with all cells a superposition of all tiles
    pub fn initFull(
        allocator: Allocator,
        input: GenInput,
        shape: Shape,
    ) error{OutOfMemory}!CellGrid {
        const cell_grid = try init(allocator, input.tile_count, shape);

        var initial_state = Cell.State{ .superposition = TileSet.initEmpty() };
        {
            for (0..input.tile_count) |i| {
                initial_state.superposition.set(i);
            }
        }

        var iter = cell_grid.cells.iterate();
        while (iter.nextPtrWithIndex()) |item| {
            item.ptr.state = initial_state;
        }

        // TODO: calculate enablers once, should be the same for all cells
        var iter2 = cell_grid.cells.iterate();
        while (iter2.next()) |cell| {
            for (cell.enablers, 0..) |*tile_enabler, i| {
                const tile_index: TileIndex = @intCast(i);
                for (directions) |direction| {
                    var count: TileIndex = 0;
                    var adj_iter = input.adjacency_rules.get(tile_index, direction).iterator(.{});
                    while (adj_iter.next()) |_| {
                        count += 1;
                    }
                    tile_enabler.set(direction, count);
                }
            }
        }
        return cell_grid;
    }

    pub fn initSeeded(
        allocator: Allocator,
        input: GenInput,
        seed_array: SeedGrid,
    ) Error!CellGrid {
        const shape = seed_array.shape;

        var cell_grid = try init(allocator, input.tile_count, shape);
        errdefer cell_grid.deinit(allocator);

        var iter = cell_grid.cells.iterate();
        while (iter.nextPtrWithCoord()) |item| {
            item.ptr.state = seed_array.get(item.coord);
        }

        try initEnablersSeeded(allocator, cell_grid.cells, input.adjacency_rules);

        return cell_grid;
    }

    fn initEnablersSeeded(allocator: Allocator, cells: CellArray, adjacency: Adjacencies) !void {
        {
            var iter = cells.iterate();
            while (iter.nextWithCoord()) |entry| {
                for (entry.val.enablers, 0..) |*tile_enabler, i| {
                    const tile_index: TileIndex = @intCast(i);
                    for (directions) |direction| {
                        if (neighbouringCell(cells, entry.coord, direction, cells.shape)) |neighbour| {
                            var count: TileIndex = 0;
                            var adj_iter = adjacency.get(tile_index, direction).iterator(.{});
                            while (adj_iter.next()) |enabling_index| {
                                switch (neighbour.state) {
                                    .superposition => |possible| {
                                        if (possible.isSet(enabling_index)) {
                                            count += 1;
                                        }
                                    },
                                    .collapsed => |neighbour_index| {
                                        if (enabling_index == neighbour_index) count += 1;
                                    },
                                }
                            }
                            tile_enabler.set(direction, count);
                        } else {
                            // set to one, so edges don't give contradictions
                            tile_enabler.set(direction, 1);
                        }
                    }
                }
            }
        }

        // the enablers might mean that there are some cells with a possible tile, that isn't actually possible
        var removals = RemovalStack.init(allocator);
        defer removals.deinit();

        var iter2 = cells.iterate();
        while (iter2.nextWithCoord()) |entry| {
            switch (entry.val.state) {
                .collapsed => continue,
                .superposition => {
                    for (entry.val.enablers, 0..) |tile_enabler, i| {
                        const tile_index: TileIndex = @intCast(i);
                        if (tile_enabler.hasZeroCount()) {
                            try removals.append(.{ .tile_index = tile_index, .coord = entry.coord });
                        }
                    }
                },
            }
        }

        while (removals.popOrNull()) |removal| {
            switch (cells.getPtr(removal.coord).state) {
                .superposition => |*possible| {
                    if (possible.isSet(removal.tile_index)) {
                        possible.unset(removal.tile_index);
                        if (possible.count() == 0) {
                            log.err("seed grid does not support a valid solution", .{});
                            return Error.Contradiction;
                        }
                    } else {
                        continue;
                    }
                },
                .collapsed => |tile_index| {
                    if (tile_index == removal.tile_index) {
                        log.err("seed grid goes not support a valid solution", .{});
                        return Error.Contradiction;
                    }
                },
            }
            for (directions) |direction| {
                const neighbour_coord = neighbouringCoord(removal.coord, direction, cells.shape) orelse continue;
                const neighbour = cells.get(neighbour_coord);
                const opposite_direction = direction.opposite();

                var iter = adjacency.get(removal.tile_index, direction).iterator(.{});
                while (iter.next()) |i| {
                    const compatible_tile_idx: TileIndex = @intCast(i);
                    const enabler_counts = &neighbour.enablers[compatible_tile_idx];
                    if (neighbour.state == .superposition and enabler_counts.get(opposite_direction) == 1) {
                        // we're decrementing to zero, so we need to do removal and
                        // push a propagation here

                        try removals.append(.{ .tile_index = compatible_tile_idx, .coord = neighbour_coord });
                    }
                    enabler_counts.decr(opposite_direction);
                }
            }
        }
    }

    pub fn deinit(self: *CellGrid, allocator: Allocator) void {
        allocator.free(self.enabler_data);
        allocator.free(self.cells.items);
    }
};

pub const TileSet = std.StaticBitSet(std.math.maxInt(TileIndex) + 1);
// only do 2D for now
pub const Adjacencies = struct {
    const Self = @This();

    allowed_edges: [][directions.len]TileSet,

    pub fn init(allocator: Allocator, tile_count: TileIndex) !Self {
        const buf = try allocator.alloc([4]TileSet, tile_count);
        for (buf) |*by_direction| {
            for (by_direction) |*tile_set| {
                tile_set.* = TileSet.initEmpty();
            }
        }
        return Self{
            .allowed_edges = buf,
        };
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        allocator.free(self.allowed_edges);
    }

    pub inline fn get(self: Self, tile_index: TileIndex, direction: Direction) TileSet {
        return self.allowed_edges[tile_index][@intFromEnum(direction)];
    }

    pub inline fn set(self: Self, tile_index: TileIndex, direction: Direction, neighbour: TileIndex) void {
        self.allowed_edges[tile_index][@intFromEnum(direction)].set(neighbour);
    }
};

pub const GenInput = struct {
    seed: usize,
    tile_count: TileIndex,
    adjacency_rules: Adjacencies,
    weights: []const Weight,
    constraints: ?[]constraint.Count = null,

    pub fn init(allocator: Allocator, seed: usize, tile_count: TileIndex) !GenInput {
        return GenInput{
            .seed = seed,
            .tile_count = tile_count,
            .adjacency_rules = try Adjacencies.init(allocator, tile_count),
            .weights = try allocator.alloc(Weight, tile_count),
        };
    }

    /// Does not free `self.constraints` if non-null.
    pub fn deinit(self: GenInput, allocator: Allocator) void {
        self.adjacency_rules.deinit(allocator);
        allocator.free(self.weights);
    }
};

pub const Direction = enum {
    down,
    right,
    up,
    left,

    pub fn coordIndex(direction: Direction) usize {
        return switch (direction) {
            .down, .up => 0,
            .right, .left => 1,
        };
    }

    pub fn positive(direction: Direction) bool {
        return switch (direction) {
            .down, .right => true,
            .up, .left => false,
        };
    }

    pub fn opposite(direction: Direction) Direction {
        return switch (direction) {
            .down => .up,
            .right => .left,
            .up => .down,
            .left => .right,
        };
    }
};
// down, right, up, left
pub const directions = std.enums.values(Direction);

const EnablerCounts = struct {
    counts: [directions.len]TileIndex,

    pub inline fn get(self: EnablerCounts, direction: Direction) TileIndex {
        return self.counts[@intFromEnum(direction)];
    }

    pub inline fn set(self: *EnablerCounts, direction: Direction, count: TileIndex) void {
        self.counts[@intFromEnum(direction)] = count;
    }

    pub inline fn decr(self: *EnablerCounts, direction: Direction) void {
        self.counts[@intFromEnum(direction)] -|= 1;
    }

    fn hasZeroCount(self: EnablerCounts) bool {
        for (self.counts) |count| {
            if (count == 0)
                return true;
        }
        return false;
    }
};

const Cell = struct {
    const Self = @This();

    //TODO(performance): switch to bit-flags?
    state: State,
    // BUG: there can be up to maxInt(TileIndex) + 1 enablers in a given direction
    // we're assuming that there is fewer than maxInt(TileIndex) different tiles, or
    // no tile has a direction where it can be placed next to every other tile
    enablers: []EnablerCounts,

    const State = union(enum) {
        collapsed: TileIndex,
        superposition: TileSet,
    };

    fn possibleWeight(possible: TileSet, weights: []const Weight) usize {
        var total_weight: usize = 0;
        var iter = possible.iterator(.{});
        while (iter.next()) |i| {
            total_weight += weights[i];
        }
        return total_weight;
    }

    //TODO(performance): cache current entropy and subtract when removing possibilities
    fn entropy(possible: TileSet, weights: []const Weight) f32 {
        const total_weight: f32 = @floatFromInt(possibleWeight(possible, weights));
        var w_log_w_sum: f32 = 0;
        var iter = possible.iterator(.{});
        while (iter.next()) |i| {
            const w: f32 = @floatFromInt(weights[i]);
            w_log_w_sum += w * math.log2(w);
        }
        return math.log2(total_weight) - w_log_w_sum / total_weight;
    }

    pub fn hasNoPossibilities(possible: TileSet) bool {
        return if (possible.count() == 0) true else false;
    }
};

const Removal = struct {
    tile_index: TileIndex,
    coord: Coord,
};
const RemovalStack = std.ArrayList(Removal);

const EntropyCoord = struct {
    const Self = @This();

    entropy: f32,
    coord: Coord,

    pub fn compare(context: []Self, a: usize, b: usize) std.math.Order {
        return std.math.order(context[a].entropy, context[b].entropy);
    }
};
const EntropyHeap = struct {
    const Self = @This();
    const Heap = std.PriorityQueue(usize, []EntropyCoord, EntropyCoord.compare);

    fba: std.heap.FixedBufferAllocator,
    heap: Heap,

    pub fn init(self: *Self, heap_context: []EntropyCoord, heap_buffer: []usize) void {
        // WARNING: we're doing some (unsupported?) magic with the PriorityQueue, by setting the
        // items explicitly to heap_buffer. By using a fixed buffer we rely on the guarantee that
        // the algorithm never tries to add too many entropies to the queue. Note that the number
        // of entropies should have maximum equal to the number of cells. This invariant must be
        // maintained at all times to avoid the queue trying to resize/move the allocation
        // (see updateEntropyHeap()).
        std.debug.assert(heap_buffer.len <= heap_context.len);
        self.fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(heap_buffer));
        self.fba.end_index = self.fba.buffer.len;
        self.heap = Heap.init(self.fba.allocator(), heap_context);
        self.heap.items = heap_buffer[0..0];
        self.heap.cap = heap_buffer.len;
    }

    pub fn reset(self: *Self) void {
        self.heap.items.len = 0;
    }

    pub fn initEntropies(self: *Self, cell_grid: CellGrid, weights: []const Weight) void {
        self.reset();
        var iter = cell_grid.cells.iterate();
        while (iter.nextWithBoth()) |item_ind| {
            switch (item_ind.val.state) {
                .collapsed => {},
                .superposition => |possible| {
                    const entropy = Cell.entropy(possible, weights);
                    self.heap.context[item_ind.index] = EntropyCoord{
                        .entropy = entropy,
                        .coord = item_ind.coord,
                    };
                    self.heap.add(item_ind.index) catch {
                        std.debug.panic(
                            "ran out of memory adding entropy coord {d}\nheap has size {d}",
                            .{ item_ind.index, self.heap.capacity() },
                        );
                    };
                },
            }
        }
    }
};

pub fn neighbouringCoord(coord: Coord, direction: Direction, shape: Shape) ?Coord {
    const positive = direction.positive();
    const coord_idx = direction.coordIndex();
    var new_coord = coord;
    if (positive) {
        if (coord[coord_idx] == shape[coord_idx] - 1)
            return null;
        new_coord[coord_idx] += 1;
    } else {
        if (coord[coord_idx] == 0)
            return null;
        new_coord[coord_idx] -= 1;
    }
    return new_coord;
}

fn neighbouringCell(cells: CellGrid.CellArray, coord: Coord, direction: Direction, shape: Shape) ?Cell {
    const neighbour_coord = neighbouringCoord(coord, direction, shape) orelse return null;
    return cells.get(neighbour_coord);
}

pub const CoreState = struct {
    const Self = @This();

    cell_grid: CellGrid,
    adjacency: Adjacencies,
    weights: []const Weight,
    removals: RemovalStack,
    entropy_heap: EntropyHeap,
    random: std.Random,

    pub fn chooseCellToCollapse(self: *Self) ?Coord {
        const entropy_coord_idx = self.entropy_heap.heap.removeOrNull() orelse return null;
        const entropy_coord = self.entropy_heap.heap.context[entropy_coord_idx];
        return entropy_coord.coord;
    }

    fn observedTile(random: std.Random, possible: TileSet, weights: []const Weight) TileIndex {
        var remaining = random.uintLessThan(usize, Cell.possibleWeight(possible, weights));
        var iter = possible.iterator(.{});
        while (iter.next()) |i| {
            const tile_index: TileIndex = @intCast(i);
            const weight = weights[tile_index];
            if (remaining >= weight)
                remaining -= weight
            else {
                return tile_index;
            }
        }
        unreachable;
    }

    /// caller guarantees that coord is valid
    pub fn banTile(self: *Self, tile_index: TileIndex, coord: Coord) !void {
        const cell = self.cell_grid.cells.getPtr(coord);
        switch (cell.state) {
            .superposition => |*possible| {
                if (possible.isSet(tile_index)) {
                    possible.unset(tile_index);
                    const new_removal = Removal{
                        .tile_index = tile_index,
                        .coord = coord,
                    };
                    try self.removals.append(new_removal);
                }
            },
            .collapsed => @panic("tried to ban a tile for a collapsed cell"),
        }
    }

    // TODO: try to avoid oom possibility when propagating/collapsing
    // this can possibly be done by not pushing the removal,
    // marking a dirty removal state, and then doing some kind of scan of all cells
    /// Collapses the cell located at `coord`. To generate a complete tiling, call in
    /// a loop with `chooseCellToCollapse()`, or use the convenience wrapper `run()`.
    /// Caller guarantees that `coord` is valid. Returns the index of the tile the cell
    /// is collapsed to.
    pub fn collapseCell(self: *Self, coord: Coord) Error!TileIndex {
        const cell = self.cell_grid.cells.getPtr(coord);
        switch (cell.state) {
            .superposition => |possible| {
                const tile_index = observedTile(self.random, possible, self.weights);
                var iter = possible.iterator(.{});
                while (iter.next()) |i| {
                    if (i != tile_index) {
                        try banTile(self, @intCast(i), coord);
                    }
                }
                cell.state = Cell.State{ .collapsed = tile_index };
                try propagateInfo(self);
                return tile_index;
            },
            .collapsed => @panic("tried to collapse a collapsed cell"),
        }
    }

    fn updateEntropyHeap(self: *Self, old_entropy: f32, new_entropy: f32, coord: Coord) void {
        if (old_entropy != new_entropy) {
            const index = self.cell_grid.cells.sliceIndex(coord);
            const remove_index = std.mem.indexOfScalar(
                usize,
                self.entropy_heap.heap.items,
                index,
            ) orelse
                std.debug.panic("could not find tile index {d} in entropy heap", .{index});
            _ = self.entropy_heap.heap.removeIndex(remove_index);
            self.entropy_heap.heap.context[index].entropy = new_entropy;
            self.entropy_heap.heap.add(index) catch unreachable; //we just removed one so add() can't fail
        }
    }

    pub fn propagateInfo(self: *Self) Error!void {
        while (self.removals.popOrNull()) |removal| {
            for (directions) |direction| {
                const neighbour_coord = neighbouringCoord(removal.coord, direction, self.cell_grid.cells.shape) orelse continue;
                const neighbour = self.cell_grid.cells.getPtr(neighbour_coord);
                const opposite_direction = direction.opposite();

                var iter = self.adjacency.get(removal.tile_index, direction).iterator(.{});
                while (iter.next()) |i| {
                    const compatible_tile_idx: TileIndex = @intCast(i);
                    const enabler_counts = &neighbour.enablers[compatible_tile_idx];
                    if (neighbour.state == .superposition and enabler_counts.get(opposite_direction) == 1) {
                        // we're decrementing to zero, so we need to do removal and
                        // push a propagation here

                        // ban the tile and update entropy heap (while maintaining size invaraint)
                        const old_entropy = Cell.entropy(neighbour.state.superposition, self.weights);
                        try self.banTile(compatible_tile_idx, neighbour_coord);
                        const new_entropy = Cell.entropy(neighbour.state.superposition, self.weights);

                        // IMPORTANT: check for contradiction _before_ updating the entropy heap,
                        //            otherwise we'll try to push an entropy of -nan and hit unreachable
                        //            in std.math.order
                        if (Cell.hasNoPossibilities(neighbour.state.superposition)) {
                            // contradiction
                            return Error.Contradiction;
                        }
                        updateEntropyHeap(self, old_entropy, new_entropy, neighbour_coord);
                    }
                    enabler_counts.decr(opposite_direction);
                }
            }
        }
    }

    pub fn run(self: *Self) Error!void {
        while (self.chooseCellToCollapse()) |coord| {
            _ = try self.collapseCell(coord);
        }
    }
};

pub fn generateAlloc(
    data_allocator: Allocator,
    stack_allocator: Allocator,
    input: GenInput,
    output_shape: Shape,
    limit: usize,
) !TileGrid {
    var cell_grid = try CellGrid.initFull(data_allocator, input, output_shape);
    defer cell_grid.deinit(data_allocator);
    return generateSeededCellAlloc(data_allocator, stack_allocator, cell_grid, input, limit);
}

pub fn generateSeededAlloc(
    data_allocator: Allocator,
    stack_allocator: Allocator,
    seed_grid: SeedGrid,
    input: GenInput,
    limit: usize,
) !TileGrid {
    var cell_grid = try CellGrid.initSeeded(data_allocator, input, seed_grid);
    defer cell_grid.deinit(data_allocator);
    return generateSeededCellAlloc(data_allocator, stack_allocator, cell_grid, input, limit);
}

/// Caller is reponsible for freeing the result, which is
/// owned by `data_allocator`.
pub fn generateSeededCellAlloc(
    data_allocator: Allocator,
    stack_allocator: Allocator,
    seed_grid: CellGrid,
    input: GenInput,
    limit: usize,
) !TileGrid {
    const output_shape = seed_grid.cells.shape;
    const num_elts = seed_grid.cells.size();
    const out_buf = try data_allocator.alloc(TileIndex, num_elts);
    errdefer data_allocator.free(out_buf);

    const entropy_heap_context = try data_allocator.alloc(
        EntropyCoord,
        num_elts,
    );
    defer data_allocator.free(entropy_heap_context);

    const entropy_heap_buf = try data_allocator.alloc(usize, num_elts);
    defer data_allocator.free(entropy_heap_buf);

    var entropy_heap: EntropyHeap = undefined;
    entropy_heap.init(entropy_heap_context, entropy_heap_buf);

    const output_grid = TileGrid.ofSlicePacked(out_buf, output_shape) catch unreachable;

    var cell_grid = try CellGrid.init(data_allocator, input.tile_count, output_shape);
    defer cell_grid.deinit(data_allocator);

    _ = try tile(
        stack_allocator,
        entropy_heap,
        output_grid,
        cell_grid,
        seed_grid,
        input,
        limit,
    );
    return output_grid;
}

/// Create a tiling, by making up to `limit` repeated attempts if failures
/// occur due to reaching a contradiction or running out of memory.
///
/// Modifies `cell_grid` during execution, and writes ouput to `output_grid`.
/// Returns the number of attempts it took to tile the grid successfully.
///
/// Returns the number of attempts made before finding a tiling;
/// each attempt increments random seed by one, so in the future the same
/// result can be obtained by using the `input.seed` plus the return value
/// as the chosen seed. Note that if some attempts failed due to an out of
/// memory error, a future call to `tile()` with the same `seed_grid` and
/// `input` parameters, but more available memory, may return a different tiling.
///
/// Returns `error.AttemptLimitReached` if no tilings are found within
/// `limit` attempts .
pub fn tile(
    stack_allocator: Allocator,
    entropy_heap: EntropyHeap,
    output_grid: TileGrid,
    cell_grid: CellGrid,
    seed_grid: CellGrid,
    input: GenInput,
    limit: usize,
) error{ OutOfMemory, AttemptLimitReached }!usize {
    var rng = std.Random.Xoshiro256{ .s = undefined }; //initialised in loop

    var state = CoreState{
        .random = rng.random(),
        .cell_grid = cell_grid,
        .adjacency = input.adjacency_rules,
        .weights = input.weights,
        .removals = RemovalStack.init(stack_allocator),
        .entropy_heap = entropy_heap,
    };
    defer state.removals.deinit();

    var attempts: usize = 0;
    while (attempts < limit) : (attempts += 1) {
        // initialise state for this attempt
        rng.seed(input.seed + attempts);
        {
            var iter = state.cell_grid.cells.iterate();
            while (iter.nextPtrWithCoord()) |item| {
                const seed = seed_grid.cells.get(item.coord);
                item.ptr.state = seed.state;
                std.debug.assert(item.ptr.enablers.len == seed.enablers.len);
                @memcpy(item.ptr.enablers, seed.enablers);
            }
        }
        state.removals.clearRetainingCapacity();
        state.entropy_heap.initEntropies(state.cell_grid, state.weights);

        const result = if (input.constraints) |constraints| result: {
            for (constraints) |*c| {
                c.current = 0;
            }
            break :result constraint.run(&state, constraints);
        } else state.run();

        result catch |err| switch (err) {
            Error.OutOfMemory => return error.OutOfMemory,
            Error.Contradiction => continue,
        };
        break;
    } else {
        return error.AttemptLimitReached;
    }

    {
        var iter = output_grid.iterate();
        while (iter.nextPtrWithCoord()) |item| {
            item.ptr.* = cell_grid.cells.get(item.coord).state.collapsed;
        }
    }
    return attempts;
}

test {
    std.testing.refAllDecls(@This());
}

var bench_gpa = std.heap.GeneralPurposeAllocator(.{}){};
const bench_allocator = bench_gpa.allocator();

const bench_tile_count = 4;

var bench_edges = edges: {
    var adj_0 = [1]TileSet{TileSet.initEmpty()} ** 4;
    adj_0[0].set(0);
    adj_0[0].set(2);
    adj_0[1].set(0);
    adj_0[1].set(1);
    adj_0[2].set(0);
    adj_0[2].set(2);
    adj_0[3].set(0);
    adj_0[3].set(1);
    var adj_1 = [1]TileSet{TileSet.initEmpty()} ** 4;
    adj_1[0].set(1);
    adj_1[0].set(3);
    adj_1[1].set(0);
    adj_1[2].set(1);
    adj_1[2].set(3);
    adj_1[3].set(0);
    var adj_2 = [1]TileSet{TileSet.initEmpty()} ** 4;
    adj_2[0].set(0);
    adj_2[1].set(2);
    adj_2[1].set(3);
    adj_2[2].set(0);
    adj_2[3].set(2);
    adj_2[3].set(3);
    var adj_3 = [1]TileSet{TileSet.initEmpty()} ** 4;
    adj_3[0].set(1);
    adj_3[1].set(2);
    adj_3[2].set(1);
    adj_3[3].set(2);
    break :edges [bench_tile_count][4]TileSet{
        adj_0,
        adj_1,
        adj_2,
        adj_3,
    };
};

pub const benchmarks = benchmarks: {
    const adjacencies: Adjacencies = .{ .allowed_edges = bench_edges[0..] };

    const weights = [_]Weight{ 1, 1, 1, 1 };
    const input = GenInput{
        .seed = 0,
        .tile_count = bench_tile_count,
        .adjacency_rules = adjacencies,
        .weights = &weights,
    };

    const output_shape = TileGrid.Indices{ 64, 64 };
    const args = std.meta.ArgsTuple(@TypeOf(generateAlloc)){
        bench_allocator,
        bench_allocator,
        input,
        output_shape,
        1,
    };
    break :benchmarks .{
        .@"generateAlloc() 64x64" = @import("zubench").Spec(generateAlloc){ .args = args, .max_samples = 500 },
    };
};
