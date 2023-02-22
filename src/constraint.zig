const core = @import("core.zig");

pub const Count = struct {
    // a max of zero indicates unconstrained
    max: u32 = 0,
    current: u32 = 0,
};

pub fn collapseConstrained(state: *core.CoreState, constraints: []Count, coord: core.Coord) core.Error!void {
    const tile_index = try state.collapseCell(coord);
    constraints[tile_index].current += 1;
    if (constraints[tile_index].current == constraints[tile_index].max) {
        for (0..state.cell_grid.cells.size()) |i| {
            const ban_coord = state.cell_grid.cells.coordOfIterIndex(i);
            if (state.cell_grid.cells.get(ban_coord).state == .superposition) {
                try state.banTile(tile_index, ban_coord);
            }
        }
        try state.propagateInfo();
        var iter = state.cell_grid.cells.iterate();
        while (iter.next()) |cell| {
            switch (cell.state) {
                .collapsed => {},
                .superposition => |possible| {
                    if (possible.isSet(tile_index)) {
                        @panic("failed to properly remove tile due to constraint");
                    }
                },
            }
        }
    }
}

pub fn run(state: *core.CoreState, constraints: []Count) core.Error!void {
    while (state.chooseCellToCollapse()) |coord| {
        try collapseConstrained(state, constraints, coord);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
