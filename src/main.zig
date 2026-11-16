const std = @import("std");
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
};

/// Returns the control key for that character.
///
/// Eg: q -> Ctrl + q.
pub fn controlKey(c: u8) u8 {
    return c & std.ascii.control_code.us;
}

pub const Row = struct {
    buffer: []u8,
};

pub const Position = struct {
    x: u8,
    y: u8,
};

pub const Editor = struct {
    console: struct {
        initial_input_mode: windows.DWORD = 0,
        initial_output_mode: windows.DWORD = 0,
        console_screen_buffer_info: CONSOLE_SCREEN_BUFFER_INFO = undefined,
    },
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    terminal_rows: u8, // Number of rows the terminal currently has.
    terminal_cols: u8, // Number of columns the terminal currently has.
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

        const terminal_cols: u8 = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1);
        var rows = try std.ArrayList(Row).initCapacity(alloc, 1);
        try rows.append(alloc, Row{ .buffer = try alloc.alloc(u8, terminal_cols) });
        for (0..rows.items.len) |idx| {
            rows.items[idx].buffer = try alloc.alloc(u8, terminal_cols);
            @memset(rows.items[idx].buffer, 0);
        }

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

    /// By default terminals process input in canonical mode, i.e input from a user is
    /// sent to the program when they press ENTER. To process each character of user input
    /// as they appear, we need the terminal to process input in Raw mode.
    pub fn enableRawMode(self: *Editor) !void {
        const stdin_handle = std.Io.File.stdin().handle;
        const stdout_handle = std.Io.File.stdout().handle;

        const input_mode = self.console.initial_input_mode & ~(enable_line_input | enable_echo_input | enable_processed_input) | enable_virtual_terminal_input;
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

    pub fn readKey(self: *Editor) !union(enum) { key: EditorKey, value: u8 } {
        const value = try self.reader.takeByte();

        return switch (value) {
            '\x1b' => {
                const seq0 = try self.readTimeout(50);
                if (seq0 == null) {
                    if (self.mode != EditorMode.Normal) {
                        return .{ .key = EditorKey.ModeChange };
                    } else {
                        return .{ .value = value };
                    }
                }

                return switch (seq0.?) {
                    '[' => {
                        const seq1 = try self.reader.takeByte();
                        return switch (seq1) {
                            '0'...'9' => {
                                const seq2 = try self.reader.takeByte();
                                if (seq2 == '~') {
                                    return switch (seq1) {
                                        '1' => .{ .key = EditorKey.Home },
                                        '3' => .{ .key = EditorKey.Del },
                                        '4' => .{ .key = EditorKey.End },
                                        '5' => .{ .key = EditorKey.PageUp },
                                        '6' => .{ .key = EditorKey.PageDown },
                                        '7' => .{ .key = EditorKey.Home },
                                        '8' => .{ .key = EditorKey.End },
                                        else => .{ .value = value },
                                    };
                                }
                                return .{ .value = value };
                            },
                            'A' => .{ .key = EditorKey.ArrowUp },
                            'B' => .{ .key = EditorKey.ArrowDown },
                            'C' => .{ .key = EditorKey.ArrowRight },
                            'D' => .{ .key = EditorKey.ArrowLeft },
                            'H' => .{ .key = EditorKey.Home },
                            'F' => .{ .key = EditorKey.End },
                            else => .{ .value = value },
                        };
                    },
                    'O' => {
                        const seq1 = try self.reader.takeByte();
                        return switch (seq1) {
                            'H' => .{ .key = EditorKey.Home },
                            'F' => .{ .key = EditorKey.End },
                            else => .{ .value = value },
                        };
                    },
                    else => {
                        return .{ .value = value };
                    },
                };
            },
            'w' => {
                if (self.mode == EditorMode.Normal) return .{ .key = EditorKey.ArrowUp };
                return .{ .value = value };
            },
            's' => {
                if (self.mode == EditorMode.Normal) return .{ .key = EditorKey.ArrowDown };
                return .{ .value = value };
            },
            'a' => {
                if (self.mode == EditorMode.Normal) return .{ .key = EditorKey.ArrowLeft };
                return .{ .value = value };
            },
            'd' => {
                if (self.mode == EditorMode.Normal) return .{ .key = EditorKey.ArrowRight };
                return .{ .value = value };
            },
            'i' => {
                if (self.mode == EditorMode.Normal) return .{ .key = EditorKey.ModeChange };
                return .{ .value = value };
            },
            '\r' => {
                if (self.mode == EditorMode.Insert) {
                    const seq0 = try self.readTimeout(50);
                    if (seq0 == '\n') {
                        return .{ .key = EditorKey.Enter };
                    }
                    return .{ .key = EditorKey.Enter };
                }
                return .{ .value = value };
            },
            '\x7f' => {
                return .{ .key = EditorKey.Backspace };
            },
            else => .{ .value = value },
        };
    }

    pub fn processKeypress(self: *Editor, alloc: std.mem.Allocator) !void {
        const value = try self.readKey();
        return switch (value) {
            .key => {
                return switch (value.key) {
                    EditorKey.ArrowLeft => {
                        if (self.cursor.x > 0) self.cursor.x -= 1;
                    },
                    EditorKey.ArrowRight => {
                        if (self.cursor.x < self.terminal_cols) self.cursor.x += 1;
                    },
                    EditorKey.ArrowUp => {
                        if (self.cursor.y > 0) self.cursor.y -= 1;
                    },
                    EditorKey.ArrowDown => {
                        if (self.cursor.y < self.terminal_rows) self.cursor.y += 1;
                    },
                    EditorKey.PageUp => {
                        self.cursor.y = 0;
                    },
                    EditorKey.PageDown => {
                        self.cursor.y = self.terminal_rows - 1;
                    },
                    EditorKey.Home => {
                        self.cursor.x = 0;
                    },
                    EditorKey.End => {
                        self.cursor.x = self.terminal_cols - 1;
                    },
                    EditorKey.ModeChange => {
                        if (self.mode == EditorMode.Normal) {
                            self.mode = EditorMode.Insert;
                            const y: u8 = @intCast(@min(self.rows.items.len - 1, self.cursor.y));
                            const x: u8 = @intCast(@min(self.rows.items[y].buffer.len - 1, self.cursor.x));
                            self.cursor.x = x;
                            self.cursor.y = y;
                        } else {
                            self.mode = EditorMode.Normal;
                        }
                    },
                    EditorKey.Enter => {
                        if (self.mode == EditorMode.Normal) return;
                        _ = try self.rows.append(alloc, Row{
                            .buffer = try alloc.alloc(u8, self.terminal_cols),
                        });
                        self.cursor.y += 1;
                        self.cursor.x = 0;
                        @memset(self.rows.items[self.cursor.y].buffer, 0);
                    },
                    EditorKey.Del, EditorKey.Backspace => {
                        const row = &self.rows.items[self.cursor.y];
                        if (self.mode == EditorMode.Insert and self.cursor.x > 0) {
                            row.buffer[self.cursor.x - 1] = 0;
                        }
                        if (self.cursor.x > 0) self.cursor.x -= 1;
                    },
                };
            },
            .value => {
                return switch (value.value) {
                    controlKey('q') => EditorError.ExitKeyPressed,
                    else => {
                        if (self.mode == EditorMode.Normal) return;
                        self.writeCharacter(value.value);
                    },
                };
            },
        };
    }

    pub fn refreshScreen(self: *Editor) !void {
        // Hide the cursor.
        _ = try self.writer.write("\x1b[?25l");

        // Position the cursor at the first column and row.
        _ = try self.writer.write("\x1b[H");

        // Wipe the scroll back buffer, i.e the history above visible window.
        _ = try self.writer.write("\x1b[3J");

        try self.renderScreen();
        _ = try self.writer.print("\x1b[{d};{d}H", .{ self.cursor.y + 1, self.cursor.x + 1 });

        // Unhide the cursor
        _ = try self.writer.write("\x1b[?25h");

        try self.writer.flush();
    }

    /// Writes the character at the current cursor's position.
    pub fn writeCharacter(self: *Editor, character: u8) void {
        std.debug.assert(self.mode == EditorMode.Insert);
        std.debug.assert(self.cursor.y < self.rows.items.len);
        std.debug.assert(self.cursor.x < self.rows.items[self.cursor.y].buffer.len);

        const slice = self.rows.items[self.cursor.y].buffer;
        slice[self.cursor.x] = character;
        self.cursor.x += 1;
    }

    pub fn renderScreen(self: *Editor) !void {
        _ = try self.writer.write("\x1b[K");

        for (0..self.rows.items.len) |idx| {
            _ = try self.writer.write(self.rows.items[idx].buffer);
            _ = try self.writer.write("\r\n");
            _ = try self.writer.write("\x1b[K");
        }

        const start: u8 = @intCast(self.rows.items.len);
        const end: u8 = @intCast(self.terminal_rows);
        for (start..end) |i| {
            if (i < self.terminal_rows - 1) {
                _ = try self.writer.write("~");
                _ = try self.writer.write("\r\n");
            } else {
                const mode = switch (self.mode) {
                    EditorMode.Insert => "---- INSERT ----",
                    EditorMode.Normal => "---- NORMAL ----",
                };
                _ = try self.writer.write(mode);
            }
            // Clear the line after the current position.
            _ = try self.writer.write("\x1b[K");
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

    defer editor.disableRawMode() catch {};
    try editor.enableRawMode();

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
