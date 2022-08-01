const git = @cImport({
    @cInclude("git2/config.h");
    @cInclude("git2/errors.h");
    @cInclude("git2/global.h");
    @cInclude("git2/repository.h");
});

const std = @import("std");

const expect = std.testing.expect;

// TODO: make non-fatal errors warnings and still exec git

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

        const git_path = try std.fs.path.joinZ(allocator, &[_][]const u8{ entry, "git" });
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

            return error.LibGit2Failed;
        }
        return config_entry;
    }
};

fn die(err: []const u8) void {
    std.io.getStdErr().writer().print("\x1b[2;31mgit-brief: {s}\x1b[0m\n", .{err}) catch {};
    std.os.exit(1);
}

fn die_oom() void {
    die("out of memory");
}

fn die_detect(err: anyerror) void {
    switch (err) {
        std.mem.Allocator.Error.OutOfMemory => {
            die_oom();
        },
        else => die("unknown error"),
    }
}

// should mimic https://github.com/git/git/blob/23b219f8e3f2adfb0441e135f0a880e6124f766c/alias.c#L54
fn split_cmdline(allocator: std.mem.Allocator, cmdline: []const u8) std.mem.Allocator.Error![]const []const u8 {
    // will contain the split arguments
    var split = std.ArrayList([]const u8).init(allocator);

    // will contain positions of quotes that should be removed
    var quotes = std.ArrayList(usize).init(allocator);
    defer quotes.deinit();

    // 0 if there's no quote in effect, or the character that started the
    // quoting if it is active; either '\'' or '"'
    var quote: u8 = 0;
    // the start of the current section
    var s: usize = 0;
    // the current index
    var i: usize = 0;

    while (i < cmdline.len) {
        const c = cmdline[i];
        if (quote == 0) {
            if (c == '\'' or c == '"') {
                // a quoted section is starting
                try quotes.append(i - s);
                quote = c;
                i += 1;
            } else if (c == ' ') {
                // this is the division of a section
                if (s != i) {
                    try split.append(try excluding_quotes(allocator, quotes.items, cmdline[s..i]));
                    // the arraylist doesn't own it's elements, so we don't
                    // deinitalize it
                    try quotes.resize(0);
                } // otherwise, the current section contains only a ' ', so ignore it
                i += 1;
                s = i;
            } else {
                i += 1;
            }
        } else {
            if (c == quote) {
                try quotes.append(i - s);
                quote = 0;
            } else if (quote == '"' and c == '\\') {
                try quotes.append(i - s);
                i += 1;
            }
            i += 1;
        }
    }
    if (s != i) {
        try split.append(try excluding_quotes(allocator, quotes.items, cmdline[s..i]));
        try quotes.resize(0);
    } // otherwise, the current section contains only a ' ', so ignore it

    return split.toOwnedSlice();
}

fn excluding_quotes(allocator: std.mem.Allocator, quotes: []usize, original: []const u8) ![]const u8 {
    var after = std.ArrayList(u8).init(allocator);
    var p: usize = 0;

    for (quotes) |q| {
        try after.appendSlice(original[p..q]);
        p = q + 1;
    }
    try after.appendSlice(original[p..]);

    return after.toOwnedSlice();
}

test "split simple" {
    const actual = try split_cmdline(std.testing.allocator, "rebase --interactive");
    const expected = &[_][]const u8{ "rebase", "--interactive" };
    try expect(actual.len == expected.len);
    var i: usize = 0;
    while (i < actual.len) : (i += 1) {
        try std.testing.expectEqualStrings(actual[i], expected[i]);
        std.testing.allocator.free(actual[i]);
    }
    std.testing.allocator.free(actual);
}

test "split single quote" {
    const actual = try split_cmdline(std.testing.allocator, "commit -m 'this - a thing'");
    const expected = &[_][]const u8{ "commit", "-m", "this - a thing" };
    try expect(actual.len == expected.len);
    var i: usize = 0;
    while (i < actual.len) : (i += 1) {
        try std.testing.expectEqualStrings(actual[i], expected[i]);
        std.testing.allocator.free(actual[i]);
    }
    std.testing.allocator.free(actual);
}

test "split double quote" {
    const actual = try split_cmdline(std.testing.allocator, "commit -m \"this - a thing\"");
    const expected = &[_][]const u8{ "commit", "-m", "this - a thing" };
    try expect(actual.len == expected.len);
    var i: usize = 0;
    while (i < actual.len) : (i += 1) {
        try std.testing.expectEqualStrings(actual[i], expected[i]);
        std.testing.allocator.free(actual[i]);
    }
    std.testing.allocator.free(actual);
}

test "split single quote escape" {
    // an escape in single quotes shouldn't have any effect
    const actual = try split_cmdline(std.testing.allocator, "commit -m 'this - a thing\\'");
    const expected = &[_][]const u8{ "commit", "-m", "this - a thing\\" };
    try expect(actual.len == expected.len);
    var i: usize = 0;
    while (i < actual.len) : (i += 1) {
        try std.testing.expectEqualStrings(actual[i], expected[i]);
        std.testing.allocator.free(actual[i]);
    }
    std.testing.allocator.free(actual);
}

test "split double quote escape" {
    // an escape in double quotes should have an effect
    const actual = try split_cmdline(std.testing.allocator, "commit -m \"this - a thing\\\" more\"");
    const expected = &[_][]const u8{ "commit", "-m", "this - a thing\" more" };
    try expect(actual.len == expected.len);
    var i: usize = 0;
    while (i < actual.len) : (i += 1) {
        try std.testing.expectEqualStrings(actual[i], expected[i]);
        std.testing.allocator.free(actual[i]);
    }
    std.testing.allocator.free(actual);
}

fn indexOfSlice(comptime T: type, haystack: []const []const T, needle: []const []const T) ?usize {
    var i: usize = 0;
    outer: while (i < haystack.len) : (i += 1) {
        var j: usize = 0;
        while (i + j < haystack.len and j < needle.len) : (j += 1) {
            if (!std.mem.eql(T, haystack[i + j], needle[j])) {
                continue :outer;
            }
        }
        return i;
    }
    return null;
}

fn containsShortFlags(allocator: std.mem.Allocator, parts: []const []const u8, short_flags: []const u8) std.mem.Allocator.Error!bool {
    // collect all the short flags that can be found
    var seen_flags = std.AutoHashMap(i32, void).init(allocator);
    for (parts) |part| {
        if (part.len >= 2 and part[0] == '-' and part[1] != '-') {
            for (part) |c| {
                try seen_flags.put(c, {});
            }
        }
    }

    // iterate through the flags we want, if any of them aren't found, return
    // false
    for (short_flags) |flag| {
        if (seen_flags.get(flag) == null) {
            return false;
        }
    }

    return true;
}

fn containsShortFollowedByValue(parts: []const []const u8, short: u8, value: []const u8) std.mem.Allocator.Error!bool {
    for (parts) |part, i| {
        // if the current part is a set of short flags, and there is a next
        // value, and the current set of short flags ends with the target flag,
        // and the next value is equal to the target value, then return true
        if (part.len >= 2 and part[0] == '-' and part[1] != '-' and i + 1 < parts.len and part[part.len - 1] == short and std.mem.eql(u8, parts[i + 1], value)) {
            return true;
        }
    }

    return false;
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // an arraylist to hold all the sentinel-terminated command line args
    var argv_slist = std.ArrayList(?[*:0]const u8).init(allocator);
    // an arraylist to hold all the slice command line args
    var argv_list = std.ArrayList([]const u8).init(allocator);

    var args = std.process.argsWithAllocator(allocator) catch {
        die_oom();
    };
    while (args.next()) |a| {
        argv_slist.append(a) catch {
            die_oom();
        };
        argv_list.append(std.mem.span(a)) catch {
            die_oom();
        };
    }
    args.deinit();


    // the path to the git binary that will be executed
    const git_path = find_git(allocator, argv_list.items[0]) catch |err| {
        return die_detect(err);
    } orelse "/usr/bin/git";

    var best_advice: ?[2][]const u8 = null;

    // iterate through config
    var config_iterator = ConfigIterator.init("^alias\\.") catch {
        return die("libgit2 failure");
    };
    outer: while (config_iterator.next()) |rentry| {
        // prep work
        const entry = rentry orelse {
            break;
        };
        const value = std.mem.span(entry.value);
        // if it starts with '!', it's an alias that will be evaulated by the
        // shell, so we can't support it, and if it's empty then it won't be of
        // much use so we just skip too
        if (value.len == 0 or value[0] == '!') {
            continue;
        }
        const parts = split_cmdline(allocator, value) catch {
            return die_oom();
        };
        defer {
            for (parts) |part| {
                allocator.free(part);
            }
            allocator.free(parts);
        }

        // iterate through the arguments
        var i: usize = 0;
        while (i < parts.len) : (i += 1) {
            if (parts[i].len != 0 and parts[i][0] == '-') {
                // this argument is a flag of some kind
                if (parts[i].len >= 2 and parts[i][1] == '-') {
                    // this argument is a long flag

                    // if the next argument doesn't look like a flag, check if
                    // this long flag is followed by the same value in the
                    // arguments
                    if (i + 1 < parts.len and (parts[i + 1].len == 0 or parts[i + 1][0] != '-')) {
                        _ = indexOfSlice(u8, argv_list.items, parts[i..i + 2]) orelse {
                            continue :outer;
                        };
                        i += 1;
                    } else {
                        // just check if the flag itself is in the parts
                        _ = indexOfSlice(u8, argv_list.items, &[_][] const u8{parts[i]}) orelse {
                            continue :outer;
                        };
                    }
                } else {
                    // this argument is a short flag

                    var end = parts[i].len - 1;
                    // if the next argument doesn't look like a flag, don't
                    // check for the final short flag generally, instead look
                    // for it, followed by the same entry
                    if (i + 1 < parts.len and (parts[i + 1].len == 0 or parts[i + 1][0] != '-')) {
                        end -= 1;
                        const contains = containsShortFollowedByValue(argv_list.items, parts[i][parts[i].len - 1], parts[i + 1]) catch {
                            return die_oom();
                        };
                        if (!contains) {
                            continue :outer;
                        }
                        i += 1;
                    }

                    const contains = containsShortFlags(allocator, argv_list.items, parts[i][1..end]) catch {
                        return die_oom();
                    };
                    if (!contains) {
                        continue :outer;
                    }
                }
            } else {
                _ = indexOfSlice(u8, argv_list.items, &[_][]const u8{parts[i]}) orelse {
                    continue :outer;
                };
            }
        }

        // if we haven't continue :outer'd to the next iteration yet, this alias
        // is a candidate, so add it if it's better than the current best
        if (best_advice == null or best_advice.?[1].len < value.len) {
            if (best_advice != null) {
                allocator.free(best_advice.?[0]);
                allocator.free(best_advice.?[1]);
            }
            best_advice = [2][]const u8{ allocator.dupe(u8, std.mem.span(entry.name)[6..]) catch {
                return die_oom();
            }, allocator.dupe(u8, value) catch {
                return die_oom();
            } };
        }
    } else |err| {
        die_detect(err);
    }

    config_iterator.deinit();
    argv_list.deinit();

    const argv = argv_slist.toOwnedSliceSentinel(null) catch {
        return die_oom();
    };

    if (best_advice) |advice| {
        std.io.getStdErr().writer().print("\x1b[2;90mgit-brief: you could've used '{s}' instead of '{s}'\x1b[0m\n", .{ advice[0], advice[1] }) catch |err| {
            // TODO: detect better
            die_detect(err);
        };
        allocator.free(advice[0]);
        allocator.free(advice[1]);
    }

    if (true) {
        std.os.execveZ(git_path, argv, &[_:null]?[*:0]const u8{}) catch {
            die("exec failed");
        };
    } else {
        // useful for checking leaks; can't be executed in the release version
        // because argv and git_path cannot be de-allocated before the call to
        // execveZ, at which point control of the process is transfered to git
        allocator.destroy(git_path);
        allocator.free(argv);
        _ = gpa.deinit();
    }
}
