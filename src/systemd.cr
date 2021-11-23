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

  LISTEN_FDS_START = 3

  def self.listen_fds : Indexable(Int32)
    if Process.pid == ENV.fetch("LISTEN_PID", "").to_i?
      fds = ENV.fetch("LISTEN_FDS", "0").to_i
      Array(Int32).new(fds) { |i| LISTEN_FDS_START + i }
    else
      Array(Int32).new(0)
    end
  end

  def self.listen_fds_with_names : Indexable(Tuple(Int32, String))
    if Process.pid == ENV.fetch("LISTEN_PID", "").to_i?
      ENV.fetch("LISTEN_FDNAMES", "").split(":").map_with_index do |name, i|
        {LISTEN_FDS_START + i, name}
      end
    else
      Array(Tuple(Int32, String)).new(0)
    end
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
      res = LibSystemD.sd_pid_notify_with_fds(0, 0, "FDSTORE=1\nFDNAME=#{name}\n", fds.to_unsafe, fds.size)
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
      f = getsockopts(fd, LibC::SO_DOMAIN, 0)
      family.includes?(Socket::Family.new(f.to_u16)) || return false

      t = getsockopts(fd, LibC::SO_TYPE, 0)
      type == Socket::Type.new(t) || return false

      if type == Socket::Type::STREAM
        l = getsockopts(fd, LibC::SO_ACCEPTCONN, 0)
        l == listening
      else
        sockaddr = Pointer(LibC::Sockaddr).null
        addrlen = 0u32
        if LibC.getpeername(fd, sockaddr, pointerof(addrlen)) == 0
          listening == 0
        else # getpeername failed, which means it's not connected to a remote, ie listening
          listening == 1
        end
      end
    {% else %}
      false
    {% end %}
  end

  def self.listening_socket?(fd : Int)
    t = getsockopts(fd, LibC::SO_TYPE, 0)
    type = Socket::Type.new(t)
    case type
    when Socket::Type::STREAM
      getsockopts(fd, LibC::SO_ACCEPTCONN, 0) == listening
    else
      sockaddr = Pointer(LibC::Sockaddr).null
      addrlen = 0u32
      if LibC.getpeername(fd, sockaddr, pointerof(addrlen)) == 0
        listening == 0
      else
        listening == 1
      end
    end
  end

  def self.tcp_socket?(fd : Int)
    t = getsockopts(fd, LibC::SO_TYPE, 0)
    Socket::Type.new(t) == Socket::Type::STREAM || return false

    f = getsockopts(fd, LibC::SO_DOMAIN, 0)
    (Socket::Family::INET | Socket::Family::INET6).includes? Socket::Family.new(f.to_u16)
  end

  def self.udp_socket?(fd : Int)
    t = getsockopts(fd, LibC::SO_TYPE, 0)
    Socket::Type.new(t) == Socket::Type::DGRAM || return false

    f = getsockopts(fd, LibC::SO_DOMAIN, 0)
    (Socket::Family::INET | Socket::Family::INET6).includes? Socket::Family.new(f.to_u16)
  end

  def self.unix_stream_socket?(fd : Int)
    t = getsockopts(fd, LibC::SO_TYPE, 0)
    Socket::Type.new(t) == Socket::Type::STREAM || return false

    f = getsockopts(fd, LibC::SO_DOMAIN, 0)
    Socket::Family.new(f.to_u16) == Socket::Family::UNIX
  end

  def self.unix_dgram_socket?(fd : Int)
    t = getsockopts(fd, LibC::SO_TYPE, 0)
    Socket::Type.new(t) == Socket::Type::DGRAM || return false

    f = getsockopts(fd, LibC::SO_DOMAIN, 0)
    Socket::Family.new(f.to_u16) == Socket::Family::UNIX
  end

  private def self.getsockopts(fd, optname, optval, level = LibC::SOL_SOCKET)
    optsize = LibC::SocklenT.new(sizeof(typeof(optval)))
    ret = LibC.getsockopt(fd, level, optname, pointerof(optval), pointerof(optsize))
    raise Socket::Error.from_errno("getsockopt") if ret == -1
    optval
  end

  class Error < Exception; end
end

lib LibC
  {% if flag?(:linux) %}
    SO_TYPE       =  3
    SO_ACCEPTCONN = 30
    SO_DOMAIN     = 39
  {% end %}
end
