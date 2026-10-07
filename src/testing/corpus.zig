//! Reads the fixture corpus captured from git (`testdata/git-<version>/`):
//! a text header ending at an empty line, then records of `fields` fields,
//! each a little-endian u32 length and that many bytes.

const std = @import("std");

pub const Corpus = struct {
    /// The header's lines: kind, git version, field names.
    git_version: []const u8,
    fields: usize,
    names: []const u8,
    body: []const u8,

    pub fn parse(bytes: []const u8) !Corpus {
        const end = std.mem.find(u8, bytes, "\n\n") orelse return error.BadCorpus;
        var lines = std.mem.splitScalar(u8, bytes[0..end], '\n');
        _ = lines.next() orelse return error.BadCorpus;
        const version = lines.next() orelse return error.BadCorpus;
        const fields_line = lines.next() orelse return error.BadCorpus;
        if (!std.mem.startsWith(u8, fields_line, "fields:")) return error.BadCorpus;
        const names = std.mem.trim(u8, fields_line["fields:".len..], " ");
        return .{
            .git_version = version,
            .fields = std.mem.count(u8, names, " ") + 1,
            .names = names,
            .body = bytes[end + 2 ..],
        };
    }

    pub fn records(c: Corpus) Iterator {
        return .{ .corpus = c };
    }
};

pub const max_fields = 16;

pub const Record = struct {
    fields: [max_fields][]const u8,
    index: usize,
};

pub const Iterator = struct {
    corpus: Corpus,
    at: usize = 0,
    index: usize = 0,

    pub fn next(it: *Iterator) ?Record {
        const body = it.corpus.body;
        if (it.at >= body.len) return null;
        var r: Record = .{ .fields = undefined, .index = it.index };
        for (0..it.corpus.fields) |f| {
            const len = std.mem.readInt(u32, body[it.at..][0..4], .little);
            it.at += 4;
            r.fields[f] = body[it.at..][0..len];
            it.at += len;
        }
        it.index += 1;
        return r;
    }
};

/// The flags field, one per line.
pub fn flags(field: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, field, '\n');
}
