const std = @import("std");

const otel = @import("opentelemetry-sdk");
const Simulator = @import("zigmulator");

fn metricsReproducer(init: std.process.Init) !void {
    const allocator = init.gpa;

    const provider = try otel.metrics.MeterProvider.init(allocator, init.io);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "reproduce.metrics.temporality",
        .version = "0.1.0",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "reproducer counter",
    });

    const metric_export = try otel.metrics.MetricExporter.InMemory(allocator, init.io, null, null);
    defer metric_export.in_memory.deinit();
    const reader = try otel.metrics.MetricReader.init(allocator, init.io, metric_export.exporter);
    defer reader.shutdown();
    try provider.addReader(reader);

    // The first collect stores cumulative datapoints keyed by borrowed attributes.
    // Freeing the fetched measurements leaves that key dangling; the second collect compares against it.
    try recordAndCollect(allocator, reader, metric_export.in_memory, counter, 1);
    try recordAndCollect(allocator, reader, metric_export.in_memory, counter, 2);
}

pub fn main(init: std.process.Init) !void {
    // Back the simulator (and therefore the reproducer's `init.gpa`) with a
    // DebugAllocator so any memory leaked by the temporality aggregator is
    // reported once everything has been torn down.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.print("LEAK DETECTED: metrics temporality reproducer leaked memory\n", .{});
        std.process.exit(1);
    };

    var sim: Simulator = undefined;
    sim.init(debug_allocator.allocator(), init.io, 0);
    defer sim.deinit();

    try sim.addExecutable("metrics_reproducer", metricsReproducer);
    try sim.spawn("metrics_reproducer", .{});

    while (sim.scheduleOne()) {}
}

fn recordAndCollect(
    allocator: std.mem.Allocator,
    reader: *otel.metrics.MetricReader,
    in_memory: *otel.metrics.InMemoryExporter,
    counter: *otel.metrics.Counter(u64),
    value: u64,
) !void {
    try counter.add(value, .{ "route", @as([]const u8, "/reproducer") });
    try reader.collect();

    const collected = try in_memory.fetch(allocator);
    defer allocator.free(collected);

    for (collected) |*measurement| {
        measurement.deinit(allocator);
    }
}
