@[Link(ldflags: "-lsystemd")]
lib LibSystemD
  LOG_EMERG = 0
  LOG_ALERT = 1
  LOG_CRIT = 2
  LOG_ERR = 3
  LOG_WARNING = 4
  LOG_NOTICE = 5
  LOG_INFO = 6
  LOG_DEBUG = 7
  SD_LISTEN_FDS_START = 3
  alias Int = LibC::Int
  alias PidT = LibC::PidT
  alias UInt = LibC::UInt
  alias Char = UInt8
  {% if flag?(:linux) %}
    fun sd_listen_fds(unset_environment : Int) : Int
    fun sd_listen_fds_with_names(unset_environment : Int, names : Char***) : Int
    fun sd_notify(unset_environment : Int, state : Char*) : Int
    fun sd_pid_notify(pid : PidT, unset_environment : Int, state : Char*) : Int
    fun sd_pid_notify_with_fds(pid : PidT, unset_environment : Int, state : Char*, fds : Void*, n_fds : UInt) : Int
    fun sd_journal_print(priority : Int, format : Char*, ...) : Int
  {% end %}
end
