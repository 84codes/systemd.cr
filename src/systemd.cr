require "socket"
{% if flag?(:linux) %}
  require "./libsystemd"
{% end %}

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
    usec = Time.monotonic.total_microseconds.to_u64
    self.notify("RELOADING=1\nMONOTONIC_USEC=#{usec}\n")
  end

  def self.notify_status(status : String)
    self.notify("STATUS=#{status}\n")
  end

  # Report to systemd in a separate fiber
  # The *callback* should return a trueish value or else the keepalive won't be sent
  # If systemd doesn't get a ping every `WATCHDOG_USEC` it will kill the process.
  # This method can always be called, if watchdog isn't enabled in systemd or
  # the process is not running under systemd it will do nothing.
  def self.watchdog(&callback : -> _)
    sock_path = ENV["NOTIFY_SOCKET"]? || return
    interval = self.watchdog_interval? || return
    interval = interval / 2
    spawn(name: "SystemD Watchdog") do
      sock = UNIXSocket.new(sock_path, Socket::Type::DGRAM)
      loop do
        sleep interval
        callback.call || break
        sock.send("WATCHDOG=1\n")
      end
    end
  end

  def self.watchdog
    self.watchdog { true }
  end

  def self.watchdog_interval? : Time::Span?
    if wpid = ENV.fetch("WATCHDOG_PID", "").to_i?
      return unless wpid == Process.pid
    end
    if usec = ENV.fetch("WATCHDOG_USEC", "").to_u64?
      return usec.microsecond
    end
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

  def self.listeners : Indexable(Socket)
    listen_fds.map do |fd|
      family = Socket::Family.new(getsockopts(fd, LibC::SO_DOMAIN, 0).to_u16)
      type = Socket::Type.new(getsockopts(fd, LibC::SO_TYPE, 0))
      Socket.new(fd: fd, family: family, type: type)
    end
  end

  def self.named_listeners : Indexable(Tuple(Socket, String))
    listen_fds_with_names.map do |fd, name|
      family = Socket::Family.new(getsockopts(fd, LibC::SO_DOMAIN, 0).to_u16)
      type = Socket::Type.new(getsockopts(fd, LibC::SO_TYPE, 0))
      {Socket.new(fd: fd, family: family, type: type), name}
    end
  end

  def self.is_listening?(fd)
    getsockopts(fd, LibC::SO_ACCEPTCONN, 0) == 1
  end

  def self.listen_fds_with_names : Indexable(Tuple(Int32, String))
    names = ENV.fetch("LISTEN_FDNAMES", "").split(":")
    listen_fds.map_with_index do |fd, i|
      {fd, names[i]? || "unknown"}
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
