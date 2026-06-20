const std = @import("std");

const otel = @import("opentelemetry-sdk");
const Simulator = @import("zigmulator");

fn printStatus(init: std.process.Init, comptime fmt: []const u8, args: anytype) !void {
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try stdout.interface.print(fmt ++ "\n", args);
    try stdout.interface.flush();
}

fn runLogNode(init: std.process.Init, comptime node_name: []const u8, delay_ms: i64) anyerror!void {
    const allocator = init.gpa;

    var baggage = otel.api.baggage.Baggage.init();
    defer baggage.deinit();
    try baggage.setValue(allocator, "service.name", node_name, null);
    try baggage.setValue(allocator, "simulation.id", "long-running-nodes", "deterministic=true");
    try baggage.setValue(allocator, "service.name", node_name ++ "-updated", null);
    try baggage.setValue(allocator, "transient", "remove-me", null);
    try baggage.removeValue(allocator, "transient");
    try baggage.removeValue(allocator, "missing");
    std.debug.assert(std.mem.eql(u8, baggage.getValue("simulation.id").?.metadata.?, "deterministic=true"));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_exporter = otel.logs.StdoutExporter.init(std.Io.File.stdout().writer(init.io, &stdout_buffer));
    var processor = otel.logs.SimpleLogRecordProcessor.init(init.io, stdout_exporter.asLogRecordExporter());

    var provider = try otel.logs.LoggerProvider.init(allocator, init.io, null);
    defer provider.deinit();
    try provider.addLogRecordProcessor(processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{
        .name = "opentelemetry-zig.simulation." ++ node_name,
        .version = "0.1.0",
    });
    const cached_logger = try provider.getLogger(.{
        .name = "opentelemetry-zig.simulation." ++ node_name,
        .version = "0.1.0",
    });
    std.debug.assert(logger == cached_logger);

    const empty_context = otel.api.context.Context.init();
    std.debug.assert(logger.enabled(.{
        .context = empty_context,
        .severity = 9,
        .event_name = "simulated node tick",
    }));

    var tick: u64 = 0;
    while (true) : (tick +%= 1) {
        if (tick % 17 == 0) {
            try baggage.setValue(allocator, "service.name", node_name ++ "-updated", null);
        }
        if (tick % 23 == 0) {
            try baggage.setValue(allocator, "simulation.id", "long-running-nodes", "deterministic=true");
        }
        const attrs = [_]otel.Attribute{
            .{ .key = "node.name", .value = .{ .string = node_name } },
            .{ .key = "simulation.tick", .value = .{ .int = @intCast(tick) } },
            .{ .key = "baggage.service", .value = .{ .string = baggage.getValue("service.name").?.value } },
        };
        logger.emit(.info, "simulated node tick", .{
            .attributes = &attrs,
            .severity_text = "INFO",
        });

        if (tick % 100 == 0) {
            try provider.forceFlush();
            try printStatus(init, "{s} log node reached tick {d}.", .{ node_name, tick });
        }
        try std.Io.sleep(init.io, .fromMilliseconds(delay_ms), .awake);
    }
}

fn configPropagationNode(init: std.process.Init) anyerror!void {
    const allocator = init.gpa;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_SERVICE_NAME", "simulation-service");
    try env_map.put("OTEL_RESOURCE_ATTRIBUTES", "deployment.environment=simulation,service.namespace=zig");
    try env_map.put("OTEL_PROPAGATORS", "baggage,tracecontext,b3,none");
    try env_map.put("OTEL_LOG_LEVEL", "debug");
    try env_map.put("OTEL_TRACES_EXPORTER", "console");
    try env_map.put("OTEL_METRICS_EXPORTER", "console");
    try env_map.put("OTEL_LOGS_EXPORTER", "console");
    try env_map.put("OTEL_BSP_MAX_QUEUE_SIZE", "8");
    try env_map.put("OTEL_BLRP_MAX_QUEUE_SIZE", "8");

    const cfg = try otel.config.Configuration.init(allocator, &env_map);
    defer cfg.deinit();

    var baggage = otel.api.baggage.Baggage.init();
    defer baggage.deinit();
    try baggage.setValue(allocator, "user_id", "alice", null);
    try baggage.setValue(allocator, "simulation", "true", "dst");

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        headers.deinit();
    }

    var propagator = try otel.propagation.CompositePropagator.initFromConfig(allocator, cfg);
    defer propagator.deinit();
    try propagator.injectBaggage(baggage, &headers);
    var extracted = try propagator.extractBaggage(&headers);
    if (extracted) |*bag| {
        defer bag.deinit();
        std.debug.assert(bag.count() == 2);
    }
    const fields = try propagator.fields();
    defer allocator.free(fields);

    var tick: u64 = 0;
    while (true) : (tick +%= 1) {
        const tick_value = try std.fmt.allocPrint(allocator, "{d}", .{tick});
        defer allocator.free(tick_value);
        try baggage.setValue(allocator, "simulation.tick", tick_value, "dst");

        var loop_headers = std.StringHashMap([]const u8).init(allocator);

        try propagator.injectBaggage(baggage, &loop_headers);
        var loop_extracted = try propagator.extractBaggage(&loop_headers);
        if (loop_extracted) |*bag| {
            std.debug.assert(bag.count() >= 2);
            bag.deinit();
        }
        var value_it = loop_headers.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        loop_headers.deinit();

        if (tick % 100 == 0) {
            try printStatus(init, "config/propagation node reached tick {d} with {d} propagated fields.", .{ tick, fields.len });
        }
        try std.Io.sleep(init.io, .fromMilliseconds(3), .awake);
    }
}

fn traceNode(init: std.process.Init) anyerror!void {
    const allocator = init.gpa;

    var prng = std.Random.DefaultPrng.init(12345);
    const id_generator = otel.trace.IDGenerator{
        .Random = otel.trace.RandomIDGenerator.init(prng.random()),
    };

    var provider = try otel.trace.TracerProvider.init(allocator, init.io, id_generator);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_exporter = otel.trace.StdOutExporter.init(std.Io.File.stdout().writer(init.io, &stdout_buffer));
    var processor = otel.trace.SimpleProcessor.init(allocator, init.io, stdout_exporter.asSpanExporter());
    try provider.addSpanProcessor(processor.asSpanProcessor());

    const tracer = try provider.getTracer(.{
        .name = "opentelemetry-zig.simulation.trace",
        .version = "0.1.0",
    });

    const attrs = try otel.Attributes.from(allocator, .{
        "component", @as([]const u8, "simulation"),
        "attempt",   @as(i64, 1),
    });
    defer allocator.free(attrs.?);

    var tick: u64 = 0;
    while (true) : (tick +%= 1) {
        var root_span = try tracer.startSpan(allocator, "simulation root", .{
            .kind = .Server,
            .attributes = attrs,
        });

        try root_span.setAttribute("node.count", .{ .int = 5 });
        try root_span.setAttribute("simulation.tick", .{ .int = @intCast(tick) });
        try root_span.addEvent("root tick", null, attrs);
        root_span.setStatus(otel.api.trace.Status.ok());

        var child = try tracer.startSpan(allocator, "simulation child", .{ .kind = .Client });
        try child.setAttribute("tick", .{ .int = @intCast(tick) });
        try std.Io.sleep(init.io, .fromMilliseconds(4), .awake);
        tracer.endSpan(&child);
        child.deinit();

        if (tick % 3 == 0) {
            var linked_child = try tracer.startSpan(allocator, "simulation linked child", .{ .kind = .Internal });
            try linked_child.addLink(root_span.span_context, attrs);
            tracer.endSpan(&linked_child);
            linked_child.deinit();
        }

        tracer.endSpan(&root_span);
        root_span.deinit();
        try provider.forceFlush();
        if (tick % 100 == 0) {
            try printStatus(init, "trace node reached tick {d}.", .{tick});
        }
    }
}

fn metricsNode(init: std.process.Init) anyerror!void {
    const allocator = init.gpa;

    const provider = try otel.metrics.MeterProvider.init(allocator, init.io);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "opentelemetry-zig.simulation.metrics",
        .version = "0.1.0",
    });

    var counter = try meter.createCounter(u64, .{ .name = "requests", .description = "simulated requests" });
    var up_down = try meter.createUpDownCounter(i64, .{ .name = "queue_depth" });
    var histogram = try meter.createHistogram(f64, .{ .name = "latency", .unit = "ms" });
    var gauge = try meter.createGauge(i64, .{ .name = "workers" });

    const metric_export = try otel.metrics.MetricExporter.InMemory(allocator, init.io, null, null);
    defer metric_export.in_memory.deinit();
    const reader = try otel.metrics.MetricReader.init(allocator, init.io, metric_export.exporter);
    defer reader.shutdown();
    try provider.addReader(reader);

    var tick: u64 = 0;
    while (true) : (tick +%= 1) {
        try counter.add(1, .{ "route", @as([]const u8, "/simulation") });
        try up_down.add(@as(i64, @intCast(tick)) - 1, .{ "queue", @as([]const u8, "main") });
        try histogram.record(@as(f64, @floatFromInt(tick)) + 0.5, .{ "phase", @as([]const u8, "work") });
        try gauge.record(@intCast(tick), .{ "pool", @as([]const u8, "default") });

        if (tick % 10 == 0) {
            try reader.collect();

            const collected = try metric_export.in_memory.fetch(allocator);
            for (collected) |*measurement| {
                measurement.deinit(allocator);
            }
            allocator.free(collected);
        }
        if (tick % 100 == 0) {
            try printStatus(init, "metrics node reached tick {d}.", .{tick});
        }
        try std.Io.sleep(init.io, .fromMilliseconds(2), .awake);
    }
}

fn batchingLogNode(init: std.process.Init) anyerror!void {
    const allocator = init.gpa;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_exporter = otel.logs.StdoutExporter.init(std.Io.File.stdout().writer(init.io, &stdout_buffer));
    const batch_processor = try otel.logs.BatchingLogRecordProcessor.init(
        allocator,
        init.io,
        stdout_exporter.asLogRecordExporter(),
        .{ .max_queue_size = 8, .max_export_batch_size = 2, .scheduled_delay_millis = 1 },
    );
    defer batch_processor.deinit();

    var provider = try otel.logs.LoggerProvider.init(allocator, init.io, null);
    defer provider.deinit();
    try provider.addLogRecordProcessor(batch_processor.asLogRecordProcessor());
    const logger = try provider.getLogger(.{ .name = "opentelemetry-zig.simulation.batch-logs" });

    for (0..5) |tick| {
        logger.emit(.warn, "batched simulated log", .{
            .severity_text = "WARN",
            .attributes = &[_]otel.Attribute{
                .{ .key = "tick", .value = .{ .int = @intCast(tick) } },
            },
        });
        try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
    }

    try provider.forceFlush();
    try provider.shutdown();
    try printStatus(init, "batching log node finished.", .{});
}

fn frontendNode(init: std.process.Init) anyerror!void {
    try runLogNode(init, "frontend", 5);
}

fn workerNode(init: std.process.Init) anyerror!void {
    try runLogNode(init, "worker", 8);
}

pub fn main(init: std.process.Init) !void {
    var sim: Simulator = undefined;
    sim.init(std.heap.page_allocator, init.io, 0);
    defer sim.deinit();

    try sim.addExecutable("frontend", frontendNode);
    try sim.addExecutable("worker", workerNode);
    try sim.addExecutable("config_propagation", configPropagationNode);
    try sim.addExecutable("trace", traceNode);
    try sim.addExecutable("metrics", metricsNode);
    try sim.addExecutable("batching_logs", batchingLogNode);
    try sim.spawn("frontend", .{});
    try sim.spawn("worker", .{});
    try sim.spawn("config_propagation", .{});
    try sim.spawn("trace", .{});
    try sim.spawn("metrics", .{});
    // Batching processors require std.Io.concurrent for their background export
    // loop. Keep the executable registered, but do not spawn it until the
    // simulator supports concurrent tasks.
    // try sim.spawn("batching_logs", .{});

    while (sim.scheduleOne()) {}

    std.debug.print("Simulation ended\n", .{});
}
