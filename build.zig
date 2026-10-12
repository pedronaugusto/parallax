const std = @import("std");

/// What a project that depends on parallax builds: the `parallax` module and its
/// library. The tests, example, benchmarks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    // One module. Its parts are namespaces of the root (`parallax.diff`,
    // `.merge`, `.patch`, ...): none has a dependency or a link of its own,
    // so a separate module would buy nothing Zig's lazy analysis does not.
    const module = b.addModule("parallax", .{
        .root_source_file = b.path("src/parallax.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aegis", .module = aegis }},
    });
    b.installArtifact(b.addLibrary(.{ .name = "parallax", .root_module = module }));
}

/// parallax's development: its tests, example, benchmarks and checks under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const baseline_filter = b.option([]const u8, "baseline-filter", "Select baseline tests by name");
    const package = b.dependency("parallax", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("parallax");
    const library = package.artifact("parallax");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_dependency.module("aegis");
    const tests = b.addTest(.{
        .name = "parallax-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("aegis", aegis);
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    // The references' output, captured once, as data: git's, GNU patch's
    // and the reference's.
    for ([_][]const u8{
        "git-2.55/diff",
        "git-2.55/unified",
        "git-2.55/merge",
        "git-2.55/function",
        "git-2.55/markers",
        "gnu-patch-2.8/patch",
        "gnu-patch-2.8/reversed",
        "cleanup-20241021/cleanup",
    }) |path| {
        const name = path[std.mem.findScalar(u8, path, '/').? + 1 ..];
        tests.root_module.addAnonymousImport(b.fmt("{s}.corpus", .{name}), .{ .root_source_file = p.path(b.fmt("testdata/{s}.corpus", .{path})) });
    }
    tests.root_module.addAnonymousImport("gen", .{ .root_source_file = p.path("bench/gen.zig") });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The benchmark baseline is code with tests of its own; its root runs them.
    const baseline_tests = b.addTest(.{
        .name = "baseline-tests",
        .filters = if (baseline_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("bench/baseline/diff/textdiff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(baseline_tests).step);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    check.dependOn(&baseline_tests.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "parallax", .module = module }} }),
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
            .root_source_file = p.path("bench/main.zig"),
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
            .root_source_file = p.path("bench/cli.zig"),
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
        .root_module = b.createModule(.{ .root_source_file = p.path("bench/corpus.zig"), .target = target, .optimize = .safe }),
    });
    check.dependOn(&corpus.step);
    const corpus_run = b.addRunArtifact(corpus);
    corpus_run.addArg("--manifest");
    corpus_run.addFileArg(p.path("bench/linux-v6.11-v6.12.manifest"));
    corpus_run.addPassthruArgs();
    corpus_run.has_side_effects = true;
    b.step("bench-corpus", "Collect the real-history corpus: -- --repo <git repository> --out <directory>").dependOn(&corpus_run.step);
    // No Io and no OS calls: the library builds for a target with no OS.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const object = b.addObject(.{
        .name = "parallax-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = p.path("ci/freestanding.zig"),
            .target = freestanding,
            .optimize = .small,
            .imports = &.{.{ .name = "parallax", .module = computationModule(b, freestanding, .small) }},
        }),
    });
    b.step("check-freestanding", "Build the library for wasm32-freestanding").dependOn(&object.step);
    tools.preflight.addCi(b, p, .{
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
    tools.preflight.addConsumerCheck(b, p, .{ .package = "parallax", .program = p.path("ci/consumer.zig"), .packages = &.{aegis_dependency} });

    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);
}

/// `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    // The benchmark harness is shakedown's.
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "parallax", .module = computationModule(b, target, optimize) },
    }) catch @panic("out of memory");
}

/// The library for a target, for what builds against it apart from the
/// public module: the benchmarks and the freestanding object.
fn computationModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const p = b.dependency("parallax", .{ .target = target, .optimize = optimize }).builder;
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    return b.createModule(.{
        .root_source_file = p.path("src/parallax.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aegis", .module = aegis }},
    });
}
