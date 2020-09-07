require "spec"
require "socket"
require "../src/systemd"
require "../src/journald"

ENV["LISTEN_PID"] = Process.pid.to_s
