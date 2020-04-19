require "./spec_helper"

describe SystemD do
  it "can notify" do
    ENV["NOTIFY_SOCKET"] = path = File.tempname
    sock = Socket.unix(Socket::Type::DGRAM)
    sock.bind Socket::UNIXAddress.new(path)
    SystemD.notify_ready.should eq 1
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
    SystemD.listen_fds_with_names.should eq [{ 3, "echo.socket" }, { 4, "stored" }]
  end
end
