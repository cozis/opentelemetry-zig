const std = @import("std");

var now_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn timestamp() i64 {
    return @intCast(now_ns.load(.monotonic) / std.time.ns_per_s);
}

pub fn milliTimestamp() i64 {
    return @intCast(now_ns.load(.monotonic) / std.time.ns_per_ms);
}

pub fn nanoTimestamp() i128 {
    return now_ns.fetchAdd(std.time.ns_per_ms, .monotonic);
}

pub fn monotonicNs() u64 {
    return @intCast(nanoTimestamp());
}

pub fn sleep(ns: u64) void {
    _ = now_ns.fetchAdd(ns, .monotonic);
}

pub fn timeoutAfterNs(ns: u64) std.Io.Timeout {
    return .{
        .duration = .{
            .raw = .{ .nanoseconds = @intCast(ns) },
            .clock = .awake,
        },
    };
}

pub fn timeoutAfterMs(ms: u64) std.Io.Timeout {
    return timeoutAfterNs(ms * std.time.ns_per_ms);
}

pub fn waitTimeout(io: std.Io, event: *std.Io.Event, ns: u64) (error{Timeout} || std.Io.Cancelable)!void {
    return event.waitTimeout(io, timeoutAfterNs(ns));
}
