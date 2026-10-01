# SystemD

SystemD integration for Crystal applications, can notify systemd, get socket listeners, store/restore file descriptors, and monitor memory pressure. libsystemd is only required for storing FDs.

Man pages:

https://man7.org/linux/man-pages/man3/sd_pid_notify.3.html
https://man7.org/linux/man-pages/man3/sd_listen_fds.3.html
https://systemd.io/PRESSURE/

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

## Memory pressure

systemd can notify a service when its cgroup is under memory pressure. Enable it under `[Service]`:

```ini
MemoryPressureWatch=auto
# Optional, how long tasks may stall on memory within a 2s window before a notification (default 200ms)
MemoryPressureThresholdSec=200ms
```

systemd then passes `MEMORY_PRESSURE_WATCH` (the cgroup's `memory.pressure` file) and `MEMORY_PRESSURE_WRITE` (the trigger to register on it) to the service. Without `MEMORY_PRESSURE_WATCH`, or when it's `/dev/null`, monitoring is disabled and the blocks are never called.

### Reacting to pressure

`monitor` calls its block each time memory pressure is detected:

```crystal
SystemD::MemoryPressure.monitor do
  # Take action like clearing caches, reducing memory usage, etc.
  clear_caches
end
```

### Pressure and relief

Notifications only signal the onset of pressure, never that it's over. Use `watch` when the application backs off under pressure and must know when to resume. Its block is called with `true` when pressure is detected, and with `false` when it's relieved:

```crystal
SystemD::MemoryPressure.watch(release_below: 1.0, check_interval: 1.second) do |pressure|
  if pressure
    pause_work
  else
    resume_work
  end
end
```

While under pressure, `watch` reads the PSI file every `check_interval`. It signals relief once `some avg10` drops below `release_below`, which is the percentage of the last 10 seconds that some task stalled on memory. If no PSI file can be read, relief is signalled at the first check.

`avg10` is a 10-second running average, so it lags behind the stalls. Together with the onset threshold (200ms of stalls in 2s by default), that gives hysteresis: pressure has to be well past before relief is signalled.

Both blocks run in a dedicated thread (an isolated execution context), so keep them short. For example, set a flag and act on it from the application's own fibers.

### Reading PSI values

```crystal
if pressure = SystemD::MemoryPressure.pressure
  pressure.some.avg10    # % of time some task stalled on memory, 10s average
  pressure.some.avg60
  pressure.some.avg300
  pressure.some.total    # total stall time in microseconds
  pressure.full.try &.avg10 # % of time all tasks stalled, nil if there's no "full" line
end
```

`pressure` reads the watched file when it's a `.pressure` file, otherwise the process' cgroup v2 `memory.pressure`, falling back to the system-wide `/proc/pressure/memory`. `SystemD::MemoryPressure.parse(string)` parses PSI file contents directly.

### Testing locally

`MEMORY_PRESSURE_WATCH` can point at a regular PSI file, a FIFO or a Unix socket. Writing to a FIFO simulates a notification:

```sh
mkfifo /tmp/pressure
MEMORY_PRESSURE_WATCH=/tmp/pressure MEMORY_PRESSURE_WRITE= ./my-app &
echo > /tmp/pressure
```

Processes started from a desktop session usually inherit both variables from the desktop's own service, so a shell may already have them set. Clear `MEMORY_PRESSURE_WRITE` when watching a FIFO, as above. Otherwise its trigger is written into the FIFO and read back as a pressure notification.

## Contributing

1. Fork it (<https://github.com/84codes/systemd.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Carl Hörberg](https://github.com/carlhoerberg) - creator and maintainer
