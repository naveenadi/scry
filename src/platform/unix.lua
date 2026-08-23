-- src/platform/unix.lua — Unix platform abstraction
-- Process spawn/termination, environment paths, terminal size, signals, socket readiness

local ffi = require("ffi")

ffi.cdef[[
typedef int pid_t;
typedef int sighandler_t;

pid_t fork(void);
pid_t waitpid(pid_t pid, int *wstatus, int options);
int execvp(const char *file, char *const argv[]);
pid_t getpid(void);
int kill(pid_t pid, int sig);

sighandler_t signal(int signum, sighandler_t handler);

int pipe(int pipefd[2]);
int close(int fd);
int dup2(int oldfd, int newfd);

typedef struct {
    int fds[2];
} scry_pipe_t;

// For socket readiness
typedef unsigned int nfds_t;
struct pollfd {
    int fd;
    short events;
    short revents;
};
int poll(struct pollfd *fds, nfds_t nfds, int timeout);

// For ephemeral port allocation
struct sockaddr {
    unsigned short sa_family;
    char sa_data[14];
};
struct sockaddr_in {
    short sin_family;
    unsigned short sin_port;
    int sin_addr;
    char sin_zero[8];
};
int socket(int domain, int type, int protocol);
int bind(int sockfd, const struct sockaddr *addr, unsigned int addrlen);
int getsockname(int sockfd, struct sockaddr *addr, unsigned int *addrlen);
int listen(int sockfd, int backlog);
int accept(int sockfd, struct sockaddr *addr, unsigned int *addrlen);

// Constants
enum {
    SIGINT = 2,
    SIGTERM = 15,
    SIGPIPE = 13,
    SIG_IGN = 1,
    WNOHANG = 1,
    AF_INET = 2,
    SOCK_STREAM = 1,
    SOL_SOCKET = 1,
    SO_REUSEADDR = 2,
    INADDR_ANY = 0,
    POLLIN = 1,
    POLLOUT = 4,
};

int mkdir(const char *path, int mode);
unsigned short ntohs(unsigned short netshort);

struct timespec {
    long tv_sec;
    long tv_nsec;
};
int clock_gettime(int clk_id, struct timespec *tp);
]]

local C = ffi.C

local M = {}

-- Spawn a child process. Returns pid, or nil + error on failure.
-- argv[0] is the program name.
function M.spawn(argv, opts)
    opts = opts or {}
    local pipefd
    if opts.capture_output then
        pipefd = ffi.new("int[2]")
        if C.pipe(pipefd) ~= 0 then
            return nil, "pipe failed"
        end
    end

    local pid = C.fork()
    if pid < 0 then
        return nil, "fork failed"
    end
    if pid == 0 then
        -- Child
        if opts.capture_output then
            C.close(pipefd[0])
            C.dup2(pipefd[1], 1) -- stdout
            C.dup2(pipefd[1], 2) -- stderr
            C.close(pipefd[1])
        end
        -- Build argv for execvp
        local c_argv = ffi.new("const char*[?]", #argv + 1)
        for i, arg in ipairs(argv) do
            c_argv[i - 1] = arg
        end
        c_argv[#argv] = nil
        C.execvp(argv[0], c_argv)
        -- If execvp returns, it failed
        os.exit(127)
    end
    -- Parent
    if opts.capture_output then
        C.close(pipefd[1])
        return pid, nil, pipefd[0]
    end
    return pid
end

-- Wait for a child process. Returns exit code, or nil if still running.
function M.waitpid(pid, nohang)
    local status = ffi.new("int[1]")
    local opts = nohang and C.WNOHANG or 0
    local ret = C.waitpid(pid, status, opts)
    if ret < 0 then
        return nil, "waitpid failed"
    end
    if ret == 0 then
        return nil -- still running
    end
    -- Extract exit status
    if bit.band(status[0], 0x7F) == 0 then
        return bit.rshift(status[0], 8) -- normal exit
    else
        return -bit.band(status[0], 0x7F) -- killed by signal
    end
end

-- Kill a process.
function M.kill(pid, sig)
    sig = sig or 15 -- SIGTERM
    return C.kill(pid, sig) == 0
end

-- Get process ID.
function M.getpid()
    return C.getpid()
end

-- Get environment variable.
function M.getenv(name)
    local val = os.getenv(name)
    return val
end

-- Get the user's home directory.
function M.home_dir()
    return os.getenv("HOME") or "/tmp"
end

-- Get XDG config directory.
function M.config_dir()
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg then
        return xdg .. "/scry"
    end
    return M.home_dir() .. "/.config/scry"
end

-- Get XDG state directory (for logs, history).
function M.state_dir()
    local xdg = os.getenv("XDG_STATE_HOME")
    if xdg then
        return xdg .. "/scry"
    end
    return M.home_dir() .. "/.local/state/scry"
end

-- Get the debug log path.
function M.log_path()
    return M.state_dir() .. "/scry.log"
end

-- Get the history file path.
function M.history_path()
    return M.state_dir() .. "/history.jsonl"
end

-- Allocate an ephemeral port by binding to port 0.
-- Returns the port number, or nil + error.
function M.ephemeral_port()
    local sockfd = C.socket(C.AF_INET, C.SOCK_STREAM, 0)
    if sockfd < 0 then
        return nil, "socket failed"
    end
    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = C.AF_INET
    addr.sin_port = 0 -- OS assigns
    addr.sin_addr = C.INADDR_ANY
    if C.bind(sockfd, ffi.cast("struct sockaddr*", addr), ffi.sizeof(addr)) ~= 0 then
        C.close(sockfd)
        return nil, "bind failed"
    end
    local addrlen = ffi.new("unsigned int[1]", ffi.sizeof(addr))
    if C.getsockname(sockfd, ffi.cast("struct sockaddr*", addr), addrlen) ~= 0 then
        C.close(sockfd)
        return nil, "getsockname failed"
    end
    local port = C.ntohs(addr.sin_port)
    C.close(sockfd)
    return port
end

-- Check if a file descriptor is ready for reading.
-- Returns true if ready, false if timeout.
function M.poll_readable(fd, timeout_ms)
    local pfd = ffi.new("struct pollfd")
    pfd.fd = fd
    pfd.events = C.POLLIN
    local ret = C.poll(pfd, 1, timeout_ms or 0)
    return ret > 0 and bit.band(pfd.revents, C.POLLIN) ~= 0
end

-- Check if a file descriptor is ready for writing.
function M.poll_writable(fd, timeout_ms)
    local pfd = ffi.new("struct pollfd")
    pfd.fd = fd
    pfd.events = C.POLLOUT
    local ret = C.poll(pfd, 1, timeout_ms or 0)
    return ret > 0 and bit.band(pfd.revents, C.POLLOUT) ~= 0
end

-- Create a directory (recursive, like mkdir -p).
-- Per-segment FFI mkdir — no shell involved, no escaping concerns.
function M.mkdir_p(path)
    local segments = {}
    for seg in path:gmatch("[^/]+") do
        segments[#segments + 1] = seg
    end
    local acc = ""
    for i, seg in ipairs(segments) do
        if i == 1 and path:sub(1, 1) == "/" then
            acc = "/" .. seg
        elseif acc == "" then
            acc = seg
        else
            acc = acc .. "/" .. seg
        end
        C.mkdir(acc, 0x1FF) -- 0777; EEXIST on existing segments is fine
    end
end

-- Check if a file exists.
function M.file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- Read a file entirely.
function M.read_file(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content
end

-- Write a file entirely.
function M.write_file(path, content)
    local f, err = io.open(path, "w")
    if not f then
        return nil, err
    end
    f:write(content)
    f:close()
    return true
end

-- Append to a file.
function M.append_file(path, content)
    local f, err = io.open(path, "a")
    if not f then
        return nil, err
    end
    f:write(content)
    f:close()
    return true
end

-- Get current working directory.
function M.cwd()
    local handle = io.popen("pwd")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result:gsub("%s+$", "")
    end
    return nil
end

-- Wall-clock milliseconds (for elapsed query time; os.clock() is CPU time
-- and freezes during network waits).
function M.monotonic_ms()
    local ts = ffi.new("struct timespec")
    C.clock_gettime(0, ts) -- CLOCK_REALTIME
    return tonumber(ts.tv_sec) * 1000 + math.floor(tonumber(ts.tv_nsec) / 1000000)
end

-- Path separator.
M.path_sep = "/"

-- Join path components.
function M.path_join(...)
    local parts = {...}
    return table.concat(parts, "/")
end

-- Get the directory part of a path.
function M.path_dirname(path)
    return path:match("(.+)/[^/]+$") or "."
end

-- Get the filename part of a path.
function M.path_basename(path)
    return path:match("[^/]+$") or path
end

return M
