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

  it "parses PSI data" do
    data = "some avg10=1.50 avg60=0.25 avg300=0.00 total=12345\nfull avg10=0.75 avg60=0.10 avg300=0.00 total=678\n"
    pressure = SystemD::MemoryPressure.parse(data).should_not be_nil
    pressure.some.should eq SystemD::MemoryPressure::Stall.new(1.5, 0.25, 0.0, 12345u64)
    pressure.full.try(&.avg10).should eq 0.75
  end

  it "parses PSI data without a full line" do
    pressure = SystemD::MemoryPressure.parse("some avg10=2.00 avg60=1.00 avg300=0.50 total=1\n").should_not be_nil
    pressure.some.avg10.should eq 2.0
    pressure.full.should be_nil
  end

  it "returns nil for malformed PSI data" do
    SystemD::MemoryPressure.parse("garbage").should be_nil
    SystemD::MemoryPressure.parse("some avg10=x avg60=1 avg300=1 total=1").should be_nil
  end

  it "reads pressure from a file" do
    path = File.tempname
    File.write(path, "some avg10=3.00 avg60=2.00 avg300=1.00 total=99\n")
    SystemD::MemoryPressure.pressure(path).try(&.some.total).should eq 99
    SystemD::MemoryPressure.pressure("/nonexistent/memory.pressure").should be_nil
  ensure
    File.delete?(path) if path
  end

  it "prefers a watched .pressure file" do
    path = File.tempname(suffix: ".pressure")
    File.write(path, "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
    ENV["MEMORY_PRESSURE_WATCH"] = path
    SystemD::MemoryPressure.pressure_path.should eq path
  ensure
    ENV.delete("MEMORY_PRESSURE_WATCH")
    File.delete?(path) if path
  end

  it "monitor only calls the block on pressure" do
    fifo_path = File.tempname
    begin
      LibC.mkfifo(fifo_path, 0o600).should eq 0
      ENV["MEMORY_PRESSURE_WATCH"] = fifo_path
      ENV.delete("MEMORY_PRESSURE_WRITE")

      calls = Atomic(Int32).new(0)
      SystemD::MemoryPressure.monitor { calls.add(1) }

      File.open(fifo_path, "w") do |f|
        f.sync = true
        f.print "pressure"
      end

      sleep 100.milliseconds
      calls.get.should eq 1
    ensure
      File.delete(fifo_path) if File.exists?(fifo_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
    end
  end

  it "watch signals relief once pressure drops below the threshold" do
    fifo_path = File.tempname
    begin
      LibC.mkfifo(fifo_path, 0o600).should eq 0
      ENV["MEMORY_PRESSURE_WATCH"] = fifo_path
      ENV.delete("MEMORY_PRESSURE_WRITE")

      pressured = Channel(Nil).new(1)
      relieved = Channel(Nil).new(1)
      SystemD::MemoryPressure.watch(Float64::MAX, 10.milliseconds) { |pressure| pressure ? pressured.send(nil) : relieved.send(nil) }

      File.open(fifo_path, "w") do |f|
        f.sync = true
        f.print "pressure"
      end

      pressured.receive
      select
      when relieved.receive
      when timeout(5.seconds)
        fail "relief was not signalled"
      end
    ensure
      File.delete(fifo_path) if File.exists?(fifo_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
    end
  end

  it "watch does not signal relief while pressure persists" do
    pending! "no PSI" unless File.file?("/proc/pressure/memory")
    fifo_path = File.tempname
    begin
      LibC.mkfifo(fifo_path, 0o600).should eq 0
      ENV["MEMORY_PRESSURE_WATCH"] = fifo_path
      ENV.delete("MEMORY_PRESSURE_WRITE")

      pressured = Channel(Nil).new(1)
      relieved = Channel(Nil).new(1)
      SystemD::MemoryPressure.watch(0.0, 10.milliseconds) { |pressure| pressure ? pressured.send(nil) : relieved.send(nil) }

      File.open(fifo_path, "w") do |f|
        f.sync = true
        f.print "pressure"
      end

      pressured.receive
      select
      when relieved.receive
        fail "relief signalled while under pressure"
      when timeout(200.milliseconds)
      end
    ensure
      File.delete(fifo_path) if File.exists?(fifo_path)
      ENV.delete("MEMORY_PRESSURE_WATCH")
    end
  end
end
