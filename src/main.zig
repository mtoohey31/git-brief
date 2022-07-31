const git = @cImport({
    @cInclude("git2/config.h");
    @cInclude("git2/errors.h");
    @cInclude("git2/global.h");
    @cInclude("git2/repository.h");
});

const stdio = @cImport(@cInclude("stdio.h"));
const std = @import("std");
const mode = @import("builtin").mode;

// using the absolute path is necessary because the user presumeably has this
// program set up as a wrapper for git, so if we use $PATH, we're likely to
// recursively execute ourself endlessly
const git_path = "/usr/bin/git";

// TODO: clean up logging so it looks prettier and declares that it's from
// git-brief, so people don't think errors are coming from git, and don't fail
// to execute git if at all possible, even if we hit an error in the analysis

// TODO: understand aliases and arguments better. for example: ignore
// unimportant whitespce

pub fn main() anyerror!void {
    // initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // an arraylist to hold all the 
    var argv: std.ArrayList(?[*:0]const u8) = undefined;

    // this all happens at a separate level so deinit defers in here happen
    // before leak checks
    {
        argv = std.ArrayList(?[*:0]const u8).init(allocator);
        // an arraylist to hold the args, concatenated by ' '
        var args_concat = std.ArrayList(u8).init(allocator);
        defer args_concat.deinit();
        var args = try std.process.argsWithAllocator(allocator);
        if (args.next()) |a| {
            try argv.append(a);
        }
        if (args.next()) |a| {
            try argv.append(a);
            try args_concat.appendSlice(a);
        }
        while (args.next()) |a| {
            try argv.append(a);
            try args_concat.append(' ');
            try args_concat.appendSlice(a);
        }
        args.deinit();

        // reading the config
        var cfg: ?*git.git_config = undefined;

        // TODO: figure out if there's a way to get libgit2 to print friendly
        // errors
        if (git.git_libgit2_init() < 0) {
            std.log.err("failed to initialize libgit2", .{});
            std.process.exit(1);
        }

        if (git.git_config_open_default(&cfg) < 0) {
            std.log.err("failed to open git configuration", .{});
        }

        var iter: ?*git.git_config_iterator = undefined;
        defer git.git_config_iterator_free(iter);
        if (git.git_config_iterator_glob_new(&iter, cfg, "^alias\\.") < 0) {
            std.log.err("failed to initialize config iterator", .{});
            std.process.exit(1);
        }

        // iterate through config
        var config_entry: ?*git.git_config_entry = undefined;
        while (true) {
            const res = git.git_config_next(&config_entry, iter);
            if (res < 0) {
                // means we've read all the aliases
                if (res == git.GIT_ITEROVER) {
                    break;
                }

                std.log.err("error getting next iterator value", .{});
                std.process.exit(1);
            }

            // TODO: don't print suggestions for which val is a subset of
            // another suggestion that has already been/will be given
            const entry = config_entry.?.*;
            const val = std.mem.span(entry.value);
            if (std.mem.indexOf(u8, args_concat.items, val)) |i| {
                const name = std.mem.span(entry.name)[6..];
                try std.io.getStdErr().writer().print("git-brief: you could've used {s} instead of {s}\n",
                    .{name, args_concat.items[i..i + val.len]});
            }
        }

        if (git.git_libgit2_shutdown() != 0) {
            std.log.err("failed to shutdown libgit2", .{});
            std.process.exit(1);
        }
    }

    // useful for checking leaks
    // _ = gpa.deinit();

    try argv.append(null);
    return std.os.execveZ(git_path,
        @ptrCast([*:null]const ?[*:0]const u8, argv.items),
        &[_:null]?[*:0]const u8{});
}
