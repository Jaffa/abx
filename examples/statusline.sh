#!/usr/bin/env bash

input=$(cat)

# The agentbox image may not include jq; say so rather than rendering an empty line.
if ! command -v jq >/dev/null 2>&1; then
    printf 'statusline: jq is not installed in this environment\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Theme detection
# ---------------------------------------------------------------------------
THEME="dark"
theme_file="$HOME/.claude/statusline-theme"
if [ -f "$theme_file" ]; then
    THEME=$(tr '[:upper:]' '[:lower:]' < "$theme_file" | tr -d '[:space:]')
fi
if [ "$THEME" != "light" ] && [ "$THEME" != "dark" ]; then
    THEME="dark"
fi
if [ "$THEME" = "dark" ] && [ -n "$COLORFGBG" ]; then
    bg="${COLORFGBG##*;}"
    if [ "$bg" -ge 7 ] 2>/dev/null; then
        THEME="light"
    fi
fi

# ---------------------------------------------------------------------------
# ANSI color codes
# ---------------------------------------------------------------------------
RESET="\033[0m"
BOLD="\033[1m"

if [ "$THEME" = "light" ]; then
    C_BLUE="\033[38;5;26m"
    C_GREEN="\033[38;5;28m"
    C_YELLOW="\033[38;5;130m"
    C_MAGENTA="\033[38;5;127m"
    C_CYAN="\033[38;5;33m"
    C_RED="\033[38;5;160m"
    C_GRAY="\033[38;5;240m"
else
    C_BLUE="\033[38;5;75m"
    C_GREEN="\033[38;5;114m"
    C_YELLOW="\033[38;5;220m"
    C_MAGENTA="\033[38;5;177m"
    C_CYAN="\033[38;5;87m"
    C_RED="\033[38;5;203m"
    C_GRAY="\033[38;5;245m"
fi

# ---------------------------------------------------------------------------
# Parse JSON
# ---------------------------------------------------------------------------
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
thinking=$(echo "$input" | jq -r '.thinking.enabled // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
ctx_total_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
session_resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_resets_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
worktree_branch=$(echo "$input" | jq -r '.worktree.branch // empty')
worktree_original=$(echo "$input" | jq -r '.worktree.original_branch // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')

# ---------------------------------------------------------------------------
# Working directory (project-relative inside an agentbox sandbox)
# ---------------------------------------------------------------------------
# Inside the sandbox the project is always mounted at /workspace, so the
# real name has to come from files the host leaves in the project.
SANDBOX_ROOT="${STATUSLINE_SANDBOX_ROOT:-/workspace}"

# Sandbox markers are checked before git so a nested repository (a vendored
# dependency, say) isn't mistaken for the project root.
find_project_root() {
    local d="$1" top
    while [ -n "$d" ]; do
        if [ -d "$d/.agent-sandbox" ] || [ -d "$d/.abx" ]; then
            printf '%s' "$d"
            return 0
        fi
        [ "$d" = "/" ] && break
        d=$(dirname "$d")
    done
    top=$(git -C "$1" -c safe.directory="$1" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] && printf '%s' "$top"
}

# The project directory is writable by the agent, so names read from it are
# stripped of control characters before they reach the terminal.
clean_name() {
    LC_ALL=C tr -d '\000-\037\177' | cut -c1-60
}

project_name() {
    local root="$1" name="" f url
    if [ -f "$root/.abx/project-name" ]; then
        name=$(head -n1 "$root/.abx/project-name" | clean_name)
    fi
    if [ -z "$name" ] && [ -d "$root/.agent-sandbox" ]; then
        for f in "$root"/.agent-sandbox/*.yml "$root"/.agent-sandbox/*.yaml "$root"/.agent-sandbox/compose/*.yml; do
            [ -f "$f" ] || continue
            name=$(sed -n "s/^name:[[:space:]]*['\"]\{0,1\}\([^'\"#[:space:]]*\).*/\1/p" "$f" | head -n1 | clean_name)
            [ -n "$name" ] && break
        done
    fi
    if [ -z "$name" ]; then
        url=$(git -C "$root" -c safe.directory="$root" --no-optional-locks remote get-url origin 2>/dev/null)
        if [ -n "$url" ]; then
            url="${url%/}"; url="${url%.git}"
            name=$(printf '%s' "${url##*[/:]}" | clean_name)
        fi
    fi
    printf '%s' "${name:-$(basename "$root")}"
}

dir_section=""
if [ -n "$cwd" ]; then
    display_cwd="${cwd/#$HOME/"~"}"
    case "$cwd" in
        "$SANDBOX_ROOT"|"$SANDBOX_ROOT"/*)
            root=$(find_project_root "$cwd")
            if [ -n "$root" ]; then
                display_cwd="$(project_name "$root")${cwd#"$root"}"
            fi
            ;;
    esac
    dir_section="$(printf "${C_BLUE}${BOLD}%s${RESET}" "$display_cwd")"
fi

# ---------------------------------------------------------------------------
# Git branch (worktree-aware)
# ---------------------------------------------------------------------------
git_section=""
if [ -n "$worktree_branch" ]; then
    if [ -n "$worktree_original" ]; then
        git_section="$(printf "${C_GREEN}${BOLD}${worktree_original} → ${worktree_branch}${RESET}")"
    else
        git_section="$(printf "${C_GREEN}${BOLD}${worktree_branch}${RESET}")"
    fi
elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
    branch=$(git -C "$cwd" -c safe.directory="$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        git_section="$(printf "${C_GREEN}${BOLD}${branch}${RESET}")"
    fi
fi

# ---------------------------------------------------------------------------
# Model & effort
# ---------------------------------------------------------------------------
model_section=""
if [ -n "$model" ]; then
    model_clean="${model% (*context*)}"
    model_suffix=""
    [ -n "$effort" ] && [ "$effort" != "null" ] && model_suffix=" [${effort}]"
    [ "$thinking" = "true" ] && model_suffix="${model_suffix} ~"
    model_lower=$(echo "$model_clean" | tr '[:upper:]' '[:lower:]')
    case "$model_lower" in
        *opus*)  model_color="$C_YELLOW" ;;
        *haiku*) model_color="$C_CYAN" ;;
        *)       model_color="$C_MAGENTA" ;;
    esac
    model_section="$(printf "${model_color}${BOLD}${model_clean}${model_suffix}${RESET}")"
fi

# ---------------------------------------------------------------------------
# Context window usage
# ---------------------------------------------------------------------------
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 85 ] 2>/dev/null; then echo "$C_RED"
    elif [ "$pct" -ge 60 ] 2>/dev/null; then echo "$C_YELLOW"
    else echo "$C_CYAN"
    fi
}

ctx_section=""
if [ -n "$used_pct" ]; then
    pct_int=$(printf "%.0f" "$used_pct" 2>/dev/null || echo "0")
    color=$(color_for_pct "$pct_int")
    filled=$(( pct_int * 10 / 100 ))
    bar=""
    for i in $(seq 1 10); do
        if [ "$i" -le "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    done
    ctx_section="$(printf "${color}${BOLD}${bar} ${pct_int}%%${RESET}")"
    if [ -n "$ctx_total_in" ] || [ -n "$ctx_total_out" ]; then
        tok_str=""
        if [ -n "$ctx_total_in" ]; then
            in_k=$(( ctx_total_in / 1000 ))
            if [ "$ctx_total_in" -ge 100000 ] 2>/dev/null; then tok_color="$C_YELLOW"
            else tok_color="$C_CYAN"
            fi
            tok_str="$(printf "${tok_color}↑${in_k}k${RESET}")"
        fi
        if [ -n "$ctx_total_out" ]; then
            out_k=$(( ctx_total_out / 1000 ))
            tok_str="${tok_str}$(printf " ${C_GRAY}↓${out_k}k${RESET}")"
        fi
        ctx_section="${ctx_section}$(printf " ${tok_str}")"
    fi
fi

# ---------------------------------------------------------------------------
# 5h usage % + time remaining (combined)
# ---------------------------------------------------------------------------
five_hour_section=""
five_hour_text=""
if [ -n "$five_hour_pct" ]; then
    pct_int=$(printf "%.0f" "$five_hour_pct" 2>/dev/null || echo "0")
    pct_color=$(color_for_pct "$pct_int")
    five_hour_text="${pct_color}${BOLD}5h ${pct_int}%%${RESET}"
fi
if [ -n "$session_resets_at" ]; then
    now=$(date +%s)
    secs_left=$(( session_resets_at - now ))
    if [ "$secs_left" -gt 0 ]; then
        h=$(( secs_left / 3600 ))
        m=$(( (secs_left % 3600) / 60 ))
        time_color="$C_GRAY"
        if [ "$h" -gt 0 ]; then
            time_text="${h}h${m}m"
        else
            time_text="${m}m"
        fi
        if [ -n "$five_hour_text" ]; then
            five_hour_section="$(printf "${five_hour_text} ${time_color}${time_text}${RESET}")"
        else
            five_hour_section="$(printf "${time_color}${BOLD}5h ${time_text}${RESET}")"
        fi
    fi
fi
[ -z "$five_hour_section" ] && [ -n "$five_hour_text" ] && five_hour_section="$(printf "${five_hour_text}")"

# ---------------------------------------------------------------------------
# 7d usage %
# ---------------------------------------------------------------------------
seven_day_section=""
if [ -n "$seven_day_pct" ]; then
    pct_int=$(printf "%.0f" "$seven_day_pct" 2>/dev/null || echo "0")
    color=$(color_for_pct "$pct_int")
    seven_day_section="$(printf "${color}${BOLD}7d ${pct_int}%%${RESET}")"
fi

# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------
agent_section=""
if [ -n "$agent_name" ]; then
    agent_section="$(printf "${C_YELLOW}${BOLD}agent:${agent_name}${RESET}")"
fi

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
parts=()
[ -n "$dir_section" ]         && parts+=("$dir_section")
[ -n "$git_section" ]         && parts+=("$git_section")
[ -n "$agent_section" ]       && parts+=("$agent_section")
[ -n "$model_section" ]       && parts+=("$model_section")
[ -n "$ctx_section" ]         && parts+=("$ctx_section")
[ -n "$five_hour_section" ]   && parts+=("$five_hour_section")
[ -n "$seven_day_section" ]   && parts+=("$seven_day_section")

sep="$(printf " ${C_GRAY}|${RESET} ")"

output=""
for i in "${!parts[@]}"; do
    if [ "$i" -eq 0 ]; then
        output="${parts[$i]}"
    else
        output="${output}${sep}${parts[$i]}"
    fi
done

printf "%b\n" "$output"
