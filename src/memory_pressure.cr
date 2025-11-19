require "base64"
require "log"

lib LibC
  struct PollFD
    fd : Int
    events : Short
    revents : Short
  end

  POLLIN  = 0x0001
  POLLPRI = 0x0002

  fun poll(fds : PollFD*, nfds : UInt, timeout : Int) : Int
end

module SystemD
  # Module to monitor memory pressure using systemd's memory pressure notification mechanism.
  module MemoryPressure
    Log = ::Log.for("systemd.memory_pressure")

    # The block is called when memory pressure is detected
    def self.monitor(&block : ->)
      watch_path = ENV["MEMORY_PRESSURE_WATCH"]?
      return unless watch_path

      if watch_path == "/dev/null"
        Log.info { "Memory pressure monitoring disabled" }
        return
      end

      Fiber::ExecutionContext::Isolated.new("Memory Pressure Monitor") do
        begin
          monitor_internal(watch_path, &block)
        rescue ex
          Log.error(exception: ex) { "Memory pressure monitoring failed" }
        end
      end
    end

    private def self.monitor_internal(watch_path : String, &block : ->)
      write_data = decode_write_data
      file_type = determine_file_type(watch_path)

      case file_type
      when :regular
        monitor_regular_file(watch_path, write_data, &block)
      when :fifo
        monitor_fifo(watch_path, write_data, &block)
      when :socket
        monitor_socket(watch_path, write_data, &block)
      else
        Log.warn { "Unknown file type for #{watch_path}, attempting as regular file" }
        monitor_regular_file(watch_path, write_data, &block)
      end
    end

    private def self.decode_write_data : Bytes?
      if encoded = ENV["MEMORY_PRESSURE_WRITE"]?
        Base64.decode(encoded)
      end
    end

    private def self.determine_file_type(path : String) : Symbol
      result = LibC.stat(path, out stat)
      raise IO::Error.from_errno("stat failed") if result != 0

      file_mode = stat.st_mode & LibC::S_IFMT
      case file_mode
      when LibC::S_IFREG
        :regular
      when LibC::S_IFIFO
        :fifo
      when LibC::S_IFSOCK
        :socket
      else
        :unknown
      end
    end

    private def self.monitor_regular_file(path : String, write_data : Bytes?, &block : ->)
      Log.info { "Monitoring memory pressure on regular file: #{path}" }

      fd = LibC.open(path, LibC::O_RDWR)
      raise IO::Error.from_errno("open failed") if fd < 0

      begin
        # Write the pressure threshold data if provided
        if write_data
          written = LibC.write(fd, write_data, write_data.size)
          raise IO::Error.from_errno("write failed") if written < 0
        end

        poll_fd = LibC::PollFD.new
        poll_fd.fd = fd
        poll_fd.events = LibC::POLLPRI

        loop do
          result = LibC.poll(pointerof(poll_fd), 1, -1) # -1 = infinite timeout
          if result < 0
            next if Errno.value == Errno::EINTR
            raise IO::Error.from_errno("poll failed")
          elsif result > 0 && (poll_fd.revents & LibC::POLLPRI) != 0
            handle_memory_pressure(&block)
            # For regular files, we don't read from the FD
          end
        end
      ensure
        LibC.close(fd)
      end
    end

    private def self.monitor_fifo(path : String, write_data : Bytes?, &block : ->)
      Log.info { "Monitoring memory pressure on FIFO: #{path}" }

      fd = LibC.open(path, LibC::O_RDWR)
      raise IO::Error.from_errno("open failed") if fd < 0

      begin
        # Write the pressure threshold data if provided
        if write_data
          written = LibC.write(fd, write_data, write_data.size)
          raise IO::Error.from_errno("write failed") if written < 0
        end

        poll_fd = LibC::PollFD.new
        poll_fd.fd = fd
        poll_fd.events = LibC::POLLIN

        loop do
          result = LibC.poll(pointerof(poll_fd), 1, -1)
          if result < 0
            next if Errno.value == Errno::EINTR
            raise IO::Error.from_errno("poll failed")
          end
          if result > 0 && (poll_fd.revents & LibC::POLLIN) != 0
            handle_memory_pressure(&block)
            # Read and discard data from FIFO
            buf = uninitialized UInt8[4096]
            bytes_read = LibC.read(fd, buf, 4096)
            # EOF (0) or error is expected, continue polling
          end
        end
      ensure
        LibC.close(fd)
      end
    end

    private def self.monitor_socket(path : String, write_data : Bytes?, &block : ->)
      Log.info { "Monitoring memory pressure on Unix socket: #{path}" }

      fd = connect_unix_socket(path)

      begin
        # Write the pressure threshold data if provided
        if write_data
          written = LibC.write(fd, write_data, write_data.size)
          raise IO::Error.from_errno("write failed") if written < 0
        end

        poll_fd = LibC::PollFD.new
        poll_fd.fd = fd
        poll_fd.events = LibC::POLLIN

        loop do
          result = LibC.poll(pointerof(poll_fd), 1, -1)
          if result < 0
            next if Errno.value == Errno::EINTR
            raise IO::Error.from_errno("poll failed")
          end
          if result > 0 && (poll_fd.revents & LibC::POLLIN) != 0
            handle_memory_pressure(&block)
            # Read and discard data from socket
            buffer = uninitialized UInt8[4096]
            bytes_read = LibC.read(fd, buffer, 4096)
            if bytes_read <= 0
              # Connection closed, reconnect
              LibC.close(fd)
              fd = connect_unix_socket(path)
              poll_fd.fd = fd
              if write_data
                written = LibC.write(fd, write_data, write_data.size)
                raise IO::Error.from_errno("write failed after reconnect") if written < 0
              end
            end
          end
        end
      ensure
        LibC.close(fd)
      end
    end

    private def self.connect_unix_socket(path : String) : Int32
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

    private def self.handle_memory_pressure(&block : ->)
      Log.info { "Memory pressure detected" }
      block.call
    end
  end
end
