#!/bin/sh
#
# Toggle Tailscale (GL native) + gl-tailscale-fix Kill Switch and related preferences via
# the physical side switch on supported GL.iNet routers (Beryl AX, Slate AX, etc.).
#
# Prerequisites — verify all of these BEFORE deploying this script:
#   1. gl-tailscale-fix v1.0.9 or later installed on the router.
#   2. Tailscale enabled in the GL admin UI at least once and bound to your Tailscale account
#      ("Bind Account" set).
#   3. A Custom Exit Node selected at least once in the GL UI (so an exit node IP is stored in
#      tailscale.settings.exit_node_ip — the script reuses GL's most recent selection on each
#      "on" flip).
#   4. Exit node(s) approved in the Tailscale admin console at
#      https://login.tailscale.com/admin/machines (Edit route settings → Use as exit node).
#   5. If LAN_ENABLED=true (the default): this router's LAN subnet route also approved in the
#      Tailscale admin console.
#   6. Any WireGuard, OpenVPN, or Tor client tunnel managed via the GL admin UI (Apps menu)
#      should be disabled before configuring the slider. Their policy routing at priority
#      6000 wins against Tailscale's exit-node routing at priority 5270, so Tailscale traffic
#      wouldn't actually flow through the exit node. The script also defensively disables
#      WG/OVPN/Tor on each "on" flip — but only as a backup for the case where the slider
#      was previously bound to one of those functions and is being rebound to Tailscale.
#      It is not a substitute for the proper GUI-side disable.
#   7. End-to-end tested in the GL UI before relying on the slider — enable Tailscale, select
#      the exit node, confirm your LAN clients route through it and the kill switch engages.
#
# Install on the router:
#   wget -q https://raw.githubusercontent.com/RemoteToHome-io/gl-tailscale-fix/main/examples/gl-switch.d/tailscale.sh -O /etc/gl-switch.d/tailscale.sh
#   chmod +x /etc/gl-switch.d/tailscale.sh
#
# Bind the physical slider to this script. The GL admin UI dropdown for Toggle Button
# Settings does NOT list Tailscale as an option, so this must be done via UCI:
#   uci set switch-button.@main[0].func='tailscale'
#   uci commit switch-button
#
# IMPORTANT: after the UCI binding, DO NOT open System → Toggle Button Settings in the
# GL admin UI. That page only knows about its hardcoded function list, so it will display
# "No Function" (or a stale prior selection) and clicking Apply will overwrite the UCI
# binding with whatever the GUI displays. To unbind cleanly, run:
#   uci set switch-button.@main[0].func='' && uci commit switch-button
#
# Then edit the Configuration block below to your preferred posture. Every "on" flip applies
# that posture in full, so a single edit here locks in your setup across switch toggles.
#
# Exit-node handling is special: by default the script reuses GL's most recently selected exit
# node (so changing the selection in the GL UI sticks across toggles). DEFAULT_EXIT_NODE_IP is
# used only as a fallback on first run, when nothing has been selected yet.
#
# By default this script treats slider "on" as "enable Tailscale + apply posture" and slider
# "off" as "disable everything." If you prefer the inverted convention (resting position is
# "off" with Tailscale active), swap the action names in the if/elif branches below.
#
# Released under the same terms as gl-tailscale-fix (GPL-3.0).

# --- Configuration ---
DEFAULT_EXIT_NODE_IP="XX.XX.XX.XX"   # Fallback only — used on first run when GL has no selection

# GL native settings
# Allow Remote Access LAN — required for tailnet peers to reach LAN devices behind this router.
# Subnet route must also be approved in the Tailscale admin console for this to take effect.
LAN_ENABLED=true
# Allow Remote Access WAN — only needed when advertising this router as an exit node.
WAN_ENABLED=false

# gl-tailscale-fix preferences — applied on every "on" because the plugin's watchdog tears
# these down to 0 when Tailscale is disabled.
KILL_SWITCH=true                      # Engage kill switch on enable
ROUTE_GUEST=false                     # Route guest network through Tailscale
ADVERTISE_EXIT_NODE=false             # Advertise this router as an exit node
TAILSCALE_SSH=false                   # Enable Tailscale's ACL-based SSH

# --- Logic ---
action=$1

# GL RPC endpoint — port lookup mirrors GL's own switch scripts in /etc/gl-switch.d/.
PORT=$(cat /etc/nginx/conf.d/gl.conf 2>/dev/null | grep -E "    listen [0-9]+;" | grep -oE '[0-9]+' | head -1)
[ -z "$PORT" ] && PORT=80
RPC="http://127.0.0.1:$PORT/rpc"

if [ "$action" = "on" ]; then
    # Defensive: disable competing VPN/proxy clients (WG, OpenVPN, Tor) only if currently
    # active. Their priority-6000 policy routing wins against Tailscale's exit-node routing
    # at priority 5270, so leaving any of them running would prevent traffic from actually
    # flowing through the Tailscale exit node. Backup for the case where the slider was
    # previously bound to one of those and is being rebound here without explicit teardown.
    # Pre-checks avoid spurious "Turning X OFF" MCU notifications when the service wasn't on.
    wg_status=$(curl -H 'glinet: 1' -s -k "$RPC" -d '{"jsonrpc":"2.0","method":"call","params":["","wg-client","get_status",{}],"id":1}' | jsonfilter -e '@.result.status' 2>/dev/null)
    [ -n "$wg_status" ] && [ "$wg_status" != "0" ] && /etc/gl-switch.d/wireguard.sh off >/dev/null 2>&1
    # OpenVPN's switch script has its own internal status pre-check, so direct call is safe.
    [ -x /etc/gl-switch.d/openvpn.sh ] && /etc/gl-switch.d/openvpn.sh off >/dev/null 2>&1
    tor_enabled=$(curl -H 'glinet: 1' -s -k "$RPC" -d '{"jsonrpc":"2.0","method":"call","params":["","tor","get_config",{}],"id":1}' | jsonfilter -e '@.result.enable' 2>/dev/null)
    [ "$tor_enabled" = "true" ] && /etc/gl-switch.d/tor.sh off >/dev/null 2>&1

    # Reuse GL's most recently selected exit node IP; fall back to default only when GL has
    # nothing set (first run or after a manual clear).
    exit_node_ip=$(uci -q get tailscale.settings.exit_node_ip)
    [ -z "$exit_node_ip" ] && exit_node_ip="$DEFAULT_EXIT_NODE_IP"

    # Enable Tailscale via GL's RPC, passing the resolved exit node IP.
    curl -H 'glinet: 1' -s -k "$RPC" -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tailscale\",\"set_config\",{\"enabled\":true,\"lan_enabled\":$LAN_ENABLED,\"wan_enabled\":$WAN_ENABLED,\"exit_node_ip\":\"$exit_node_ip\"}],\"id\":1}"

    sleep 5

    # Apply gl-tailscale-fix posture in lock-step with Tailscale.
    curl -H 'glinet: 1' -s -k "$RPC" -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ts-fix\",\"set_config\",{\"kill_switch\":$KILL_SWITCH,\"route_guest\":$ROUTE_GUEST,\"advertise_exit_node\":$ADVERTISE_EXIT_NODE,\"tailscale_ssh\":$TAILSCALE_SSH}],\"id\":2}"

elif [ "$action" = "off" ]; then
    # Disable Tailscale via UCI directly, bypassing GL's RPC. This preserves
    # tailscale.settings.exit_node_ip so the next "on" flip reconnects to the same node —
    # calling GL's set_config would clear it. The gl-tailscale-fix watchdog detects the
    # enabled=0 transition and tears down the kill switch routing rules within ~5 seconds.
    uci set tailscale.settings.enabled='0'
    uci commit tailscale
    /usr/bin/gl_tailscale restart >/dev/null 2>&1 &

else
    echo "Usage: $0 [on|off]" >&2
    exit 1
fi
