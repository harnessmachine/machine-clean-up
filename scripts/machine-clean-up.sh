#!/usr/bin/env bash
set -u

APPLY=0
MIN_AGE_MIN=10
SHOW_ALL=0
REVIEW_NAME=""
APPLY_REVIEW=0
KEEP_NEWEST=1
AUTO=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Machine Clean Up - conservative agent/MCP process scanner for macOS.

Usage:
  machine-clean-up.sh --auto [--dry-run] [--min-age-min N]
  machine-clean-up.sh [--apply] [--min-age-min N] [--show-all]
  machine-clean-up.sh --review NAME [--keep-newest N]
  machine-clean-up.sh --apply-review NAME [--keep-newest N]

Default is read-only scan. --apply terminates only SAFE_TO_TERMINATE candidates.
--auto closes orphaned MCP processes and duplicate MCP groups under the same
parent agent (keeps the newest copy per parent), without prompting.
--dry-run with --auto prints the plan and closes nothing.
--review shows live duplicate MCP process groups that could be closed.
--apply-review closes live duplicate MCP process groups after keeping newest N.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --auto) AUTO=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --show-all) SHOW_ALL=1 ;;
    --review)
      shift
      REVIEW_NAME="${1:-}"
      APPLY_REVIEW=0
      ;;
    --apply-review)
      shift
      REVIEW_NAME="${1:-}"
      APPLY_REVIEW=1
      ;;
    --keep-newest)
      shift
      KEEP_NEWEST="${1:-1}"
      ;;
    --min-age-min)
      shift
      MIN_AGE_MIN="${1:-10}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$MIN_AGE_MIN" in
  ''|*[!0-9]*)
    echo "--min-age-min must be an integer" >&2
    exit 2
    ;;
esac

case "$KEEP_NEWEST" in
  ''|*[!0-9]*)
    echo "--keep-newest must be an integer" >&2
    exit 2
    ;;
esac

if [ -n "$REVIEW_NAME" ]; then
  case "$REVIEW_NAME" in
    *[!A-Za-z0-9_.@/+:-]*)
      echo "--review/--apply-review NAME must be a simple process substring" >&2
      exit 2
      ;;
  esac
fi

MIN_AGE_SEC=$((MIN_AGE_MIN * 60))
TMP="${TMPDIR:-/tmp}/machine-clean-up.$$"
PS_RAW="$TMP.ps"
PS_TSV="$TMP.tsv"
CANDIDATES="$TMP.candidates"
REVIEW_GROUPS="$TMP.review-groups"
REVIEW_CLOSE="$TMP.review-close"
PROTECTED_PGIDS="$TMP.protected-pgids"
DUP_PLAN="$TMP.dup-plan"
DUP_CLOSE="$TMP.dup-close"
trap 'rm -f "$PS_RAW" "$PS_TSV" "$CANDIDATES" "$REVIEW_GROUPS" "$REVIEW_CLOSE" "$PROTECTED_PGIDS" "$DUP_PLAN" "$DUP_CLOSE"' EXIT

ps -axo pid=,ppid=,pgid=,etime=,pcpu=,rss=,args= > "$PS_RAW"

awk '
function etime_to_sec(e, parts, tparts, days, n) {
  days = 0;
  n = split(e, parts, "-");
  if (n == 2) {
    days = parts[1];
    e = parts[2];
  }
  n = split(e, tparts, ":");
  if (n == 3) {
    return days * 86400 + tparts[1] * 3600 + tparts[2] * 60 + tparts[3];
  }
  if (n == 2) {
    return days * 86400 + tparts[1] * 60 + tparts[2];
  }
  return days * 86400 + e;
}
{
  pid=$1; ppid=$2; pgid=$3; etimes=etime_to_sec($4); pcpu=$5; rss=$6;
  args="";
  for (i=7; i<=NF; i++) args=args (i==7 ? "" : " ") $i;
  gsub(/\t/, " ", args);
  print pid "\t" ppid "\t" pgid "\t" etimes "\t" pcpu "\t" rss "\t" args;
}
' "$PS_RAW" > "$PS_TSV"

# A process group containing Cursor is owner live work, even when it also
# contains MCP children. Never terminate or review that whole group.
: > "$PROTECTED_PGIDS"
awk -F '\t' '$7 ~ /\/Applications\/Cursor\.app|Cursor Helper|\/Application Support\/Cursor|_productName=Cursor/ {print $3}' "$PS_TSV" | sort -u > "$PROTECTED_PGIDS"

# The agent that runs this script and its ancestors are live work too.
ancestor=$$
while [ -n "$ancestor" ] && [ "$ancestor" != "0" ] && [ "$ancestor" != "1" ]; do
  ps -o pgid= -p "$ancestor" 2>/dev/null | tr -d ' ' >> "$PROTECTED_PGIDS"
  ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
done

is_agent_or_mcp_args() {
  case "$1" in
    *Codex.app*|*"codex app-server"*|*"/codex "*|*" claude "*|*/claude|*"opencode"*|*"mcp"*|*"MCP"*|*"npm exec"*|*"bun "*|*"uv --directory"*|*"playwright"*|*"chrome-devtools"*|*"context7"*|*"shell-snapshot"*|*"Google Chrome Helper"*|*"playwright_chromiumdev_profile"*|*"ms-playwright"*|*"computer-use"*|*"SkyComputerUseService"*|*"Codex Computer Use"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_mcp_like_args() {
  case "$1" in
    *"mcp"*|*"MCP"*|*"npm exec"*|*"bun "*|*"uv --directory"*|*"playwright-mcp"*|*"chrome-devtools-mcp"*|*"context7-mcp"*|*"shell-snapshot"*|*"playwright_chromiumdev_profile"*|*"ms-playwright"*|*"computer-use"*|*"SkyComputerUseService"*|*"Codex Computer Use"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_protected_pgid() {
  target_pgid="$1"
  ps -axo pgid=,args= | awk -v target="$target_pgid" '
    $1 == target && ($0 ~ /\/Applications\/Cursor\.app/ || $0 ~ /Cursor Helper/ || $0 ~ /\/Application Support\/Cursor/ || $0 ~ /_productName=Cursor/) { found=1 }
    END { exit found ? 0 : 1 }
  '
}

has_sensitive_args() {
  case "$1" in
    *PASSWORD=*|*PASS=*|*TOKEN=*|*SECRET=*|*API_KEY=*|*OPENAI_API_KEY=*|*ANTHROPIC_API_KEY=*|*"--password="*|*"--token="*|*"--api-key="*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

age_to_sec() {
  awk -v e="$1" '
    function etime_to_sec(e, parts, tparts, days, n) {
      days = 0;
      n = split(e, parts, "-");
      if (n == 2) {
        days = parts[1];
        e = parts[2];
      }
      n = split(e, tparts, ":");
      if (n == 3) {
        return days * 86400 + tparts[1] * 3600 + tparts[2] * 60 + tparts[3];
      }
      if (n == 2) {
        return days * 86400 + tparts[1] * 60 + tparts[2];
      }
      return days * 86400 + e;
    }
    BEGIN { print etime_to_sec(e); }
  '
}

fmt_age() {
  sec="$1"
  days=$((sec / 86400))
  rem=$((sec % 86400))
  hrs=$((rem / 3600))
  rem=$((rem % 3600))
  mins=$((rem / 60))
  if [ "$days" -gt 0 ]; then
    printf "%dd%02dh" "$days" "$hrs"
  elif [ "$hrs" -gt 0 ]; then
    printf "%dh%02dm" "$hrs" "$mins"
  else
    printf "%dm" "$mins"
  fi
}

short_args() {
  printf "%s" "$1" | sed -E \
    -e 's/(PASSWORD=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(PASS=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(TOKEN=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(SECRET=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(API_KEY=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(OPENAI_API_KEY=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(ANTHROPIC_API_KEY=)[^ ]+/\1[REDACTED]/g' \
    -e 's/(--password[= ]+)[^ ]+/\1[REDACTED]/g' \
    -e 's/(--token[= ]+)[^ ]+/\1[REDACTED]/g' \
    -e 's/(--api-key[= ]+)[^ ]+/\1[REDACTED]/g' \
    | cut -c 1-180
}

kb_to_mb() {
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f", kb / 1024 }'
}

system_snapshot() {
  load_avg=$(uptime | sed -E 's/.*load averages?: //')
  proc_count=$(ps -axo pid= | wc -l | tr -d ' ')
  page_size=$(pagesize 2>/dev/null || echo 4096)
  avail_mb=$(vm_stat | awk -v page_size="$page_size" '
    /Pages free/ {gsub(/\./, "", $3); free=$3}
    /Pages inactive/ {gsub(/\./, "", $3); inactive=$3}
    /Pages speculative/ {gsub(/\./, "", $3); speculative=$3}
    END { printf "%.0f", (free + inactive + speculative) * page_size / 1048576 }
  ')
  echo "load_avg=$load_avg available_ram=${avail_mb}MB processes=$proc_count"
}

SYSTEM_BEFORE=$(system_snapshot)

echo "Machine Clean Up scan"
if [ "$AUTO" -eq 1 ]; then
  mode_name=$([ "$DRY_RUN" -eq 1 ] && echo auto-dry-run || echo auto)
else
  mode_name=$([ "$APPLY" -eq 1 ] && echo apply || echo scan)
fi
echo "mode=$mode_name min_age_min=$MIN_AGE_MIN"
echo "System before: $SYSTEM_BEFORE"
echo

agent_roots=$(awk -F '\t' '$7 ~ /Codex.app|codex app-server|(^| )claude( |$)|opencode/ {print}' "$PS_TSV" | wc -l | tr -d ' ')
mcp_like=$(awk -F '\t' '$7 ~ /mcp|MCP|npm exec|uv --directory|bun |playwright|chrome-devtools|context7|shell-snapshot/ {print}' "$PS_TSV" | wc -l | tr -d ' ')
echo "Active agent/MCP-like rows: $mcp_like"
echo "Agent root/app rows: $agent_roots"
echo

: > "$CANDIDATES"
echo "SAFE_TO_TERMINATE candidates"
while IFS="$(printf '\t')" read -r pid ppid pgid etimes pcpu rss args; do
  if [ -z "${pid:-}" ]; then
    continue
  fi
  if [ "$ppid" = "1" ] && [ "$etimes" -ge "$MIN_AGE_SEC" ] && is_mcp_like_args "$args" && ! grep -Fqx "$pgid" "$PROTECTED_PGIDS"; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$pid" "$ppid" "$pgid" "$etimes" "$pcpu" "$rss" "$args" >> "$CANDIDATES"
    printf "  pid=%s ppid=%s pgid=%s age=%s cpu=%s rss=%sKB args=%s\n" \
      "$pid" "$ppid" "$pgid" "$(fmt_age "$etimes")" "$pcpu" "$rss" "$(short_args "$args")"
  fi
done < "$PS_TSV"

candidate_count=$(wc -l < "$CANDIDATES" | tr -d ' ')
candidate_rss_kb=$(awk -F '\t' '{sum += $6} END {print sum + 0}' "$CANDIDATES")
if [ "$candidate_count" = "0" ]; then
  echo "  none"
else
  echo "Would close: $candidate_count process(es), estimated RSS $(kb_to_mb "$candidate_rss_kb") MB"
fi

echo
echo "REVIEW_ONLY likely duplicates under live parents"
review_count=0
awk -F '\t' '$2 != 1 && $7 ~ /npm exec .*mcp|uv --directory .*mcp|chrome-devtools-mcp|playwright-mcp|context7-mcp|computer-use|SkyComputerUseService|Codex Computer Use|Computer Use.* mcp|Pencil.*mcp-server|node_repl/ {print}' "$PS_TSV" |
while IFS="$(printf '\t')" read -r pid ppid pgid etimes pcpu rss args; do
  review_count=$((review_count + 1))
  if [ "$SHOW_ALL" -eq 1 ] || [ "$review_count" -le 30 ]; then
    printf "  pid=%s parent=%s pgid=%s age=%s cpu=%s rss=%sKB args=%s\n" \
      "$pid" "$ppid" "$pgid" "$(fmt_age "$etimes")" "$pcpu" "$rss" "$(short_args "$args")"
  fi
done

echo
echo "SENSITIVE_ARGS findings"
sens_count=0
while IFS="$(printf '\t')" read -r pid ppid pgid etimes pcpu rss args; do
  if is_agent_or_mcp_args "$args" && has_sensitive_args "$args"; then
    sens_count=$((sens_count + 1))
    printf "  pid=%s parent=%s age=%s args=%s\n" "$pid" "$ppid" "$(fmt_age "$etimes")" "$(short_args "$args")"
  fi
done < "$PS_TSV"
if [ "$sens_count" = "0" ]; then
  echo "  none"
fi

# Duplicate MCP groups: the same MCP started more than once under the same
# parent agent. Only process-group leaders are considered, so an MCP that
# shares its agent's group is never closed by group signal.
group_alive() {
  # group_alive PGID PPID: the leader still exists under the same parent.
  cur=$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')
  [ -n "$cur" ] && [ "$cur" = "$2" ]
}

if [ "$AUTO" -eq 1 ]; then
  : > "$DUP_CLOSE"
  awk -F '\t' -v protected_file="$PROTECTED_PGIDS" '
    # A duplicate is the exact same MCP command line. Relative paths depend on
    # the working directory, so such commands are never treated as duplicates.
    function mcpkey(a) {
      if (a !~ /mcp|MCP/) return "";
      if (a ~ /machine-clean-up\.sh|node_repl|SkyComputerUseService|Computer Use/) return "";
      if (a ~ /(^| )\.\.?\//) return "";
      sub(/[ ]+$/, "", a);
      return a;
    }
    BEGIN {
      while ((getline line < protected_file) > 0) skip[line] = 1;
      close(protected_file);
    }
    {
      grss[$3] += $6;
      if ($7 ~ /Codex\.app|codex app-server|(^|\/)claude( |$)|opencode|Claude\.app\/Contents\/MacOS|ChatGPT\.app\/Contents\/MacOS/) hasroot[$3] = 1;
      if ($1 == $3 && $2 != 1) { leader[$3] = 1; lppid[$3] = $2; lage[$3] = $4; largs[$3] = $7; }
    }
    END {
      for (g in leader) {
        if ((g in skip) || (g in hasroot)) continue;
        k = mcpkey(largs[g]);
        if (k == "") continue;
        print lppid[g] "\t" k "\t" g "\t" lage[g] "\t" grss[g] "\t" largs[g];
      }
    }
  ' "$PS_TSV" | sort -t "$(printf '\t')" -k1,1n -k2,2 -k4,4n > "$DUP_PLAN"

  echo
  echo "AUTO duplicate MCP groups (newest copy per parent is kept)"
  prev=""
  while IFS="$(printf '\t')" read -r parent key pgid age rss sample; do
    if [ "$parent|$key" != "$prev" ]; then
      prev="$parent|$key"
      continue
    fi
    if [ "$age" -lt "$MIN_AGE_SEC" ]; then
      continue
    fi
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$parent" "$key" "$pgid" "$age" "$rss" "$sample" >> "$DUP_CLOSE"
    printf "  WOULD_CLOSE parent=%s pgid=%s age=%s rss=%sMB mcp=%s\n" \
      "$parent" "$pgid" "$(fmt_age "$age")" "$(kb_to_mb "$rss")" "$(short_args "$key")"
  done < "$DUP_PLAN"

  dup_count=$(wc -l < "$DUP_CLOSE" | tr -d ' ')
  dup_rss=$(awk -F '\t' '{sum += $5} END {print sum + 0}' "$DUP_CLOSE")
  if [ "$dup_count" = "0" ]; then
    echo "  none"
  else
    echo "Would close: $dup_count group(s), estimated RSS $(kb_to_mb "$dup_rss") MB"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "Dry run complete. Nothing was closed."
    exit 0
  fi

  dup_closed=0
  dup_freed=0
  if [ "$dup_count" != "0" ]; then
    echo
    echo "Closing duplicate MCP groups: SIGTERM first."
    while IFS="$(printf '\t')" read -r parent key pgid age rss sample; do
      if group_alive "$pgid" "$parent" && ! grep -Fqx "$pgid" "$PROTECTED_PGIDS" && ! is_protected_pgid "$pgid"; then
        echo "  TERM group pgid=$pgid mcp=$(short_args "$key")"
        kill -TERM "-$pgid" 2>/dev/null || true
      else
        echo "  SKIP changed group pgid=$pgid"
      fi
    done < "$DUP_CLOSE"
    sleep 5
    while IFS="$(printf '\t')" read -r parent key pgid age rss sample; do
      if group_alive "$pgid" "$parent"; then
        echo "  KILL survivor group pgid=$pgid mcp=$(short_args "$key")"
        kill -KILL "-$pgid" 2>/dev/null || true
        sleep 1
      fi
      if ! group_alive "$pgid" "$parent"; then
        dup_closed=$((dup_closed + 1))
        dup_freed=$((dup_freed + rss))
      fi
    done < "$DUP_CLOSE"
  fi
  echo "Duplicate summary: closed_groups=$dup_closed estimated_ram_freed=$(kb_to_mb "$dup_freed") MB"

  # Orphans are closed by the regular apply path below.
  APPLY=1
fi

if [ -n "$REVIEW_NAME" ]; then
  : > "$REVIEW_GROUPS"
  : > "$REVIEW_CLOSE"

  awk -F '\t' -v needle="$REVIEW_NAME" -v protected_file="$PROTECTED_PGIDS" '
    BEGIN {
      while ((getline line < protected_file) > 0) protected_pgid[line]=1;
      close(protected_file);
    }
    {
      pid[NR]=$1; ppid[NR]=$2; pgid[NR]=$3; age[NR]=$4; row_rss[NR]=$6; args[NR]=$7;
      if ($2 != 1 && index($7, needle) > 0 && $7 !~ /machine-clean-up\.sh/ && !($3 in protected_pgid)) {
        matched[$3]=1;
        if (!($3 in sample)) sample[$3]=$7;
      }
    }
    END {
      for (i=1; i<=NR; i++) {
        g=pgid[i];
        if (!(g in matched)) continue;
        if (args[i] ~ /machine-clean-up\.sh/) continue;
        count[g]++;
        rss[g] += row_rss[i];
        if (!(g in min_age) || age[i] < min_age[g]) min_age[g]=age[i];
        if (!(g in max_age) || age[i] > max_age[g]) max_age[g]=age[i];
      }
      for (g in matched) {
        print g "\t" count[g] "\t" min_age[g] "\t" max_age[g] "\t" rss[g] "\t" sample[g];
      }
    }
  ' "$PS_TSV" | sort -t "$(printf '\t')" -k3,3n > "$REVIEW_GROUPS"

  group_count=$(wc -l < "$REVIEW_GROUPS" | tr -d ' ')
  echo
  echo "LIVE_DUPLICATE_REVIEW name=$REVIEW_NAME keep_newest=$KEEP_NEWEST groups=$group_count"

  if [ "$group_count" = "0" ]; then
    echo "  none"
  else
    idx=0
    while IFS="$(printf '\t')" read -r pgid count min_age max_age rss sample; do
      idx=$((idx + 1))
      if [ "$idx" -le "$KEEP_NEWEST" ]; then
        action="KEEP"
      else
        action="WOULD_CLOSE"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$pgid" "$count" "$min_age" "$max_age" "$rss" "$sample" >> "$REVIEW_CLOSE"
      fi
      printf "  %s pgid=%s processes=%s newest_age=%s oldest_age=%s rss=%sMB sample=%s\n" \
        "$action" "$pgid" "$count" "$(fmt_age "$min_age")" "$(fmt_age "$max_age")" "$(kb_to_mb "$rss")" "$(short_args "$sample")"
    done < "$REVIEW_GROUPS"
  fi

  close_count=$(wc -l < "$REVIEW_CLOSE" | tr -d ' ')
  close_rss=$(awk -F '\t' '{sum += $5} END {print sum + 0}' "$REVIEW_CLOSE")
  echo "Would close live duplicate groups: $close_count, estimated RSS $(kb_to_mb "$close_rss") MB"

  if [ "$APPLY_REVIEW" -eq 1 ] && [ "$close_count" != "0" ]; then
    echo
    echo "Applying live duplicate cleanup for $REVIEW_NAME."
    review_term=0
    review_kill=0
    review_closed=0
    review_survivors=0
    review_freed=0

    while IFS="$(printf '\t')" read -r pgid count min_age max_age rss sample; do
      if is_protected_pgid "$pgid"; then
        echo "  SKIP protected Cursor group pgid=$pgid"
      elif ps -axo pgid=,args= | awk -v pgid="$pgid" -v needle="$REVIEW_NAME" '$1 == pgid && index($0, needle) > 0 {found=1} END {exit found ? 0 : 1}'; then
        echo "  TERM group pgid=$pgid sample=$(short_args "$sample")"
        kill -TERM "-$pgid" 2>/dev/null || true
        review_term=$((review_term + 1))
      else
        echo "  SKIP changed group pgid=$pgid"
      fi
    done < "$REVIEW_CLOSE"

    sleep 5

    while IFS="$(printf '\t')" read -r pgid count min_age max_age rss sample; do
      if ps -axo pgid=,args= | awk -v pgid="$pgid" -v needle="$REVIEW_NAME" '$1 == pgid && index($0, needle) > 0 {found=1} END {exit found ? 0 : 1}'; then
        echo "  KILL survivor group pgid=$pgid sample=$(short_args "$sample")"
        kill -KILL "-$pgid" 2>/dev/null || true
        review_kill=$((review_kill + 1))
      fi
      if ps -axo pgid=,args= | awk -v pgid="$pgid" -v needle="$REVIEW_NAME" '$1 == pgid && index($0, needle) > 0 {found=1} END {exit found ? 0 : 1}'; then
        review_survivors=$((review_survivors + 1))
      else
        review_closed=$((review_closed + 1))
        review_freed=$((review_freed + rss))
      fi
    done < "$REVIEW_CLOSE"

    SYSTEM_AFTER_REVIEW=$(system_snapshot)
    echo
    echo "Machine Clean Up live duplicate summary"
    echo "  name=$REVIEW_NAME keep_newest=$KEEP_NEWEST term_groups=$review_term kill_groups=$review_kill"
    echo "  closed_groups=$review_closed survivor_groups=$review_survivors"
    echo "  estimated_ram_freed=$(kb_to_mb "$review_freed") MB"
    echo "  system_before: $SYSTEM_BEFORE"
    echo "  system_after:  $SYSTEM_AFTER_REVIEW"
  elif [ "$APPLY_REVIEW" -eq 1 ]; then
    echo "No live duplicate groups to close."
  else
    echo "Review-only complete. Re-run with --apply-review $REVIEW_NAME to close WOULD_CLOSE groups."
  fi

  if [ "$APPLY" -ne 1 ]; then
    exit 0
  fi
fi

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "Read-only scan complete. Re-run with --apply only after reviewing SAFE_TO_TERMINATE candidates."
  exit 0
fi

if [ "$candidate_count" = "0" ]; then
  echo
  echo "No SAFE_TO_TERMINATE candidates to kill."
  exit 0
fi

echo
echo "Applying cleanup to $candidate_count candidate process(es): SIGTERM first."

term_sent=0
skipped_changed=0
while IFS="$(printf '\t')" read -r pid ppid pgid etimes pcpu rss args; do
  current=$(ps -p "$pid" -o ppid=,pgid=,etime=,args= 2>/dev/null || true)
  if [ -z "$current" ]; then
    continue
  fi
  cur_ppid=$(printf "%s\n" "$current" | awk '{print $1}')
  cur_pgid=$(printf "%s\n" "$current" | awk '{print $2}')
  cur_etime_str=$(printf "%s\n" "$current" | awk '{print $3}')
  cur_etime=$(age_to_sec "$cur_etime_str")
  cur_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  if [ "$cur_ppid" = "1" ] && [ "$cur_pgid" = "$pgid" ] && [ "$cur_etime" -ge "$MIN_AGE_SEC" ] && is_mcp_like_args "$cur_args" && ! is_protected_pgid "$cur_pgid"; then
    echo "  TERM pid=$pid pgid=$pgid args=$(short_args "$cur_args")"
    kill -TERM "$pid" 2>/dev/null || true
    term_sent=$((term_sent + 1))
  else
    echo "  SKIP changed pid=$pid"
    skipped_changed=$((skipped_changed + 1))
  fi
done < "$CANDIDATES"

sleep 5

echo "Checking survivors."
closed_count=0
freed_rss_kb=0
survivor_count=0
kill_sent=0
while IFS="$(printf '\t')" read -r pid ppid pgid etimes pcpu rss args; do
  if kill -0 "$pid" 2>/dev/null; then
    current=$(ps -p "$pid" -o ppid=,pgid=,etime=,args= 2>/dev/null || true)
    cur_ppid=$(printf "%s\n" "$current" | awk '{print $1}')
    cur_pgid=$(printf "%s\n" "$current" | awk '{print $2}')
    cur_etime_str=$(printf "%s\n" "$current" | awk '{print $3}')
    cur_etime=$(age_to_sec "$cur_etime_str")
    cur_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
    if [ "$cur_ppid" = "1" ] && [ "$cur_pgid" = "$pgid" ] && [ "$cur_etime" -ge "$MIN_AGE_SEC" ] && is_mcp_like_args "$cur_args" && ! is_protected_pgid "$cur_pgid"; then
      echo "  KILL survivor pid=$pid pgid=$pgid args=$(short_args "$cur_args")"
      kill -KILL "$pid" 2>/dev/null || true
      kill_sent=$((kill_sent + 1))
    else
      echo "  survivor changed, left alone pid=$pid"
    fi
    if kill -0 "$pid" 2>/dev/null; then
      survivor_count=$((survivor_count + 1))
    else
      closed_count=$((closed_count + 1))
      freed_rss_kb=$((freed_rss_kb + rss))
    fi
  else
    closed_count=$((closed_count + 1))
    freed_rss_kb=$((freed_rss_kb + rss))
  fi
done < "$CANDIDATES"

SYSTEM_AFTER=$(system_snapshot)
echo
echo "Machine Clean Up summary"
echo "  candidates=$candidate_count term_sent=$term_sent kill_sent=$kill_sent skipped_changed=$skipped_changed"
echo "  closed=$closed_count survivors=$survivor_count"
echo "  estimated_ram_freed=$(kb_to_mb "$freed_rss_kb") MB"
echo "  system_before: $SYSTEM_BEFORE"
echo "  system_after:  $SYSTEM_AFTER"
echo "Cleanup pass complete."
