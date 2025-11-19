# SystemD

SystemD integration for Crystal applications, can notify systemd, get socket listeners, store/restore file descriptors, and monitor memory pressure. libsystemd is only required for storing FDs.

Man pages:

https://man7.org/linux/man-pages/man3/sd_pid_notify.3.html
https://man7.org/linux/man-pages/man3/sd_listen_fds.3.html
https://systemd.io/MEMORY_PRESSURE/

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

# When reloading
Signal::HUP.trap do
  SystemD.notify_reloading
  # reload
  SystemD.notify_ready
end

# Starts a watchdog fiber that will report to systemd that the app is ok
# Enable systemd watchdog support with `WatchdogSec=5` under `[Service]`
SystemD.watchdog

# Monitor memory pressure notifications from systemd
# Enable with `MemoryPressureWatch=auto` and `MemoryPressureThresholdSec=1s` under `[Service]`
SystemD::MemoryPressure.monitor do
  # Called when memory pressure is detected
  # Take action like clearing caches, reducing memory usage, etc.
  clear_caches
end

# Store FDs with the SystemD, they will be sent back
# to the application when it restarts. Requires libsystemd
clients = Array(TCPSocket).new
SystemD.store_fds(clients.map &.fd)

# Retrive store FDs
SystemD.named_listeners do |socket, name|
  case name
  when .ends_with?(".socket")
    spawn do
      while client = socket.accept?
        spawn handle_client(client)
      end
    end
  when "stored" # stored FD without name
    @connections << socket
  else
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
