require "./spec_helper"

describe SystemD do
  it "can notify" do
    SystemD.notify_ready.should eq 1
  end
end
