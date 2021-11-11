@[Link(ldflags: "-lsystemd")]
lib LibSystemD
  SD_LISTEN_FDS_START = 3
  alias Int = LibC::Int
  alias PidT = LibC::PidT
  alias UInt = LibC::UInt
  alias Char = UInt8
  fun sd_listen_fds(unset_environment : Int) : Int
  fun sd_listen_fds_with_names(unset_environment : Int, names : Char***) : Int
  fun sd_notify(unset_environment : Int, state : Char*) : Int
  fun sd_pid_notify(pid : PidT, unset_environment : Int, state : Char*) : Int
  fun sd_pid_notify_with_fds(pid : PidT, unset_environment : Int, state : Char*, fds : Void*, n_fds : UInt) : Int
  fun sd_is_socket(fd : Int, family : Int, type : Int, listening : Int) : Int
end
