require "./libsystemd"
require "socket"

# Wrapper for libsystemd
# http://man7.org/linux/man-pages/man3/sd_pid_notify_with_fds.3.html
# http://man7.org/linux/man-pages/man3/sd_listen_fds_with_names.3.html
module SystemD
  def self.notify_ready
    self.notify("READY=1\n")
  end

  def self.notify_stopping
    self.notify("STOPPING=1\n")
  end

  def self.notify_reloading
    self.notify("RELOADING=1\n")
  end

  def self.notify_status(status : String)
    self.notify("STATUS=#{status}\n")
  end

  def self.watchdog
    self.notify("WATCHDOG=1\n")
  end

  def self.notify(message = "READY=1\n") : Bool
    if path = ENV["NOTIFY_SOCKET"]?
      sock = Socket.unix(Socket::Type::DGRAM)
      begin
        sock.send(message, to: Socket::UNIXAddress.new(path))
      ensure
        sock.close
      end
      true
    else
      false
    end
  end

  def self.listen_fds
    {% if flag?(:linux) %}
      fds = LibSystemD.sd_listen_fds(0)
      raise Error.new if fds < 0
      Array(Int32).new(fds) { |i| LibSystemD::SD_LISTEN_FDS_START + i }
    {% else %}
      Array(Int32).new(0)
    {% end %}
  end

  def self.listen_fds_with_names
    {% if flag?(:linux) %}
      val = Pointer(UInt8).null
      arr = pointerof(val)
      fds = LibSystemD.sd_listen_fds_with_names(0, pointerof(arr))
      raise Error.new if fds < 0
      names = Array(Tuple(Int32, String)).new(fds) do |i|
        ptr = (arr + i).value
        name = String.new(ptr)
        LibC.free ptr
        { i + LibSystemD::SD_LISTEN_FDS_START, name }
      end
      LibC.free arr if fds > 0
      names
    {% else %}
      Array(Tuple(Int32, String)).new(0)
    {% end %}
  end

  def self.store_fds(fds : Array(Int32)) : Bool
    {% if flag?(:linux) %}
      res = LibSystemD.sd_pid_notify_with_fds(0, 0, "FDSTORE=1\n",
                                              fds.to_unsafe, fds.size)
      raise Error.new if res < 0
      res > 0
    {% else %}
      false
    {% end %}
  end

  def self.store_fds(fds : Array(Int32), name : String) : Bool
    {% if flag?(:linux) %}
      res = LibSystemD.sd_pid_notify_with_fds(0, 0,
                                              "FDSTORE=1\nFDNAME=#{name}\n",
                                              fds.to_unsafe, fds.size)
      raise Error.new if res < 0
      res > 0
    {% else %}
      false
    {% end %}
  end

  def self.remove_fds(name : String)
    self.notify("FDSTOREREMOVE=1\nFDNAME=#{name}\n")
  end

  def self.is_tcp_socket?(fd : Int)
    self.is_socket?(fd, Socket::Family::INET | Socket::Family::INET6, Socket::Type::STREAM, 0)
  end

  def self.is_udp_socket?(fd : Int)
    self.is_socket?(fd, Socket::Family::INET | Socket::Family::INET6, Socket::Type::DGRAM, 0)
  end

  def self.is_unix_stream_socket?(fd : Int)
    self.is_socket?(fd, Socket::Family::UNIX, Socket::Type::STREAM, 0)
  end

  def self.is_unix_dgram_socket?(fd : Int)
    self.is_socket?(fd, Socket::Family::UNIX, Socket::Type::DGRAM, 0)
  end

  def self.is_tcp_listener?(fd : Int)
    self.is_socket?(fd, Socket::Family::INET | Socket::Family::INET6, Socket::Type::STREAM, 1)
  end

  def self.is_udp_listener?(fd : Int)
    self.is_socket?(fd, Socket::Family::INET | Socket::Family::INET6, Socket::Type::DGRAM, 1)
  end

  def self.is_unix_stream_listener?(fd : Int)
    self.is_socket?(fd, Socket::Family::UNIX, Socket::Type::STREAM, 1)
  end

  def self.is_unix_dgram_listener?(fd : Int)
    self.is_socket?(fd, Socket::Family::UNIX, Socket::Type::DGRAM, 1)
  end

  # Checks if a FD refers to a socket of the specified type
  # https://www.man7.org/linux/man-pages/man3/sd_is_socket_unix.3.html
  def self.is_socket?(fd : Int, family : Socket::Family, type : Socket::Type, listening : Int) : Bool
    {% if flag?(:linux) %}
      res = LibSystemD.sd_is_socket(fd, family, type, listening)
      raise Error.new if res < 0
      res > 0
    {% else %}
      false
    {% end %}
  end

  class Error < Exception; end
end
