require "./spec_helper"
require "../src/memory_pressure"

describe SystemD::MemoryPressure do
  it "does nothing when MEMORY_PRESSURE_WATCH is not set" do
    ENV.delete("MEMORY_PRESSURE_WATCH")
    ENV.delete("MEMORY_PRESSURE_WRITE")

    called = false
    SystemD::MemoryPressure.monitor { called = true }

    sleep 0.1.seconds
    called.should be_false
  end

  it "does nothing when MEMORY_PRESSURE_WATCH is /dev/null" do
    ENV["MEMORY_PRESSURE_WATCH"] = "/dev/null"
    ENV.delete("MEMORY_PRESSURE_WRITE")

    called = false
    SystemD::MemoryPressure.monitor { called = true }

    sleep 0.1.seconds
    called.should be_false
  end

  it "monitors memory pressure on a FIFO" do
    fifo_path = File.tempname
    begin
      # Create a FIFO
      ret = LibC.mkfifo(fifo_path, 0o600)
      raise IO::Error.from_errno("mkfifo failed") if ret != 0

      ENV["MEMORY_PRESSURE_WATCH"] = fifo_path
      ENV.delete("MEMORY_PRESSURE_WRITE")

      wg = WaitGroup.new(1)
      SystemD::MemoryPressure.monitor { wg.done }

      # Write to the FIFO to trigger memory pressure
      File.open(fifo_path, "w") do |f|
        f.sync = true
        f.print "pressure"
      end

      # Wait for the callback to be called
      wg.wait
    ensure
      File.delete(fifo_path) if File.exists?(fifo_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
    end
  end

  it "monitors memory pressure on a Unix socket" do
    socket_path = File.tempname
    begin
      # Create a Unix socket server
      server = UNIXServer.new(socket_path)

      ENV["MEMORY_PRESSURE_WATCH"] = socket_path
      ENV.delete("MEMORY_PRESSURE_WRITE")

      ch = Channel(Nil).new
      SystemD::MemoryPressure.monitor { ch.send(nil) }

      # Accept the connection and send data
      client = server.accept
      client.print "pressure"
      client.flush

      # Wait for the callback to be called
      ch.receive

      client.close
      server.close
    ensure
      File.delete(socket_path) if File.exists?(socket_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
    end
  end

  it "writes threshold data when MEMORY_PRESSURE_WRITE is set" do
    socket_path = File.tempname
    begin
      server = UNIXServer.new(socket_path)

      # Set up both environment variables
      write_data = "some threshold"
      ENV["MEMORY_PRESSURE_WATCH"] = socket_path
      ENV["MEMORY_PRESSURE_WRITE"] = Base64.strict_encode(write_data)

      ch = Channel(Nil).new
      SystemD::MemoryPressure.monitor { ch.send(nil) }

      # Accept the connection and read the threshold data
      client = server.accept
      buffer = uninitialized UInt8[4096]
      count = client.read(buffer.to_slice)
      received = String.new(buffer.to_unsafe, count)
      received.should eq write_data

      # Now send pressure notification
      client.print "pressure"
      client.flush

      # Wait for the callback to be called
      ch.receive

      client.close
      server.close
    ensure
      File.delete(socket_path) if File.exists?(socket_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
      ENV.delete("MEMORY_PRESSURE_WRITE")
    end
  end

  it "handles socket reconnection" do
    socket_path = File.tempname
    begin
      server = UNIXServer.new(socket_path)

      ENV["MEMORY_PRESSURE_WATCH"] = socket_path
      ENV.delete("MEMORY_PRESSURE_WRITE")

      call_count = 0
      SystemD::MemoryPressure.monitor { call_count += 1 }

      # Accept first connection and trigger pressure
      client1 = server.accept
      client1.print "pressure1"

      # Close the connection to force reconnection
      client1.close

      # Accept second connection and trigger pressure again
      client2 = server.accept
      client2.print "pressure2"

      # Wait a bit for callbacks
      timeout = Time.monotonic + 2.seconds
      until call_count >= 2 || Time.monotonic > timeout
        Fiber.yield
      end

      call_count.should be >= 2

      client2.close
      server.close
    ensure
      File.delete(socket_path) if File.exists?(socket_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
    end
  end
end
