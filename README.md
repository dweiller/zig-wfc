# zig-wfc
An implementation of the wave function collapse algorithm in Zig

A generic library implementing the *wave function collapse* algorithm. This library exposes a generic core algorithm which produces tilings given a collection of tiles and associated adjacency constraints, as well a tile generator for implementing the _overlapping_ mode. See the [original implementation](https://github.com/mxgmn/WaveFunctionCollapse) for an overview of the algorithm and links to other resources.

## Using zig-wfc

You can use `zig-wfc` in a Zig project with the Zig build system. Include a dependency in your `build.zig.zon`, e.g.:
```
.dependencies = .{
    .zig_wfc = .{
        .url = "https://github.com/dweiller/zig-wfc/archive/[[COMMIT_HASH]].tar.gz",
        .hash = "[[ZIG_PACKAGE_HASH]]",
    },
}
```

Then retrieve the `wfc` module from the dependency in your `build.zig`:
```
pub fn build(b: *std.Build) !void {

    // -- snip --

    const wfc = b.dependency("zig_wfc", .{}).module("wfc");

    // assuming you have a `std.Build.Step.Compile` called 'exe' that wants to do WFC
    exe.addModule("zig-wfc", wfc);
}
```

You can ascertain the correct value for `[[ZIG_PACKAGE_HASH]]` by leaving that field out initially; this make Zig report the correct hash value.

## WFC Core

WFC is sometimes considered as having two different modes: overlapping and tiled. I think is description is a little misleading: I would rather say the WFC is a tiling generator (or maybe even more generally a graph colouring algorithm) and the overlapping mode merely one of several processing pipelines that can be used to achieve various effects. A good explanation how the core tiling algorithm relates to the overlapping mode can be found [here](https://www.gridbugs.org/wave-function-collapse/). Another processing pipeline of particular interest I haven't yet seen talked about is what could be called the 'iterative mode' (if we want to keep the nomenclature of modes), which allows for generating [large-scale structure](#large-scale-structure), which are usually considered outside the scope of WFC.

The most common situation is generating a 2D or 3D cubic tiling and this library is currently restricted to 2-dimensional rectangular tilings.

## Features (and todos)

  - [x] generic core algorithm you can use with any set of (2D) tiles/edge constraints forming a rectangular grid
  - [x] generate tiles from image (overlapping mode)
  - [x] seeded generation
  - generation constraints
    - [x] maximum tile count (i.e. max number of times a tile can be used)
    - [ ] minimum tile count (i.e. min number of times a tile can be used)
    - [ ] connectivity constraints (i.e. forces tiles to be part of the same region/path)
    - [ ] distance constraints (distance between particular tiles and of paths)
  - [ ] tile symmetry groups
  - [ ] iterative pipeline
  - [ ] _n_-dimensional rectangular tilings
  - [ ] hexagonal grid

## Iterative pipeline

Helper utilities for the iterative pipeline is not yet implemented, but are planned for the future. This pipeline is a fairly general idea that produces intermediate tilings that are used to seed the next stage.

### Large-scale structure

WFC does not generally produce large-scale structures as the constraints it considers are all local. However, the core tiling algorithm can be used to generate large-scale structure fairly easily using an iterative strategy. The basic idea is to first generate a low resolution tiling which is used to seed subsequent tile generation. The increase in resolution naturally leads to the initial tiling producing large-scale structure.

For example, say you wanted to generate a 2D tiling with some larger-scale structure that includes houses, roads and grass, including more specialised tiles for the boundary regions between the road and a front lawn (like a footpath). You could start by generating a 'seed' tiling at a lower resolution that has the tiles 'property' and 'road'. You then expand this tiling into a higher resolution one initially seeded with 'house', 'footpath' and 'grass' tiles in the regions associated to 'property' tiles and 'road' tiles seeded where the 'road' tiles were. The adjacency constraints for 'footpath' can then require that they border 'road' tiles and 'grass' tiles surround 'house' tiles. This guarantees a minimum size for each large-scale 'property' which are grassy regions (possibly) with house tiles inside them. More passes/sub-tile types could be added for improved internal structure of a 'property' (e.g. to make 'house' tiles form a connected region or to add a driveway).


## Contributing

Contributions are welcome, as are issues requesting/suggesting better documentation or API and new features; feel free to open issues and send PRs.
