require "./spec_helper"

describe SystemD do
  it "can notify" do
    ENV["NOTIFY_SOCKET"] = path = File.tempname
    sock = Socket.unix(Socket::Type::DGRAM)
    sock.bind Socket::UNIXAddress.new(path)
    SystemD.notify_ready.should be_true
    message, _ = sock.receive
    message.should eq "READY=1\n"
    sock.close
    File.delete path
  end

  it "can get listen fds" do
    ENV["LISTEN_FDS"] = "2"
    SystemD.listen_fds.should eq [3, 4]
  end

  it "can get listen fds with names" do
    ENV["LISTEN_FDS"] = "2"
    ENV["LISTEN_FDNAMES"] = "echo.socket:stored"
    SystemD.listen_fds_with_names.should eq [{3, "echo.socket"}, {4, "stored"}]
  end

  it "can identify tcp listerner sockets" do
    TCPServer.open("localhost", 0) do |s|
      SystemD.is_unix_stream_listener?(s.fd).should be_false
      SystemD.is_tcp_socket?(s.fd).should be_false
      SystemD.is_tcp_listener?(s.fd).should be_true
    end
  end

  it "can identify tcp sockets" do
    TCPServer.open("localhost", 0) do |s|
      port = s.local_address.port
      TCPSocket.open("localhost", port) do |c|
        SystemD.is_tcp_listener?(c.fd).should be_false
        SystemD.is_unix_stream_socket?(c.fd).should be_false
        SystemD.is_tcp_socket?(c.fd).should be_true
      end
    end
  end

  it "can identify unix sockets" do
    path = File.tempname
    s = UNIXServer.new(path)
    c = UNIXSocket.new(path)
    File.delete path
    SystemD.is_unix_stream_listener?(s.fd).should be_true
    SystemD.is_unix_stream_socket?(c.fd).should be_true
    c.close
    s.close
  end
end
