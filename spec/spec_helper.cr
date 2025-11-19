require "spec"
require "socket"
require "wait_group"
require "../src/systemd"

ENV["LISTEN_PID"] = Process.pid.to_s
