require "socket"
require "openssl"
require "../src/systemd"
pp ENV

# a simple TCP app that will echo the input to output
# But if it's being restarted by systemd it will send the FDs back to systemd
# and then acquire them again when started.

def handle_client(client)
  loop do
    message = client.gets
    client.puts message
    client.flush
  end
rescue IO::Error
  CLIENTS.delete(client)
end

CLIENTS = Array(Socket).new

def server(fd)
  server =
    case
    when SystemD.is_tcp_listener?(fd)
      TCPServer.new(fd: fd)
    when SystemD.is_unix_stream_listener?(fd)
      UNIXServer.new(fd: fd)
    else
      raise "invalid socket type"
    end

  while client = server.accept?
    CLIENTS << client
    spawn handle_client(client)
  end
end

Signal::TERM.trap do
  SystemD.store_fds(CLIENTS.map(&.fd))
  exit 0
end

SystemD.listen_fds_with_names.each do |fd, name|
  case name
  when /\.socket$/
    spawn server(fd)
  else
    client =
      case
      when SystemD.is_tcp_socket?(fd)
        TCPSocket.new(fd: fd)
      when SystemD.is_unix_stream_socket?(fd)
        UNIXSocket.new(fd: fd)
      else
        raise "unknown socket type"
      end
    CLIENTS << client
    spawn handle_client(client)
  end
end
SystemD.notify_ready
sleep
