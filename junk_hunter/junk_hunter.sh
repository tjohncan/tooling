#!/usr/bin/env bash

# Require bash 4+ (for associative arrays and string manipulation)
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "bash 4+ is required to run Junk Hunter."
    exit 1
fi

set -uo pipefail

# Interactive mode: we handle errors explicitly rather than crashing
# -u: error on undefined variables (catches typos)
# -o pipefail: pipes fail if any command fails
# NO -e: we want to handle errors gracefully, not crash

# junk_hunter.sh
# Terminal-based disk audit and cleanup browser
# A size-first approach to reclaiming disk space

VERSION="1.1.1"

# State variables
CURRENT_PATH="$(pwd)"
START_PATH="$(pwd)"  # Remember where we started - don't allow going above this
STAGING_DIR=""
SESSION_LOG=""
DEEP_SCAN_MODE=false  # Toggle between normal (current path dirs+files) and deep scan (all files, unnested)
CURRENT_PAGE=1        # Current page number for pagination (1-indexed)
SESSION_ID=""         # Unique session identifier (hex string)
SHOW_TIMESTAMPS=false # Toggle timestamp display

# Deep scan state
SCAN_ROOT=""          # Where deep scan started
NAV_PREFIX=""         # Current filter prefix for virtual navigation within deep scan
HEIGHT_FILTER=0       # 0=files, 1+=directories of that height
SCAN_START_SIZE=0     # Total size at start of deep scan
declare -A DIR_HEIGHTS    # Maps directory path → height
declare -A DIR_SIZES      # Maps directory path → total size of contained files
declare -A DIR_COUNTS     # Maps directory path → count of contained files
declare -A DIR_TIMESTAMPS # Maps directory path → most recent file timestamp

# Arrays for current directory contents
declare -a ITEM_NAMES
declare -a ITEM_SIZES
declare -a ITEM_PATHS
declare -a ITEM_TYPES
declare -a ITEM_HIDDEN     # Flag array: items marked as hidden (staged/deleted) don't show
declare -a ITEM_TIMESTAMPS # Last modified timestamp for each item

# Configuration variables (adjustable during session)
SIZE_THRESHOLD_HIGH=$((500 * 1024 * 1024))   # 500 MB - red
SIZE_THRESHOLD_MEDIUM=$((50 * 1024 * 1024))  # 50 MB - yellow
MAX_DISPLAY_ITEMS=20                          # Max items to show per screen
CONFIRM_DELETES=true                          # Require confirmation for permanent deletes
CONFIRM_STAGES=false                          # Require confirmation for staging (default off for speed)

# Running totals
TOTAL_STAGED=0
TOTAL_DELETED=0
COUNT_STAGED=0
COUNT_DELETED=0

# Color codes
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_CYAN="\033[36m"

# Platform detection (set once at startup)
DU_SUPPORTS_BYTES=false
if du -sb "$0" >/dev/null 2>&1; then
    DU_SUPPORTS_BYTES=true
fi

# Can bash's printf format timestamps? (bash 4.2+)
PRINTF_HAS_DATETIME=false
if printf '%(%Y)T' 0 >/dev/null 2>&1; then
    PRINTF_HAS_DATETIME=true
fi

# Does find support -printf? (GNU find)
FIND_HAS_PRINTF=false
if find . -maxdepth 0 -printf '' 2>/dev/null; then
    FIND_HAS_PRINTF=true
fi

# Generate random hex string for session ID
generate_session_id() {
    printf "%04x%04x" $RANDOM $RANDOM
}

# Log an action to the session log
log_action() {
    local action="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action" >> "$SESSION_LOG"
}

# Update parent directory sizes after removing an item
# This avoids needing to rescan the entire directory
update_parent_sizes() {
    local removed_path="$1"
    local removed_size="$2"

    # Subtract size from any parent directories in current view
    for i in "${!ITEM_PATHS[@]}"; do
        # Check if removed_path is a child of this directory
        if [[ "$removed_path" == "${ITEM_PATHS[$i]}"/* ]]; then
            ITEM_SIZES[$i]=$((ITEM_SIZES[$i] - removed_size))
            # Prevent negative sizes (shouldn't happen but safety check)
            if [[ ${ITEM_SIZES[$i]} -lt 0 ]]; then
                ITEM_SIZES[$i]=0
            fi
        fi
    done
}

# Update DIR_SIZES and DIR_COUNTS for ancestor directories after removing a file
# (deep scan mode only - keeps height-view sizes accurate without rescanning)
update_dir_sizes_for_file() {
    local file_path="$1"
    local file_size="$2"
    $DEEP_SCAN_MODE || return 0

    local dir="${file_path%/*}"
    while [[ -n "$dir" ]]; do
        if [[ -n "${DIR_SIZES[$dir]+x}" ]]; then
            DIR_SIZES["$dir"]=$(( ${DIR_SIZES[$dir]} - file_size ))
            [[ ${DIR_SIZES[$dir]} -lt 0 ]] && DIR_SIZES["$dir"]=0
        fi
        if [[ -n "${DIR_COUNTS[$dir]+x}" ]]; then
            DIR_COUNTS["$dir"]=$(( ${DIR_COUNTS[$dir]} - 1 ))
            [[ ${DIR_COUNTS[$dir]} -lt 0 ]] && DIR_COUNTS["$dir"]=0
        fi
        [[ "$dir" == "$SCAN_ROOT" ]] && break
        local parent="${dir%/*}"
        [[ "$parent" == "$dir" ]] && break
        dir="$parent"
    done
}

# Hide an item from display (mark as staged/deleted)
hide_item() {
    local array_index=$1
    ITEM_HIDDEN[$array_index]="true"
}

# Parse and execute multiple commands (e.g., "d3 d2 s5 s7" or "s 1-10 d 15")
# Note: ranges like 1-10 must have NO spaces around the hyphen
execute_multi_command() {
    local command_str="$1"

    # Validate format: d/s with optional spaces before numbers, but NO spaces in ranges
    if [[ ! "$command_str" =~ ^([ds][[:space:]]*[0-9]+(-[0-9]+)?[[:space:]]*)+$ ]]; then
        return 1
    fi

    # Extract all commands into arrays, expanding ranges
    local cmds=()
    local display_nums=()

    while [[ "$command_str" =~ ([ds])[[:space:]]*([0-9]+)(-([0-9]+))? ]]; do
        local cmd="${BASH_REMATCH[1]}"
        local start="${BASH_REMATCH[2]}"
        local has_range="${BASH_REMATCH[3]}"
        local end="${BASH_REMATCH[4]}"

        if [[ -n "$has_range" ]]; then
            if [[ $start -gt $end ]]; then
                echo -e "${C_RED}Error: Invalid range ${cmd}${start}-${end} (start > end)${C_RESET}"
                sleep 2
                return 1
            fi
            for ((n=start; n<=end; n++)); do
                cmds+=("$cmd")
                display_nums+=("$n")
            done
        else
            cmds+=("$cmd")
            display_nums+=("$start")
        fi

        command_str="${command_str#*${BASH_REMATCH[0]}}"
    done

    # Check for duplicate numbers
    local seen_nums=()
    for num in "${display_nums[@]}"; do
        for seen in "${seen_nums[@]}"; do
            if [[ "$num" == "$seen" ]]; then
                echo -e "${C_RED}Error: Duplicate item number $num${C_RESET}"
                sleep 2
                return 1
            fi
        done
        seen_nums+=("$num")
    done

    # HEIGHT VIEW: Handle directory operations
    if $DEEP_SCAN_MODE && [[ $HEIGHT_FILTER -gt 0 ]]; then
        # Validate all indices first
        local dir_indices=()
        for display_num in "${display_nums[@]}"; do
            local dir_index=$(($display_num - 1))
            if [[ $dir_index -lt 0 || $dir_index -ge ${#HEIGHT_DISPLAY_PATHS[@]} ]]; then
                echo -e "${C_RED}Error: Invalid item number $display_num${C_RESET}"
                sleep 2
                return 1
            fi
            dir_indices+=("$dir_index")
        done

        # Separate into delete and stage lists
        local delete_dirs=()
        local stage_dirs=()
        for i in "${!cmds[@]}"; do
            if [[ "${cmds[$i]}" == "d" ]]; then
                delete_dirs+=("${dir_indices[$i]}")
            else
                stage_dirs+=("${dir_indices[$i]}")
            fi
        done

        # Batch delete confirmation
        if [[ ${#delete_dirs[@]} -gt 0 ]] && $CONFIRM_DELETES; then
            clear
            echo
            echo -e "${C_RED}${C_BOLD}WARNING: PERMANENT DELETION${C_RESET}"
            local total_size=0
            for idx in "${delete_dirs[@]}"; do
                total_size=$((total_size + HEIGHT_DISPLAY_SIZES[$idx]))
            done
            echo -e "${C_RED}About to permanently delete ${#delete_dirs[@]} folder(s) totaling $(human_size $total_size):${C_RESET}"
            echo
            local shown=0
            for idx in "${delete_dirs[@]}"; do
                [[ $shown -ge $MAX_DISPLAY_ITEMS ]] && break
                echo -e "  ${HEIGHT_DISPLAY_NAMES[$idx]} ${C_DIM}($(human_size "${HEIGHT_DISPLAY_SIZES[$idx]}"))${C_RESET}"
                shown=$((shown + 1))
            done
            if [[ ${#delete_dirs[@]} -gt $MAX_DISPLAY_ITEMS ]]; then
                echo -e "  ${C_DIM}... and $((${#delete_dirs[@]} - MAX_DISPLAY_ITEMS)) more folder(s)${C_RESET}"
            fi
            echo
            echo -e "${C_YELLOW}Type 'yes' or 'y' to confirm deletion of ALL folders (case insensitive):${C_RESET}"
            echo -n -e "${C_RED}>${C_RESET} "
            read -r confirmation
            if [[ "${confirmation,,}" != "y" && "${confirmation,,}" != "yes" ]]; then
                echo -e "${C_GREEN}Cancelled.${C_RESET}"
                sleep 2
                return 1
            fi
        fi

        # Batch stage confirmation
        if [[ ${#stage_dirs[@]} -gt 0 ]] && $CONFIRM_STAGES; then
            clear
            echo
            echo -e "${C_YELLOW}${C_BOLD}STAGE FOLDERS FOR DELETION${C_RESET}"
            local total_size=0
            for idx in "${stage_dirs[@]}"; do
                total_size=$((total_size + HEIGHT_DISPLAY_SIZES[$idx]))
            done
            echo -e "${C_YELLOW}About to stage ${#stage_dirs[@]} folder(s) totaling $(human_size $total_size):${C_RESET}"
            echo
            local shown=0
            for idx in "${stage_dirs[@]}"; do
                [[ $shown -ge $MAX_DISPLAY_ITEMS ]] && break
                echo -e "  ${HEIGHT_DISPLAY_NAMES[$idx]} ${C_DIM}($(human_size "${HEIGHT_DISPLAY_SIZES[$idx]}"))${C_RESET}"
                shown=$((shown + 1))
            done
            if [[ ${#stage_dirs[@]} -gt $MAX_DISPLAY_ITEMS ]]; then
                echo -e "  ${C_DIM}... and $((${#stage_dirs[@]} - MAX_DISPLAY_ITEMS)) more folder(s)${C_RESET}"
            fi
            echo
            echo -e "Type 'yes' or 'y' to confirm:"
            echo -n -e "${C_GREEN}>${C_RESET} "
            read -r confirmation
            if [[ "${confirmation,,}" != "y" && "${confirmation,,}" != "yes" ]]; then
                echo -e "${C_GREEN}Cancelled.${C_RESET}"
                sleep 2
                return 1
            fi
        fi

        # Execute operations
        for i in "${!cmds[@]}"; do
            local dir_path="${HEIGHT_DISPLAY_PATHS[${dir_indices[$i]}]}"
            if [[ "${cmds[$i]}" == "d" ]]; then
                delete_dir_by_path "$dir_path"
            else
                stage_dir_by_path "$dir_path"
            fi
        done
        return 0
    fi

    # NORMAL FILE VIEW: Original logic
    # Resolve ALL display numbers to array indices BEFORE executing anything
    local array_indices=()
    for display_num in "${display_nums[@]}"; do
        local array_index
        if ! array_index=$(get_array_index_from_display "$display_num"); then
            echo -e "${C_RED}Error: Invalid item number $display_num${C_RESET}"
            sleep 2
            return 1
        fi
        array_indices+=("$array_index")
    done

    # Separate into delete and stage lists for batch confirmation
    local delete_indices=()
    local stage_indices=()
    for i in "${!cmds[@]}"; do
        if [[ "${cmds[$i]}" == "d" ]]; then
            delete_indices+=("${array_indices[$i]}")
        else
            stage_indices+=("${array_indices[$i]}")
        fi
    done

    # Batch delete confirmation
    if [[ ${#delete_indices[@]} -gt 0 ]] && $CONFIRM_DELETES; then
        clear
        echo
        echo -e "${C_RED}${C_BOLD}WARNING: PERMANENT DELETION${C_RESET}"

        # Calculate total size
        local total_size=0
        for idx in "${delete_indices[@]}"; do
            total_size=$((total_size + ITEM_SIZES[$idx]))
        done

        echo -e "${C_RED}About to permanently delete ${#delete_indices[@]} item(s) totaling $(human_size $total_size):${C_RESET}"
        echo

        # Show items (compact format, respects MAX_DISPLAY_ITEMS config)
        local shown=0
        for idx in "${delete_indices[@]}"; do
            if [[ $shown -ge $MAX_DISPLAY_ITEMS ]]; then
                break
            fi
            echo -e "  ${ITEM_NAMES[$idx]} ${C_DIM}($(human_size "${ITEM_SIZES[$idx]}"))${C_RESET}"
            shown=$((shown + 1))
        done

        # If truncated, show count
        if [[ ${#delete_indices[@]} -gt $MAX_DISPLAY_ITEMS ]]; then
            local remaining=$((${#delete_indices[@]} - MAX_DISPLAY_ITEMS))
            echo -e "  ${C_DIM}... and $remaining more item(s)${C_RESET}"
        fi

        echo
        echo -e "${C_YELLOW}Type 'yes' or 'y' to confirm deletion of ALL items (case insensitive):${C_RESET}"
        echo -n -e "${C_RED}>${C_RESET} "
        read -r confirmation
        confirmation_lower="${confirmation,,}"
        if [[ "$confirmation_lower" != "y" && "$confirmation_lower" != "yes" ]]; then
            echo -e "${C_GREEN}Cancelled.${C_RESET}"
            sleep 2
            return 1
        fi
    fi

    # Batch stage confirmation
    if [[ ${#stage_indices[@]} -gt 0 ]] && $CONFIRM_STAGES; then
        clear
        echo
        echo -e "${C_YELLOW}${C_BOLD}STAGE FOR DELETION${C_RESET}"

        # Calculate total size
        local total_size=0
        for idx in "${stage_indices[@]}"; do
            total_size=$((total_size + ITEM_SIZES[$idx]))
        done

        echo -e "${C_YELLOW}About to stage ${#stage_indices[@]} item(s) totaling $(human_size $total_size):${C_RESET}"
        echo

        # Show items (compact format, respects MAX_DISPLAY_ITEMS config)
        local shown=0
        for idx in "${stage_indices[@]}"; do
            if [[ $shown -ge $MAX_DISPLAY_ITEMS ]]; then
                break
            fi
            echo -e "  ${ITEM_NAMES[$idx]} ${C_DIM}($(human_size "${ITEM_SIZES[$idx]}"))${C_RESET}"
            shown=$((shown + 1))
        done

        # If truncated, show count
        if [[ ${#stage_indices[@]} -gt $MAX_DISPLAY_ITEMS ]]; then
            local remaining=$((${#stage_indices[@]} - MAX_DISPLAY_ITEMS))
            echo -e "  ${C_DIM}... and $remaining more item(s)${C_RESET}"
        fi

        echo
        echo -e "Type 'yes' or 'y' to confirm:"
        echo -n -e "${C_GREEN}>${C_RESET} "
        read -r confirmation
        confirmation_lower="${confirmation,,}"
        if [[ "$confirmation_lower" != "y" && "$confirmation_lower" != "yes" ]]; then
            echo -e "${C_GREEN}Cancelled.${C_RESET}"
            sleep 2
            return 1
        fi
    fi

    # Execute all operations using pre-resolved array indices
    for i in "${!cmds[@]}"; do
        local cmd="${cmds[$i]}"
        local array_index="${array_indices[$i]}"

        if [[ "$cmd" == "d" ]]; then
            delete_item_by_index "$array_index"
        else
            stage_item_by_index "$array_index"
        fi
    done

    return 0
}

# Map display number to array index (skipping hidden items)
# In deep scan mode with NAV_PREFIX, only counts items under the prefix
# (must match the same filter logic used in show_contents)
get_array_index_from_display() {
    local target_display=$1
    local current_display=0

    # Apply same NAV_PREFIX filter as show_contents
    local filter_prefix=""
    if $DEEP_SCAN_MODE && [[ -n "$NAV_PREFIX" ]]; then
        filter_prefix="$NAV_PREFIX/"
    fi

    for i in "${!ITEM_NAMES[@]}"; do
        if [[ "${ITEM_HIDDEN[$i]}" != "true" ]]; then
            if [[ -n "$filter_prefix" && "${ITEM_PATHS[$i]}" != "$filter_prefix"* ]]; then
                continue
            fi
            current_display=$((current_display + 1))
            if [[ $current_display -eq $target_display ]]; then
                echo "$i"
                return 0
            fi
        fi
    done

    # Not found
    return 1
}

# Navigate into a directory (by index)
navigate_into() {
    local display_num=$1
    local array_index

    # Map display number to array index
    if ! array_index=$(get_array_index_from_display "$display_num"); then
        echo -e "${C_RED}Invalid item number${C_RESET}"
        sleep 1
        return 1
    fi

    local target_path="${ITEM_PATHS[$array_index]}"
    local target_type="${ITEM_TYPES[$array_index]}"

    # Can only navigate into directories
    if [[ "$target_type" != "dir" ]]; then
        echo -e "${C_YELLOW}Cannot navigate into a file${C_RESET}"
        sleep 1
        return 1
    fi

    # Try to change directory
    if ! cd "$target_path" 2>/dev/null; then
        echo -e "${C_RED}Cannot access directory (may have been deleted or permission denied)${C_RESET}"
        sleep 1
        return 1
    fi

    CURRENT_PATH="$(pwd)"
    log_action "Navigated into: $CURRENT_PATH"
    return 0
}

# Ensure staging directory exists
ensure_staging_dir() {
    if [[ ! -d "$STAGING_DIR" ]]; then
        if ! mkdir -p "$STAGING_DIR" 2>/dev/null; then
            echo -e "${C_RED}Failed to create staging directory${C_RESET}"
            return 1
        fi
        log_action "Created staging directory: $STAGING_DIR"
    fi
    return 0
}

# Delete an item by array index (no confirmation, used by batch operations)
delete_item_by_index() {
    local array_index=$1

    local item_path="${ITEM_PATHS[$array_index]}"
    local item_name="${ITEM_NAMES[$array_index]}"
    local item_size="${ITEM_SIZES[$array_index]}"

    # Perform deletion
    if ! rm -rf "$item_path" 2>/dev/null; then
        echo -e "${C_RED}Failed to delete $item_name (permission denied or in use)${C_RESET}"
        sleep 1
        return 1
    fi

    # Log and update
    log_action "DELETED: $item_path ($(human_size $item_size))"
    TOTAL_DELETED=$((TOTAL_DELETED + item_size))
    COUNT_DELETED=$((COUNT_DELETED + 1))
    update_parent_sizes "$item_path" "$item_size"
    update_dir_sizes_for_file "$item_path" "$item_size"
    hide_item "$array_index"
    return 0
}

# Delete an item permanently (with confirmation)
delete_item() {
    local display_num=$1

    # Height view: delete directory instead of file
    if $DEEP_SCAN_MODE && [[ $HEIGHT_FILTER -gt 0 ]]; then
        local dir_index=$(($display_num - 1))
        if [[ $dir_index -lt 0 || $dir_index -ge ${#HEIGHT_DISPLAY_PATHS[@]} ]]; then
            echo -e "${C_RED}Invalid item number${C_RESET}"
            sleep 1
            return 1
        fi
        local dir_path="${HEIGHT_DISPLAY_PATHS[$dir_index]}"
        local dir_size="${HEIGHT_DISPLAY_SIZES[$dir_index]}"
        local dir_name="${HEIGHT_DISPLAY_NAMES[$dir_index]}"

        # Show warning and ask for confirmation (if enabled)
        if $CONFIRM_DELETES; then
            clear
            echo
            echo -e "${C_RED}${C_BOLD}WARNING: PERMANENT DELETION${C_RESET}"
            echo -e "${C_RED}This will permanently delete folder:${C_RESET}"
            echo
            echo -e "  Name: ${C_BOLD}$dir_name${C_RESET}"
            echo -e "  Type: folder (height ${HEIGHT_FILTER})"
            echo -e "  Size: $(human_size $dir_size)"
            echo -e "  Path: ${C_DIM}$dir_path${C_RESET}"
            echo
            echo -e "${C_YELLOW}Type 'yes' or 'y' to confirm permanent deletion (case insensitive):${C_RESET}"
            echo -n -e "${C_RED}>${C_RESET} "
            read -r confirmation
            confirmation_lower="${confirmation,,}"
            if [[ "$confirmation_lower" != "y" && "$confirmation_lower" != "yes" ]]; then
                echo -e "${C_GREEN}Cancelled.${C_RESET}"
                sleep 1
                return 1
            fi
        fi

        if delete_dir_by_path "$dir_path"; then
            echo -e "${C_GREEN}Folder deleted permanently.${C_RESET}"
            sleep 1
            return 0
        else
            return 1
        fi
    fi

    local array_index

    # Map display number to array index
    if ! array_index=$(get_array_index_from_display "$display_num"); then
        echo -e "${C_RED}Invalid item number${C_RESET}"
        sleep 1
        return 1
    fi

    local item_path="${ITEM_PATHS[$array_index]}"
    local item_name="${ITEM_NAMES[$array_index]}"
    local item_size="${ITEM_SIZES[$array_index]}"
    local item_type="${ITEM_TYPES[$array_index]}"

    # Show warning and ask for confirmation (if enabled)
    if $CONFIRM_DELETES; then
        clear
        echo
        echo -e "${C_RED}${C_BOLD}WARNING: PERMANENT DELETION${C_RESET}"
        echo -e "${C_RED}This will permanently delete:${C_RESET}"
        echo
        echo -e "  Name: ${C_BOLD}$item_name${C_RESET}"
        echo -e "  Type: $item_type"
        echo -e "  Size: $(human_size $item_size)"
        echo -e "  Path: ${C_DIM}$item_path${C_RESET}"
        echo
        echo -e "${C_YELLOW}Type 'yes' or 'y' to confirm permanent deletion (case insensitive):${C_RESET}"
        echo -n -e "${C_RED}>${C_RESET} "
        read -r confirmation

        confirmation_lower="${confirmation,,}"
        if [[ "$confirmation_lower" != "y" && "$confirmation_lower" != "yes" ]]; then
            echo -e "${C_GREEN}Cancelled.${C_RESET}"
            sleep 1
            return 1
        fi
    fi

    # Use the _by_index helper
    if delete_item_by_index "$array_index"; then
        echo -e "${C_GREEN}Deleted permanently.${C_RESET}"
        sleep 1
        return 0
    else
        return 1
    fi
}

# Stage an item by array index (no confirmation, used by batch operations)
stage_item_by_index() {
    local array_index=$1

    local item_path="${ITEM_PATHS[$array_index]}"
    local item_name="$(basename "${ITEM_PATHS[$array_index]}")"
    local item_size="${ITEM_SIZES[$array_index]}"

    # Ensure staging directory exists
    if ! ensure_staging_dir; then
        return 1
    fi

    # Generate unique name in staging area
    local staged_name="$item_name"
    local counter=2
    while [[ -e "$STAGING_DIR/$staged_name" ]]; do
        staged_name="${item_name}.${counter}"
        counter=$((counter + 1))
    done

    # Move to staging
    if ! mv "$item_path" "$STAGING_DIR/$staged_name" 2>/dev/null; then
        echo -e "${C_RED}Failed to stage $item_name (permission denied or in use)${C_RESET}"
        sleep 1
        return 1
    fi

    # Log and update
    log_action "STAGED: $item_path -> $STAGING_DIR/$staged_name ($(human_size $item_size))"
    TOTAL_STAGED=$((TOTAL_STAGED + item_size))
    COUNT_STAGED=$((COUNT_STAGED + 1))
    update_parent_sizes "$item_path" "$item_size"
    update_dir_sizes_for_file "$item_path" "$item_size"
    hide_item "$array_index"
    return 0
}

# Stage an item for deletion (move to staging area)
stage_item() {
    local display_num=$1

    # Height view: stage directory instead of file
    if $DEEP_SCAN_MODE && [[ $HEIGHT_FILTER -gt 0 ]]; then
        local dir_index=$(($display_num - 1))
        if [[ $dir_index -lt 0 || $dir_index -ge ${#HEIGHT_DISPLAY_PATHS[@]} ]]; then
            echo -e "${C_RED}Invalid item number${C_RESET}"
            sleep 1
            return 1
        fi
        local dir_path="${HEIGHT_DISPLAY_PATHS[$dir_index]}"
        local dir_size="${HEIGHT_DISPLAY_SIZES[$dir_index]}"
        local dir_name="${HEIGHT_DISPLAY_NAMES[$dir_index]}"

        # Ask for confirmation if enabled
        if $CONFIRM_STAGES; then
            clear
            echo
            echo -e "${C_YELLOW}${C_BOLD}STAGE FOLDER FOR DELETION${C_RESET}"
            echo -e "${C_YELLOW}About to stage:${C_RESET}"
            echo
            echo -e "  Name: ${C_BOLD}$dir_name${C_RESET}"
            echo -e "  Size: $(human_size $dir_size)"
            echo
            echo -e "Type 'yes' or 'y' to confirm:"
            echo -n -e "${C_GREEN}>${C_RESET} "
            read -r confirmation
            confirmation_lower="${confirmation,,}"
            if [[ "$confirmation_lower" != "y" && "$confirmation_lower" != "yes" ]]; then
                echo -e "${C_GREEN}Cancelled.${C_RESET}"
                sleep 1
                return 1
            fi
        fi

        if stage_dir_by_path "$dir_path"; then
            echo -e "${C_GREEN}Folder staged successfully!${C_RESET}"
            sleep 1
            return 0
        else
            return 1
        fi
    fi

    local array_index

    # Map display number to array index
    if ! array_index=$(get_array_index_from_display "$display_num"); then
        echo -e "${C_RED}Invalid item number${C_RESET}"
        sleep 1
        return 1
    fi

    local item_path="${ITEM_PATHS[$array_index]}"
    local item_name="${ITEM_NAMES[$array_index]}"
    local item_size="${ITEM_SIZES[$array_index]}"

    # Ask for confirmation if enabled
    if $CONFIRM_STAGES; then
        clear
        echo
        echo -e "${C_YELLOW}${C_BOLD}STAGE FOR DELETION${C_RESET}"
        echo -e "${C_YELLOW}About to stage:${C_RESET}"
        echo
        echo -e "  Name: ${C_BOLD}$item_name${C_RESET}"
        echo -e "  Size: $(human_size $item_size)"
        echo
        echo -e "Type 'yes' or 'y' to confirm:"
        echo -n -e "${C_GREEN}>${C_RESET} "
        read -r confirmation

        confirmation_lower="${confirmation,,}"
        if [[ "$confirmation_lower" != "y" && "$confirmation_lower" != "yes" ]]; then
            echo -e "${C_GREEN}Cancelled.${C_RESET}"
            sleep 1
            return 1
        fi
    fi

    # Use the _by_index helper
    if stage_item_by_index "$array_index"; then
        echo -e "${C_GREEN}Staged successfully!${C_RESET}"
        sleep 1
        return 0
    else
        return 1
    fi
}

# Hide all files under a directory path (for deep scan mode)
hide_files_under_dir() {
    local dir_path="$1"
    local dir_size="${DIR_SIZES[$dir_path]:-0}"

    for i in "${!ITEM_PATHS[@]}"; do
        if [[ "${ITEM_PATHS[$i]}" == "$dir_path"/* ]]; then
            ITEM_HIDDEN[$i]="true"
        fi
    done

    # Remove this directory AND all child directories from tracking
    for dir in "${!DIR_HEIGHTS[@]}"; do
        if [[ "$dir" == "$dir_path" || "$dir" == "$dir_path"/* ]]; then
            unset "DIR_HEIGHTS[$dir]"
            unset "DIR_SIZES[$dir]"
            unset "DIR_COUNTS[$dir]"
            unset "DIR_TIMESTAMPS[$dir]"
        fi
    done

    # Subtract size from ancestor directories up to SCAN_ROOT
    local parent="${dir_path%/*}"
    while [[ -n "$parent" && "$parent" != "$dir_path" ]]; do
        if [[ -n "${DIR_SIZES[$parent]+x}" ]]; then
            DIR_SIZES["$parent"]=$(( ${DIR_SIZES[$parent]} - dir_size ))
            [[ ${DIR_SIZES[$parent]} -lt 0 ]] && DIR_SIZES["$parent"]=0
        fi
        [[ "$parent" == "$SCAN_ROOT" ]] && break
        local grandparent="${parent%/*}"
        [[ "$grandparent" == "$parent" ]] && break
        parent="$grandparent"
    done
}

# Stage a directory by path (for height-filtered view)
stage_dir_by_path() {
    local dir_path="$1"
    local dir_size="${DIR_SIZES[$dir_path]:-0}"
    local dir_name
    dir_name="$(basename "$dir_path")"

    # Ensure staging directory exists
    if ! ensure_staging_dir; then
        return 1
    fi

    # Generate unique name in staging area
    local staged_name="$dir_name"
    local counter=2
    while [[ -e "$STAGING_DIR/$staged_name" ]]; do
        staged_name="${dir_name}.${counter}"
        counter=$((counter + 1))
    done

    # Move to staging
    if ! mv "$dir_path" "$STAGING_DIR/$staged_name" 2>/dev/null; then
        echo -e "${C_RED}Failed to stage $dir_name (permission denied or in use)${C_RESET}"
        sleep 1
        return 1
    fi

    # Log and update
    log_action "STAGED: $dir_path -> $STAGING_DIR/$staged_name ($(human_size $dir_size))"
    TOTAL_STAGED=$((TOTAL_STAGED + dir_size))
    COUNT_STAGED=$((COUNT_STAGED + 1))

    # Hide all files under this directory and remove from height tracking
    hide_files_under_dir "$dir_path"

    return 0
}

# Delete a directory by path (for height-filtered view)
delete_dir_by_path() {
    local dir_path="$1"
    local dir_size="${DIR_SIZES[$dir_path]:-0}"
    local dir_name
    dir_name="$(basename "$dir_path")"

    # Perform deletion
    if ! rm -rf "$dir_path" 2>/dev/null; then
        echo -e "${C_RED}Failed to delete $dir_name (permission denied or in use)${C_RESET}"
        sleep 1
        return 1
    fi

    # Log and update
    log_action "DELETED: $dir_path ($(human_size $dir_size))"
    TOTAL_DELETED=$((TOTAL_DELETED + dir_size))
    COUNT_DELETED=$((COUNT_DELETED + 1))

    # Hide all files under this directory and remove from height tracking
    hide_files_under_dir "$dir_path"

    return 0
}

# Navigate up to parent directory
navigate_up() {
    local parent
    parent="$(dirname "$CURRENT_PATH")"

    # Check if we're already at root
    if [[ "$parent" == "$CURRENT_PATH" ]]; then
        echo -e "${C_YELLOW}Already at root directory${C_RESET}"
        sleep 1
        return 1
    fi

    # Check if we're trying to go above start directory
    if [[ "$CURRENT_PATH" == "$START_PATH" ]]; then
        echo -e "${C_YELLOW}Cannot go above starting directory${C_RESET}"
        sleep 1
        return 1
    fi

    # Try to navigate up
    if ! cd "$parent" 2>/dev/null; then
        echo -e "${C_RED}Cannot access parent directory${C_RESET}"
        sleep 1
        return 1
    fi

    CURRENT_PATH="$(pwd)"
    log_action "Navigated up to: $CURRENT_PATH"
    return 0
}

# Initialize session (sets up paths but doesn't create log file yet)
init_session() {
    SESSION_ID="$(generate_session_id)"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    STAGING_DIR="${CURRENT_PATH}/.junk_hunter_staging_${timestamp}_${SESSION_ID}"
    SESSION_LOG="${CURRENT_PATH}/.junk_hunter_log_${timestamp}_${SESSION_ID}.txt"
}

# Create the session log file (called after user commits to a session)
create_session_log() {
    echo "Session started at $(date)" > "$SESSION_LOG"
    echo "Current path: $CURRENT_PATH" >> "$SESSION_LOG"
    echo "Staging directory: $STAGING_DIR" >> "$SESSION_LOG"
}

# Convert bytes to human-readable format (uses rounding, not truncation)
human_size() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes

    while (( size > 1024 && unit < 4 )); do
        size=$(( (size + 512) / 1024 ))
        unit=$((unit + 1))
    done

    printf "%4d %s" "$size" "${units[$unit]}"
}

# Compute directory heights, sizes, counts, and timestamps from the current file list
# Height 1 = leaf directories (no subdirs), Height N = max child height + 1
compute_heights() {
    DIR_HEIGHTS=()
    DIR_SIZES=()
    DIR_COUNTS=()
    DIR_TIMESTAMPS=()

    # Collect all unique directories and their relationships
    declare -A all_dirs
    declare -A max_child_height

    for i in "${!ITEM_PATHS[@]}"; do
        [[ "${ITEM_HIDDEN[$i]}" == "true" ]] && continue

        local file_size="${ITEM_SIZES[$i]}"
        local file_ts="${ITEM_TIMESTAMPS[$i]:-}"
        local path="${ITEM_PATHS[$i]}"
        local dir="${path%/*}"

        # Walk up to SCAN_ROOT, accumulating sizes/counts/timestamps
        while [[ "$dir" != "$SCAN_ROOT" && "$dir" != "/" && "$dir" != "." && -n "$dir" ]]; do
            all_dirs["$dir"]=1
            DIR_SIZES["$dir"]=$(( ${DIR_SIZES[$dir]:-0} + file_size ))
            DIR_COUNTS["$dir"]=$(( ${DIR_COUNTS[$dir]:-0} + 1 ))
            # Track most recent timestamp (lexicographic compare works for YYYY-MM-DD HH:MM:SS)
            if [[ -n "$file_ts" && "$file_ts" > "${DIR_TIMESTAMPS[$dir]:-}" ]]; then
                DIR_TIMESTAMPS["$dir"]="$file_ts"
            fi
            local parent="${dir%/*}"
            [[ "$parent" == "$dir" ]] && break
            dir="$parent"
        done
        # Include SCAN_ROOT itself
        all_dirs["$SCAN_ROOT"]=1
        DIR_SIZES["$SCAN_ROOT"]=$(( ${DIR_SIZES[$SCAN_ROOT]:-0} + file_size ))
        DIR_COUNTS["$SCAN_ROOT"]=$(( ${DIR_COUNTS[$SCAN_ROOT]:-0} + 1 ))
        if [[ -n "$file_ts" && "$file_ts" > "${DIR_TIMESTAMPS[$SCAN_ROOT]:-}" ]]; then
            DIR_TIMESTAMPS["$SCAN_ROOT"]="$file_ts"
        fi
    done

    # Sort directories by depth (deepest first)
    local sorted_dirs
    sorted_dirs=$(for d in "${!all_dirs[@]}"; do
        echo "${d//[^\/]/}" "$d"
    done | sort -r | cut -d' ' -f2-)

    # Compute heights bottom-up
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue

        local my_height
        if [[ -z "${max_child_height[$dir]:-}" ]]; then
            # No children processed yet - this is a leaf directory
            my_height=1
        else
            # Height = 1 + max child height
            my_height=$((max_child_height[$dir] + 1))
        fi
        DIR_HEIGHTS["$dir"]=$my_height

        # Update parent's max_child_height
        local parent="${dir%/*}"
        if [[ "$parent" != "$dir" && -n "$parent" ]]; then
            local current_max="${max_child_height[$parent]:-0}"
            if [[ $my_height -gt $current_max ]]; then
                max_child_height["$parent"]=$my_height
            fi
        fi
    done <<< "$sorted_dirs"
}

# Scan recursively for all files under current path
scan_deep() {
    # Initialize deep scan state
    SCAN_ROOT="$CURRENT_PATH"
    NAV_PREFIX=""
    HEIGHT_FILTER=0

    # Clear arrays
    ITEM_NAMES=()
    ITEM_SIZES=()
    ITEM_PATHS=()
    ITEM_TYPES=()
    ITEM_HIDDEN=()
    ITEM_TIMESTAMPS=()

    # Check if we can read the directory
    if [[ ! -r "$CURRENT_PATH" ]]; then
        echo -e "${C_RED}Error: Cannot read directory${C_RESET}" >&2
        return 1
    fi

    # Show scanning indicator
    echo -e "${C_CYAN}Running deep scan... This may take a while.${C_RESET}" >&2

    # Start a progress indicator (killed by trap when function returns)
    (
        sleep 5
        echo -e "${C_DIM}Still scanning... Large directory trees can take several minutes.${C_RESET}" >&2
    ) &
    local progress_pid=$!

    # Kill progress indicator when done
    trap "kill $progress_pid 2>/dev/null" RETURN

    # Create temp file for results
    local tmpfile
    tmpfile=$(mktemp)

    # Find all files recursively (no directories, files only)
    if $FIND_HAS_PRINTF; then
        # Fast path: GNU find gets size+mtime in one traversal (no per-file stat/date)
        while IFS=$'\t' read -r size mtime item; do
            [[ "$item" == "$STAGING_DIR"* || "$item" == "$SESSION_LOG" ]] && continue
            local name="${item#$CURRENT_PATH/}"
            local mtime_int="${mtime%.*}"
            local timestamp=""
            if $PRINTF_HAS_DATETIME; then
                printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' "$mtime_int"
            else
                timestamp=$(date -d "@$mtime_int" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            fi
            printf '%s\tfile\t%s\t%s\t%s\t%s\n' "$size" "$name" "$item" "$mtime_int" "$timestamp"
        done < <(find "$CURRENT_PATH" -type f -printf '%s\t%T@\t%p\n' 2>/dev/null) > "$tmpfile"
    else
        # Portable path: per-file stat calls (BSD/macOS)
        while IFS= read -r -d '' item; do
            [[ "$item" == "$STAGING_DIR"* || "$item" == "$SESSION_LOG" ]] && continue
            local name="${item#$CURRENT_PATH/}"
            local size mtime timestamp

            # Combined stat: one call for both size and mtime (instead of two)
            local stat_out
            if stat_out=$(stat -c '%s %Y' "$item" 2>/dev/null); then
                size="${stat_out% *}"
                mtime="${stat_out##* }"
            elif stat_out=$(stat -f '%z %m' "$item" 2>/dev/null); then
                size="${stat_out% *}"
                mtime="${stat_out##* }"
            else
                size=0; mtime=0
            fi

            if $PRINTF_HAS_DATETIME; then
                printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' "$mtime"
            else
                timestamp=$(date -d "@$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                           date -r "$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            fi

            printf '%s\tfile\t%s\t%s\t%s\t%s\n' "$size" "$name" "$item" "$mtime" "$timestamp"
        done < <(find "$CURRENT_PATH" -type f -print0 2>/dev/null) > "$tmpfile"
    fi

    # Sort by size (descending) and populate arrays
    local index=0
    while IFS=$'\t' read -r size item_type name path mtime timestamp; do
        ITEM_SIZES[$index]=$size
        ITEM_TYPES[$index]="file"
        ITEM_NAMES[$index]=$name
        ITEM_PATHS[$index]=$path
        ITEM_HIDDEN[$index]="false"
        ITEM_TIMESTAMPS[$index]=$timestamp
        index=$((index + 1))
    done < <(sort -rn "$tmpfile")

    rm -f "$tmpfile"

    # Compute directory heights, sizes, counts, and timestamps
    compute_heights

    # Capture start size only on initial deep scan from start path
    if [[ "$SCAN_ROOT" == "$START_PATH" && $SCAN_START_SIZE -eq 0 ]]; then
        for size in "${ITEM_SIZES[@]}"; do
            SCAN_START_SIZE=$((SCAN_START_SIZE + size))
        done
    fi

    return 0
}

# Scan current directory and populate item arrays
scan_directory() {
    # Clear arrays
    ITEM_NAMES=()
    ITEM_SIZES=()
    ITEM_PATHS=()
    ITEM_TYPES=()
    ITEM_HIDDEN=()
    ITEM_TIMESTAMPS=()

    # Check if we can read the directory
    if [[ ! -r "$CURRENT_PATH" ]]; then
        echo -e "${C_RED}Error: Cannot read directory${C_RESET}" >&2
        return 1
    fi

    # Show scanning indicator
    echo -e "${C_CYAN}Scanning directory...${C_RESET}" >&2

    # Start a progress indicator (killed by trap when function returns)
    (
        sleep 5
        echo -e "${C_DIM}This can take a while for large directories...${C_RESET}" >&2
    ) &
    local progress_pid=$!

    # Kill progress indicator when done
    trap "kill $progress_pid 2>/dev/null" RETURN

    # Create temp file for results
    local tmpfile
    tmpfile=$(mktemp)

    # Find all immediate children (not recursive)
    # For each item, get its size using du
    while IFS= read -r -d '' item; do
        local name size item_type mtime timestamp
        name=$(basename "$item")

        # Skip the staging directory and session log if in current path
        if [[ "$item" == "$STAGING_DIR" ]] || [[ "$item" == "$SESSION_LOG" ]]; then
            continue
        fi

        # Get modification time (epoch seconds)
        mtime=$(stat -c '%Y' "$item" 2>/dev/null || stat -f '%m' "$item" 2>/dev/null || echo "0")
        timestamp=$(date -d "@$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

        # Determine type
        if [[ -d "$item" ]]; then
            item_type="dir"
            # Get directory size (this can be slow for large dirs)
            if $DU_SUPPORTS_BYTES; then
                size=$(du -sb "$item" 2>/dev/null | cut -f1)
            else
                size=$(du -sk "$item" 2>/dev/null | cut -f1)
                size=$((size * 1024))
            fi
        else
            item_type="file"
            size=$(stat -c%s "$item" 2>/dev/null || stat -f%z "$item" 2>/dev/null || echo "0")
        fi

        # Default to 0 if size is empty
        size=${size:-0}

        # Write to temp file: size\ttype\tname\tpath\ttimestamp
        printf "%s\t%s\t%s\t%s\t%s\n" "$size" "$item_type" "$name" "$item" "$timestamp" >> "$tmpfile"
    done < <(find "$CURRENT_PATH" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    # Sort by size (descending) and populate arrays
    local index=0
    while IFS=$'\t' read -r size item_type name path timestamp; do
        ITEM_SIZES[$index]=$size
        ITEM_TYPES[$index]=$item_type
        ITEM_NAMES[$index]=$name
        ITEM_PATHS[$index]=$path
        ITEM_HIDDEN[$index]="false"
        ITEM_TIMESTAMPS[$index]=$timestamp
        index=$((index + 1))
    done < <(sort -rn "$tmpfile")

    rm -f "$tmpfile"
    return 0
}

# Clear screen and show header
show_header() {
    clear
    echo
    echo
    echo -e "    ${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}"
    # Right-align session ID on the title line
    local header_left="JUNK HUNTER v${VERSION}"
    local header_right="Session: ${SESSION_ID}"
    local padding=$((63 - ${#header_left} - ${#header_right}))
    local spaces=$(printf '%*s' "$padding" '')
    echo -e "    ${C_BOLD}JUNK HUNTER${C_RESET} ${C_DIM}v${VERSION}${C_RESET}${spaces}${C_DIM}${header_right}${C_RESET}"
    echo -e "    ${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo
    # Show current location (NAV_PREFIX in deep scan, CURRENT_PATH otherwise)
    if $DEEP_SCAN_MODE && [[ -n "$NAV_PREFIX" ]]; then
        echo -e "    ${C_DIM}Current location:${C_RESET} ${C_BOLD}$NAV_PREFIX${C_RESET}"
    else
        echo -e "    ${C_DIM}Current location:${C_RESET} ${C_BOLD}$CURRENT_PATH${C_RESET}"
    fi

    # Show mode indicator
    if $DEEP_SCAN_MODE; then
        local height_desc
        if [[ $HEIGHT_FILTER -eq 0 ]]; then
            height_desc="files"
        else
            height_desc="height-${HEIGHT_FILTER} folders"
        fi
        # Show start size on right if at root of initial deep scan with files view
        if [[ $HEIGHT_FILTER -eq 0 && -z "$NAV_PREFIX" && "$CURRENT_PATH" == "$START_PATH" && $SCAN_START_SIZE -gt 0 ]]; then
            local start_size_human
            start_size_human=$(human_size $SCAN_START_SIZE)
            echo -e "    ${C_YELLOW}${C_BOLD}[DEEP SCAN: All ${height_desc} under this location]${C_RESET}  ${C_DIM}Size at session start: ${start_size_human}${C_RESET}"
        else
            echo -e "    ${C_YELLOW}${C_BOLD}[DEEP SCAN: All ${height_desc} under this location]${C_RESET}"
        fi
    fi

    # Show running totals if any activity
    local total_freed=$((TOTAL_STAGED + TOTAL_DELETED))
    if [[ $total_freed -gt 0 ]]; then
        echo
        echo -e "    ${C_DIM}Session totals:${C_RESET} ${C_YELLOW}Staged: $(human_size $TOTAL_STAGED)${C_RESET} | ${C_RED}Deleted: $(human_size $TOTAL_DELETED)${C_RESET} | ${C_GREEN}Total freed: $(human_size $total_freed)${C_RESET}"
    fi
    echo
}

# Arrays for height-filtered display (populated by build_height_display)
declare -a HEIGHT_DISPLAY_PATHS
declare -a HEIGHT_DISPLAY_SIZES
declare -a HEIGHT_DISPLAY_NAMES

# Build display arrays for height-filtered view
build_height_display() {
    HEIGHT_DISPLAY_PATHS=()
    HEIGHT_DISPLAY_SIZES=()
    HEIGHT_DISPLAY_NAMES=()
    HEIGHT_DISPLAY_TIMESTAMPS=()

    # Determine the prefix to filter by
    local filter_prefix="$SCAN_ROOT"
    if [[ -n "$NAV_PREFIX" ]]; then
        filter_prefix="$NAV_PREFIX"
    fi

    # Build temp file for sorting
    local tmpfile
    tmpfile=$(mktemp)

    # Collect directories matching HEIGHT_FILTER under filter_prefix
    for dir in "${!DIR_HEIGHTS[@]}"; do
        [[ ${DIR_HEIGHTS[$dir]} -ne $HEIGHT_FILTER ]] && continue

        # Must be under filter_prefix (or equal to it for edge cases)
        if [[ "$dir" != "$filter_prefix" && "$dir" != "$filter_prefix"/* ]]; then
            continue
        fi

        # Skip if this dir is the filter_prefix itself (we want children)
        [[ "$dir" == "$filter_prefix" ]] && continue

        local size="${DIR_SIZES[$dir]:-0}"
        local name="${dir#$filter_prefix/}"
        local timestamp="${DIR_TIMESTAMPS[$dir]:-}"

        printf "%s\t%s\t%s\t%s\n" "$size" "$name" "$dir" "$timestamp" >> "$tmpfile"
    done

    # Sort by size descending and populate arrays
    local index=0
    while IFS=$'\t' read -r size name path timestamp; do
        HEIGHT_DISPLAY_SIZES[$index]=$size
        HEIGHT_DISPLAY_NAMES[$index]=$name
        HEIGHT_DISPLAY_PATHS[$index]=$path
        HEIGHT_DISPLAY_TIMESTAMPS[$index]=$timestamp
        index=$((index + 1))
    done < <(sort -rn "$tmpfile")

    rm -f "$tmpfile"
}

# Show height-filtered directory contents
show_height_contents() {
    build_height_display

    local visible_count=${#HEIGHT_DISPLAY_PATHS[@]}

    if [[ $visible_count -eq 0 ]]; then
        echo -e "    ${C_DIM}(no height-${HEIGHT_FILTER} folders found)${C_RESET}"
        echo
        return
    fi

    # Calculate pagination
    local total_pages=$(( (visible_count + MAX_DISPLAY_ITEMS - 1) / MAX_DISPLAY_ITEMS ))

    if [[ $CURRENT_PAGE -lt 1 ]]; then
        CURRENT_PAGE=1
    elif [[ $CURRENT_PAGE -gt $total_pages ]]; then
        CURRENT_PAGE=$total_pages
    fi

    local start_item=$(( (CURRENT_PAGE - 1) * MAX_DISPLAY_ITEMS + 1 ))
    local end_item=$(( CURRENT_PAGE * MAX_DISPLAY_ITEMS ))
    if [[ $end_item -gt $visible_count ]]; then
        end_item=$visible_count
    fi

    # Header row
    printf "    ${C_BOLD}%-4s  %-12s  %s${C_RESET}\n" "NUM" "SIZE" "PATH"
    echo -e "    ${C_DIM}────────────────────────────────────────────────────────────────${C_RESET}"

    # Show items for current page
    local display_num=0
    for i in "${!HEIGHT_DISPLAY_PATHS[@]}"; do
        display_num=$((display_num + 1))

        [[ $display_num -lt $start_item ]] && continue
        [[ $display_num -gt $end_item ]] && break

        local size_human
        size_human=$(human_size "${HEIGHT_DISPLAY_SIZES[$i]}")
        local name="${HEIGHT_DISPLAY_NAMES[$i]}"
        local timestamp="${HEIGHT_DISPLAY_TIMESTAMPS[$i]:-}"

        # Append timestamp if enabled
        local display_name="$name"
        if $SHOW_TIMESTAMPS && [[ -n "$timestamp" ]]; then
            display_name="$name  ${C_DIM}($timestamp)${C_RESET}"
        fi

        # Size color
        local size_color="$C_RESET"
        if [[ ${HEIGHT_DISPLAY_SIZES[$i]} -gt $SIZE_THRESHOLD_HIGH ]]; then
            size_color="$C_RED"
        elif [[ ${HEIGHT_DISPLAY_SIZES[$i]} -gt $SIZE_THRESHOLD_MEDIUM ]]; then
            size_color="$C_YELLOW"
        fi

        printf "    ${C_DIM}%-4s${C_RESET}  ${size_color}%-12s${C_RESET}  %b\n" \
            "$display_num" "$size_human" "$display_name"
    done

    echo
    if [[ $total_pages -gt 1 ]]; then
        echo -e "    ${C_CYAN}${C_BOLD}[Page $CURRENT_PAGE of $total_pages]${C_RESET}  ${C_DIM}(showing items $start_item-$end_item of $visible_count total)${C_RESET}"
    else
        echo -e "    ${C_DIM}Total items: $visible_count${C_RESET}"
    fi
}

# Show current directory contents
show_contents() {
    # Deep scan with height filter > 0: show directories instead
    if $DEEP_SCAN_MODE && [[ $HEIGHT_FILTER -gt 0 ]]; then
        show_height_contents
        return
    fi

    # Count visible items (with NAV_PREFIX filtering in deep scan mode)
    local visible_count=0
    local filter_prefix=""
    if $DEEP_SCAN_MODE && [[ -n "$NAV_PREFIX" ]]; then
        filter_prefix="$NAV_PREFIX/"
    fi

    for i in "${!ITEM_NAMES[@]}"; do
        if [[ "${ITEM_HIDDEN[$i]}" != "true" ]]; then
            # Apply NAV_PREFIX filter in deep scan mode
            if [[ -n "$filter_prefix" ]]; then
                [[ "${ITEM_PATHS[$i]}" != "$filter_prefix"* ]] && continue
            fi
            visible_count=$((visible_count + 1))
        fi
    done

    if [[ $visible_count -eq 0 ]]; then
        echo -e "    ${C_DIM}(empty directory)${C_RESET}"
        echo
        return
    fi

    # Calculate pagination
    local total_pages=$(( (visible_count + MAX_DISPLAY_ITEMS - 1) / MAX_DISPLAY_ITEMS ))

    # Ensure current page is within bounds
    if [[ $CURRENT_PAGE -lt 1 ]]; then
        CURRENT_PAGE=1
    elif [[ $CURRENT_PAGE -gt $total_pages ]]; then
        CURRENT_PAGE=$total_pages
    fi

    local start_item=$(( (CURRENT_PAGE - 1) * MAX_DISPLAY_ITEMS + 1 ))
    local end_item=$(( CURRENT_PAGE * MAX_DISPLAY_ITEMS ))
    if [[ $end_item -gt $visible_count ]]; then
        end_item=$visible_count
    fi

    # Header row (different for recursive mode)
    if $DEEP_SCAN_MODE; then
        printf "    ${C_BOLD}%-4s  %-12s  %s${C_RESET}\n" "NUM" "SIZE" "PATH"
        echo -e "    ${C_DIM}────────────────────────────────────────────────────────────────${C_RESET}"
    else
        printf "    ${C_BOLD}%-4s  %-12s  %-8s  %s${C_RESET}\n" "NUM" "SIZE" "TYPE" "NAME"
        echo -e "    ${C_DIM}────────────────────────────────────────────────────────────────${C_RESET}"
    fi

    # Show items for current page only
    local display_num=0
    for i in "${!ITEM_NAMES[@]}"; do
        # Skip hidden items
        if [[ "${ITEM_HIDDEN[$i]}" == "true" ]]; then
            continue
        fi

        # Apply NAV_PREFIX filter in deep scan mode
        if [[ -n "$filter_prefix" ]]; then
            [[ "${ITEM_PATHS[$i]}" != "$filter_prefix"* ]] && continue
        fi

        display_num=$((display_num + 1))

        # Skip items before current page
        if [[ $display_num -lt $start_item ]]; then
            continue
        fi

        # Stop after current page
        if [[ $display_num -gt $end_item ]]; then
            break
        fi

        local size_human
        size_human=$(human_size "${ITEM_SIZES[$i]}")
        local item_type="${ITEM_TYPES[$i]}"
        local name="${ITEM_NAMES[$i]}"
        local timestamp="${ITEM_TIMESTAMPS[$i]:-}"

        # When filtering by NAV_PREFIX, show path relative to that prefix
        if [[ -n "$filter_prefix" ]]; then
            name="${ITEM_PATHS[$i]#$filter_prefix}"
        fi

        # Append timestamp if enabled
        local display_name="$name"
        if $SHOW_TIMESTAMPS && [[ -n "$timestamp" ]]; then
            display_name="$name  ${C_DIM}($timestamp)${C_RESET}"
        fi

        # Size color based on configured thresholds
        local size_color="$C_RESET"
        if [[ ${ITEM_SIZES[$i]} -gt $SIZE_THRESHOLD_HIGH ]]; then
            size_color="$C_RED"
        elif [[ ${ITEM_SIZES[$i]} -gt $SIZE_THRESHOLD_MEDIUM ]]; then
            size_color="$C_YELLOW"
        fi

        if $DEEP_SCAN_MODE; then
            # Recursive mode: just show number, size, and path
            printf "    ${C_DIM}%-4s${C_RESET}  ${size_color}%-12s${C_RESET}  %b\n" \
                "$display_num" "$size_human" "$display_name"
        else
            # Normal mode: show type column
            local type_display type_color
            if [[ "$item_type" == "dir" ]]; then
                type_display="DIR"
                type_color="$C_BLUE"
            else
                type_display="FILE"
                type_color="$C_RESET"
            fi

            printf "    ${C_DIM}%-4s${C_RESET}  ${size_color}%-12s${C_RESET}  ${type_color}%-8s${C_RESET}  %b\n" \
                "$display_num" "$size_human" "$type_display" "$display_name"
        fi
    done

    echo
    if [[ $total_pages -gt 1 ]]; then
        echo -e "    ${C_CYAN}${C_BOLD}[Page $CURRENT_PAGE of $total_pages]${C_RESET}  ${C_DIM}(showing items $start_item-$end_item of $visible_count total)${C_RESET}"
    else
        echo -e "    ${C_DIM}Total items: $visible_count${C_RESET}"
    fi
}

# Show and modify configuration
show_config() {
    while true; do
        clear
        echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}"
        echo -e "${C_BOLD}  CONFIGURATION${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "${C_BOLD}Current Settings:${C_RESET}"
        echo
        echo -e "  ${C_BOLD}1.${C_RESET} High size threshold (red):   $(human_size $SIZE_THRESHOLD_HIGH)"
        echo -e "  ${C_BOLD}2.${C_RESET} Medium size threshold (yellow): $(human_size $SIZE_THRESHOLD_MEDIUM)"
        echo -e "  ${C_BOLD}3.${C_RESET} Max items per screen:       $MAX_DISPLAY_ITEMS"
        if $CONFIRM_DELETES; then
            echo -e "  ${C_BOLD}4.${C_RESET} Ask before deleting:        ${C_GREEN}yes${C_RESET}"
        else
            echo -e "  ${C_BOLD}4.${C_RESET} Ask before deleting:        ${C_YELLOW}no${C_RESET}"
        fi
        if $CONFIRM_STAGES; then
            echo -e "  ${C_BOLD}5.${C_RESET} Ask before staging:         ${C_GREEN}yes${C_RESET}"
        else
            echo -e "  ${C_BOLD}5.${C_RESET} Ask before staging:         ${C_YELLOW}no${C_RESET}"
        fi
        echo
        echo -e "${C_DIM}───────────────────────────────────────────────────────────────${C_RESET}"
        echo -e "Type a number to change that setting, or press Enter to go back."
        echo -e "${C_DIM}───────────────────────────────────────────────────────────────${C_RESET}"
        echo
        echo -n -e "${C_GREEN}>${C_RESET} "
        read -r choice

        # Strip escape sequences (arrow keys, etc)
        choice="${choice//[$'\033']}"
        choice="${choice//[$'\001'-$'\037']}"

        case "$choice" in
            1)
                echo
                echo -e "Type new high threshold in MB (currently $(( SIZE_THRESHOLD_HIGH / 1024 / 1024 )) MB):"
                echo -n -e "${C_GREEN}>${C_RESET} "
                read -r new_value
                if [[ "$new_value" =~ ^[0-9]+$ ]] && [[ $new_value -gt 0 ]]; then
                    SIZE_THRESHOLD_HIGH=$((new_value * 1024 * 1024))
                    echo -e "${C_GREEN}Updated!${C_RESET}"
                else
                    echo -e "${C_RED}Invalid value${C_RESET}"
                fi
                sleep 1
                ;;
            2)
                echo
                echo -e "Type new medium threshold in MB (currently $(( SIZE_THRESHOLD_MEDIUM / 1024 / 1024 )) MB):"
                echo -n -e "${C_GREEN}>${C_RESET} "
                read -r new_value
                if [[ "$new_value" =~ ^[0-9]+$ ]] && [[ $new_value -gt 0 ]]; then
                    SIZE_THRESHOLD_MEDIUM=$((new_value * 1024 * 1024))
                    echo -e "${C_GREEN}Updated!${C_RESET}"
                else
                    echo -e "${C_RED}Invalid value${C_RESET}"
                fi
                sleep 1
                ;;
            3)
                echo
                echo -e "Type new max display items (currently $MAX_DISPLAY_ITEMS):"
                echo -n -e "${C_GREEN}>${C_RESET} "
                read -r new_value
                if [[ "$new_value" =~ ^[0-9]+$ ]] && [[ $new_value -gt 0 ]]; then
                    MAX_DISPLAY_ITEMS=$new_value
                    echo -e "${C_GREEN}Updated!${C_RESET}"
                else
                    echo -e "${C_RED}Invalid value${C_RESET}"
                fi
                sleep 1
                ;;
            4)
                if $CONFIRM_DELETES; then
                    CONFIRM_DELETES=false
                    echo -e "${C_YELLOW}Delete confirmation disabled${C_RESET}"
                else
                    CONFIRM_DELETES=true
                    echo -e "${C_GREEN}Delete confirmation enabled${C_RESET}"
                fi
                sleep 1
                ;;
            5)
                if $CONFIRM_STAGES; then
                    CONFIRM_STAGES=false
                    echo -e "${C_YELLOW}Stage confirmation disabled${C_RESET}"
                else
                    CONFIRM_STAGES=true
                    echo -e "${C_GREEN}Stage confirmation enabled${C_RESET}"
                fi
                sleep 1
                ;;
            "")
                return
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    echo -e "${C_RED}Invalid choice${C_RESET}"
                    sleep 1
                fi
                ;;
        esac
    done
}

# Show command menu
show_menu() {
    echo
    echo -e "    ${C_DIM}───────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "    ${C_BOLD}Commands:${C_RESET}"
    if $DEEP_SCAN_MODE; then
        # Navigate into folders (only when showing folders, not files)
        if [[ $HEIGHT_FILTER -gt 0 ]]; then
            echo "      [number]  - Navigate into item (height -1)"
        fi
        # Up/back commands (only when navigated into a subfolder)
        if [[ -n "$NAV_PREFIX" ]]; then
            echo "      u         - Up to parent folder (height +1)"
            echo "      w         - Back to scan root (height 0)"
        fi
        echo "      h [num]   - Set height filter (0=files, 1+=folders by max-depth)"
        echo "      f         - Exit deep scan (back to directory view)"
    else
        echo "      [number]  - Navigate into item"
        echo "      u         - Up to parent directory"
        echo "      w         - Back to starting directory"
        echo "      f         - Deep scan (show ALL files by size)"
    fi
    echo "      t         - Toggle timestamps"
    echo "      c         - Configuration / settings"
    echo "      s [num]   - Stage item for deletion (multiple commands per line OK; ranges OK)"
    echo "      d [num]   - Delete item permanently (multiple commands per line OK; ranges OK)"
    echo "      r         - Refresh current view"
    echo "      n         - Next page"
    echo "      b         - Previous page"
    echo "      p [num]   - Jump to page"
    echo "      q         - Quit"
    echo -e "    ${C_DIM}───────────────────────────────────────────────────────────────${C_RESET}"
}

# Main interactive loop
main_loop() {
    local command
    local running=true
    local needs_scan=true

    while $running; do
        # Scan directory if needed
        if $needs_scan; then
            if $DEEP_SCAN_MODE; then
                if ! scan_deep; then
                    echo -e "${C_RED}Deep scan failed. Press Enter to continue...${C_RESET}"
                    read -r
                fi
            else
                if ! scan_directory; then
                    echo -e "${C_RED}Failed to scan directory. Press Enter to continue...${C_RESET}"
                    read -r
                fi
            fi
            needs_scan=false
        fi

        show_header
        show_contents
        show_menu

        echo
        echo -n -e "    ${C_GREEN}>${C_RESET} "
        read -r command

        # Strip escape sequences (arrow keys, etc) from input
        command=$(echo "$command" | tr -d '\033[:cntrl:]')

        # Check if it's a multi-command first (e.g., "d3 d2 s5" or "s1-10" or "d 1-10")
        if [[ "$command" =~ ^([ds][[:space:]]*[0-9]+(-[0-9]+)?[[:space:]]*){2,}$ ]] || [[ "$command" =~ ^[ds][[:space:]]*[0-9]+-[0-9]+$ ]]; then
            # Multi-command or range detected
            execute_multi_command "$command"
            # No rescan needed - we update in place!
            continue
        fi

        case "$command" in
            q|quit|exit)
                running=false
                ;;
            r|refresh)
                needs_scan=true
                ;;
            c|config)
                show_config
                ;;
            f)
                # Toggle deep scan mode
                if $DEEP_SCAN_MODE; then
                    # Exit deep scan mode - go to current location if navigated
                    if [[ -n "$NAV_PREFIX" ]]; then
                        CURRENT_PATH="$NAV_PREFIX"
                    fi
                    DEEP_SCAN_MODE=false
                    NAV_PREFIX=""
                    HEIGHT_FILTER=0
                    CURRENT_PAGE=1
                    needs_scan=true
                else
                    # Enter deep scan mode with confirmation
                    echo
                    echo -e "${C_YELLOW}Deep scan: show ALL files under this location?${C_RESET}"
                    echo -e "${C_DIM}This may take a while for large directory trees.${C_RESET}"
                    echo -n "Continue? (y/n): "
                    read -r confirm
                    confirm_lower="${confirm,,}"
                    if [[ "$confirm_lower" == "y" || "$confirm_lower" == "yes" ]]; then
                        DEEP_SCAN_MODE=true
                        CURRENT_PAGE=1
                        needs_scan=true
                    fi
                fi
                ;;
            u|up)
                if $DEEP_SCAN_MODE; then
                    if [[ -n "$NAV_PREFIX" ]]; then
                        # Navigate up within deep scan (trim NAV_PREFIX to parent)
                        local parent
                        parent="$(dirname "$NAV_PREFIX")"
                        if [[ "$parent" == "$SCAN_ROOT" || "$parent" == "$NAV_PREFIX" ]]; then
                            # At scan root - clear prefix
                            NAV_PREFIX=""
                        else
                            NAV_PREFIX="$parent"
                        fi
                        HEIGHT_FILTER=$((HEIGHT_FILTER + 1))
                        CURRENT_PAGE=1
                    else
                        if [[ "$SCAN_ROOT" != "$START_PATH" ]]; then
                            echo -e "${C_YELLOW}Already at scan root. Use 'f' to exit deep scan.${C_RESET}"
                        else
                            echo -e "${C_YELLOW}Already at scan root.${C_RESET}"
                        fi
                        sleep 1
                    fi
                elif navigate_up; then
                    CURRENT_PAGE=1
                    needs_scan=true
                fi
                ;;
            w)
                # Jump to root (START_PATH in directory mode, SCAN_ROOT in deep scan)
                if $DEEP_SCAN_MODE; then
                    NAV_PREFIX=""
                    HEIGHT_FILTER=0
                    CURRENT_PAGE=1
                else
                    if [[ "$CURRENT_PATH" != "$START_PATH" ]]; then
                        cd "$START_PATH" || true
                        CURRENT_PATH="$START_PATH"
                        CURRENT_PAGE=1
                        needs_scan=true
                    fi
                fi
                ;;
            h*)
                # Height filter (deep scan mode only): "h [number]" or "h[number]"
                if $DEEP_SCAN_MODE; then
                    if [[ "$command" =~ ^h[[:space:]]*([0-9]+)$ ]]; then
                        HEIGHT_FILTER="${BASH_REMATCH[1]}"
                        CURRENT_PAGE=1
                    else
                        echo -e "${C_YELLOW}Usage: h [number] (0=files, 1+=folders by max-depth)${C_RESET}"
                        sleep 1
                    fi
                else
                    echo -e "${C_YELLOW}Height filter only available in deep scan mode${C_RESET}"
                    sleep 1
                fi
                ;;
            t)
                # Toggle timestamp display
                if $SHOW_TIMESTAMPS; then
                    SHOW_TIMESTAMPS=false
                else
                    SHOW_TIMESTAMPS=true
                fi
                ;;
            n|next)
                # Next page
                CURRENT_PAGE=$((CURRENT_PAGE + 1))
                # show_contents() will clamp to valid range
                ;;
            b|back|prev)
                # Previous page
                CURRENT_PAGE=$((CURRENT_PAGE - 1))
                # show_contents() will clamp to valid range
                ;;
            p*)
                # Page jump: "p [number]" or "p[number]"
                if [[ "$command" =~ ^p[[:space:]]*([0-9]+)$ ]]; then
                    local page_num="${BASH_REMATCH[1]}"
                    CURRENT_PAGE=$page_num
                    # show_contents() will clamp to valid range
                else
                    echo -e "${C_YELLOW}Usage: p [page number]${C_RESET}"
                    sleep 1
                fi
                ;;
            s*)
                # Stage command: "s [number]" or "s[number]"
                if [[ "$command" =~ ^s[[:space:]]*([0-9]+)$ ]]; then
                    local item_num="${BASH_REMATCH[1]}"
                    stage_item "$item_num"
                    # No rescan needed - we update in place!
                else
                    echo -e "${C_YELLOW}Usage: s [number] or multi: 's1 s2 d3'${C_RESET}"
                    sleep 1
                fi
                ;;
            d*)
                # Delete command: "d [number]" or "d[number]"
                if [[ "$command" =~ ^d[[:space:]]*([0-9]+)$ ]]; then
                    local item_num="${BASH_REMATCH[1]}"
                    delete_item "$item_num"
                    # No rescan needed - we update in place!
                else
                    echo -e "${C_YELLOW}Usage: d [number] or multi: 's1 s2 d3'${C_RESET}"
                    sleep 1
                fi
                ;;
            "")
                # Empty input - silently continue
                ;;
            *)
                if [[ "$command" =~ ^[0-9]+$ ]]; then
                    if $DEEP_SCAN_MODE; then
                        if [[ $HEIGHT_FILTER -gt 0 ]]; then
                            # Navigate into a directory in deep scan mode
                            local nav_index=$(($command - 1))
                            if [[ $nav_index -ge 0 && $nav_index -lt ${#HEIGHT_DISPLAY_PATHS[@]} ]]; then
                                NAV_PREFIX="${HEIGHT_DISPLAY_PATHS[$nav_index]}"
                                HEIGHT_FILTER=$((HEIGHT_FILTER - 1))
                                CURRENT_PAGE=1
                            else
                                echo -e "${C_RED}Invalid item number${C_RESET}"
                                sleep 1
                            fi
                        else
                            echo -e "${C_YELLOW}Cannot navigate into files. Use 'h 1' to view folders.${C_RESET}"
                            sleep 1
                        fi
                    elif navigate_into "$command"; then
                        CURRENT_PAGE=1
                        needs_scan=true
                    fi
                # Silently ignore ONLY escape sequence remnants (arrow keys, page up/down, etc.)
                # After stripping, these look like: [A, [B, [5~, [C, etc.
                # Only match if the ENTIRE string is escape sequences (possibly multiple)
                elif [[ "$command" =~ ^([[]([A-Z]|[0-9]+~|O[A-Z]))+$ ]]; then
                    # Pure escape sequences only - silently ignore
                    :
                else
                    echo -e "${C_RED}Unknown command: $command${C_RESET}"
                    sleep 1
                fi
                ;;
        esac
    done
}

# Entry point
main() {
    init_session

    echo -e "${C_BOLD}${C_GREEN}Welcome to Junk Hunter!${C_RESET}"
    echo
    echo "Starting in: $CURRENT_PATH"
    echo "Staging directory: $STAGING_DIR"
    echo "Session log: $SESSION_LOG"
    echo
    echo -e "${C_BOLD}Choose starting mode:${C_RESET}"
    echo "  1 - Directory view (navigate folders, see dirs + files)"
    echo "  2 - Deep scan (flat list of ALL files by size)"
    echo
    echo -n "Choice (1 or 2): "
    read -r mode_choice

    if [[ "$mode_choice" == "2" ]]; then
        DEEP_SCAN_MODE=true
        echo "Starting deep scan..."
    else
        echo "Starting in directory mode..."
    fi

    # Now that user has committed to a session, create the log file
    create_session_log
    sleep 1

    # Enter alternate screen buffer (like vim/less)
    tput smcup

    # Ensure we restore terminal on exit (even if interrupted)
    trap 'tput rmcup' EXIT

    main_loop

    # Exit alternate screen buffer manually so summary appears in main terminal
    tput rmcup
    trap - EXIT  # Clear the trap so it doesn't run again

    # Write summary to session log
    {
        echo ""
        echo "-------------------------------------------------------------------"
        echo "Session ended at $(date)"
        echo ""
        echo "Summary:"
        echo "  Staged: $COUNT_STAGED item(s), $(human_size $TOTAL_STAGED)"
        echo "  Deleted: $COUNT_DELETED item(s), $(human_size $TOTAL_DELETED)"
        echo "  Total space freed: $(human_size $((TOTAL_STAGED + TOTAL_DELETED)))"
        echo "-------------------------------------------------------------------"
    } >> "$SESSION_LOG"

    # Session summary
    echo
    echo -e "${C_BOLD}${C_GREEN}Session ended!${C_RESET}"
    echo

    # Show deletion summary
    if [[ $COUNT_DELETED -eq 0 ]]; then
        echo "No files were deleted."
    else
        echo -e "${C_RED}Deleted ${COUNT_DELETED} file(s), reclaiming $(human_size $TOTAL_DELETED) of disk space.${C_RESET}"
    fi

    # Show staging summary
    if [[ $COUNT_STAGED -eq 0 ]]; then
        echo "No files were staged for manual inspection/deletion."
    else
        echo -e "${C_YELLOW}${COUNT_STAGED} file(s) ($(human_size $TOTAL_STAGED)) await manual inspection and deletion from the staging directory!${C_RESET}"
        echo -e "${C_DIM}Staging directory: $STAGING_DIR${C_RESET}"
    fi

    echo -e "${C_DIM}Session log: $SESSION_LOG${C_RESET}"
}

# Run
main
