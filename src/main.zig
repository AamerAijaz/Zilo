const std = @import("std");
const windows = std.os.windows;

const AppError = error{
    ExitKeyPressed,
};

/// store the console input and output modes before enabling raw mode.
var initial_input_mode: windows.DWORD = 0;
var initial_output_mode: windows.DWORD = 0;
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

/// Returns the control key for that character.
///
/// Eg: q -> Ctrl + q.
pub fn controlKey(c: u8) u8 { return c & std.ascii.control_code.us; }

/// By default terminals process input in canonical mode, i.e input from a user is
/// sent to the program when they press ENTER. To process each character of user input
/// as they appear, we need the terminal to process input in Raw mode.
pub fn enableRawMode() !void {
    const stdin_handle = std.Io.File.stdin().handle;
    if (GetConsoleMode(stdin_handle, &initial_input_mode) == windows.BOOL.FALSE) {
        std.debug.print("Failed to get console input mode - {d}\r\n", .{windows.GetLastError()});
        return error.ErrorEnablingRawMode;
    }

    const input_mode = initial_input_mode & ~(enable_line_input | enable_echo_input | enable_processed_input) | enable_virtual_terminal_input;
    if (SetConsoleMode(stdin_handle, input_mode) == windows.BOOL.FALSE) {
        std.debug.print("Failed to set console input mode - {d}\r\n", .{windows.GetLastError()});
        return error.ErrorEnablingRawMode;
    }

    const stdout_handle = std.Io.File.stdout().handle;
    if (GetConsoleMode(stdout_handle, &initial_output_mode) == windows.BOOL.FALSE) {
        std.debug.print("Failed to get console output mode - {d}\r\n", .{windows.GetLastError()});
        return error.ErrorEnablingRawMode;
    }

    const output_mode = initial_output_mode | enable_virtual_terminal_processing | disable_newline_auto_return;
    if (SetConsoleMode(stdout_handle, output_mode) == windows.BOOL.FALSE) {
        std.debug.print("Failed to set console output mode - {d}\r\n", .{windows.GetLastError()});
        return error.ErrorEnablingRawMode;
    }
}

pub fn disableRawMode() !void {
    const stdin_handle = std.Io.File.stdin().handle;
    if (SetConsoleMode(stdin_handle, initial_input_mode) == windows.BOOL.FALSE) {
        std.debug.print("Failed to set console input mode - {d}\r\n", .{windows.GetLastError()});
        return error.ErrorDisablingRawMode;
    }

    const stdout_handle = std.Io.File.stdout().handle;
    if (SetConsoleMode(stdout_handle, initial_output_mode) == windows.BOOL.FALSE) {
        std.debug.print("Failed to set console output mode - {d}\r\n", .{windows.GetLastError()});
        return error.ErrorDisablingRawMode;
    }
}

pub const Editor = struct {
    pub fn processKeypress(reader: *std.Io.Reader) !void {
        const value = try reader.takeByte();
        return switch (value) {
            controlKey('q') => {
                return AppError.ExitKeyPressed;
            },
            else => {},
        };
    }

    pub fn refreshScreen(writer: *std.Io.Writer) !void {
        _ = try writer.write("\x1b[2J");
    }
};

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin_reader_if = &stdin_reader.interface;

    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    const stdout_writer_if = &stdout_writer.interface;

    defer disableRawMode() catch {};
    try enableRawMode();

    while (true) {
        Editor.refreshScreen(stdout_writer_if) catch |err| {
            std.debug.print("ERROR: Refreshing screen: {any}\r\n", .{err});
        };

        Editor.processKeypress(stdin_reader_if) catch |err| switch (err) {
            AppError.ExitKeyPressed => break,
            else => std.debug.print("ERROR: Reading byte from terminal: {any}\r\n", .{err}),
        };
    }
}
