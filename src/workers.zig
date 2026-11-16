//! A fixed pool of worker threads that run row bands of one job at a time. `std.Io.Group.async`
//! allocates a task per call, which breaks static allocation, so the pool synchronizes with
//! pthread primitives directly.

const std = @import("std");
const assert = std.debug.assert;
const c = std.c;

/// Worker threads besides the caller, which always runs band 0.
pub const thread_count_max: u32 = 7;

pub const Job = struct {
    function: *const fn (context: *const anyopaque, band_index: u32, band_count: u32) void,
    context: *const anyopaque,
};

pub const Workers = struct {
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    wake: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    done: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    threads: [thread_count_max]std.Thread = undefined,
    thread_count: u32 = 0,
    job: ?Job = null,
    generation: u64 = 0,
    pending: u32 = 0,
    shutdown: bool = false,

    pub fn init(workers: *Workers, thread_count: u32) !void {
        assert(thread_count <= thread_count_max);
        workers.* = .{};
        errdefer workers.deinit();
        for (0..thread_count) |index| {
            workers.threads[index] = try std.Thread.spawn(
                .{ .stack_size = 256 * 1024, .allocator = null },
                worker_loop,
                .{ workers, @as(u32, @intCast(index)) + 1 },
            );
            workers.thread_count += 1;
        }
        assert(workers.thread_count == thread_count);
    }

    pub fn deinit(workers: *Workers) void {
        assert(workers.thread_count <= thread_count_max);
        assert(workers.pending == 0);
        _ = c.pthread_mutex_lock(&workers.mutex);
        workers.shutdown = true;
        _ = c.pthread_cond_broadcast(&workers.wake);
        _ = c.pthread_mutex_unlock(&workers.mutex);
        for (workers.threads[0..workers.thread_count]) |thread| thread.join();
        workers.thread_count = 0;
    }

    /// Runs `job` with one band per thread and returns when every band is done.
    pub fn run(workers: *Workers, job: Job) void {
        assert(workers.job == null);
        assert(!workers.shutdown);
        const band_count = workers.thread_count + 1;
        _ = c.pthread_mutex_lock(&workers.mutex);
        workers.job = job;
        workers.generation += 1;
        workers.pending = workers.thread_count;
        _ = c.pthread_cond_broadcast(&workers.wake);
        _ = c.pthread_mutex_unlock(&workers.mutex);

        job.function(job.context, 0, band_count);

        _ = c.pthread_mutex_lock(&workers.mutex);
        while (workers.pending > 0) _ = c.pthread_cond_wait(&workers.done, &workers.mutex);
        workers.job = null;
        _ = c.pthread_mutex_unlock(&workers.mutex);
        assert(workers.pending == 0);
    }
};

fn worker_loop(workers: *Workers, band_index: u32) void {
    assert(band_index >= 1);
    assert(band_index <= thread_count_max);
    var generation_seen: u64 = 0;
    // An event loop: it runs until shutdown, waiting for the next job generation.
    while (true) {
        _ = c.pthread_mutex_lock(&workers.mutex);
        while (!workers.shutdown and workers.generation == generation_seen) {
            _ = c.pthread_cond_wait(&workers.wake, &workers.mutex);
        }
        if (workers.shutdown) {
            _ = c.pthread_mutex_unlock(&workers.mutex);
            break;
        }
        generation_seen = workers.generation;
        const job = workers.job.?;
        const band_count = workers.thread_count + 1;
        _ = c.pthread_mutex_unlock(&workers.mutex);

        job.function(job.context, band_index, band_count);

        _ = c.pthread_mutex_lock(&workers.mutex);
        assert(workers.pending > 0);
        workers.pending -= 1;
        if (workers.pending == 0) _ = c.pthread_cond_broadcast(&workers.done);
        _ = c.pthread_mutex_unlock(&workers.mutex);
    }
    assert(workers.shutdown);
}

pub const Rows = struct { begin: u32, end: u32 };

pub fn band_rows(band_index: u32, band_count: u32, height: u32) Rows {
    assert(band_count >= 1);
    assert(band_index < band_count);
    const begin: u32 = @intCast(@divFloor(@as(u64, height) * band_index, band_count));
    const end: u32 = @intCast(@divFloor(@as(u64, height) * (band_index + 1), band_count));
    assert(begin <= end);
    assert(end <= height);
    return .{ .begin = begin, .end = end };
}

const VisitTest = struct {
    counts: []std.atomic.Value(u32),

    fn visit(context: *const anyopaque, band_index: u32, band_count: u32) void {
        const visit_test: *const VisitTest = @ptrCast(@alignCast(context));
        const height: u32 = @intCast(visit_test.counts.len);
        const rows = band_rows(band_index, band_count, height);
        for (rows.begin..rows.end) |row| _ = visit_test.counts[row].fetchAdd(1, .monotonic);
    }
};

test "workers: every row is visited exactly once" {
    // Goal: bands cover the rows without gaps or overlap. Method: count visits with 0, 2, 6
    // worker threads (1, 3 and 7 bands including the caller).
    var counts: [1000]std.atomic.Value(u32) = undefined;
    for ([_]u32{ 0, 2, 6 }) |thread_count| {
        for (&counts) |*count| count.* = .init(0);
        var workers: Workers = undefined;
        try workers.init(thread_count);
        defer workers.deinit();
        const visit_test: VisitTest = .{ .counts = &counts };
        workers.run(.{ .function = VisitTest.visit, .context = &visit_test });
        workers.run(.{ .function = VisitTest.visit, .context = &visit_test });
        for (&counts) |*count| try std.testing.expectEqual(@as(u32, 2), count.load(.monotonic));
    }
}
