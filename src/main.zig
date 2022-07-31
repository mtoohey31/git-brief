const git = @cImport({
    @cInclude("git2/config.h");
    @cInclude("git2/errors.h");
    @cInclude("git2/global.h");
    @cInclude("git2/repository.h");
});

const stdio = @cImport(@cInclude("stdio.h"));
const std = @import("std");
const mode = @import("builtin").mode;

// TODO: clean up logging so it looks prettier and declares that it's from
// git-brief, so people don't think errors are coming from git, and don't fail
// to execute git if at all possible, even if we hit an error in the analysis

// TODO: understand aliases and arguments better. for example: ignore
// unimportant whitespce

fn find_git(allocator: std.mem.Allocator, arg0: []const u8) !?[*:0]const u8 {
    const arg0_dir = std.fs.path.dirname(arg0);
    var path_iterator = std.mem.split(u8, std.os.getenv("PATH").?, ":");
    while (path_iterator.next()) |entry| {
        // if the entry is in the same directory as the binary being executed,
        // skip it because we don't want to re-execute ourself
        if (std.mem.eql(u8, arg0_dir.?, entry)) {
            continue;
        }

        var git_path = try std.fs.path.joinZ(allocator, &[_][]const u8{ entry, "git" });
        var stat: std.os.Stat = undefined;
        // TODO: figure out why std.os.errno is broken
        const r = @bitCast(isize, std.os.linux.stat(git_path, &stat));
        if (r == 0) {
            return git_path;
        } else if (r != -2) {
            return error.StatFailed;
        }
        allocator.free(git_path);
    }
    return null;
}

const ConfigIterator = struct {
    config: ?*git.git_config,
    inner: ?*git.git_config_iterator,

    fn init(glob: [*c]const u8) !ConfigIterator {
        // TODO: figure out if there's a way to get friendly errors from libgit2
        if (git.git_libgit2_init() < 0) {
            return error.LibGit2Failed;
        }

        var self = ConfigIterator{ .config = undefined, .inner = undefined };

        if (git.git_config_open_default(&self.config) < 0) {
            return error.LibGit2Failed;
        }

        if (git.git_config_iterator_glob_new(&self.inner, self.config, glob) < 0) {
            return error.LibGit2Failed;
        }

        return self;
    }

    fn deinit(self: *ConfigIterator) void {
        git.git_config_iterator_free(self.inner);
        git.git_config_free(self.config);

        // "resource deallocation must succeed"
        _ = git.git_libgit2_shutdown();
    }

    fn next(self: *ConfigIterator) !?*git.git_config_entry {
        var config_entry: ?*git.git_config_entry = undefined;
        const res = git.git_config_next(&config_entry, self.inner);
        if (res < 0) {
            // means we've read all the aliases
            if (res == git.GIT_ITEROVER) {
                return null;
            }

            // TODO: figure out what the error is and wrap it
            return error.LibGit2Failed;
        }
        return config_entry;
    }
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // an arraylist to hold all the command line args
    var argv_list = std.ArrayList(?[*:0]const u8).init(allocator);

    var args = try std.process.argsWithAllocator(allocator);
    while (args.next()) |a| {
        try argv_list.append(a);
    }
    args.deinit();

    // args concatenated by ' '
    var args_concat = std.ArrayList(u8).init(allocator);

    for (argv_list.items[1..]) |rarg| {
        if (rarg) |arg| {
            try args_concat.appendSlice(std.mem.span(arg));
            try args_concat.append(' ');
        }
    }
    // remove the last space
    _ = args_concat.popOrNull();

    // the path to the git binary that will be executed
    const git_path = (try find_git(allocator, std.mem.span(argv_list.items[0].?))) orelse "/usr/bin/git";

    // iterate through config
    var config_iterator = try ConfigIterator.init("^alias\\.");
    while (config_iterator.next()) |rentry| {
        if (rentry) |entry| {
            // TODO: don't print suggestions for which val is a subset of
            // another suggestion that has already been/will be given
            const val = std.mem.span(entry.value);
            if (std.mem.indexOf(u8, args_concat.items, val)) |i| {
                const name = std.mem.span(entry.name)[6..];
                try std.io.getStdErr().writer().print("git-brief: you could've used {s} instead of {s}\n", .{ name, args_concat.items[i .. i + val.len] });
            }
        } else {
            break;
        }
    } else |err| {
        std.log.err("error getting next iterator value: {}", .{err});
        std.process.exit(1);
    }

    args_concat.deinit();
    config_iterator.deinit();
    const argv = try argv_list.toOwnedSliceSentinel(null);

    if (true) {
        return std.os.execveZ(git_path, argv, &[_:null]?[*:0]const u8{});
    } else {
        // useful for checking leaks; can't be executed in the release version
        // because argv and git_path cannot be de-allocated before the call to
        // execveZ, at which point control of the process is transfered to git
        allocator.destroy(git_path);
        allocator.free(argv);
        _ = gpa.deinit();
    }
}
