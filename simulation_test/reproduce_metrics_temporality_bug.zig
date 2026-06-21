const std = @import("std");

const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const MeterProvider = metrics_sdk.MeterProvider;

const Simulator = @import("zigmulator");

/// Reproduces the metrics temporality use-after-free from inside the simulator.
///
/// The body mirrors `examples/metrics/basic.zig`: a counter is recorded against
/// a meter provider wired to an in-memory exporter, then the metrics are
/// collected and fetched. Unlike the example, the record / collect / fetch
/// cycle runs more than once, which is what exposes the bug.
///
/// On each collection the cumulative temporality aggregator stores a hash-map
/// key whose `datapoint_attributes` field *borrows* (does not own) the
/// attribute slice of the fetched datapoint. We then free that slice, following
/// the documented `fetch` ownership contract, by deinit'ing each measurement.
/// That leaves the aggregator's key dangling, so the *next* `collect` faults
/// when `getOrPut` rehashes/compares the freed attributes.
///
/// The fault only surfaces with an allocator that unmaps freed pages (see the
/// `page_allocator` in `main`); an allocator that recycles the tiny freed slice
/// through a bucket would let the stale read silently succeed.
fn metricsReproducer(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Use the builtin meter provider
    const mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "reproduce.metrics.temporality",
    });

    // Declare an in-memory exporter
    const me = try metrics_sdk.MetricExporter.InMemory(allocator, io, null, null);
    defer me.in_memory.deinit();

    // Create a metric reader to aggregate the metrics
    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    defer mr.shutdown();

    // Register the metric reader to the meter provider
    try mp.addReader(mr);

    const sample_counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "number of requests",
    });

    // Collect more than once: the second collection is the one that touches the
    // dangling aggregator key left behind by the first.
    for (1..3) |round| {
        try sample_counter.add(@intCast(round), .{ "route", @as([]const u8, "/reproducer") });

        // Collect the metrics from the reader.
        // This is just an example, normally collection would happen in the
        // background, by using more sophisticated readers.
        try mr.collect();

        // Fetch the metrics and release them following the documented ownership
        // contract: deinit each measurement and then free the slice. Freeing the
        // attributes here is what leaves the aggregator's borrowed key dangling.
        const stored_metrics = try me.in_memory.fetch(allocator);
        defer allocator.free(stored_metrics);
        for (stored_metrics) |*measurement| {
            measurement.deinit(allocator);
        }

        // Only 1 instrument collected measurements.
        try std.testing.expectEqual(1, stored_metrics.len);
    }
}

pub fn main(init: std.process.Init) !void {
    // Back the simulator (and therefore the reproducer's `init.gpa`) with the
    // page allocator: it unmaps freed pages, so the use-after-free on the
    // aggregator's dangling key faults instead of silently reading recycled
    // memory.
    var sim: Simulator = undefined;
    sim.init(std.heap.page_allocator, init.io, 0);
    defer sim.deinit();

    try sim.addExecutable("metrics_reproducer", metricsReproducer);
    try sim.spawn("metrics_reproducer", .{});

    while (sim.scheduleOne()) {}
}
