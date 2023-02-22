const std = @import("std");
const core = @import("core.zig");

fn printHor(count: usize) void {
    for (0..count) |_| {
        std.debug.print("─", .{});
    }
}

pub fn dumpPossible(cell_grid: core.CellGrid) void {
    const cells = cell_grid.slice();
    const rows = cell_grid.shape[0];
    const cols = cell_grid.shape[1];
    const count = cells[0].possible.len;
    {
        std.debug.print("┌", .{});
        printHor(count);
        for (0..cols - 1) |_| {
            std.debug.print("┬", .{});
            printHor(count);
        }
        std.debug.print("┐\n", .{});
    }
    for (cells[0..cols]) |cell| {
        std.debug.print("│", .{});
        for (cell.possible, 0..) |possible, tile_index| {
            if (possible) {
                std.debug.print("{d}", .{tile_index});
            } else std.debug.print(" ", .{});
        }
    }
    std.debug.print("│\n", .{});
    for (1..rows) |row| {
        {
            std.debug.print("├", .{});
            printHor(count);
            for (0..cols - 1) |_| {
                std.debug.print("┼", .{});
                printHor(count);
            }
            std.debug.print("┤\n", .{});
        }
        const row_start = row * cols;
        for (cells[row_start .. row_start + cols]) |cell| {
            std.debug.print("│", .{});
            for (cell.possible, 0..) |possible, tile_index| {
                if (possible) {
                    std.debug.print("{d}", .{tile_index});
                } else std.debug.print(" ", .{});
            }
        }
        std.debug.print("│\n", .{});
    }
    {
        std.debug.print("└", .{});
        printHor(count);
        for (0..cols - 1) |_| {
            std.debug.print("┴", .{});
            printHor(count);
        }
        std.debug.print("┘\n", .{});
    }
}
