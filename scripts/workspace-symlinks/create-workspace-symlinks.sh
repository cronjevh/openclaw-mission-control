#!/bin/bash

set -euo pipefail

OUTPUT_ROOT="/home/cronjev/mission-control-tfsmrt/workspaces"
API_BASE_URL="http://localhost:8000"
UI_BASE_URL="http://localhost:3000"
OPENCLAW_JSON="/home/cronjev/.openclaw/openclaw.json"
ENV_FILE="/home/cronjev/mission-control-tfsmrt/backend/.env"

# Function to get local auth token
get_local_auth_token() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Error: Mission Control env file not found: $ENV_FILE" >&2
        exit 1
    fi
    grep '^LOCAL_AUTH_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- | xargs
}

# Function to invoke API
invoke_api() {
    local path="$1"
    curl -s -H "Authorization: Bearer $TOKEN" "$API_BASE_URL$path"
}

# Function to get paged items
get_paged_items() {
    local path="$1"
    local items=()
    local limit=200
    local offset=0
    while true; do
        local sep="?"
        if [[ "$path" == *"?"* ]]; then sep="&"; fi
        local response=$(invoke_api "$path${sep}limit=$limit&offset=$offset")
        local batch=$(echo "$response" | jq -r '.items[]? // empty')
        if [[ -z "$batch" ]]; then
            batch=$(echo "$response" | jq -r '.[]? // empty')
        fi
        if [[ -z "$batch" ]]; then
            echo "Error: Unexpected API payload for $path" >&2
            exit 1
        fi
        items+=("$batch")
        local count=$(echo "$batch" | wc -l)
        if (( count < limit )); then break; fi
        offset=$((offset + limit))
    done
    printf '%s\n' "${items[@]}"
}

# Function to get OpenClaw agents
get_openclaw_agents() {
    if [[ ! -f "$OPENCLAW_JSON" ]]; then
        echo "Error: openclaw.json not found: $OPENCLAW_JSON" >&2
        exit 1
    fi
    # Parse JSON to get agents
    jq -r '.agents.list[] | select(.id and .workspace) | {id: .id, name: (.name // .id), workspace: .workspace}' "$OPENCLAW_JSON"
}

# Function to convert to safe name
convert_to_safe_name() {
    local value="$1"
    local fallback="$2"
    local safe=$(echo "$value" | sed 's/[<>:"\/\\|?*]/-/g' | sed 's/  */ /g' | sed 's/^[. ]*//;s/[. ]*$//')
    if [[ -z "$safe" ]]; then
        echo "$fallback"
    else
        echo "$safe"
    fi
}

# Function to get unique name
get_unique_name() {
    local name="$1"
    local used_names="$2"
    local suffix="$3"
    if ! echo "$used_names" | grep -q "^$name$"; then
        echo "$name"
        return
    fi
    local counter=1
    while true; do
        local candidate
        if (( counter == 1 )); then
            candidate="$name ($suffix)"
        else
            candidate="$name ($suffix-$counter)"
        fi
        if ! echo "$used_names" | grep -q "^$candidate$"; then
            echo "$candidate"
            return
        fi
        counter=$((counter + 1))
    done
}

# Function to resolve OpenClaw agent
resolve_openclaw_agent() {
    local mc_agent="$1"
    local by_id="$2"
    local by_session="$3"
    local session_id=$(echo "$mc_agent" | jq -r '.openclaw_session_id // empty')
    if [[ -n "$session_id" ]]; then
        echo "$by_session" | jq -r ".[\"$session_id\"] // empty"
        return
    fi
    local is_lead=$(echo "$mc_agent" | jq -r '.is_board_lead // false')
    local board_id=$(echo "$mc_agent" | jq -r '.board_id // empty')
    if [[ "$is_lead" == "true" ]] && [[ -n "$board_id" ]]; then
        local lead_id="lead-$board_id"
        echo "$by_id" | jq -r ".[\"$lead_id\"] // empty"
        return
    fi
    local candidates=($(echo "$mc_agent" | jq -r '.id, "mc-\(.id)", .name'))
    for candidate in "${candidates[@]}"; do
        if [[ -n "$candidate" ]]; then
            local resolved=$(echo "$by_id" | jq -r ".[\"$candidate\"] // empty")
            if [[ -n "$resolved" ]]; then
                echo "$resolved"
                return
            fi
        fi
    done
    echo ""
}

# Function to write planned link
write_planned_link() {
    local link_path="$1"
    local target_path="$2"
    echo "[planned-link] $link_path -> $target_path"
    if [[ ! -e "$target_path" ]]; then
        echo "[warning] Target path does not exist: $target_path"
    fi
    if [[ -e "$link_path" ]]; then
        rm -rf "$link_path"
    fi
    ln -s "$target_path" "$link_path"
    echo "[success] Symlink created: $link_path -> $target_path"
}

# Function to write markdown file
write_markdown_file() {
    local path="$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    echo -e "$content" > "$path"
}

# Function to get board readme content
get_board_readme_content() {
    local board="$1"
    local linked_agents="$2"
    local missing_agents="$3"
    local content="# $(echo "$board" | jq -r '.name')\n\n"
    content+="- Board ID: '$(echo "$board" | jq -r '.id')'\n"
    content+="- Mission Control URL: $UI_BASE_URL/boards/$(echo "$board" | jq -r '.id')\n\n"
    local desc=$(echo "$board" | jq -r '.description // empty')
    if [[ -n "$desc" ]]; then
        content+="## Description\n\n$desc\n\n"
    fi
    content+="## Linked Workspaces\n\n"
    echo "$linked_agents" | jq -r '.[] | "- **\(.Name)**  \n  MC Agent ID: `\(.MissionControlId)`  \n  OpenClaw ID: `\(.OpenClawId)`  \n  Workspace: `\(.WorkspaceLinuxPath)`\n"'
    content+="$(echo "$linked_agents" | jq -r '.[] | "- **\(.Name)**  \n  MC Agent ID: `\(.MissionControlId)`  \n  OpenClaw ID: `\(.OpenClawId)`  \n  Workspace: `\(.WorkspaceLinuxPath)`\n"')\n"
    local missing_count=$(echo "$missing_agents" | jq length)
    if (( missing_count > 0 )); then
        content+="## Missing Workspace Mappings\n\n"
        content+="$(echo "$missing_agents" | jq -r '.[] | "- **\(.Name)** (`\(.MissionControlId)`)'\n")\n"
    fi
    echo -e "$content"
}

# Function to get agents readme content
get_agents_readme_content() {
    local agents="$1"
    local content="# Agents\n\nMission Control URL: $UI_BASE_URL/agents\n\n"
    content+="$(echo "$agents" | jq -r '.[] | "- **\(.Name)**  \n  OpenClaw ID: `\(.AgentId)`  \n  Workspace: `\(.Workspace)`\n"')\n"
    echo -e "$content"
}

# Function to get root readme content
get_root_readme_content() {
    local board_count="$1"
    local agent_count="$2"
    local output_path="$3"
    cat <<EOF
# Mission Control Links

This folder is generated by create-workspace-symlinks.sh.

- Boards UI: $UI_BASE_URL/boards
- Agents UI: $UI_BASE_URL/agents
- Output root: $output_path
- Boards discovered: $board_count
- OpenClaw agents discovered: $agent_count

The script creates native Linux symlinks and README files from the live Mission Control state.
EOF
}

# Main script
TOKEN=$(get_local_auth_token)
if [[ -z "$TOKEN" ]]; then
    echo "Error: LOCAL_AUTH_TOKEN not found" >&2
    exit 1
fi

openclaw_agents=$(get_openclaw_agents)
boards=$(get_paged_items "/api/v1/boards" | jq -s 'sort_by(.name)')
mission_control_agents=$(get_paged_items "/api/v1/agents")

mkdir -p "$OUTPUT_ROOT/boards" "$OUTPUT_ROOT/agents"

agent_links_dir="$OUTPUT_ROOT/agents"
board_links_dir="$OUTPUT_ROOT/boards"

used_agent_names=""
board_members_for_cleanup=""

# Process agents
sorted_agents=$(echo "$openclaw_agents" | jq -s 'sort_by(.name, .id)')
echo "$sorted_agents" | jq -c '.[]' | while read -r agent; do
    agent_id=$(echo "$agent" | jq -r '.id')
    name=$(echo "$agent" | jq -r '.name')
    workspace=$(echo "$agent" | jq -r '.workspace')
    safe_name=$(convert_to_safe_name "$name" "$agent_id")
    link_name=$(get_unique_name "$safe_name" "$used_agent_names" "${agent_id:0:8}")
    used_agent_names="$used_agent_names\n$link_name"
    link_path="$agent_links_dir/$link_name"
    write_planned_link "$link_path" "$workspace"
done

agents_readme=$(get_agents_readme_content "$sorted_agents")
write_markdown_file "$agent_links_dir/README.md" "$agents_readme"

used_board_names=""
linked_board_count=0

echo "$boards" | jq -c '.[]' | while read -r board; do
    board_id=$(echo "$board" | jq -r '.id')
    board_name=$(echo "$board" | jq -r '.name')
    if [[ -z "$board_id" ]] || [[ -z "$board_name" ]]; then
        echo "[warning] Skipping board with invalid ID or name: ID='$board_id', Name='$board_name'"
        continue
    fi
    members=$(echo "$mission_control_agents" | jq -c "[.[] | select(.board_id == \"$board_id\")]")
    member_count=$(echo "$members" | jq length)
    if (( member_count == 0 )); then continue; fi

    board_safe_name=$(convert_to_safe_name "$board_name" "$board_id")
    board_folder_name=$(get_unique_name "$board_safe_name" "$used_board_names" "${board_id:0:8}")
    used_board_names="$used_board_names\n$board_folder_name"
    board_folder_path="$board_links_dir/$board_folder_name"
    mkdir -p "$board_folder_path"

    linked_agents=""
    missing_agents=""
    used_member_names=""

    echo "$members" | jq -c '.[]' | while read -r member; do
        resolved=$(resolve_openclaw_agent "$member" "$openclaw_agents" "$openclaw_agents")  # Need to adjust for by_id and by_session
        if [[ -z "$resolved" ]]; then
            member_name=$(echo "$member" | jq -r '.name')
            member_id=$(echo "$member" | jq -r '.id')
            missing_agents="$missing_agents{\"Name\":\"$member_name\",\"MissionControlId\":\"$member_id\"}"
            continue
        fi
        # Add to cleanup
        board_members_for_cleanup="$board_members_for_cleanup$resolved"

        resolved_name=$(echo "$resolved" | jq -r '.name')
        resolved_id=$(echo "$resolved" | jq -r '.id')
        safe_member_name=$(convert_to_safe_name "$resolved_name" "$resolved_id")
        member_id_short=$(echo "$member" | jq -r '.id' | cut -c1-8)
        member_link_name=$(get_unique_name "$safe_member_name" "$used_member_names" "$member_id_short")
        used_member_names="$used_member_names\n$member_link_name"
        member_link_path="$board_folder_path/$member_link_name"
        workspace=$(echo "$resolved" | jq -r '.workspace')
        write_planned_link "$member_link_path" "$workspace"

        linked_agents="$linked_agents{\"Name\":\"$resolved_name\",\"MissionControlId\":\"$(echo "$member" | jq -r '.id')\",\"OpenClawId\":\"$resolved_id\",\"WorkspaceLinuxPath\":\"$workspace\"}"
    done

    linked_agents_json=$(echo "[$linked_agents]" | jq .)
    missing_agents_json=$(echo "[$missing_agents]" | jq .)
    board_readme=$(get_board_readme_content "$board" "$linked_agents_json" "$missing_agents_json")
    write_markdown_file "$board_folder_path/README.md" "$board_readme"
    linked_board_count=$((linked_board_count + 1))
done

root_readme=$(get_root_readme_content "$linked_board_count" "$(echo "$openclaw_agents" | jq length)" "$OUTPUT_ROOT")
write_markdown_file "$OUTPUT_ROOT/README.md" "$root_readme"

echo ""
echo "Prepared output folder: $OUTPUT_ROOT"
echo "Boards with members: $linked_board_count"
echo "OpenClaw agents: $(echo "$openclaw_agents" | jq length)"