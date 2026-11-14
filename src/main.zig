const std = @import("std");
const windows = std.os.windows;

const EditorError = error{
    ExitKeyPressed,
};

pub const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

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

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOuput: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;

/// Returns the control key for that character.
///
/// Eg: q -> Ctrl + q.
pub fn controlKey(c: u8) u8 {
    return c & std.ascii.control_code.us;
}

pub const Editor = struct {
    console: struct {
        initial_input_mode: windows.DWORD = 0,
        initial_output_mode: windows.DWORD = 0,
        console_screen_buffer_info: CONSOLE_SCREEN_BUFFER_INFO = undefined,
    },
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    rows: u8,
    cols: u8,
    cursor: struct {
        x: u8,
        y: u8,
    },

    pub fn init(reader: *std.Io.Reader, writer: *std.Io.Writer) !Editor {
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

        return Editor{
            .reader = reader,
            .writer = writer,
            .console = .{
                .initial_input_mode = input_mode,
                .initial_output_mode = output_mode,
                .console_screen_buffer_info = csbi,
            },
            .rows = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1),
            .cols = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1),
            .cursor = .{
                .x = 0,
                .y = 0,
            }
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

    pub fn readKey(self: *Editor) !u8 {
        const value = try self.reader.takeByte();

        // If the value read is an escape sequence.
        if (value == '\x1b') {
            const sequence = try self.reader.takeArray(2);
            if (sequence[0] == '[') {
                return switch (sequence[1]) {
                    'A' => 'w',
                    'B' => 's',
                    'C' => 'd',
                    'D' => 'a',
                    else => '\x1b'
                };
            }
            return '\x1b';
        }

        return value;
    }

    pub fn processKeypress(self: *Editor) !void {
        const value = try self.readKey();
        return switch (value) {
            controlKey('q') => {
                return EditorError.ExitKeyPressed;
            },
            'a' => {
                if (self.cursor.x > 0)  self.cursor.x -= 1;
            },
            'd' => {
                if (self.cursor.x < self.cols)  self.cursor.x += 1;
            },
            'w' => {
                if (self.cursor.y > 0)  self.cursor.y -= 1;
            },
            's' => {
                if (self.cursor.y < self.rows)  self.cursor.y += 1;
            },
            else => {},
        };
    }

    pub fn refreshScreen(self: *Editor) !void {
        // Hide the cursor.
        _ = try self.writer.write("\x1b[?25l");

        // Position the cursor at the first column and row.
        _ = try self.writer.write("\x1b[H");

        // Wipe the scroll back buffer, i.e the history above visible window.
        _ = try self.writer.write("\x1b[3J");

        try self.drawRows();
        _ = try self.writer.print("\x1b[{d};{d}H", .{self.cursor.y + 1, self.cursor.x + 1});

        // Unhide the cursor
        _ = try self.writer.write("\x1b[?25h");

        try self.writer.flush();
    }

    pub fn drawRows(self: *Editor) !void {
        for (0..self.rows) |i| {
            if (i == self.rows / 3) {
                var buf: [64]u8 = undefined;
                const written = try std.mem.print(&buf, "Zilo editor -- version {s}", .{zilo_version});

                for (0..(self.cols - written.len) / 2) |_| {
                    _ = try self.writer.write(" ");
                }

                _ = try self.writer.write(written);
            } else {
                _ = try self.writer.write("~");
            }

            // Clear the line after the current position.
            _ = try self.writer.write("\x1b[K");

            if (i < self.rows - 1) {
                _ = try self.writer.write("\r\n");
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &read_buffer);
    var stdout_writer = std.Io.File.stdout().writer(init.io, &write_buffer);

    var editor = Editor.init(&stdin_reader.interface, &stdout_writer.interface) catch |err| {
        std.debug.print("ERROR: Unable to initialize editor: {any}\r\n", .{err});
        return err;
    };

    defer editor.disableRawMode() catch {};
    try editor.enableRawMode();

    while (true) {
        editor.refreshScreen() catch |err| {
            std.debug.print("ERROR: Refreshing screen: {any}\r\n", .{err});
        };

        editor.processKeypress() catch |err| switch (err) {
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
