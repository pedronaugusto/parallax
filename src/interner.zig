//! Dense ids for any type: the way into `Differ.sequences` for tokens,
//! records or anything with a hash and an equality.

const std = @import("std");
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");

/// An equivalence class, distinct from a position or a byte offset.
pub const ClassId = aegis.id.Id(struct {}, u32);
/// Number of equivalence classes in one shared interning domain.
pub const ClassCount = aegis.units.Count(ClassId, u32);

comptime {
    if (@sizeOf(ClassId) != @sizeOf(u32) or @alignOf(ClassId) != @alignOf(u32)) @compileError("class ids must keep the raw kernel layout");
}

/// Gives each distinct item a `u32` id, the first item 0, then 1, and so on.
/// `Context` is as std.HashMap's: `hash(Context, T) u64` and
/// `eql(Context, T, T) bool`. Items are kept by value, so a slice item stays
/// borrowed until `clear` or `deinit`.
pub fn Interner(comptime T: type, comptime Context: type) type {
    return struct {
        gpa: Allocator,
        context: Context,
        /// Private: the first item with each id.
        items: std.ArrayList(T) = .empty,
        /// Private: open addressing over the hashes, a power of two of them.
        slots: std.ArrayList(Slot) = .empty,

        const Self = @This();
        // aegis: measured-boundary: docs/design.md#numeric-boundaries; the one-domain probe loop stores class+1, reserving zero for an empty slot.
        const Slot = struct { hash: u64, id: u32 };

        pub fn init(gpa: Allocator, context: Context) Self {
            return .{ .gpa = gpa, .context = context };
        }

        pub fn deinit(s: *Self) void {
            s.items.deinit(s.gpa);
            s.slots.deinit(s.gpa);
            s.* = undefined;
        }

        /// Forget every item, keeping the memory. The table starts small
        /// again, so a clear after one large use costs little.
        pub fn clear(s: *Self) void {
            s.items.clearRetainingCapacity();
            s.slots.shrinkRetainingCapacity(@min(s.slots.items.len, 64));
            @memset(s.slots.items, .{ .hash = 0, .id = 0 });
        }

        /// How many distinct items: every id is below this.
        pub fn classes(s: *const Self) ClassCount {
            return .fromRaw(@intCast(s.items.items.len)); // safe: intern refuses the u32 class ceiling before appending
        }

        /// The first item interned with `id`.
        pub fn get(s: *const Self, id: ClassId) T {
            return s.items.items[id.raw()];
        }

        pub const InternError = error{ OutOfMemory, TooManyClasses };

        /// The id of `item`, a new one if no equal item came before.
        pub fn intern(s: *Self, item: T) InternError!ClassId {
            if ((s.items.items.len + 1) * 2 > s.slots.items.len) try s.grow();
            const h = s.context.hash(item);
            const mask = s.slots.items.len - 1;
            var at: usize = @intCast(h & mask);
            while (true) : (at = (at + 1) & mask) {
                const slot = &s.slots.items[at];
                if (slot.id == 0) {
                    if (s.items.items.len == std.math.maxInt(u32)) return error.TooManyClasses;
                    try s.items.append(s.gpa, item);
                    slot.* = .{ .hash = h, .id = @intCast(s.items.items.len) };
                    return .fromRaw(slot.id - 1);
                }
                if (slot.hash == h and s.context.eql(s.items.items[slot.id - 1], item)) return .fromRaw(slot.id - 1);
            }
        }

        /// The id of every item, into `out`, which is as long as `items`.
        pub fn internSlice(s: *Self, items: []const T, out: []ClassId) InternError!void {
            std.debug.assert(items.len == out.len);
            for (items, out) |item, *id| id.* = try s.intern(item);
        }

        // aegis: design: docs/design.md#numeric-boundaries; the live slot extent and half-full invariant bound the double-size table plus scratch before allocation.
        fn grow(s: *Self) Allocator.Error!void {
            const old_len = s.slots.items.len;
            const new_len = @max(64, old_len * 2);
            // The new table after the live slots, then the live ones moved in.
            try s.slots.resize(s.gpa, old_len + new_len);
            const table = s.slots.items[old_len..][0..new_len];
            @memset(table, .{ .hash = 0, .id = 0 });
            const mask = new_len - 1;
            for (s.slots.items[0..old_len]) |slot| {
                if (slot.id == 0) continue;
                var at: usize = @intCast(slot.hash & mask);
                while (table[at].id != 0) at = (at + 1) & mask;
                table[at] = slot;
            }
            @memmove(s.slots.items[0..new_len], table);
            s.slots.shrinkRetainingCapacity(new_len);
        }
    };
}

test "equal items share an id and ids are dense in first-seen order" {
    var interner: Interner([]const u8, std.hash_map.StringContext) = .init(std.testing.allocator, .{});
    defer interner.deinit();
    const words = [_][]const u8{ "the", "cat", "the", "hat", "cat" };
    var ids: [words.len]ClassId = undefined;
    try interner.internSlice(&words, &ids);
    try std.testing.expectEqualSlices(ClassId, &.{ .fromRaw(0), .fromRaw(1), .fromRaw(0), .fromRaw(2), .fromRaw(1) }, &ids);
    try std.testing.expectEqual(ClassCount.fromRaw(3), interner.classes());
    try std.testing.expectEqualStrings("hat", interner.get(.fromRaw(2)));
    interner.clear();
    try std.testing.expectEqual(ClassId.fromRaw(0), try interner.intern("hat"));
}

test "the table grows and keeps every id" {
    var interner: Interner(u64, std.hash_map.AutoContext(u64)) = .init(std.testing.allocator, .{});
    defer interner.deinit();
    for (0..5000) |i| try std.testing.expectEqual(ClassId.fromRaw(@intCast(i % 1700)), try interner.intern(i % 1700));
    try std.testing.expectEqual(ClassCount.fromRaw(1700), interner.classes());
}
