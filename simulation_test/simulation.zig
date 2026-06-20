const std = @import("std");

const Simulator = @import("zigmulator");

fn dummyMain(init: std.process.Init) anyerror!void {
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try stdout.interface.print("Hello from a simulated OpenTelemetry process.\n", .{});
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var sim: Simulator = undefined;
    sim.init(std.heap.page_allocator, init.io, 0);
    defer sim.deinit();

    try sim.addExecutable("dummy", dummyMain);
    try sim.spawn("dummy", .{});

    while (sim.scheduleOne()) {}

    std.debug.print("Simulation ended\n", .{});
}
