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

CLIENTS = Array(TCPSocket).new

def server(fd)
  server = TCPServer.new(fd: fd)
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
    client = TCPSocket.new(fd: fd)
    CLIENTS << client
    spawn handle_client(client)
  end
end
SystemD.notify_ready
sleep
