require "base64"
require "log"

lib LibC
  struct PollFD
    fd : Int
    events : Short
    revents : Short
  end

  {% unless LibC.has_constant?(:POLLIN) %}
    POLLIN = 0x0001
  {% end %}

  {% unless LibC.has_constant?(:POLLPRI) %}
    POLLPRI = 0x0002
  {% end %}

  fun poll(fds : PollFD*, nfds : UInt, timeout : Int) : Int
end

module SystemD
  # Module to monitor memory pressure using systemd's memory pressure notification mechanism.
  module MemoryPressure
    Log = ::Log.for("systemd.memory_pressure")

    # One line of a PSI file, avg values are percentages
    record Stall, avg10 : Float64, avg60 : Float64, avg300 : Float64, total : UInt64

    # Pressure stall information, `full` is missing on older kernels
    record Pressure, some : Stall, full : Stall?

    # The block is called with `true` when memory pressure is detected and
    # with `false` when it is relieved. Notifications only signal the onset,
    # so while under pressure the PSI file is polled every *check_interval*
    # and relief is signalled once its "some avg10" drops below
    # *release_below* (percent), or at the first check if no PSI file can be
    # read.
    def self.monitor(release_below : Float64 = 1.0, check_interval : Time::Span = 1.second,
                     &block : Bool ->)
      watch_path = ENV["MEMORY_PRESSURE_WATCH"]?
      return unless watch_path

      if watch_path == "/dev/null"
        Log.info { "Memory pressure monitoring disabled" }
        return
      end

      Fiber::ExecutionContext::Isolated.new("Memory Pressure Monitor") do
        begin
          watcher = Watcher.new(watch_path, decode_write_data, release_below, check_interval, block)
          watcher.run
        rescue ex
          Log.error(exception: ex) { "Memory pressure monitoring failed" }
        end
      end
    end

    # Current memory pressure, see `pressure_path` for which file is read
    def self.pressure : Pressure?
      if path = pressure_path
        pressure(path)
      end
    end

    def self.pressure(path : String) : Pressure?
      parse(File.read(path))
    rescue File::Error
    end

    # The watched file if it is a regular PSI file, otherwise the process'
    # cgroup v2 memory.pressure, falling back to the system wide one
    def self.pressure_path : String?
      if (watch_path = ENV["MEMORY_PRESSURE_WATCH"]?) && watch_path.ends_with?(".pressure") &&
         File.file?(watch_path)
        return watch_path
      end
      if cgroup = File.read("/proc/self/cgroup")[/0::(.*)\n/, 1]?
        path = "/sys/fs/cgroup#{cgroup}/memory.pressure"
        return path if File.file?(path)
      end
      "/proc/pressure/memory" if File.file?("/proc/pressure/memory")
    rescue File::Error
      "/proc/pressure/memory" if File.file?("/proc/pressure/memory")
    end

    def self.parse(data : String) : Pressure?
      some = full = nil
      data.each_line do |line|
        kind, _, rest = line.partition(' ')
        stall = parse_stall(rest) || next
        case kind
        when "some" then some = stall
        when "full" then full = stall
        end
      end
      Pressure.new(some, full) if some
    end

    private def self.parse_stall(fields : String) : Stall?
      avg10 = avg60 = avg300 = nil
      total = nil
      fields.split(' ', remove_empty: true) do |field|
        key, _, value = field.partition('=')
        case key
        when "avg10"  then avg10 = value.to_f64?
        when "avg60"  then avg60 = value.to_f64?
        when "avg300" then avg300 = value.to_f64?
        when "total"  then total = value.to_u64?
        end
      end
      Stall.new(avg10, avg60, avg300, total) if avg10 && avg60 && avg300 && total
    end

    private def self.decode_write_data : Bytes?
      if encoded = ENV["MEMORY_PRESSURE_WRITE"]?
        Base64.decode(encoded)
      end
    end

    private class Watcher
      enum Kind
        Regular
        FIFO
        Socket
      end

      @kind : Kind
      @fd : Int32
      @under_pressure = false

      def initialize(@path : String, @write_data : Bytes?, @release_below : Float64,
                     @check_interval : Time::Span, @callback : Bool ->)
        @kind = determine_kind(@path)
        Log.info { "Monitoring memory pressure on #{@kind.to_s.downcase}: #{@path}" }
        @fd = open
      end

      def run
        poll_fd = LibC::PollFD.new
        poll_fd.fd = @fd
        poll_fd.events = @kind.regular? ? LibC::POLLPRI : LibC::POLLIN
        loop do
          result = LibC.poll(pointerof(poll_fd), 1, timeout)
          if result < 0
            next if Errno.value == Errno::EINTR
            raise IO::Error.from_errno("poll failed")
          elsif result == 0
            check_relief
          elsif (poll_fd.revents & poll_fd.events) != 0
            @under_pressure = true
            Log.info { "Memory pressure detected" }
            @callback.call(true)
            poll_fd.fd = @fd if drain
          end
        end
      ensure
        LibC.close(@fd)
      end

      private def timeout : Int32
        @under_pressure ? @check_interval.total_milliseconds.to_i : -1
      end

      private def check_relief
        avg10 = (path = MemoryPressure.pressure_path) && MemoryPressure.pressure(path).try &.some.avg10
        return if avg10 && avg10 >= @release_below
        @under_pressure = false
        Log.info { "Memory pressure relieved" }
        @callback.call(false)
      end

      # Reads and discards the notification, returns true if the fd was replaced
      private def drain : Bool
        return false if @kind.regular?
        buf = uninitialized UInt8[4096]
        bytes_read = LibC.read(@fd, buf, buf.size)
        # EOF or error is expected on a FIFO, a closed socket is reconnected
        return false unless @kind.socket? && bytes_read <= 0
        LibC.close(@fd)
        @fd = open
        true
      end

      private def open : Int32
        fd = @kind.socket? ? connect_unix_socket(@path) : LibC.open(@path, LibC::O_RDWR)
        raise IO::Error.from_errno("open failed") if fd < 0
        if data = @write_data
          if LibC.write(fd, data, data.size) < 0
            LibC.close(fd)
            raise IO::Error.from_errno("write failed")
          end
        end
        fd
      end

      private def determine_kind(path : String) : Kind
        result = LibC.stat(path, out stat)
        raise IO::Error.from_errno("stat failed") if result != 0

        case stat.st_mode & LibC::S_IFMT
        when LibC::S_IFIFO  then Kind::FIFO
        when LibC::S_IFSOCK then Kind::Socket
        when LibC::S_IFREG  then Kind::Regular
        else
          Log.warn { "Unknown file type for #{path}, attempting as regular file" }
          Kind::Regular
        end
      end

      private def connect_unix_socket(path : String) : Int32
        fd = LibC.socket(LibC::AF_UNIX, LibC::SOCK_STREAM, 0)
        raise IO::Error.from_errno("socket creation failed") if fd < 0

        sockaddr = Pointer(LibC::SockaddrUn).malloc
        sockaddr.value.sun_family = LibC::AF_UNIX.to_u16
        sockaddr.value.sun_path.to_unsafe.copy_from(path.to_unsafe, {path.bytesize + 1, sockaddr.value.sun_path.size}.min)

        if LibC.connect(fd, sockaddr.as(LibC::Sockaddr*), sizeof(LibC::SockaddrUn)) < 0
          LibC.close(fd)
          raise IO::Error.from_errno("connect failed")
        end

        fd
      end
    end
  end
end
