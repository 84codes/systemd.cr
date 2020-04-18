require "spec"
require "socket"
require "../src/systemd"
ENV["NOTIFY_SOCKET"] = path = "/tmp/systemd_cr_spec.sock"
sock = Socket.unix(Socket::Type::DGRAM)
sock.bind Socket::UNIXAddress.new(path)
spawn do
  loop do
    response, addr = sock.receive
    p response, addr
  rescue
    next
  end
ensure
  sock.close
  File.delete path
end
