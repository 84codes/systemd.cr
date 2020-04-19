require "spec"
require "socket"
require "../src/systemd"

ENV["LISTEN_PID"] = Process.pid.to_s
