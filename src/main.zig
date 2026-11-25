const std = @import("std");
const windows = @import("windows.zig");

// ------ Global Variables -----
var zilo_version: []const u8 = "0.0.2";

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
    Save,
};

/// Returns the control key for that character.
///
/// Eg: q -> Ctrl + q.
pub fn controlKey(c: u8) u8 {
    return c & std.ascii.control_code.us;
}

pub const Row = struct {
    start: u16,
    end: u16,
};

pub const EditorInput = union(enum) {
    key: EditorKey,
    value: u8,
};

const Position = struct {
    x: u16,
    y: u16,
};

/// Editor
pub const Editor = struct {
    console: struct {
        initial_input_mode: windows.Dword = 0,
        initial_output_mode: windows.Dword = 0,
        console_screen_buffer_info: windows.ConsoleScreenBufferInfo = undefined,
    },
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    terminal_rows: u16, // Number of rows the terminal currently has.
    terminal_cols: u16, // Number of columns the terminal currently has.
    cursor: u16,
    row_offset: u16 = 0,
    mode: EditorMode,
    rows: std.ArrayList(Row),
    buffer: std.ArrayList(u8),
    path: []const u8,

    pub fn init(alloc: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !Editor {
        const stdin = std.Io.File.stdin();
        const stdout = std.Io.File.stdout();

        var input_mode: windows.Dword = 0;
        if (windows.GetConsoleMode(stdin.handle, &input_mode) == windows.Bool.FALSE) {
            std.debug.print("Failed to get console input mode - {d}\r\n", .{windows.GetLastError()});
            return error.EditorInitializationFailure;
        }

        var output_mode: windows.Dword = 0;
        if (windows.GetConsoleMode(stdout.handle, &output_mode) == windows.Bool.FALSE) {
            std.debug.print("Failed to get console output mode - {d}\r\n", .{windows.GetLastError()});
            return error.EditorInitializationFailure;
        }

        var csbi: windows.ConsoleScreenBufferInfo = undefined;
        if (windows.GetConsoleScreenBufferInfo(stdout.handle, &csbi) == windows.Bool.FALSE) {
            std.debug.print("Failed to get console screen buffer info - {d}\r\n", .{windows.GetLastError()});
            return error.EditorInitializationFailure;
        }

        var buffer = try std.ArrayList(u8).initCapacity(alloc, 1024);
        errdefer buffer.deinit(alloc);

        var rows = try std.ArrayList(Row).initCapacity(alloc, 24);
        errdefer rows.deinit(alloc);

        try rows.append(alloc, Row{
            .start = 0,
            .end = 0,
        });

        // Wipe the scroll back buffer, i.e the history above visible window.
        try writer.writeAll("\x1b[3J");

        return Editor{
            .reader = reader,
            .writer = writer,
            .console = .{
                .initial_input_mode = input_mode,
                .initial_output_mode = output_mode,
                .console_screen_buffer_info = csbi,
            },
            .terminal_rows = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1),
            .terminal_cols = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1),
            .cursor = 0,
            .row_offset = 0,
            .mode = EditorMode.Normal,
            .rows = rows,
            .buffer = buffer,
            .path = "",
        };
    }

    pub fn openFile(self: *Editor, io: std.Io, alloc: std.mem.Allocator, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{
            .mode = .read_write,
        });
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buffer);
        var file_reader_if = &file_reader.interface;

        var buffer_writer = std.Io.Writer.Allocating.fromArrayList(alloc, &self.buffer);
        defer buffer_writer.deinit();

        var pending_cr = false;
        while (true) {
            const value = file_reader_if.takeByte() catch |err| switch (err) {
                std.Io.Reader.Error.EndOfStream => break,
                else => {
                    return err;
                },
            };

            if (pending_cr) {
                pending_cr = false;
                if (value == '\n') {
                    try buffer_writer.writer.writeAll("\n");
                    continue;
                } else {
                    try buffer_writer.writer.writeAll("\r");
                }
            }

            if (value == '\r') {
                pending_cr = true;
            } else {
                try buffer_writer.writer.writeByte(value);
            }
        }

        if (pending_cr) {
            try buffer_writer.writer.writeAll("\r");
        }

        try buffer_writer.writer.flush();

        self.buffer = buffer_writer.toArrayList();
        try self.updateRows(alloc);

        self.path = path;
    }

    pub fn save(self: *Editor, io: std.Io) !void {
        if (std.mem.eql(u8, self.path, ""))
            return;

        var file = try std.Io.Dir.cwd().openFile(
            io,
            self.path,
            .{ .mode = .write_only },
        );
        defer file.close(io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        var file_writer_if = &file_writer.interface;

        for (0..self.rows.items.len) |idx| {
            const row = &self.rows.items[idx];
            const buf = self.buffer.items[row.start..row.end];

            try file_writer_if.writeAll(buf);
            if (row.end == self.buffer.items.len or self.buffer.items[row.end] == '\n') {
                try file_writer_if.writeAll("\r\n");
            } else {
                try file_writer_if.writeByte(self.buffer.items[row.end]);
            }
        }

        try file_writer_if.flush();
    }

    /// Recomputes the rows.
    /// Each rows has an index to the beginning and the end of the rows content's in the buffer.
    /// Ensures that there is at least one row at all times.
    pub fn updateRows(self: *Editor, alloc: std.mem.Allocator) !void {
        self.rows.clearRetainingCapacity();
        var row: Row = .{ .start = 0, .end = 0 };

        for (0..self.buffer.items.len) |idx| {
            const c = self.buffer.items[idx];
            if (c == '\n') {
                row.end = @intCast(idx);
                try self.rows.append(alloc, row);
                row.start = @intCast(idx + 1);
            }
        }
        row.end = @intCast(self.buffer.items.len);

        try self.rows.append(alloc, row);
    }

    /// By default terminals process input in canonical mode, i.e input from a user is
    /// sent to the program when they press ENTER. To process each character of user input
    /// as they appear, we need the terminal to process input in Raw mode.
    pub fn enableRawMode(self: *Editor) !void {
        const stdin_handle = std.Io.File.stdin().handle;
        const stdout_handle = std.Io.File.stdout().handle;

        const input_mode = self.console.initial_input_mode & ~(enable_line_input | enable_echo_input | enable_processed_input);
        if (windows.SetConsoleMode(stdin_handle, input_mode) == windows.Bool.FALSE) {
            std.debug.print("Failed to set console input mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorEnablingRawMode;
        }

        const output_mode = self.console.initial_output_mode | enable_virtual_terminal_processing | disable_newline_auto_return;
        if (windows.SetConsoleMode(stdout_handle, output_mode) == windows.Bool.FALSE) {
            std.debug.print("Failed to set console output mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorEnablingRawMode;
        }
    }

    pub fn disableRawMode(self: *Editor) !void {
        const stdin_handle = std.Io.File.stdin().handle;
        const stdout_handle = std.Io.File.stdout().handle;

        if (windows.SetConsoleMode(stdin_handle, self.console.initial_input_mode) == windows.Bool.FALSE) {
            std.debug.print("Failed to set console input mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorDisablingRawMode;
        }

        if (windows.SetConsoleMode(stdout_handle, self.console.initial_output_mode) == windows.Bool.FALSE) {
            std.debug.print("Failed to set console output mode - {d}\r\n", .{windows.GetLastError()});
            return error.ErrorDisablingRawMode;
        }
    }

    pub fn readTimeout(self: *Editor, timeout: u32) !?u8 {
        const stdin_handle = std.Io.File.stdin().handle;
        const WAIT_OBJECT_0: u32 = 0;
        if (windows.WaitForSingleObject(stdin_handle, timeout) == WAIT_OBJECT_0) {
            return try self.reader.takeByte();
        }
        return null;
    }

    pub fn readInput(self: *Editor) !EditorInput {
        const stdin = std.Io.File.stdin();
        var input: windows.InputRecord = undefined;
        var num_inputs_read: windows.Dword = 0;

        if (windows.ReadConsoleInputA(stdin.handle, &input, 1, &num_inputs_read) == windows.Bool.FALSE) {
            std.debug.print("ERROR: Unable to read console input: {d}\n", .{std.os.windows.GetLastError()});
            return error.ErrorConsoleInput;
        }

        if (input.EventType == windows.key_event) {
            const event = input.Event.KeyEvent;
            if (event.dwControlKeyState & windows.left_ctrl_pressed != 0 or
                event.dwControlKeyState & windows.right_ctrl_pressed != 0)
            {
                switch (event.wVirtualKeyCode) {
                    windows.VirtualKey.KeyQ => {
                        return .{ .key = EditorKey.Quit };
                    },
                    windows.VirtualKey.KeyS => {
                        return .{ .key = EditorKey.Save };
                    },
                    else => {
                        return .{ .key = EditorKey.Invalid };
                    },
                }
            }

            if (event.bKeyDown == windows.Bool.FALSE) {
                return .{ .key = EditorKey.Invalid };
            }

            switch (event.wVirtualKeyCode) {
                // ------------ Movement --------------
                windows.VirtualKey.Home => {
                    return .{ .key = EditorKey.Home };
                },
                windows.VirtualKey.Left => {
                    return .{ .key = EditorKey.ArrowLeft };
                },
                windows.VirtualKey.Up => {
                    return .{ .key = EditorKey.ArrowUp };
                },
                windows.VirtualKey.Right => {
                    return .{ .key = EditorKey.ArrowRight };
                },
                windows.VirtualKey.Down => {
                    return .{ .key = EditorKey.ArrowDown };
                },
                windows.VirtualKey.KeyW => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowUp };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                windows.VirtualKey.KeyD => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowRight };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                windows.VirtualKey.KeyS => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowDown };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                windows.VirtualKey.KeyA => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ArrowLeft };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                windows.VirtualKey.PageUp => {
                    return .{ .key = EditorKey.PageUp };
                },
                windows.VirtualKey.PageDown => {
                    return .{ .key = EditorKey.PageDown };
                },

                // ------------ Mode Change --------------
                windows.VirtualKey.Escape => {
                    if (self.mode == EditorMode.Insert) {
                        return .{ .key = EditorKey.ModeChange };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                windows.VirtualKey.KeyI => {
                    const value = event.uChar.AsciiChar;
                    if (self.mode == EditorMode.Normal and std.ascii.isLower(value)) {
                        return .{ .key = EditorKey.ModeChange };
                    }
                    return .{ .value = value };
                },

                // ------------ Text --------------
                windows.VirtualKey.BackSpace => {
                    return .{ .key = EditorKey.Backspace };
                },
                windows.VirtualKey.Delete => {
                    return .{ .key = EditorKey.Del };
                },
                windows.VirtualKey.Tab => {
                    if (self.mode == EditorMode.Normal) {
                        return .{ .key = EditorKey.Invalid };
                    }
                    return .{ .key = EditorKey.Tab };
                },
                windows.VirtualKey.Enter => {
                    if (self.mode == EditorMode.Insert) {
                        return .{ .key = EditorKey.Enter };
                    }
                    return .{ .value = event.uChar.AsciiChar };
                },
                windows.VirtualKey.Space => {
                    if (self.mode == EditorMode.Insert) {
                        return .{ .value = event.uChar.AsciiChar };
                    }
                    return .{ .key = EditorKey.Invalid };
                },

                windows.VirtualKey.F2 => {
                    return .{ .key = EditorKey.Save };
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

    pub fn processKeypress(self: *Editor, io: std.Io, alloc: std.mem.Allocator) !void {
        const value = try self.readInput();
        return switch (value) {
            .key => {
                return switch (value.key) {
                    EditorKey.ArrowLeft => {
                        self.cursor = self.cursor -| 1;
                    },
                    EditorKey.ArrowRight => {
                        const lower: u16 = 0;
                        const upper: u16 = @intCast(self.buffer.items.len);
                        self.cursor = std.math.clamp(self.cursor + 1, lower, upper);
                    },
                    EditorKey.ArrowUp => {
                        const cur = self.getCursorPos();
                        if (cur.y == 0) return;

                        const prev = &self.rows.items[cur.y - 1];
                        self.cursor = prev.start + std.math.clamp(cur.x, 0, prev.end - prev.start);
                    },
                    EditorKey.ArrowDown => {
                        const cursor_position = self.getCursorPos();
                        if (cursor_position.y >= self.rows.items.len - 1) return;

                        const next = &self.rows.items[cursor_position.y + 1];
                        self.cursor = next.start + std.math.clamp(cursor_position.x, 0, next.end - next.start);
                    },
                    EditorKey.PageUp => {},
                    EditorKey.PageDown => {},
                    EditorKey.Home => {},
                    EditorKey.End => {},
                    EditorKey.ModeChange => {
                        if (self.mode == EditorMode.Normal) {
                            self.mode = EditorMode.Insert;
                        } else {
                            self.mode = EditorMode.Normal;
                        }
                    },
                    EditorKey.Enter => {
                        try self.write(alloc, '\n');
                    },
                    EditorKey.Tab => {
                        try self.write(alloc, 32);
                        try self.write(alloc, 32);
                        try self.write(alloc, 32);
                        try self.write(alloc, 32);
                    },
                    EditorKey.Backspace => {
                        try self.backspace(alloc);
                    },
                    EditorKey.Del => {
                        try self.delete(alloc);
                    },
                    EditorKey.Quit => EditorError.ExitKeyPressed,
                    EditorKey.Save => {
                        try self.save(io);
                    },
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

    /// Gets the current cursor position in terms of 0-indexed x, y.
    pub fn getCursorPos(self: *Editor) Position {
        if (self.cursor > self.buffer.items.len) {
            self.cursor = @intCast(self.buffer.items.len);
        }

        var cx: u16 = 0;
        var cy: u16 = 0;

        for (0..self.rows.items.len) |idx| {
            const row = &self.rows.items[idx];
            if (self.cursor >= row.start and self.cursor <= row.end) {
                cy = @intCast(idx);
                cx = @intCast(self.cursor - row.start);
                break;
            }
        }

        return .{
            .x = cx,
            .y = cy,
        };
    }

    pub fn draw(self: *Editor) !void {
        self.scroll();

        // Hide the cursor.
        try self.writer.writeAll("\x1b[?25l");

        // Position the cursor at the first column and row.
        try self.writer.writeAll("\x1b[H");

        try self.renderRows();

        // Draw the cursor.
        const cursor_position = self.getCursorPos();
        _ = try self.writer.print("\x1b[{d};{d}H", .{ cursor_position.y + 1 - self.row_offset, cursor_position.x + 1 });

        // Unhide the cursor
        try self.writer.writeAll("\x1b[?25h");

        try self.writer.flush();
    }

    pub fn backspace(self: *Editor, alloc: std.mem.Allocator) !void {
        if (self.mode == EditorMode.Normal) return;
        if (self.cursor > self.buffer.items.len) {
            self.cursor = @intCast(self.buffer.items.len);
        }

        if (self.cursor == 0) return;

        _ = self.buffer.orderedRemove(self.cursor - 1);
        self.cursor -= 1;

        try self.updateRows(alloc);
    }

    pub fn delete(self: *Editor, alloc: std.mem.Allocator) !void {
        if (self.mode == EditorMode.Normal) return;
        if (self.cursor > self.buffer.items.len) {
            self.cursor = @intCast(self.buffer.items.len);
        }

        if (self.cursor == self.buffer.items.len) return;

        _ = self.buffer.orderedRemove(self.cursor);
        try self.updateRows(alloc);
    }

    /// Writes the character at the current cursor's position.
    /// Increments the cursor's position by one.
    pub fn write(self: *Editor, alloc: std.mem.Allocator, character: u8) !void {
        if (self.mode == EditorMode.Normal) return;
        if (self.cursor > self.buffer.items.len) {
            self.cursor = @intCast(self.buffer.items.len);
        }

        try self.buffer.insert(alloc, self.cursor, character);
        self.cursor += 1;

        try self.updateRows(alloc);
    }

    pub fn scroll(self: *Editor) void {
        const cursor_row = self.getCursorPos().y + 1;
        const page_end = self.row_offset + self.terminal_rows;

        if (page_end - cursor_row <= 4) {
            self.row_offset += 1;
        } else if (cursor_row - self.row_offset == 4) {
            self.row_offset = self.row_offset -| 1;
        }
    }

    pub fn renderRows(self: *Editor) !void {
        try self.writer.writeAll("\x1b[K");
        const cursor_position = self.getCursorPos();

        const rows_len: u16 = @intCast(self.rows.items.len);
        const page_rows: u16 = std.math.clamp(self.row_offset + self.terminal_rows - 1, 0, rows_len);
        for (self.row_offset..page_rows) |idx| {
            const row = &self.rows.items[idx];
            const buf = self.buffer.items[row.start..row.end];

            if (row.end == self.buffer.items.len or self.buffer.items[row.end] == '\n') {
                try self.writer.writeAll(buf);
                try self.writer.writeAll("\r\n\x1b[K");
            } else {
                try self.writer.writeAll(buf);
                try self.writer.writeAll(self.buffer.items[row.end .. row.end + 1]);
                try self.writer.writeAll("\x1b[K");
            }
        }

        if ((page_rows - self.row_offset) < self.terminal_rows - 1) {
            for ((page_rows - self.row_offset)..self.terminal_rows - 1) |_| {
                try self.writer.writeAll("~\r\n\x1b[K");
            }
        }

        const mode = switch (self.mode) {
            EditorMode.Insert => "[INSERT]",
            EditorMode.Normal => "[NORMAL]",
        };
        try self.writer.print("{s} - {s} {d}/{d}:{d} \x1b[K", .{ mode, self.path, cursor_position.y + 1, self.rows.items.len, cursor_position.x + 1 });
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
        editor.draw() catch |err| {
            std.debug.print("ERROR: Refreshing screen: {any}\r\n", .{err});
        };

        editor.processKeypress(init.io, allocator) catch |err| switch (err) {
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
