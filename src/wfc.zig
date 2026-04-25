const std = @import("std");

pub const overlapping = @import("overlapping.zig");
pub const constraint = @import("constraint.zig");

const core = @import("core.zig");

pub const TileIndex = core.TileIndex;
pub const Weight = core.Weight;
pub const TileGrid = core.TileGrid;
pub const Coord = core.Coord;
pub const Error = core.Error;
pub const SeedGrid = core.SeedGrid;
pub const CellGrid = core.CellGrid;
pub const TileSet = core.TileSet;
pub const Adjacencies = core.Adjacencies;
pub const GenInput = core.GenInput;
pub const Direction = core.Direction;
pub const directions = core.directions;
pub const CoreState = core.CoreState;

pub const initSeedGrid = core.initSeedGrid;
pub const neighbouringCoord = core.neighbouringCoord;
pub const generateAlloc = core.generateAlloc;
pub const generateSeededAlloc = core.generateSeededAlloc;
pub const generateSeededCellAlloc = core.generateSeededCellAlloc;
pub const tile = core.tile;

comptime {
    std.testing.refAllDecls(@This());
}
