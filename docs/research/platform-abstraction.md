# Platform Abstraction via LuaJIT FFI

Research findings for cross-platform (macOS, Linux, Windows) system primitives
using LuaJIT's FFI library. Each section covers the POSIX API, the Windows API,
and the LuaJIT FFI declarations needed.

**Primary sources:**
- POSIX.1-2017: pubs.opengroup.org
- Win32 API: learn.microsoft.com
- LuaJIT FFI: luajit.org/ext_ffi.html

---

## 1. Process Spawn

### Unix: fork + exec / posix_spawn

**Preferred approach: `posix_spawn`** — avoids copying page tables, constant-time
regardless of parent memory usage. Available on macOS and Linux (glibc 2.2+).

```c
// POSIX.1-2017 signature
int posix_spawn(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[], char *const envp[]);

int posix_spawnp(pid_t *pid, const char *file,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[], char *const envp[]);
```

**To capture stdout/stderr:** Use `posix_spawn_file_actions_adddup2` to redirect
pipe write-ends to the child's fd 1 and fd 2.

**Alternative: fork + exec** — simpler mental model, but slower for large processes.

```c
pid_t fork(void);
int execvp(const char *file, char *const argv[]);
int pipe(int pipefd[2]);
int dup2(int oldfd, int newfd);
int close(int fd);
pid_t waitpid(pid_t pid, int *wstatus, int options);
```

**Pattern for capturing child output:**
1. `pipe()` for stdout, `pipe()` for stderr
2. `fork()`
3. In child: `dup2()` pipe write-ends to fd 1 and fd 2, close extras, `execvp()`
4. In parent: close write-ends, `read()` from read-ends, `waitpid()`

**Sending signals:** `kill(pid, SIGTERM)` / `kill(pid, SIGKILL)`

**Waiting:** `waitpid(pid, &status, 0)` — check `WIFEXITED(status)`, `WEXITSTATUS(status)`

### LuaJIT FFI Declarations (Unix)

```lua
local ffi = require("ffi")

ffi.cdef[[
  // Types
  typedef int32_t pid_t;
  typedef int64_t ssize_t;

  // Process spawning
  pid_t fork(void);
  int execvp(const char *file, char *const argv[]);
  pid_t waitpid(pid_t pid, int *wstatus, int options);

  // posix_spawn (preferred)
  typedef struct posix_spawn_file_actions_t posix_spawn_file_actions_t;
  typedef struct posix_spawnattr_t posix_spawnattr_t;
  int posix_spawn(pid_t *pid, const char *path,
      const posix_spawn_file_actions_t *file_actions,
      const posix_spawnattr_t *attrp,
      char *const argv[], char *const envp[]);
  int posix_spawnp(pid_t *pid, const char *file,
      const posix_spawn_file_actions_t *file_actions,
      const posix_spawnattr_t *attrp,
      char *const argv[], char *const envp[]);
  int posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions);
  int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions);
  int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions,
      int fildes, int newfildes);
  int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *actions,
      int fildes);

  // Pipes and I/O
  int pipe(int pipefd[2]);
  int dup2(int oldfd, int newfd);
  int close(int fd);
  ssize_t read(int fd, void *buf, size_t count);

  // Signals
  int kill(pid_t pid, int sig);

  // Errno
  int *__errno_location(void);
]]
```

**Wait status macros** (must be implemented in Lua since C macros can't be cdef'd):

```lua
local WTERMSIG = function(status) return bit.band(status, 0x7f) end
local WIFEXITED = function(status) return WTERMSIG(status) == 0 end
local WEXITSTATUS = function(status) return bit.rshift(bit.band(status, 0xff00), 8) end
local WIFSIGNALED = function(status)
  return bit.band(status, 0x7f) ~= 0 and bit.band(status, 0x7f) ~= 0x7f
end
```

### Windows: CreateProcess

```c
// Win32 API
BOOL CreateProcessW(
    LPCWSTR lpApplicationName,
    LPWSTR lpCommandLine,
    LPSECURITY_ATTRIBUTES lpProcessAttributes,
    LPSECURITY_ATTRIBUTES lpThreadAttributes,
    BOOL bInheritHandles,
    DWORD dwCreationFlags,
    LPVOID lpEnvironment,
    LPCWSTR lpCurrentDirectory,
    LPSTARTUPINFOW lpStartupInfo,
    LPPROCESS_INFORMATION lpProcessInformation
);

BOOL CreatePipe(
    PHANDLE hReadPipe,
    PHANDLE hWritePipe,
    LPSECURITY_ATTRIBUTES lpPipeAttributes,
    DWORD nSize
);

BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
BOOL GetExitCodeProcess(HANDLE hProcess, LPDWORD lpExitCode);
BOOL TerminateProcess(HANDLE hProcess, UINT uExitCode);
BOOL CloseHandle(HANDLE hObject);
```

**Pattern for capturing child output on Windows:**
1. `CreatePipe()` for stdout and stderr (with `bInheritHandle = TRUE`)
2. `SetHandleInformation()` to prevent parent's read-ends from being inherited
3. Set `STARTUPINFO.hStdOutput` / `hStdError` to pipe write-ends
4. `CreateProcessW()` with `STARTF_USESTDHANDLES` flag
5. Close write-ends in parent, `ReadFile()` from read-ends
6. `WaitForSingleObject(pi.hProcess, INFINITE)`

### LuaJIT FFI Declarations (Windows)

```lua
ffi.cdef[[
  // Types
  typedef void* HANDLE;
  typedef unsigned long DWORD;
  typedef int BOOL;
  typedef unsigned short WORD;
  typedef const wchar_t* LPCWSTR;
  typedef wchar_t* LPWSTR;
  typedef void* LPVOID;

  typedef struct SECURITY_ATTRIBUTES {
    DWORD nLength;
    LPVOID lpSecurityDescriptor;
    BOOL bInheritHandle;
  } SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;

  typedef struct STARTUPINFOW {
    DWORD cb;
    LPWSTR lpReserved;
    LPWSTR lpDesktop;
    LPWSTR lpTitle;
    DWORD dwX, dwY, dwXSize, dwYSize;
    DWORD dwXCountChars, dwYCountChars;
    DWORD dwFillAttribute;
    DWORD dwFlags;
    WORD wShowWindow;
    WORD cbReserved2;
    LPVOID lpReserved2;
    HANDLE hStdInput;
    HANDLE hStdOutput;
    HANDLE hStdError;
  } STARTUPINFOW, *LPSTARTUPINFOW;

  typedef struct PROCESS_INFORMATION {
    HANDLE hProcess;
    HANDLE hThread;
    DWORD dwProcessId;
    DWORD dwThreadId;
  } PROCESS_INFORMATION, *LPPROCESS_INFORMATION;

  // Functions
  BOOL CreateProcessW(LPCWSTR lpApplicationName, LPWSTR lpCommandLine,
      LPSECURITY_ATTRIBUTES lpProcessAttributes,
      LPSECURITY_ATTRIBUTES lpThreadAttributes,
      BOOL bInheritHandles, DWORD dwCreationFlags,
      LPVOID lpEnvironment, LPCWSTR lpCurrentDirectory,
      LPSTARTUPINFOW lpStartupInfo,
      LPPROCESS_INFORMATION lpProcessInformation);
  BOOL CreatePipe(PHANDLE hReadPipe, PHANDLE hWritePipe,
      LPSECURITY_ATTRIBUTES lpPipeAttributes, DWORD nSize);
  BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
  DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
  BOOL GetExitCodeProcess(HANDLE hProcess, LPDWORD lpExitCode);
  BOOL TerminateProcess(HANDLE hProcess, UINT uExitCode);
  BOOL CloseHandle(HANDLE hObject);
  BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead,
      LPDWORD lpNumberOfBytesRead, LPVOID lpOverlapped);
  DWORD GetStdHandle(DWORD nStdHandle);
]]

local kernel32 = ffi.load("kernel32")
-- Constants
local STARTF_USESTDHANDLES = 0x00000100
local INFINITE = 0xFFFFFFFF
local STD_OUTPUT_HANDLE = -11
local STD_ERROR_HANDLE = -12
local HANDLE_FLAG_INHERIT = 0x00000001
```

### Cross-Platform Spawn Abstraction

```lua
-- Sketch of unified interface
local M = {}

if ffi.os == "Windows" then
  function M.spawn(cmd, args)
    -- CreatePipe + CreateProcessW + WaitForSingleObject
    -- Returns: { pid, stdout_fd, stderr_fd, process_handle }
  end
  function M.kill(proc)
    kernel32.TerminateProcess(proc.handle, 1)
  end
  function M.wait(proc)
    ffi.C.WaitForSingleObject(proc.handle, INFINITE)
  end
else
  function M.spawn(cmd, args)
    -- pipe() + fork() + dup2() + execvp()
    -- Returns: { pid, stdout_fd, stderr_fd }
  end
  function M.kill(proc)
    ffi.C.kill(proc.pid, 15) -- SIGTERM
  end
  function M.wait(proc)
    ffi.C.waitpid(proc.pid, nil, 0)
  end
end
```

---

## 2. Signals

### Unix: sigaction

```c
// POSIX.1-2017
struct sigaction {
    void     (*sa_handler)(int);
    sigset_t sa_mask;
    int      sa_flags;
};

int sigaction(int signum, const struct sigaction *act,
              struct sigaction *oldact);
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int signum);
```

**Key signals:**
- `SIGINT` (2) — Ctrl+C
- `SIGTERM` (15) — graceful termination request
- `SIGWINCH` (28 on macOS, 28 on Linux) — terminal resize
- `SIGKILL` (9) — cannot be caught

**LuaJIT FFI declarations:**

```lua
ffi.cdef[[
  typedef void (*sighandler_t)(int);
  typedef struct {
    unsigned long __val[1024 / (8 * sizeof(unsigned long))];
  } sigset_t;

  struct sigaction {
    sighandler_t sa_handler;
    void (*sa_sigaction)(int, void *, void *);
    sigset_t sa_mask;
    int sa_flags;
    void (*sa_restorer)(void);
  };

  // signal() is simpler but sigaction() is more portable
  sighandler_t signal(int signum, sighandler_t handler);
  int sigaction(int signum, const struct sigaction *act,
                struct sigaction *oldact);
  int sigemptyset(sigset_t *set);
  int sigaddset(sigset_t *set, int signum);
  int raise(int sig);
  int kill(int pid, int sig);
]]
```

**Important LuaJIT caveat:** Signal handlers are C callbacks via `ffi.cast("sighandler_t", function(signum) ... end)`. These callbacks must NOT allocate Lua objects or throw errors — they run in a signal context. Set a flag and handle it in the main loop.

```lua
local winch_flag = false
local handler = ffi.cast("sighandler_t", function(sig)
  winch_flag = true  -- just set a flag, no Lua calls
end)
ffi.C.signal(28, handler)  -- SIGWINCH (use correct number per OS)
```

**SIGWINCH signal number:**
- macOS: 28
- Linux: 28
- Both defined as `SIGWINCH` but since cdef can't use macros, use the literal number or define it:

```lua
local SIGWINCH = ffi.os == "BSD" and 28 or 28  -- same on both, but verify
local SIGINT = 2
local SIGTERM = 15
```

### Windows: SetConsoleCtrlHandler

```c
// Win32 API
typedef BOOL (WINAPI *PHANDLER_ROUTINE)(DWORD dwCtrlType);

BOOL WINAPI SetConsoleCtrlHandler(
    PHANDLER_ROUTINE HandlerRoutine,
    BOOL Add
);

BOOL GenerateConsoleCtrlEvent(DWORD dwCtrlEvent, DWORD dwProcessGroupId);
```

**Control event types:**
- `CTRL_C_EVENT` (0) — Ctrl+C
- `CTRL_BREAK_EVENT` (1) — Ctrl+Break
- `CTRL_CLOSE_EVENT` (2) — console window closed
- `CTRL_LOGOFF_EVENT` (5)
- `CTRL_SHUTDOWN_EVENT` (6)

**No SIGWINCH equivalent on Windows.** Must poll `GetConsoleScreenBufferInfo()` or use `ReadConsoleInput()` with `WINDOW_BUFFER_SIZE_EVENT`.

**LuaJIT FFI declarations (Windows):**

```lua
ffi.cdef[[
  typedef BOOL (WINAPI *PHANDLER_ROUTINE)(DWORD dwCtrlType);
  BOOL SetConsoleCtrlHandler(PHANDLER_ROUTINE HandlerRoutine, BOOL Add);
  BOOL GenerateConsoleCtrlEvent(DWORD dwCtrlEvent, DWORD dwProcessGroupId);
]]

local kernel32 = ffi.load("kernel32")

local CTRL_C_EVENT = 0
local CTRL_BREAK_EVENT = 1
local CTRL_CLOSE_EVENT = 2

local handler = ffi.cast("PHANDLER_ROUTINE", function(ctrl_type)
  if ctrl_type == CTRL_C_EVENT then
    -- set flag
    return 1  -- TRUE = handled
  end
  return 0  -- FALSE = let default handler run
end)
kernel32.SetConsoleCtrlHandler(handler, 1)
```

### Cross-Platform Signal Abstraction

```lua
local signals = {}

if ffi.os == "Windows" then
  function signals.on_ctrl_c(fn)
    local handler = ffi.cast("PHANDLER_ROUTINE", function(ct)
      if ct == 0 then fn(); return 1 end
      return 0
    end)
    kernel32.SetConsoleCtrlHandler(handler, 1)
    return handler  -- prevent GC; caller must keep reference
  end
  -- No SIGWINCH; poll terminal size instead
else
  function signals.on_ctrl_c(fn)
    local h = ffi.cast("sighandler_t", function() fn() end)
    ffi.C.signal(2, h)
    return h
  end
  function signals.on_winch(fn)
    local h = ffi.cast("sighandler_t", function() fn() end)
    ffi.C.signal(28, h)
    return h
  end
end
```

---

## 3. Terminal Size

### Unix: ioctl TIOCGWINSZ

```c
// POSIX / Linux tty_ioctl(4)
struct winsize {
    unsigned short ws_row;    // rows in characters
    unsigned short ws_col;    // columns in characters
    unsigned short ws_xpixel; // horizontal size in pixels (unused)
    unsigned short ws_ypixel; // vertical size in pixels (unused)
};

int ioctl(int fd, int request, ...);
// Usage: ioctl(STDIN_FILENO, TIOCGWINSZ, &winsize)
```

**TIOCGWINSZ constant values:**
- macOS: `0x40087468`
- Linux: `0x5413`

**LuaJIT FFI declarations:**

```lua
ffi.cdef[[
  struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
  };

  int ioctl(int fd, unsigned long request, ...);
]]

local TIOCGWINSZ
if ffi.os == "OSX" then
  TIOCGWINSZ = 0x40087468
else  -- Linux
  TIOCGWINSZ = 0x5413
end

local function get_terminal_size()
  local ws = ffi.new("struct winsize")
  if ffi.C.ioctl(0, TIOCGWINSZ, ws) == 0 then
    return tonumber(ws.ws_col), tonumber(ws.ws_row)
  end
  return nil, "ioctl failed (not a tty?)"
end
```

### Windows: GetConsoleScreenBufferInfo

```c
// Win32 API
typedef struct _COORD {
  SHORT X;
  SHORT Y;
} COORD, *PCOORD;

typedef struct _SMALL_RECT {
  SHORT Left;
  SHORT Top;
  SHORT Right;
  SHORT Bottom;
} SMALL_RECT, *PSMALL_RECT;

typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
  COORD      dwSize;
  COORD      dwCursorPosition;
  WORD       wAttributes;
  SMALL_RECT srWindow;
  COORD      dwMaximumWindowSize;
} CONSOLE_SCREEN_BUFFER_INFO, *PCONSOLE_SCREEN_BUFFER_INFO;

BOOL WINAPI GetConsoleScreenBufferInfo(
    HANDLE hConsoleOutput,
    PCONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo
);
```

**LuaJIT FFI declarations:**

```lua
ffi.cdef[[
  typedef short SHORT;
  typedef unsigned short WORD;

  typedef struct COORD {
    SHORT X;
    SHORT Y;
  } COORD;

  typedef struct SMALL_RECT {
    SHORT Left;
    SHORT Top;
    SHORT Right;
    SHORT Bottom;
  } SMALL_RECT;

  typedef struct CONSOLE_SCREEN_BUFFER_INFO {
    COORD      dwSize;
    COORD      dwCursorPosition;
    WORD       wAttributes;
    SMALL_RECT srWindow;
    COORD      dwMaximumWindowSize;
  } CONSOLE_SCREEN_BUFFER_INFO;

  BOOL GetConsoleScreenBufferInfo(
      HANDLE hConsoleOutput,
      CONSOLE_SCREEN_BUFFER_INFO *lpConsoleScreenBufferInfo);
]]

local kernel32 = ffi.load("kernel32")

local function get_terminal_size()
  local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
  local h = ffi.C.GetStdHandle(-11) -- STD_OUTPUT_HANDLE
  if kernel32.GetConsoleScreenBufferInfo(h, csbi) ~= 0 then
    local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
    local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
    return cols, rows
  end
  return nil, "not a console"
end
```

### Cross-Platform Terminal Size

```lua
local function termsize()
  if ffi.os == "Windows" then
    -- GetConsoleScreenBufferInfo approach above
  else
    -- ioctl TIOCGWINSZ approach above
  end
end
```

---

## 4. Environment Variables

### os.getenv (built-in, read-only)

`os.getenv("NAME")` works cross-platform for reading. Returns `nil` if unset.

### Setting environment variables

**Unix: `setenv` / `putenv`**

```c
int setenv(const char *name, const char *value, int overwrite);
int putenv(char *string);  // "NAME=VALUE" format
int unsetenv(const char *name);
```

**Windows: `SetEnvironmentVariableW`**

```c
BOOL SetEnvironmentVariableW(LPCWSTR lpName, LPCWSTR lpValue);
// Setting value to NULL deletes the variable
```

**Windows gotcha:** Windows maintains multiple copies of the environment block.
`SetEnvironmentVariableW` modifies the process environment, but Lua's `os.getenv`
may use the C runtime's cached copy. The `luasystem` library documents this:
"the setenv function will not work with Lua's os.getenv on Windows."

### LuaJIT FFI Declarations

```lua
ffi.cdef[[
  // Unix
  char *getenv(const char *name);
  int setenv(const char *name, const char *value, int overwrite);
  int putenv(char *string);
  int unsetenv(const char *name);
]]

-- Windows (via kernel32, already loaded)
ffi.cdef[[
  BOOL SetEnvironmentVariableW(LPCWSTR lpName, LPCWSTR lpValue);
  DWORD GetEnvironmentVariableW(LPCWSTR lpName, LPWSTR lpBuffer, DWORD nSize);
]]
```

### Recommendation

- **Reading:** Use `os.getenv()` — it's built-in, cross-platform, no FFI needed.
- **Setting (Unix):** FFI to `setenv()`.
- **Setting (Windows):** FFI to `SetEnvironmentVariableW()`, but be aware of the
  dual-environment issue. If Lua code also needs to read the variable, use
  `GetEnvironmentVariableW` via FFI instead of `os.getenv`.
- **Cross-platform setenv wrapper:**

```lua
local function setenv(name, value)
  if ffi.os == "Windows" then
    local wname = ffi.new("wchar_t[?]", #name + 1)
    -- convert name to wide string
    kernel32.SetEnvironmentVariableW(wname, wvalue)
  else
    ffi.C.setenv(name, value, 1)
  end
end
```

---

## 5. Socket Readiness (I/O Multiplexing)

### Unix: poll (preferred) / select

**`poll()` is the best cross-platform choice** — simpler than `select()`, no
FD_SETSIZE limit, available on macOS and Linux.

```c
// POSIX.1-2017
struct pollfd {
    int   fd;        // file descriptor
    short events;    // requested events
    short revents;   // returned events
};

int poll(struct pollfd *fds, nfds_t nfds, int timeout);
// timeout in milliseconds, -1 = block forever, 0 = non-blocking
```

**Event flags:**
- `POLLIN` (0x001) — data ready to read
- `POLLOUT` (0x004) — write will not block
- `POLLERR` (0x008) — error condition
- `POLLHUP` (0x010) — hang up
- `POLLNVAL` (0x020) — invalid fd

**LuaJIT FFI declarations (Unix):**

```lua
ffi.cdef[[
  struct pollfd {
    int   fd;
    short events;
    short revents;
  };

  int poll(struct pollfd *fds, unsigned long nfds, int timeout);
]]

local POLLIN  = 0x001
local POLLOUT = 0x004
local POLLERR = 0x008
local POLLHUP = 0x010

local function poll_fds(fds, timeout_ms)
  return ffi.C.poll(fds, #fds, timeout_ms or -1)
end
```

### Windows: WSAPoll

Windows Vista+ has `WSAPoll()` which is nearly identical to POSIX `poll()`.

```c
// winsock2.h
typedef struct pollfd {
  SOCKET fd;
  SHORT  events;
  SHORT  revents;
} WSAPOLLFD;

int WSAPoll(LPWSAPOLLFD fdArray, ULONG fds, INT timeout);
```

**LuaJIT FFI declarations (Windows):**

```lua
ffi.cdef[[
  typedef struct WSAPOLLFD {
    uint64_t fd;  // SOCKET is UINT_PTR, 64-bit on x64
    short events;
    short revents;
  } WSAPOLLFD;

  int WSAPoll(WSAPOLLFD *fdArray, unsigned long fds, int timeout);
]]

local ws2 = ffi.load("ws2_32")

-- Same POLLIN/POLLOUT constants as Unix
local POLLIN  = 0x001  -- POLLRDNORM | POLLRDBAND
local POLLOUT = 0x004  -- POLLWRNORM
```

**Windows gotcha:** `WSAPoll` only works with Winsock sockets, not file descriptors.
For non-socket I/O on Windows, use `WaitForSingleObject` or overlapped I/O.

### Cross-Platform Socket Readiness

```lua
local M = {}

if ffi.os == "Windows" then
  local ws2 = ffi.load("ws2_32")
  function M.poll(fds, timeout)
    return ws2.WSAPoll(fds, #fds, timeout or -1)
  end
else
  function M.poll(fds, timeout)
    return ffi.C.poll(fds, #fds, timeout or -1)
  end
end
```

### Alternative: select (lower portability ceiling)

`select()` works everywhere but has the `FD_SETSIZE` limit (typically 1024).
The `fd_set` macros (`FD_ZERO`, `FD_SET`, `FD_ISSET`) are C preprocessor macros
that can't be cdef'd — must reimplement in Lua or use `poll()` instead.

**Recommendation: Use `poll()` / `WSAPoll()`.** Skip `select()` and `epoll()`.

---

## 6. File Paths

### Path Separator

| Platform | Separator | Example |
|----------|-----------|---------|
| Unix (macOS, Linux) | `/` | `/home/user/file` |
| Windows | `\` | `C:\Users\user\file` |

LuaJIT's `ffi.os` values: `"Linux"`, `"OSX"`, `"Windows"`, `"BSD"`, `"POSIX"`, `"Other"`

### Temp Directory

| Platform | Location | Env Var |
|----------|----------|---------|
| Linux | `/tmp` | `TMPDIR` (usually unset) |
| macOS | `/var/folders/xx/...` | `$TMPDIR` (per-user, auto-set) |
| Windows | `C:\Users\<user>\AppData\Local\Temp` | `%TEMP%` / `%TMP%` |

**Cross-platform temp dir:**

```lua
local function tmpdir()
  if ffi.os == "Windows" then
    return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
  else
    return os.getenv("TMPDIR") or "/tmp"
  end
end
```

### XDG Base Directories (Unix)

From the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/):

| Variable | Default | Purpose |
|----------|---------|---------|
| `$XDG_CONFIG_HOME` | `~/.config` | User config files |
| `$XDG_DATA_HOME` | `~/.local/share` | User data files |
| `$XDG_CACHE_HOME` | `~/.cache` | User cache files |
| `$XDG_RUNTIME_DIR` | `/run/user/$UID` | Runtime files (sockets, pipes) |
| `$XDG_STATE_HOME` | `~/.local/state` | User state files |

**macOS note:** macOS does not follow XDG by convention. Standard paths are:
- Config: `~/Library/Preferences` or `~/Library/Application Support`
- Data: `~/Library/Application Support`
- Cache: `~/Library/Caches`
- Temp: `$TMPDIR` (per-user temporary directory)

**Windows equivalents:**

| XDG | Windows | Env Var |
|-----|---------|---------|
| Config | `%APPDATA%` | `C:\Users\<user>\AppData\Roaming` |
| Data | `%LOCALAPPDATA%` | `C:\Users\<user>\AppData\Local` |
| Cache | `%LOCALAPPDATA%` | Same as data |
| Temp | `%TEMP%` | `C:\Users\<user>\AppData\Local\Temp` |

### Cross-Platform Config/Data Directory

```lua
local function config_dir(app_name)
  if ffi.os == "Windows" then
    return (os.getenv("APPDATA") or "") .. "\\" .. app_name
  elseif ffi.os == "OSX" then
    return os.getenv("HOME") .. "/Library/Application Support/" .. app_name
  else
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then return xdg .. "/" .. app_name end
    return os.getenv("HOME") .. "/.config/" .. app_name
  end
end

local function runtime_dir(app_name)
  if ffi.os == "Windows" then
    return (os.getenv("TEMP") or "") .. "\\" .. app_name
  elseif ffi.os == "OSX" then
    return (os.getenv("TMPDIR") or "/tmp") .. "/" .. app_name
  else
    local xdg = os.getenv("XDG_RUNTIME_DIR")
    if xdg and xdg ~= "" then return xdg .. "/" .. app_name end
    return "/tmp/" .. app_name .. "-" .. tostring(uid())
  end
end
```

---

## Summary: Recommended Approach per Primitive

| Primitive | Unix | Windows | Notes |
|-----------|------|---------|-------|
| **Process spawn** | `posix_spawn` or `fork+exec` | `CreateProcessW` | `posix_spawn` is faster; `fork+exec` is simpler |
| **Signals** | `sigaction` / `signal` | `SetConsoleCtrlHandler` | Use flag-in-callback pattern for LuaJIT |
| **Terminal size** | `ioctl(TIOCGWINSZ)` | `GetConsoleScreenBufferInfo` | Constants differ by OS |
| **Env vars (read)** | `os.getenv()` | `os.getenv()` | Built-in, no FFI needed |
| **Env vars (write)** | `setenv()` | `SetEnvironmentVariableW` | Windows has dual-env issue |
| **Socket readiness** | `poll()` | `WSAPoll()` | Nearly identical APIs |
| **Paths** | XDG conventions | `%APPDATA%` / `%TEMP%` | macOS uses `~/Library` not XDG |

### Key LuaJIT FFI Patterns

1. **Platform branching:** `ffi.os` returns `"Linux"`, `"OSX"`, `"Windows"`, `"BSD"`, `"POSIX"`, or `"Other"`.
2. **Library loading:** `ffi.load("kernel32")` on Windows, `ffi.C` for libc on Unix.
3. **Callbacks:** Use `ffi.cast("callback_type", lua_function)` — keep callbacks minimal, set flags only.
4. **Constants:** C `#define` macros can't go in `ffi.cdef` — define them as Lua variables.
5. **Struct sizing:** Use `ffi.sizeof("struct_name")` to verify layout matches expectations.
6. **String conversion (Windows):** Wide strings (`wchar_t*`) needed for most Windows APIs. Use `MultiByteToWideChar` or manual conversion.
7. **Error handling:** `ffi.errno()` after Unix calls, `kernel32.GetLastError()` after Windows calls.

### Existing Libraries Worth Noting

- **luasystem** (lunarmodules/luasystem): Cross-platform `getenv`, `setenv`, `termsize`, `isatty`, `random`. Could be a dependency instead of reimplementing.
- **luv** (libuv bindings): Full async I/O, process spawning, signals, filesystem. Heavy but comprehensive.
