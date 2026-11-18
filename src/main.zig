const std = @import("std");
const win = @import("windows.zig");
const windows = std.os.windows;

// ------ WinAPI -----
pub const CONSOLE_CHARACTER_ATTRIBUTES = packed struct(u16) {
    FOREGROUND_BLUE: u1 = 0,
    FOREGROUND_GREEN: u1 = 0,
    FOREGROUND_RED: u1 = 0,
    FOREGROUND_INTENSITY: u1 = 0,
    BACKGROUND_BLUE: u1 = 0,
    BACKGROUND_GREEN: u1 = 0,
    BACKGROUND_RED: u1 = 0,
    BACKGROUND_INTENSITY: u1 = 0,
    COMMON_LVB_LEADING_BYTE: u1 = 0,
    COMMON_LVB_TRAILING_BYTE: u1 = 0,
    COMMON_LVB_GRID_HORIZONTAL: u1 = 0,
    COMMON_LVB_GRID_LVERTICAL: u1 = 0,
    COMMON_LVB_GRID_RVERTICAL: u1 = 0,
    _13: u1 = 0,
    COMMON_LVB_REVERSE_VIDEO: u1 = 0,
    COMMON_LVB_UNDERSCORE: u1 = 0,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: CONSOLE_CHARACTER_ATTRIBUTES,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOuput: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;

// ------ Global Variables -----
var zilo_version: []const u8 = "0.0.1";

/// disables canonical mode.
var enable_line_input: u32 = 0x0002;
/// When enabled, the console copies characters read from
/// the application input buffer to the active screen buffer.
/// Causes input from the user to be visible on screen.
/// Must be flipped along-side enable_line_input.
var enable_echo_input: u32 = 0x0004;
/// Tells the windows console to intercept and process control keys (Ctrl+C) seperately
/// instead of writing to application input buffer.
var enable_processed_input: u32 = 0x0001;
/// Translates special physical keys (Esc, Page Up, Page Down) to
/// ANSI Virtual Terminal Escape Sequences.
var enable_virtual_terminal_input: u32 = 0x0200;
var enable_virtual_terminal_processing: u32 = 0x0004;
var disable_newline_auto_return: u32 = 0x0008;

const EditorError = error{
    ExitKeyPressed,
};

const EditorMode = enum {
    Insert,
    Normal,
};

pub const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

pub const EditorKey = enum {
    ArrowUp,
    ArrowDown,
    ArrowRight,
    ArrowLeft,
    PageUp,
    PageDown,
    Home,
    End,
    Del,
    ModeChange,
    Enter,
    Backspace,
    Tab,
    Invalid,
    Quit,
};

/// Returns the control key for that character.
///
/// Eg: q -> Ctrl + q.
pub fn controlKey(c: u8) u8 {
    return c & std.ascii.control_code.us;
}

pub const Row = struct {
    buffer: std.ArrayList(u8),
};

pub const Position = struct {
    x: u16,
    y: u16,
};

pub const EditorInput = union(enum) {
    key: EditorKey,
    value: u8,
};

pub const Editor = struct {
    console: struct {
        initial_input_mode: windows.DWORD = 0,
        initial_output_mode: windows.DWORD = 0,
        console_screen_buffer_info: CONSOLE_SCREEN_BUFFER_INFO = undefined,
    },
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    terminal_rows: u16, // Number of rows the terminal currently has.
    terminal_cols: u16, // Number of columns the terminal currently has.
    cursor: Position,
    mode: EditorMode,
    rows: std.ArrayList(Row),

    pub fn init(alloc: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !Editor {
        const stdin = std.Io.File.stdin();
        const stdout = std.Io.File.stdout();

        var input_mode: windows.DWORD = 0;
        if (GetConsoleMode(stdin.handle, &input_mode) == windows.BOOL.FALSE) {
            std.debug.print("Failed to get console input mode - {d}\r\n", .{windows.GetLastError()});
            return error.EditorInitializationFailure;
        }

        var output_mode: windows.DWORD = 0;
        if (GetConsoleMode(stdout.handle, &output_mode) == windows.BOOL.FALSE) {
            std.debug.print("Failed to get console output mode - {d}\r\n", .{windows.GetLastError()});
            return error.EditorInitializationFailure;
        }

        var csbi: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(stdout.handle, &csbi) == windows.BOOL.FALSE) {
            std.debug.print("Failed to get console screen buffer info - {d}\r\n", .{windows.GetLastError()});
            return error.EditorInitializationFailure;
        }

        const terminal_cols: u16 = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1);
        var rows = try std.ArrayList(Row).initCapacity(alloc, 1);
        try rows.append(alloc, Row{
            .buffer = try std.ArrayList(u8).initCapacity(alloc, terminal_cols),
        });
        @memset(rows.items[0].buffer.items, 0);

        return Editor{
            .reader = reader,
            .writer = writer,
            .console = .{
                .initial_input_mode = input_mode,
                .initial_output_mode = output_mode,
                .console_screen_buffer_info = csbi,
            },
            .terminal_rows = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1),
            .terminal_cols = terminal_cols,
            .cursor = .{
                .x = 0,
                .y = 0,
            },
            .mode = EditorMode.Normal,
            .rows = rows,
        };
    }

    pub fn openFile(self: *Editor, io: std.Io, alloc: std.mem.Allocator, file_path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{
            .mode = .read_only,
            .allow_directory = false,
        });

        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        var reader = &file_reader.interface;

        const data = try reader.allocRemaining(alloc, .unlimited);
        defer alloc.free(data);

        self.mode = EditorMode.Insert;
        var idx: usize = 0;
        while (idx < data.len) {
            if (self.cursor.y == self.terminal_rows - 2) break;

            const c = data[idx];
            if (c == '\r') {
                try self.addRow(alloc);
                idx += 1;
            } else {
                try self.write(alloc, c);
            }

            idx += 1;
        }
        self.mode = EditorMode.Normal;
    }

    /// By default terminals process input in canonical mode, i.e input from a user is
    /// sent to the program when they press ENTER. To process each character of user input
    /// as they appear, we need the terminal to process input in Raw mode.
    pub fn enableRawMode(self: *Editor) !void {
        const stdin_handle = std.Io.File.stdin().handle;
        const stdout_handle = std.Io.File.stdout().handle;

        const input_mode = self.console.initial_input_mode & ~(enable_line_input | enable_echo_input | enable_processed_input);
        if (SetConsoleMode(stdin_handle, input_mode) == windows.BOOL.FALSE) {
            std.debug.print("Failed to set console input mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorEnablingRawMode;
        }

        const output_mode = self.console.initial_output_mode | enable_virtual_terminal_processing | disable_newline_auto_return;
        if (SetConsoleMode(stdout_handle, output_mode) == windows.BOOL.FALSE) {
            std.debug.print("Failed to set console output mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorEnablingRawMode;
        }
    }

    pub fn disableRawMode(self: *Editor) !void {
        const stdin_handle = std.Io.File.stdin().handle;
        const stdout_handle = std.Io.File.stdout().handle;

        if (SetConsoleMode(stdin_handle, self.console.initial_input_mode) == windows.BOOL.FALSE) {
            std.debug.print("Failed to set console input mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorDisablingRawMode;
        }

        if (SetConsoleMode(stdout_handle, self.console.initial_output_mode) == windows.BOOL.FALSE) {
            std.debug.print("Failed to set console output mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorDisablingRawMode;
        }
    }

    pub fn readTimeout(self: *Editor, timeout: u32) !?u8 {
        const stdin_handle = std.Io.File.stdin().handle;
        const WAIT_OBJECT_0: u32 = 0;
        if (WaitForSingleObject(stdin_handle, timeout) == WAIT_OBJECT_0) {
            return try self.reader.takeByte();
        }
        return null;
    }

    pub fn readInput(self: *Editor) !EditorInput {
        const stdin = std.Io.File.stdin();
        var input: win.INPUT_RECORD = undefined;
        var num_inputs_read: win.DWORD = 0;

        if (win.ReadConsoleInputA(stdin.handle, &input, 1, &num_inputs_read) == win.BOOL.FALSE) {
            std.debug.print("ERROR: Unable to read console input: {d}\n", .{std.os.windows.GetLastError()});
            return error.ErrorConsoleInput;
        }

        if (input.EventType == win.key_event) {
            const event = input.Event.KeyEvent;
            if (event.dwControlKeyState & win.left_ctrl_pressed != 0 or
                event.dwControlKeyState & win.right_ctrl_pressed != 0)
            {
                switch (event.wVirtualKeyCode) {
                    win.VirtualKey.KeyQ => {
                        return .{ .key = EditorKey.Quit };
                    },
                    else => {
                        return .{ .key = EditorKey.Invalid };
                    },
                }
            }

            if (event.bKeyDown == win.BOOL.FALSE) {
                return .{ .key = EditorKey.Invalid };
            }

            switch (event.wVirtualKeyCode) {
                // ------------ Movement --------------
                win.VirtualKey.Home => {
                    return .{ .key = EditorKey.Home };
                },
                win.VirtualKey.Left => {
                    return .{ .key = EditorKey.ArrowLeft };
                },
                win.VirtualKey.Up => {
                    return .{ .key = EditorKey.ArrowUp };
                },
                win.VirtualKey.Right => {
                    return .{ .key = EditorKey.ArrowRight };
                },
                win.VirtualKey.Down => {
                    return .{ .key = EditorKey.ArrowDown };
                },
                win.VirtualKey.KeyW => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowUp };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                win.VirtualKey.KeyD => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowRight };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                win.VirtualKey.KeyS => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowDown };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                win.VirtualKey.KeyA => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowLeft };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                win.VirtualKey.PageUp => {
                    return .{ .key = EditorKey.PageUp };
                },
                win.VirtualKey.PageDown => {
                    return .{ .key = EditorKey.PageDown };
                },

                // ------------ Mode Change --------------
                win.VirtualKey.Escape => {
                    if (self.mode == EditorMode.Insert) {
                        return .{ .key = EditorKey.ModeChange };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                win.VirtualKey.KeyI => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ModeChange };
                    }
                    return .{ .value = value };
                },

                // ------------ Text --------------
                win.VirtualKey.BackSpace, win.VirtualKey.Delete => {
                    return .{ .key = EditorKey.Backspace };
                },
                win.VirtualKey.Tab => {
                    if (self.mode == EditorMode.Normal) {
                        return .{ .key = EditorKey.Invalid };
                    }
                    return .{ .key = EditorKey.Tab };
                },
                win.VirtualKey.Enter => {
                    if (self.mode == EditorMode.Insert) {
                        return .{ .key = EditorKey.Enter };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                win.VirtualKey.Space => {
                    if (self.mode == EditorMode.Insert) {
                        return .{ .value = event.uChar.AsciiChar };
                    }
                    return .{ .key = EditorKey.Invalid };
                },

                else => {
                    if (event.uChar.AsciiChar == 0) {
                        return .{ .key = EditorKey.Invalid };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
            }
        }

        return .{ .key = EditorKey.Invalid };
    }

    pub fn processKeypress(self: *Editor, alloc: std.mem.Allocator) !void {
        const value = try self.readInput();
        return switch (value) {
            .key => {
                return switch (value.key) {
                    EditorKey.ArrowLeft => self.moveCursorLeft(),
                    EditorKey.ArrowRight => {
                        const row = &self.rows.items[self.cursor.y];
                        if (self.cursor.x < row.buffer.items.len) self.cursor.x += 1;
                    },
                    EditorKey.ArrowUp => {
                        self.cursor.y = self.cursor.y -| 1;
                        self.cursor.x = @min(self.cursor.x, self.rows.items[self.cursor.y].buffer.items.len);
                    },
                    EditorKey.ArrowDown => {
                        if (self.cursor.y + 1 < self.rows.items.len) {
                            self.cursor.y += 1;
                            self.cursor.x = @min(self.cursor.x, self.rows.items[self.cursor.y].buffer.items.len);
                        }
                    },
                    EditorKey.PageUp => {
                        self.cursor.y = 0;
                        self.cursor.x = @min(self.cursor.x, self.rows.items[self.cursor.y].buffer.items.len);
                    },
                    EditorKey.PageDown => {
                        self.cursor.y = @intCast(self.rows.items.len - 1);
                        self.cursor.x = @min(self.cursor.x, self.rows.items[self.cursor.y].buffer.items.len);
                    },
                    EditorKey.Home => {
                        self.cursor.x = 0;
                    },
                    EditorKey.End => {
                        self.cursor.x = @min(self.rows.items[self.cursor.y].buffer.items.len, self.terminal_cols);
                    },
                    EditorKey.ModeChange => {
                        if (self.mode == EditorMode.Normal) {
                            self.mode = EditorMode.Insert;
                            const y: u8 = @intCast(@min(self.rows.items.len - 1, self.cursor.y));
                            const x: u8 = @intCast(@min(self.rows.items[y].buffer.items.len, self.cursor.x));
                            self.cursor.x = x;
                            self.cursor.y = y;
                        } else {
                            self.mode = EditorMode.Normal;
                        }
                    },
                    EditorKey.Enter => {
                        if (self.mode == EditorMode.Normal) return;
                        try self.addRow(alloc);
                    },
                    EditorKey.Tab => {
                        if (self.mode == EditorMode.Normal) return;
                        const cx = @min(self.cursor.x + 4, self.terminal_cols);
                        for (self.cursor.x..cx) |_| {
                            try self.write(alloc, 32);
                        }
                    },
                    EditorKey.Del, EditorKey.Backspace => {
                        if (self.mode == EditorMode.Insert) {
                            try self.delete(alloc);
                        } else if (self.mode == EditorMode.Normal) {
                            self.cursor.x = self.cursor.x -| 1;
                        }
                    },
                    EditorKey.Quit => EditorError.ExitKeyPressed,
                    EditorKey.Invalid => {},
                };
            },
            .value => {
                return switch (value.value) {
                    controlKey('q') => EditorError.ExitKeyPressed,
                    else => {
                        if (self.mode == EditorMode.Normal) return;
                        try self.write(alloc, value.value);
                    },
                };
            },
        };
    }

    pub fn refreshScreen(self: *Editor) !void {
        // Hide the cursor.
        try self.writer.writeAll("\x1b[?25l");

        // Position the cursor at the first column and row.
        try self.writer.writeAll("\x1b[H");

        // Wipe the scroll back buffer, i.e the history above visible window.
        try self.writer.writeAll("\x1b[3J");

        try self.renderRows();
        _ = try self.writer.print("\x1b[{d};{d}H", .{ self.cursor.y + 1, self.cursor.x + 1 });

        // Unhide the cursor
        try self.writer.writeAll("\x1b[?25h");

        try self.writer.flush();
    }

    /// Adds a new row.
    /// Advances the cursor's y coordinate by one.
    pub fn addRow(self: *Editor, alloc: std.mem.Allocator) !void {
        self.cursor.y += 1;
        try self.rows.insert(alloc, self.cursor.y, Row{
            .buffer = try std.ArrayList(u8).initCapacity(alloc, self.terminal_cols),
        });
        @memset(self.rows.items[self.cursor.y].buffer.items, 0);

        const prev_row = &self.rows.items[self.cursor.y - 1];
        const remaining = try alloc.dupe(u8, prev_row.buffer.items[self.cursor.x..]);
        for (self.cursor.x..prev_row.buffer.items.len) |_| {
            const c = prev_row.buffer.pop();
            if (c == null) break;
        }

        self.cursor.x = 0;
        for (remaining) |c| {
            try self.writeCharacter(alloc, c);
        }
        self.cursor.x = 0;
    }

    pub fn delete(self: *Editor, alloc: std.mem.Allocator) !void {
        std.debug.assert(self.mode == EditorMode.Insert);
        const row = &self.rows.items[self.cursor.y];

        if (self.cursor.x == 0 and self.cursor.y > 0) {
            const cx = self.rows.items[self.cursor.y - 1].buffer.items.len;
            const remaining = try row.buffer.toOwnedSlice(alloc);
            row.buffer.deinit(alloc);
            _ = self.rows.orderedRemove(self.cursor.y);
            self.moveCursorLeft();
            for (remaining) |c| {
                try self.write(alloc, c);
            }
            self.cursor.x = @intCast(cx);
        } else if (self.cursor.x > 0) {
            self.moveCursorLeft();
            _ = row.buffer.orderedRemove(self.cursor.x);
        }
    }

    /// Writes the character at the current cursor's position.
    /// Advances the cursor's x coordinate by one.
    pub fn writeCharacter(self: *Editor, alloc: std.mem.Allocator, character: u8) !void {
        std.debug.assert(self.mode == EditorMode.Insert);
        std.debug.assert(self.cursor.y < self.rows.items.len);
        std.debug.assert(self.cursor.x <= self.rows.items[self.cursor.y].buffer.items.len);

        const row = &self.rows.items[self.cursor.y];
        try row.buffer.insert(alloc, self.cursor.x, character);
        self.cursor.x += 1;
    }

    /// Writes the character at the current cursor's position.
    /// May add a new row if the cursor is at the edge of the screen.
    pub fn write(self: *Editor, alloc: std.mem.Allocator, character: u8) !void {
        std.debug.assert(self.mode == EditorMode.Insert);
        std.debug.assert(self.cursor.y < self.rows.items.len);
        std.debug.assert(self.cursor.x <= self.rows.items[self.cursor.y].buffer.items.len);

        if (self.cursor.x == self.terminal_cols - 1) {
            try self.addRow(alloc);
        }

        return try self.writeCharacter(alloc, character);
    }

    pub fn renderRows(self: *Editor) !void {
        try self.writer.writeAll("\x1b[K");

        for (0..self.rows.items.len) |idx| {
            try self.writer.writeAll(self.rows.items[idx].buffer.items);
            try self.writer.writeAll("\r\n");
            try self.writer.writeAll("\x1b[K");
        }

        const start: u8 = @intCast(self.rows.items.len);
        const end: u8 = @intCast(self.terminal_rows);
        for (start..end) |i| {
            if (i < self.terminal_rows - 1) {
                try self.writer.writeAll("~");
                try self.writer.writeAll("\r\n");
            } else {
                const mode = switch (self.mode) {
                    EditorMode.Insert => "---- INSERT ----",
                    EditorMode.Normal => "---- NORMAL ----",
                };
                try self.writer.writeAll(mode);
            }
            // Clear the line after the current position.
            try self.writer.writeAll("\x1b[K");
        }
    }

    pub fn moveCursorLeft(self: *Editor) void {
        if (self.cursor.x > 0) {
            self.cursor.x -= 1;
            return;
        }

        if (self.cursor.y > 0) {
            self.cursor.y -= 1;
            self.cursor.x = @intCast(self.rows.items[self.cursor.y].buffer.items.len);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &read_buffer);
    var stdout_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    const allocator = init.arena.allocator();

    var editor = Editor.init(allocator, &stdin_reader.interface, &stdout_writer.interface) catch |err| {
        std.debug.print("ERROR: Unable to initialize editor: {any}\r\n", .{err});
        return err;
    };

    var it = try init.minimal.args.iterateAllocator(allocator);
    defer it.deinit();

    defer editor.disableRawMode() catch {};
    try editor.enableRawMode();

    _ = it.next();
    if (it.next()) |path| {
        try editor.openFile(init.io, allocator, path);
    }

    while (true) {
        editor.refreshScreen() catch |err| {
            std.debug.print("ERROR: Refreshing screen: {any}\r\n", .{err});
        };

        editor.processKeypress(allocator) catch |err| switch (err) {
            EditorError.ExitKeyPressed => {
                _ = try editor.writer.write("\x1b[2J");
                _ = try editor.writer.write("\x1b[H");
                _ = try editor.writer.write("\x1b[3J");
                try editor.writer.flush();
                break;
            },
            else => std.debug.print("ERROR: Reading byte from terminal: {any}\r\n", .{err}),
        };
    }
}
