# Junk Hunter

**Size-first disk cleaning for operators who enjoy time in (and out of) the terminal.**

## Executive Summary

Junk Hunter is an interactive terminal tool for reclaiming disk space through intelligent, size-first exploration. Instead of clicking through folder trees hoping to find large files, it shows you the biggest items immediately, whether in a single directory or across an entire tree. Stage files for review, delete permanently with confirmation, or batch-process dozens at once with range syntax. Every action is logged, nothing is lost accidentally, and your terminal history stays pristine.

## Key Features

- **Size-first navigation** :: Always see the largest items first, sorted automatically
- **Recursive deep scan** :: Flatten entire directory trees into one sortable list
- **Safe staging area** :: Review files before permanent deletion
- **Batch operations** :: Process multiple items: `s1-20 d35 s40-45`
- **Smart updates** :: No rescans after each action; directory sizes update quickly
- **Session tracking** :: Running totals show how much space you've freed
- **Configurable thresholds** :: Adjust color-coded size warnings on the fly
- **Zero dependencies** :: Pure bash, works (almost) anywhere

## Usage

```bash
# Download and run
bash junk_hunter.sh

# Choose directory or deep scan mode at startup

# Navigate with numbers, drill into directories
> 1

# Go up
> u

# Stage items for later review
> s 3

# Delete permanently (with confirmation)
> d 5

# Batch operations with ranges (single confirmation for the batch)
> s1-10 d15 s20-25

# Toggle deep scan mode: see ALL files under current location
> f

# Configure thresholds and behavior
> c

# Quit and see session summary
> q
```

## Commands

| Command | Description |
|---------|-------------|
| `[number]` | Navigate into item |
| `u` | Up to parent directory |
| `w` | Jump to starting directory (or scan root in deep scan) |
| `f` | Toggle deep scan mode (flat view of all files) |
| `h [num]` | Height filter in deep scan (0=files, 1+=folders by max-depth) |
| `t` | Toggle last-modified timestamps |
| `c` | Configuration / settings |
| `s [num]` | Stage item for deletion (ranges & multiples OK) |
| `d [num]` | Delete item permanently (ranges & multiples OK) |
| `r` | Refresh current view |
| `n` | Next page |
| `b` | Previous page |
| `p [num]` | Jump to page number |
| `q` | Quit and show session summary |

**Batch operations:** Combine multiple commands on one line with ranges: `s1-10 d15 s20-25`

**Pagination:** Items are displayed in pages based on the "Max items per screen" setting (configurable via `c`). Use `n`/`b` to navigate or `p` to jump to a specific page. Page numbers are preserved after staging/deleting items and reset when navigating directories.

### Deep Scan Mode

Press `f` to enter deep scan mode, which scans all files under the current location and displays them in a flat, size-sorted list. Perfect for finding the largest files buried deep in folder hierarchies. Press `f` again to return to normal directory navigation.

## Technical Notes

**Implementation:** Pure bash script using standard POSIX utilities (`find`, `du`, `stat`, `sort`). No external dependencies required.

**Safety:**
- Staging uses `mv` (reversible)
- Deletes require explicit confirmation by default
- Session logs record every action with timestamps
- Alternate screen buffer preserves terminal history (note: disables terminal scrollback in most terminals; use pagination commands instead)
- Prevents navigation above starting directory

**Portability:** Works on Linux, macOS, and Windows (via Git Bash/WSL). Requires bash 4+ (macOS ships with 3.2; run `brew install bash` to upgrade). Uses both BSD and GNU `stat` and `du` syntax with automatic fallback.

**Session artifacts:**
- `.junk_hunter_staging_[timestamp]_[id]/` :: Staged files (safely reversible)
- `.junk_hunter_log_[timestamp]_[id].txt` :: Action log

---

*v1.1.1*
