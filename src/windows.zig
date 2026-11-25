const std = @import("std");
const windows = std.os.windows;

pub const Dword = windows.DWORD;
pub const Bool = windows.BOOL;
pub const GetLastError = windows.GetLastError;
pub const InputRecord = INPUT_RECORD;
pub const ConsoleScreenBufferInfo = CONSOLE_SCREEN_BUFFER_INFO;

pub const focus_event: u16 = 0x0010;
pub const key_event: u16 = 0x0001;
pub const menu_event: u16 = 0x0008;
pub const mouse_event: u16 = 0x0002;
pub const window_buffser_size_event: u16 = 0x0004;
pub const left_ctrl_pressed: u32 = 0x0008;
pub const right_ctrl_pressed: u32 = 0x0004;

pub const VirtualKey = extern struct {
    pub const BackSpace: u16 = 0x08;
    pub const Tab: u16 = 0x09;
    pub const Enter: u16 = 0x0D;
    pub const Escape: u16 = 0x1b;
    pub const Space: u16 = 0x20;
    pub const PageUp: u16 = 0x21;
    pub const PageDown: u16 = 0x22;
    pub const Home: u16 = 0x24;
    pub const Left: u16 = 0x25;
    pub const Up: u16 = 0x26;
    pub const Right: u16 = 0x27;
    pub const Down: u16 = 0x28;
    pub const Delete: u16 = 0x2E;
    pub const Key0: u16 = 0x30;
    pub const Key1: u16 = 0x31;
    pub const Key2: u16 = 0x32;
    pub const Key3: u16 = 0x33;
    pub const Key4: u16 = 0x34;
    pub const Key5: u16 = 0x35;
    pub const Key6: u16 = 0x36;
    pub const Key7: u16 = 0x37;
    pub const Key8: u16 = 0x38;
    pub const Key9: u16 = 0x39;
    pub const KeyA: u16 = 0x41;
    pub const KeyB: u16 = 0x42;
    pub const KeyC: u16 = 0x43;
    pub const KeyD: u16 = 0x44;
    pub const KeyE: u16 = 0x45;
    pub const KeyF: u16 = 0x46;
    pub const KeyG: u16 = 0x47;
    pub const KeyH: u16 = 0x48;
    pub const KeyI: u16 = 0x49;
    pub const KeyJ: u16 = 0x4A;
    pub const KeyK: u16 = 0x4B;
    pub const KeyL: u16 = 0x4C;
    pub const KeyM: u16 = 0x4D;
    pub const KeyN: u16 = 0x4E;
    pub const KeyO: u16 = 0x4F;
    pub const KeyP: u16 = 0x50;
    pub const KeyQ: u16 = 0x51;
    pub const KeyR: u16 = 0x52;
    pub const KeyS: u16 = 0x53;
    pub const KeyT: u16 = 0x54;
    pub const KeyU: u16 = 0x55;
    pub const KeyV: u16 = 0x56;
    pub const KeyW: u16 = 0x57;
    pub const KeyX: u16 = 0x58;
    pub const KeyY: u16 = 0x59;
    pub const KeyZ: u16 = 0x5A;
    pub const F2: u16 = 0x71;
    pub const F3: u16 = 0x72;
};

pub extern "kernel32" fn ReadConsoleInputA(
    hConsoleInput: windows.HANDLE,
    lpBuffer: *INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOuput: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;

const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

const CONSOLE_CHARACTER_ATTRIBUTES = packed struct(u16) {
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

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: CONSOLE_CHARACTER_ATTRIBUTES,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    },
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union {
        UnicodeChar: u16,
        AsciiChar: u8,
    },
    dwControlKeyState: u32,
};

const MENU_EVENT_RECORD = extern struct {
    dwCommandId: u32,
};

const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: windows.COORD,
    dwButtonState: u32,
    dwControlKeyState: u32,
    dwEventFlags: u32,
};

const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: windows.BOOL,
};

const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: windows.COORD,
};
