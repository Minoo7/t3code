#!/usr/bin/env bash
set -euo pipefail

fork_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
control_dir="${PLANA_BOX_CONTROL_DIR:-$fork_dir/../plana-box-control-server}"
state_dir="${T3_DAYTONA_DEMO_DIR:-$HOME/.local/state/t3-daytona-demo}"
broker_dir="$state_dir/broker"
task_file="$state_dir/current-task"
desktop_server_port=33773
desktop_web_port=25733
proxy_command="$(command -v plana-box || true)"
identity_agent="${T3_DAYTONA_IDENTITY_AGENT:-$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock}"

usage() {
  cat <<'EOF'
Usage: scripts/try-daytona-worker.sh start|show|pair|status|stop

start   Create a disposable Daytona worker and launch an isolated T3 desktop app.
show    Bring the running Daytona demo app to the front.
pair    Print a fresh pairing link for the worker (expires after 30 minutes).
status  Show the current broker task.
stop    Archive the worker workspace, then dispose of the worker and stop the tunnel.

The demo keeps its broker records, T3 home, desktop profile, and SSH files under
~/.local/state/t3-daytona-demo. It does not use your installed T3 Code profile.
EOF
}

broker() {
  (cd "$control_dir" && PLANA_BROKER_DIR="$broker_dir" bun bin/run.js broker "$@")
}

json_only() {
  sed -n '/^{/,$p'
}

task_id() {
  if [[ ! -s "$task_file" ]]; then
    echo "No demo task yet. Run '$0 start' first." >&2
    exit 1
  fi
  cat "$task_file"
}

run_dir() {
  printf '%s/runs/%s' "$state_dir" "$(task_id)"
}

worker_ssh() {
  ssh -F "$(run_dir)/ssh.conf" -o BatchMode=yes daytona-t3-demo "$@"
}

start_macos_services() {
  local run="$1" app_pid app_command
  python3 - "$run" "$fork_dir" "$PATH" "$(command -v node)" <<'PY'
import os
import plistlib
import sys

run, fork, path, node = sys.argv[1:]
home = os.path.join(run, "t3-home")
bundle_suffix = "".join(character for character in os.path.basename(fork).lower() if character.isascii() and character.isalnum()) or "local"
jobs = {
    "tunnel": {
        "Label": "com.minoo.t3-daytona-demo-tunnel",
        "ProgramArguments": [
            "/usr/bin/ssh", "-F", os.path.join(run, "ssh.conf"),
            "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-N", "-L", "127.0.0.1:39774:127.0.0.1:39773",
            "-L", "127.0.0.1:4173:127.0.0.1:4173", "daytona-t3-demo",
        ],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": os.path.join(run, "tunnel.log"),
        "StandardErrorPath": os.path.join(run, "tunnel.log"),
    },
    "desktop": {
        "Label": "com.minoo.t3-daytona-demo-desktop",
        "ProgramArguments": [
            node, os.path.join(fork, "apps/desktop/scripts/start-electron.mjs"),
        ],
        "WorkingDirectory": fork,
        "EnvironmentVariables": {
            "HOME": os.environ["HOME"],
            "PATH": path,
            "T3CODE_HOME": home,
            "T3CODE_DESKTOP_APP_DATA_DIRECTORY": os.path.join(run, "desktop-app-data"),
            "T3CODE_DESKTOP_DISPLAY_NAME": "T3 Code (Daytona Demo)",
            "T3CODE_DESKTOP_APP_USER_MODEL_ID": f"com.t3tools.t3code.daytonademo.{bundle_suffix}",
            "T3CODE_DESKTOP_DAYTONA_DEMO": "1",
            "T3CODE_PORT": "33773",
            "T3CODE_DISABLE_AUTO_UPDATE": "1",
        },
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": os.path.join(run, "desktop.log"),
        "StandardErrorPath": os.path.join(run, "desktop.log"),
    },
}
for name, job in jobs.items():
    with open(os.path.join(run, f"{name}.plist"), "wb") as file:
        plistlib.dump(job, file)
PY
  launchctl bootstrap "gui/$(id -u)" "$run/tunnel.plist"
  for _ in {1..30}; do
    curl -fsS http://127.0.0.1:39774/.well-known/t3/environment >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS http://127.0.0.1:39774/.well-known/t3/environment >/dev/null || {
    echo "Worker tunnel did not become ready. See $run/tunnel.log" >&2
    exit 1
  }
  launchctl bootstrap "gui/$(id -u)" "$run/desktop.plist"
  app_pid=""
  for _ in {1..180}; do
    while read -r pid app_command; do
      if [[ "$app_command" == "$fork_dir/apps/desktop/.electron-runtime/T3 Code (Daytona Demo).app/Contents/MacOS/Electron dist-electron/main.cjs" ]]; then
        app_pid="$pid"
        break
      fi
    done < <(ps -axo pid=,command=)
    if [[ -n "$app_pid" ]] && curl -fsS "http://127.0.0.1:$desktop_server_port/.well-known/t3/environment" >/dev/null 2>&1; then
      printf '%s\n' "$app_pid" > "$run/desktop-app.pid"
      pair
      printf 'Desktop ready: T3 Code (Daytona Demo).\n'
      printf 'To bring it forward later: %s show\n' "$fork_dir/scripts/try-daytona-worker.sh"
      return
    fi
    sleep 1
  done
  echo "Desktop did not become ready. See $run/desktop.log" >&2
  exit 1
}

show() {
  local app_path app_command pid found=""
  [[ "$(uname)" == Darwin ]] || { echo "show is available on macOS only." >&2; exit 1; }
  app_path="$fork_dir/apps/desktop/.electron-runtime/T3 Code (Daytona Demo).app"
  [[ -d "$app_path" ]] || { echo "Demo app not built. Run '$0 start' first." >&2; exit 1; }
  while read -r pid app_command; do
    if [[ "$app_command" == "$app_path/Contents/MacOS/Electron dist-electron/main.cjs" ]]; then
      found="$pid"
      break
    fi
  done < <(ps -axo pid=,command=)
  [[ -n "$found" ]] || { echo "Demo app is not running. Run '$0 start' first." >&2; exit 1; }
  open -a "$app_path"
}

pair() {
  local output link run
  run="$(run_dir)"
  output="$(worker_ssh bash -s <<'REMOTE'
set -e
. "$HOME/.config/plana-box/path.sh"
t3 pair --base-dir "$HOME/.t3-daytona-surface" --ttl 30m --label mac-daytona-demo
REMOTE
)"
  link="$(printf '%s\n' "$output" | sed -n 's/^Pairing URL: //p' | tail -1)"
  if [[ "$link" != *:39773/pair\#token=* ]]; then
    echo "The worker did not return a T3 pairing link." >&2
    exit 1
  fi
  link="${link/:39773/:39774}"
  printf '%s\n' "$link" > "$run/pairing-link"
  chmod 600 "$run/pairing-link"
  printf 'Pairing link: %s\n' "$link"
}

start() {
  local id run response status worker tunnel_pid desktop_pid desktop_wrapper_pid command_line app_pid app_command
  for command in bun jq ssh curl node; do
    command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }
  done
  [[ -n "$proxy_command" ]] || { echo "plana-box is not on PATH" >&2; exit 1; }
  [[ -S "$identity_agent" ]] || { echo "1Password SSH agent not found: $identity_agent" >&2; exit 1; }
  [[ -x "$fork_dir/node_modules/.bin/vp" ]] || {
    echo "Run 'pnpm install --frozen-lockfile --ignore-scripts' in $fork_dir first." >&2
    exit 1
  }
  [[ -f "$control_dir/bin/run.js" ]] || { echo "Broker checkout not found: $control_dir" >&2; exit 1; }
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"

  if [[ -s "$task_file" ]]; then
    id="$(task_id)"
    response="$(broker status "$id" | json_only)"
    status="$(printf '%s\n' "$response" | jq -r '.status')"
    if [[ "$status" == disposed ]]; then
      rm "$task_file"
    else
      echo "Reusing worker task $id ($status)." >&2
    fi
  fi

  if [[ ! -s "$task_file" ]]; then
    cat > "$state_dir/prompt.txt" <<'PROMPT'
Create a minimal dependency-free Node HTTP app in this repository. It must
listen on 0.0.0.0:4173 when I run `npm start`, and its main page must contain
the visible heading DAYTONA_T3_PREVIEW_OK. Include package.json, index.html,
server.js, and a short README with startup instructions. Commit the files.
PROMPT
    response="$(broker start --kind implementation --retention manual --prompt-file "$state_dir/prompt.txt" | json_only)"
    id="$(printf '%s\n' "$response" | jq -r '.id')"
    [[ "$id" =~ ^[a-f0-9-]{36}$ ]] || { echo "Broker did not return a task ID." >&2; exit 1; }
    printf '%s\n' "$id" > "$task_file"
    printf 'Created worker task %s. Waiting for its first Codex turn...\n' "$id"
  fi

  run="$(run_dir)"
  mkdir -p "$run"
  response="$(broker wait "$id" --timeout 600 | json_only)"
  printf '%s\n' "$response" > "$run/last-wait.json"
  status="$(printf '%s\n' "$response" | jq -r '.task.status')"
  if [[ "$status" != completed ]]; then
    echo "Worker status is $status. Inspect it with '$0 status', then run start again." >&2
    exit 1
  fi
  worker="$(printf '%s\n' "$response" | jq -r '.task.sandboxName')"
  [[ "$worker" == plana-task-* ]] || { echo "Unexpected worker name: $worker" >&2; exit 1; }

  cat > "$run/ssh.conf" <<SSH_CONFIG
Host daytona-t3-demo
  HostName $worker
  User daytona
  ProxyCommand $proxy_command proxy-name %h %p
  IdentityAgent "$identity_agent"
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $run/known_hosts
  ServerAliveInterval 30
SSH_CONFIG
  chmod 600 "$run/ssh.conf"

  worker_ssh bash -s <<'REMOTE'
set -e
. "$HOME/.config/plana-box/path.sh"
. "$HOME/.config/plana-box/secrets.sh"
if ! curl -fsS http://127.0.0.1:39773/.well-known/t3/environment >/dev/null 2>&1; then
  nohup t3 serve --host 127.0.0.1 --port 39773 \
    --base-dir "$HOME/.t3-daytona-surface" \
    > "$HOME/t3-daytona-demo.log" 2>&1 < /dev/null &
fi
REMOTE

  for port in 39774 4173 "$desktop_server_port" "$desktop_web_port"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "Local port $port is in use. Stop that listener, then run start again." >&2
      exit 1
    fi
  done
  if [[ "$(uname)" == Darwin ]]; then
    printf 'Building isolated desktop (log: %s/build.log)...\n' "$run"
    if ! (cd "$fork_dir" && ./node_modules/.bin/vp run build:desktop > "$run/build.log" 2>&1); then
      tail -60 "$run/build.log" >&2
      exit 1
    fi
    start_macos_services "$run"
    return
  fi
  nohup ssh -F "$run/ssh.conf" -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -N -L 127.0.0.1:39774:127.0.0.1:39773 \
    -L 127.0.0.1:4173:127.0.0.1:4173 daytona-t3-demo \
    > "$run/tunnel.log" 2>&1 < /dev/null &
  tunnel_pid=$!
  printf '%s\n' "$tunnel_pid" > "$run/tunnel.pid"
  for _ in {1..30}; do
    if curl -fsS http://127.0.0.1:39774/.well-known/t3/environment >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      echo "SSH tunnel exited. See $run/tunnel.log" >&2
      exit 1
    fi
    sleep 1
  done
  curl -fsS http://127.0.0.1:39774/.well-known/t3/environment >/dev/null || {
    echo "Worker T3 did not become ready. See $run/tunnel.log" >&2
    exit 1
  }

  pair
  printf '\nIn T3 Code (Daytona Demo): Add a computer, paste the pairing link, select only the\n'
  printf 'worker project named repo, then open Files, Diff, Terminal, or Browser.\n'
  printf 'Run npm start in the T3 terminal and select localhost:4173 in Browser.\n'
  printf 'If the dev window starts blank, wait for the build, then choose View > Force Reload.\n'
  printf 'When done, run: %s stop\n\n' "$0"
  cd "$fork_dir"
  nohup env \
    T3CODE_HOME="$run/t3-home" \
    T3CODE_DESKTOP_APP_DATA_DIRECTORY="$run/desktop-app-data" \
    T3CODE_DESKTOP_DISPLAY_NAME="T3 Code (Daytona Demo)" \
    T3CODE_PORT_OFFSET=20000 \
    T3CODE_DISABLE_AUTO_UPDATE=1 \
    ./node_modules/.bin/vp run dev:desktop --home-dir "$run/t3-home" \
    > "$run/desktop.log" 2>&1 < /dev/null &
  desktop_wrapper_pid=$!
  printf '%s\n' "$desktop_wrapper_pid" > "$run/desktop-wrapper.pid"
  desktop_pid=""
  for _ in {1..20}; do
    desktop_pid="$(pgrep -P "$desktop_wrapper_pid" | head -1 || true)"
    command_line="$(ps -p "$desktop_pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"scripts/dev-runner.ts dev:desktop"* ]]; then
      break
    fi
    sleep 0.25
  done
  [[ "$command_line" == *"scripts/dev-runner.ts dev:desktop"* ]] || {
    echo "Could not identify the isolated desktop runner process." >&2
    exit 1
  }
  printf '%s\n' "$desktop_pid" > "$run/desktop.pid"
  for _ in {1..180}; do
    app_pid=""
    while read -r pid app_command; do
      if [[ "$app_command" == "$fork_dir/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/Electron --t3code-dev-root=$fork_dir/apps/desktop "* ]]; then
        app_pid="$pid"
        break
      fi
    done < <(ps -axo pid=,command=)
    if [[ -n "$app_pid" ]]; then
      printf '%s\n' "$app_pid" > "$run/desktop-app.pid"
      break
    fi
    if ! kill -0 "$desktop_wrapper_pid" 2>/dev/null; then
      echo "Desktop build exited before opening. See $run/desktop.log" >&2
      exit 1
    fi
    sleep 1
  done
  if [[ -z "$app_pid" ]]; then
    echo "Desktop did not open within three minutes. See $run/desktop.log" >&2
    exit 1
  fi
  for _ in {1..30}; do
    if curl -fsS "http://127.0.0.1:$desktop_server_port/.well-known/t3/environment" >/dev/null 2>&1; then
      printf 'Desktop ready: T3 Code (Daytona Demo).\n'
      return
    fi
    sleep 1
  done
  echo "Desktop backend did not become ready. See $run/desktop.log" >&2
  exit 1
}

stop() {
  local id run pid command_line response status retention
  id="$(task_id)"
  run="$(run_dir)"
  if [[ "$(uname)" == Darwin ]]; then
    for name in desktop tunnel; do
      if [[ -f "$run/$name.plist" ]]; then
        launchctl bootout "gui/$(id -u)" "$run/$name.plist" 2>/dev/null || true
      fi
    done
  fi
  if [[ -s "$run/desktop.pid" ]]; then
    pid="$(cat "$run/desktop.pid")"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"scripts/dev-runner.ts dev:desktop"* && "$command_line" == *"$run/t3-home"* ]]; then
      kill -TERM "$pid"
    fi
    rm -f "$run/desktop.pid"
  fi
  if [[ -s "$run/desktop-wrapper.pid" ]]; then
    pid="$(cat "$run/desktop-wrapper.pid")"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"vp run dev:desktop"* && "$command_line" == *"$run/t3-home"* ]]; then
      kill -TERM "$pid"
    fi
    rm -f "$run/desktop-wrapper.pid"
  fi
  if [[ -s "$run/desktop-app.pid" ]]; then
    pid="$(cat "$run/desktop-app.pid")"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "$fork_dir/apps/desktop/.electron-runtime/T3 Code (Daytona Demo).app/Contents/MacOS/Electron dist-electron/main.cjs" ||
          "$command_line" == "$fork_dir/apps/desktop/.electron-runtime/T3 Code (Dev).app/Contents/MacOS/Electron --t3code-dev-root=$fork_dir/apps/desktop "* ]]; then
      kill -TERM "$pid"
    fi
    rm -f "$run/desktop-app.pid"
  fi
  response="$(broker status "$id" | json_only)"
  status="$(printf '%s\n' "$response" | jq -r '.status')"
  retention="$(printf '%s\n' "$response" | jq -r '.retention')"
  if [[ "$status" == running ]]; then
    broker stop "$id" | json_only >/dev/null
  elif [[ "$status" == starting ]]; then
    echo "Worker is still starting. Run stop again after it starts or fails." >&2
    exit 1
  fi
  if [[ "$retention" == live ]]; then
    if [[ "$status" == failed && "$(printf '%s\n' "$response" | jq -r '.commandId')" == null ]]; then
      echo "Worker setup failed before an agent turn; no workspace archive exists."
    else
      broker archive "$id" | json_only > "$run/archive.json"
      echo "Workspace archive: $(jq -r '.artifactPath' "$run/archive.json")"
    fi
  fi
  if [[ "$retention" != disposed ]]; then
    broker dispose "$id" | json_only >/dev/null
    echo "Disposed worker $id."
  fi
  if [[ -s "$run/tunnel.pid" ]]; then
    pid="$(cat "$run/tunnel.pid")"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *daytona-t3-demo* && "$command_line" == *"$run/ssh.conf"* ]]; then
      kill -TERM "$pid"
    fi
    rm -f "$run/tunnel.pid"
  fi
}

case "${1:-help}" in
  start) start ;;
  show) show ;;
  pair) pair ;;
  status) broker status "$(task_id)" | json_only ;;
  stop) stop ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
