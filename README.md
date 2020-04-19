# SystemD

libsystemd wrapper for Crystal.

Detailed information:

http://man7.org/linux/man-pages/man3/sd_pid_notify_with_fds.3.html

http://man7.org/linux/man-pages/man3/sd_listen_fds_with_names.3.html

No-op for non Linux systems.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     systemd:
       github: 84codes/systemd.cr
   ```

2. Run `shards install`

## Usage

```crystal
require "systemd"

# Notify SystemD when the application has started
SystemD.notify_ready

# Update the status
SystemD.notify_status("Accepting connections")

SystemD.listen_fds.each do |fd|
  server = TCPServer.new(fd: fd)
  ...
end

# Store FDs with the SystemD, they will be sent back
# to the application when it restarts
clients = Array(TCPSocket).new
SystemD.store_fds(clients.map &.fd)

SystemD.listen_fds_with_names.each do |fd, name|
  case name
  when /\.socket$/
    server = TCPServer.new(fd: fd)
    ...
  when "stored"
    client = TCPSocket.new(fd: fd)
    ...
  end
end
```

## Contributing

1. Fork it (<https://github.com/84codes/systemd.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Carl Hörberg](https://github.com/carlhoerberg) - creator and maintainer
