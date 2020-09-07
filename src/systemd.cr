require "./libsystemd"

# Wrapper for libsystemd
# http://man7.org/linux/man-pages/man3/sd_pid_notify_with_fds.3.html
# http://man7.org/linux/man-pages/man3/sd_listen_fds_with_names.3.html
module SystemD
  LISTEN_FDS_START = LibSystemD::SD_LISTEN_FDS_START

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

  def self.notify(message = "READY=1\n")
    {% if flag?(:linux) %}
      LibSystemD.sd_notify(0, message).tap do |ret|
        if ret == -1
          raise Error.new
        end
      end
    {% else %}
      0
    {% end %}
  end

  def self.listen_fds
    {% if flag?(:linux) %}
      fds = LibSystemD.sd_listen_fds(0)
      raise Error.new if fds < 0
      Array(Int32).new(fds) { |i| LISTEN_FDS_START + i }
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
      { i + LISTEN_FDS_START, name }
    end
    LibC.free arr
    names
    {% else %}
      Array(Tuple(Int32, String)).new(0)
    {% end %}
  end

  def self.store_fds(fds : Array(Int32))
    {% if flag?(:linux) %}
      LibSystemD.sd_pid_notify_with_fds(0, 0, "FDSTORE=1\n",
                                        fds.to_unsafe, fds.size).tap do |ret|

        if ret < 0
          raise Error.new
        end
      end
    {% else %}
      0
    {% end %}
  end

  def self.store_fds(fds : Array(Int32), fd_name : String)
    {% if flag?(:linux) %}
      res = LibSystemD.sd_pid_notify_with_fds(0, 0,
                                              "FDSTORE=1\nFDNAME=#{fd_name}\n",
                                              fds.to_unsafe, fds.size)
      raise Error.new if res < 0
      res
    {% else %}
      0
    {% end %}
  end

  def self.remove_fds(fd_name : String)
    self.notify("FDSTOREREMOVE=1\nFDNAME=#{fd_name}\n")
  end

  class Error < Exception; end
end
