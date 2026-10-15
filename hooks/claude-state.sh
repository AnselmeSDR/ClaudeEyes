#!/bin/bash
# Claude Code hook shared by every event:
#  - publishes each session state to ~/.claude/eyes/sessions/<id>.json for the Claude Eyes app
#  - drives the terminal tab progress bar (OSC 9;4) in Ghostty and iTerm2
#
# Progress bar rendering:
#   working   -> 3      accent color, bouncing
#   toolError -> 2      red, bouncing (a tool failed, Claude keeps going)
#   waiting   -> 4;100  orange, full (permission prompt or question for you), kept until you answer
#   done      -> 1;100  accent color, full, cleared after a few seconds
#   failed    -> 2;100  red, full (API error ended the turn)
# Ghostty hides the bar after 15s without update, so a keepalive loop
# re-sends the current state while Claude is busy.
# Claude Code's live status (~/.claude/sessions/<pid>.json) corrects the hook state:
# it knows when a dialog waits for you and when you answered it, which no hook reports.
# Same terminals as Claude Code's own progress bar: elsewhere OSC 9 may show up as a notification.
#
# Runs on every event: it forks as little as possible (one ps, one jq, one date, one mv).

sessionsDir="$HOME/.claude/eyes/sessions"
registryDir="$HOME/.claude/sessions"   # Claude Code's live registry, one <pid>.json per process
progressDisabledFlag="$HOME/.claude/eyes/progress-disabled"   # created by the app when the setting is off
progressDir="${TMPDIR:-/tmp}/claude-ghostty-progress"
refreshEvery=10   # seconds, must stay below Ghostty's 15s timeout
doneDelay=4       # seconds the "done" bar stays visible
maxIdle=1800      # seconds without any hook event before giving up (except while waiting)

# Sets sequence, the OSC 9;4 parameters for a state
sequenceFor() {
  case "$1" in
    working) sequence="3" ;;
    toolError) sequence="2" ;;
    waiting) sequence="4;100" ;;
    done) sequence="1;100" ;;
    failed) sequence="2;100" ;;
    *) sequence="0" ;;
  esac
}

emit() {
  printf '\033]9;4;%s\007' "$2" > "$1" 2>/dev/null
}

# Sets liveStatus (busy|idle|waiting), liveWaitingFor and liveSince (seconds) without forking:
# the keepalive loop calls it every second
readLiveStatus() {
  local file="$registryDir/$1.json" json=""
  local statusPattern='"status":"([a-z]+)"' waitingPattern='"waitingFor":"([^"]*)"' sincePattern='"statusUpdatedAt":([0-9]+)'
  liveStatus="" liveWaitingFor="" liveSince=0
  [ -r "$file" ] || return 1
  IFS= read -r -d '' json < "$file"
  [[ $json =~ $statusPattern ]] && liveStatus=${BASH_REMATCH[1]}
  [[ $json =~ $waitingPattern ]] && liveWaitingFor=${BASH_REMATCH[1]}
  [[ $json =~ $sincePattern ]] && liveSince=$(( BASH_REMATCH[1] / 1000 ))
  [ -n "$liveStatus" ]
}

# resolveState <hook state> <hook time> <claude pid>: sets shownState.
# A dialog waiting for you wins over hook events from subagents or parallel tools;
# once you answered (no hook fires then), the bar follows Claude Code again.
# "dialog open" is a dialog the user opened (/config, /model…), not Claude waiting.
resolveState() {
  shownState=$1
  readLiveStatus "$3" || return 0
  if [ "$liveStatus" = "waiting" ] && [ "$liveWaitingFor" != "dialog open" ]; then
    shownState=waiting
  elif [ "$1" = "waiting" ] && [ "$liveSince" -gt "$2" ]; then
    [ "$liveStatus" = "busy" ] && shownState=working || shownState=idle
  fi
}

# isExpired <state> <hook time> <now>
isExpired() {
  local state=$1 age=$(( $3 - $2 ))
  # A session waiting for you keeps its bar until you answer, however long it takes
  [ "$state" = "waiting" ] && return 1
  [ "$state" = "idle" ] && return 0
  [ "$state" = "done" ] && [ "$age" -ge "$doneDelay" ] && return 0
  [ "$age" -ge "$maxIdle" ]
}

keepalive() {
  local sessionId=$1 ttyDev=$2 claudePid=$3
  local stateFile="$progressDir/$sessionId.state"
  local pidFile="$progressDir/$sessionId.pid"
  local pipe="$progressDir/$sessionId.pipe"
  local state since now shown="" tick=0
  # The clock and the one-second wait cost no process: SECONDS, and a read timing out on a pipe nobody writes to
  local startedAt
  startedAt=$(date +%s)
  rm -f "$pipe"
  mkfifo "$pipe" 2>/dev/null && exec 9<>"$pipe"
  rm -f "$pipe"

  while kill -0 "$claudePid" 2>/dev/null && [ -f "$stateFile" ] && [ ! -e "$progressDisabledFlag" ]; do
    now=$(( startedAt + SECONDS ))
    read -r state since < "$stateFile"
    resolveState "$state" "$since" "$claudePid"

    if isExpired "$shownState" "$since" "$now"; then
      # Release the slot, then check once more: a new turn may have just started
      rm -f "$pidFile"
      read -r state since < "$stateFile"
      resolveState "$state" "$since" "$claudePid"
      if isExpired "$shownState" "$since" "$now"; then
        emit "$ttyDev" 0
        exit 0
      fi
      echo $$ > "$pidFile"
    fi

    # Right away when the state changes, then regularly so that Ghostty keeps the bar
    if [ "$shownState" != "$shown" ] || [ "$tick" -ge "$refreshEvery" ]; then
      sequenceFor "$shownState"
      emit "$ttyDev" "$sequence"
      shown=$shownState
      tick=0
    fi
    tick=$((tick + 1))
    read -t 1 -u 9 _ 2>/dev/null || [ $? -gt 128 ] || sleep 1
  done

  emit "$ttyDev" 0
  rm -f "$pidFile"
  kill -0 "$claudePid" 2>/dev/null || rm -f "$stateFile"
}

# Background mode, spawned by the hook itself
if [ "$1" = "--keepalive" ]; then
  keepalive "$2" "$3" "$4"
  exit 0
fi

# Hooks have no controlling terminal: walk up to the claude process, one ps per level
# (usually one: Claude Code is the hook's parent)
claudePid="" ttyDev=""
pid=$PPID
for _ in 1 2 3 4 5 6; do
  read -r parent tty comm < <(ps -o ppid=,tty=,comm= -p "$pid" 2>/dev/null)
  [ -n "$comm" ] || break
  if [ "${comm##*/}" = "claude" ]; then
    claudePid=$pid
    case "$tty" in ttys*) ttyDev="/dev/$tty" ;; esac
    break
  fi
  pid=$parent
  [ "${pid:-0}" -gt 1 ] || break
done

# One field per line. cwd, tool and command come JSON-encoded, ready to be written back.
# signal: what a command's output or an edit reveals:
#   testsFailed / testsPassed  the summary line test runners print at the end of their output
#   errorOutput                a well-known error format (traceback, compiler or git error, panic…)
#   bigEdit                    a long Write or Edit
# Summaries are at the end: only the last 8000 characters of the output are searched.
# jq anchors ^ and $ to the whole text: (?m) makes them match at each line.
{
  read -r event
  read -r sessionId
  read -r toolName
  read -r notificationType
  read -r trigger
  read -r signal
  read -r cwdJson
  read -r toolJson
  read -r commandJson
} < <(jq -r '
  def json: if . == null or . == "" then "null" else tostring | tojson end;
  def lineCount: (. // "") | tostring | split("\n") | length;
  def output: .tool_response
    | if type == "object" then [.stdout, .stderr] | map(. // "" | tostring) | join("\n")
      elif type == "string" then . else "" end
    | .[-8000:];

  # Test runner summaries (PHPUnit, Pest, Jest, Vitest, pytest, RSpec, Mocha, go test, cargo test, swift test)
  def failedRun: test("(?m)"
    + "^(FAILURES|ERRORS)!$"
    + "|^ *Tests?:? +[0-9]+ failed"
    + "|^ *Test Files +[0-9]+ failed"
    + "|^=+ .*[0-9]+ (failed|error)"
    + "|[0-9]+ examples?, [1-9][0-9]* failures?"
    + "|^ +[1-9][0-9]* failing$"
    + "|^--- FAIL: |^FAIL\t"
    + "|^test result: FAILED"
    + "|Executed [0-9]+ tests?, with [1-9][0-9]* failures?"
    + "|[1-9][0-9]* (tests?|specs?) failed");
  def passedRun: test("(?m)"
    + "^OK \\([0-9]+ tests?"
    + "|^ *Tests?:? +[0-9]+ passed"
    + "|^=+ [0-9]+ passed"
    + "|[0-9]+ examples?, 0 failures"
    + "|^ +[0-9]+ passing"
    + "|^ok +[^ ]"
    + "|^test result: ok\\."
    + "|Executed [0-9]+ tests?, with 0 failures");
  # Error formats of common tools: Python, git, compilers (gcc, clang, swiftc, rustc, tsc), JS, PHP, Go, shells, npm
  def errorOutput: test("(?m)"
    + "^Traceback \\(most recent call last\\):"
    + "|^fatal: "
    + "|^error(\\[E[0-9]+\\])?: "
    + "|:[0-9]+:[0-9]+: error: "
    + "|error TS[0-9]+: "
    + "|^(Uncaught )?([A-Z][A-Za-z]*)?Error: "
    + "|^(PHP )?(Fatal|Parse) error: "
    + "|^panic: |thread .* panicked"
    + "|: command not found$"
    + "|^npm (ERR!|error) "
    + "|Segmentation fault");

  def signal:
    if .hook_event_name != "PostToolUse" then ""
    elif .tool_name == "Bash" then
      output
      | if failedRun then "testsFailed"
        elif errorOutput then "errorOutput"
        elif passedRun then "testsPassed"
        else "" end
    elif .tool_name == "Write" and (.tool_input.content | lineCount) > 150 then "bigEdit"
    elif .tool_name == "Edit" and (.tool_input.new_string | lineCount) > 60 then "bigEdit"
    else "" end;

  (.hook_event_name // "" | tostring), (.session_id // "" | tostring), (.tool_name // "" | tostring),
  (.notification_type // "" | tostring), (.trigger // "" | tostring), signal,
  (.cwd | json), (.tool_name | json),
  (if .tool_name == "Bash" then .tool_input.command // "" | tostring | .[0:160] else null end | json)
')

# The id names a file: refuse anything else than a plain id
case "$sessionId" in "" | *[!A-Za-z0-9_-]*) exit 0 ;; esac

case "$event" in
  SessionStart)
    state=idle ;;
  UserPromptSubmit | PostToolUse | SubagentStart | PreCompact)
    state=working ;;
  PreToolUse)
    case "$toolName" in
      AskUserQuestion | ExitPlanMode) state=waiting ;;
      *) state=working ;;
    esac ;;
  PermissionRequest)
    state=waiting ;;
  Notification)
    case "$notificationType" in
      permission_prompt | elicitation_dialog) state=waiting ;;
      idle_prompt) state=idle ;;
      *) exit 0 ;;
    esac ;;
  PostToolUseFailure | PermissionDenied)
    state=toolError ;;
  PostCompact)
    [ "$trigger" = "manual" ] && state=done || state=working ;;
  Stop)
    state=done ;;
  StopFailure)
    state=failed ;;
  SessionEnd)
    state=ended ;;
  *)
    exit 0 ;;
esac

now=$(date +%s)

publishSession() {
  local file="$sessionsDir/$sessionId.json"
  if [ "$state" = "ended" ]; then
    rm -f "$file"
    return
  fi
  [ -d "$sessionsDir" ] || mkdir -p "$sessionsDir"

  # Keep the start time while the state stays the same, read without forking
  local stateSince=$now json="" prevState="" prevSince=""
  local statePattern='"state": *"([A-Za-z]+)"' sincePattern='"stateSince": *([0-9]+)'
  if [ -r "$file" ]; then
    IFS= read -r -d '' json < "$file"
    [[ $json =~ $statePattern ]] && prevState=${BASH_REMATCH[1]}
    [[ $json =~ $sincePattern ]] && prevSince=${BASH_REMATCH[1]}
    [ "$prevState" = "$state" ] && [ -n "$prevSince" ] && stateSince=$prevSince
  fi

  # Only plain values are written unquoted by hand; the rest comes JSON-encoded from jq
  local ttyJson=null signalJson=null terminalAppJson=null
  [ -n "$ttyDev" ] && ttyJson="\"$ttyDev\""
  [ -n "$signal" ] && signalJson="\"$signal\""
  case "${__CFBundleIdentifier:-}" in
    "" | *[!A-Za-z0-9.-]*) ;;
    *) terminalAppJson="\"$__CFBundleIdentifier\"" ;;
  esac

  # Atomic write: the app may read the file at any time
  printf '{"sessionId":"%s","cwd":%s,"pid":%s,"tty":%s,"state":"%s","event":"%s","tool":%s,"command":%s,"signal":%s,"terminalApp":%s,"at":%s,"stateSince":%s}\n' \
    "$sessionId" "${cwdJson:-null}" "${claudePid:-0}" "$ttyJson" "$state" "$event" "${toolJson:-null}" \
    "${commandJson:-null}" "$signalJson" "$terminalAppJson" "$now" "$stateSince" \
    > "$file.$$" && mv -f "$file.$$" "$file"
}

# versionAtLeast 3.6.6 3.6.6 -> true
versionAtLeast() {
  local i current minimum
  IFS=. read -r -a current <<< "$1"
  IFS=. read -r -a minimum <<< "$2"
  for i in 0 1 2; do
    current[i]=$(( 10#${current[i]//[!0-9]/} + 0 )) 2>/dev/null || current[i]=0
    [ "${current[i]:-0}" -gt "${minimum[i]:-0}" ] && return 0
    [ "${current[i]:-0}" -lt "${minimum[i]:-0}" ] && return 1
  done
  return 0
}

supportsProgress() {
  [ -e "$progressDisabledFlag" ] && return 1
  case "$TERM_PROGRAM" in
    ghostty) versionAtLeast "${TERM_PROGRAM_VERSION:-0}" 1.2.0 ;;
    iTerm.app) versionAtLeast "${TERM_PROGRAM_VERSION:-0}" 3.6.6 ;;
    *) return 1 ;;
  esac
}

updateProgress() {
  supportsProgress && [ -n "$ttyDev" ] || return

  [ -d "$progressDir" ] || mkdir -p "$progressDir"
  local stateFile="$progressDir/$sessionId.state"
  local pidFile="$progressDir/$sessionId.pid"
  local keepalivePid=""

  case "$state" in
    idle | ended)
      rm -f "$stateFile"
      emit "$ttyDev" 0
      return ;;
  esac

  echo "$state $now" > "$stateFile"
  resolveState "$state" "$now" "$claudePid"
  sequenceFor "$shownState"
  emit "$ttyDev" "$sequence"

  # Start one keepalive loop per session
  [ -r "$pidFile" ] && read -r keepalivePid < "$pidFile"
  if [ -z "$keepalivePid" ] || ! kill -0 "$keepalivePid" 2>/dev/null; then
    nohup "$0" --keepalive "$sessionId" "$ttyDev" "$claudePid" > /dev/null 2>&1 < /dev/null &
    echo $! > "$pidFile"
  fi
}

publishSession
updateProgress
exit 0
