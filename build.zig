const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("parallax", .{ .root_source_file = b.path("src/parallax.zig"), .target = target, .optimize = optimize });
    const library = b.addLibrary(.{ .name = "parallax", .root_module = module });
    b.installArtifact(library);
    if (b.dep_prefix.len != 0) return;
    const tests = b.addTest(.{
        .name = "parallax-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Keep configuring on the initial fetch pass so preflight declares
    // every -D option before Zig validates it.
    const shakedown = b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize }) catch null;
    if (shakedown) |dependency| tests.root_module.addImport("shakedown", dependency.module("shakedown"));
    // The references' output, captured once, as data: git's, GNU patch's
    // and diff-match-patch's.
    for ([_][]const u8{
        "git-2.55/diff",
        "git-2.55/unified",
        "git-2.55/merge",
        "git-2.55/function",
        "git-2.55/markers",
        "gnu-patch-2.8/patch",
        "gnu-patch-2.8/reversed",
        "diff-match-patch-20241021/cleanup",
    }) |path| {
        const name = path[std.mem.findScalar(u8, path, '/').? + 1 ..];
        tests.root_module.addAnonymousImport(b.fmt("{s}.corpus", .{name}), .{ .root_source_file = b.path(b.fmt("testdata/{s}.corpus", .{path})) });
    }
    tests.root_module.addAnonymousImport("gen", .{ .root_source_file = b.path("bench/gen.zig") });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "parallax", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&library.step);
    check.dependOn(&example.step);
    // `check` compiles the benchmark in the requested mode; preflight
    // owns its ReleaseFast build and the smoke runs of all bench programs.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = benchImports(b, target, optimize),
        }),
    });
    check.dependOn(&bench.step);
    // A small command over the library, to time against other tools end
    // to end; `check` compiles it with the benchmarks.
    const cli = b.addExecutable(.{
        .name = "parallax-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "parallax", .module = module }},
        }),
    });
    check.dependOn(&cli.step);
    b.step("cli", "Build bench/cli into zig-out/bin (-Doptimize=ReleaseFast to time it)").dependOn(&b.addInstallArtifact(cli, .{}).step);
    // The real-history corpus, made by git from a repository the caller
    // names, written outside this repository.
    const corpus = b.addExecutable(.{
        .name = "bench-corpus",
        .root_module = b.createModule(.{ .root_source_file = b.path("bench/corpus.zig"), .target = target, .optimize = .safe }),
    });
    check.dependOn(&corpus.step);
    const corpus_run = b.addRunArtifact(corpus);
    corpus_run.addArg("--manifest");
    corpus_run.addFileArg(b.path("bench/linux-v6.11-v6.12.manifest"));
    corpus_run.addPassthruArgs();
    corpus_run.has_side_effects = true;
    b.step("bench-corpus", "Collect the real-history corpus: -- --repo <git repository> --out <directory>").dependOn(&corpus_run.step);
    // No Io and no OS calls: the library builds for a target with no OS.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const object = b.addObject(.{
        .name = "parallax-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "parallax", .module = b.createModule(.{ .root_source_file = b.path("src/parallax.zig"), .target = freestanding, .optimize = .small }) }},
        }),
    });
    b.step("check-freestanding", "Build the library for wasm32-freestanding").dependOn(&object.step);
    // CI wiring is this repository's own. preflight is lazy and only the
    // root build asks for it, so a project depending on parallax neither
    // needs nor fetches it.
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .bench = .{
                .programs = &.{
                    .{ .name = "bench", .source = "bench/main.zig" },
                    .{ .name = "parallax-cli", .source = "bench/cli.zig", .timed = false },
                    .{ .name = "bench-corpus", .source = "bench/corpus.zig", .timed = false },
                },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on parallax by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "parallax", .program = b.path("ci/consumer.zig") });
    } else {
        // Zig validates options even on the pass that discovers preflight.
        _ = b.option(bool, "ci-lint", "Run source checks before CI tests");
        _ = b.option(bool, "ci-timings", "Record per-test durations for the next shard balance");
    }

    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
}

fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &.{.{
        .name = "parallax",
        .module = b.createModule(.{ .root_source_file = b.path("src/parallax.zig"), .target = target, .optimize = optimize }),
    }}) catch @panic("out of memory");
}
