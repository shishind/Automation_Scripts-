#!/bin/bash

# This script generates BIND DNS forward and reverse zone files.
# It allows dynamic replacement of the base domain and uses interactive prompts for IP addresses.
# The IP for 'api' and 'api-int' is now always the same, prompted once.

# --- Configuration Variables ---
DEFAULT_TTL="1W"
DEFAULT_REFRESH="3H"
DEFAULT_RETRY="30M"
DEFAULT_EXPIRY="2W"
DEFAULT_MINIMUM="1W"
DEFAULT_SERIAL=$(date +%Y%m%d%H) # Generates a serial based on current date and hour

# --- Default IP Addresses (used if user presses Enter during prompt) ---
IP_NS1="192.168.1.5"
IP_API_DEFAULT="192.168.1.5" # Default for both API and API-INT
IP_APPS="192.168.1.5"
IP_BOOTSTRAP="192.168.1.96"
IP_MASTER0="192.168.1.97"
IP_MASTER1="192.168.1.98"
IP_MASTER2="192.168.1.99"
IP_WORKER0="192.168.1.11"
IP_WORKER1="192.168.1.7"

# Initialize IP_API and IP_API_INT to the common default
IP_API="$IP_API_DEFAULT"
IP_API_INT="$IP_API_DEFAULT"

# --- Functions ---

# Basic IP validation function
is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# Function to get IP input with a default option
get_ip_input() {
    local record_name="$1"
    local default_ip="$2"
    local ip=""
    while true; do
        read -p "Enter IP for $record_name (default: $default_ip): " ip_input
        ip="${ip_input:-$default_ip}" # Use default if input is empty

        if is_valid_ip "$ip"; then
            echo "$ip"
            break
        else
            echo "Invalid IP address format. Please try again." >&2
        fi
    done
}

# Function to extract the network portion for the reverse zone name (e.g., 1.168.192)
get_reverse_zone_network() {
    local ip_address="$1"
    if ! is_valid_ip "$ip_address"; then
        echo ""
        return 1
    fi
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip_address"
    echo "$o3.$o2.$o1"
    return 0
}

# Function to extract the full in-addr.arpa name for a PTR record
get_ptr_name() {
    local ip_address="$1"
    local reverse_zone_network=$(get_reverse_zone_network "$ip_address")
    local last_octet=$(get_last_octet "$ip_address")
    if [ -z "$reverse_zone_network" ] || [ -z "$last_octet" ]; then
        echo ""
        return 1
    fi
    echo "$last_octet.$reverse_zone_network.in-addr.arpa."
}

# Function to extract the last octet of an IP
get_last_octet() {
    local ip_address="$1"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip_address"
    echo "$o4"
}

display_help() {
    echo "Usage: $0 -d <your_fqdn> [-o <forward_output_filename>] [-r <reverse_output_filename>]"
    echo ""
    echo "  -d <your_fqdn>       : The base FQDN to use (e.g., mycluster.example.org)."
    echo "                         This will replace 'ocp4.example.com' in the template."
    echo "  -o <forward_output_filename> : The name of the output forward DNS zone file (e.g., db.mycluster.zone)."
    echo "                         If not provided, forward zone output will be printed to stdout."
    echo "  -r <reverse_output_filename> : The name of the output reverse DNS zone file (e.g., db.1.168.192)."
    echo "                         Requires at least one valid IP (e.g., for NS1) to derive the network for the zone name."
    echo "                         If not provided, reverse zone is not generated."
    echo "  -h                   : Display this help message."
    echo ""
    echo "After providing command-line arguments, you will be prompted to enter IP addresses for each record."
    echo "Note: IP for api.<FQDN> and api-int.<FQDN> will be the same, prompted once."
    echo "Press Enter to accept the default IP displayed in parentheses."
    echo ""
    echo "Example:"
    echo "  $0 -d mycluster.example.org -o db.mycluster.zone -r db.1.168.192"
}

# --- Main Script Logic ---

FQDN=""
FORWARD_OUTPUT_FILE=""
REVERSE_OUTPUT_FILE=""

# Parse command-line options (only -d, -o, -r, -h now)
while getopts "d:o:r:h" opt; do
    case ${opt} in
        d )
            FQDN="$OPTARG"
            ;;
        o )
            FORWARD_OUTPUT_FILE="$OPTARG"
            ;;
        r )
            REVERSE_OUTPUT_FILE="$OPTARG"
            ;;
        h )
            display_help
            exit 0
            ;;
        \? )
            echo "Invalid option: -$OPTARG" >&2
            display_help
            exit 1
            ;;
        : )
            echo "Option -$OPTARG requires an argument." >&2
            display_help
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

if [ -z "$FQDN" ]; then
    echo "Error: FQDN (-d) is a required argument." >&2
    display_help
    exit 1
fi

# Define the base domain for SOA and NS records
BASE_DOMAIN=$(echo "$FQDN" | cut -d'.' -f2-) # Extracts "example.com" from "mycluster.example.com"

# --- Get IP addresses interactively ---
echo "" >&2
echo "Please provide IP addresses for each entry. Press Enter to use the default." >&2
echo "-----------------------------------------------------------------------" >&2

# Use get_ip_input to populate the IP variables
IP_NS1=$(get_ip_input "ns1.$BASE_DOMAIN" "$IP_NS1")
# Prompt once for API and API-INT
COMMON_API_IP=$(get_ip_input "api.$FQDN and api-int.$FQDN" "$IP_API_DEFAULT")
IP_API="$COMMON_API_IP"
IP_API_INT="$COMMON_API_IP"

IP_APPS=$(get_ip_input "*.apps.$FQDN" "$IP_APPS")
IP_BOOTSTRAP=$(get_ip_input "bootstrap.$FQDN" "$IP_BOOTSTRAP")
IP_MASTER0=$(get_ip_input "master0.$FQDN" "$IP_MASTER0")
IP_MASTER1=$(get_ip_input "master1.$FQDN" "$IP_MASTER1")
IP_MASTER2=$(get_ip_input "master2.$FQDN" "$IP_MASTER2")
IP_WORKER0=$(get_ip_input "worker0.$FQDN" "$IP_WORKER0")
IP_WORKER1=$(get_ip_input "worker1.$FQDN" "$IP_WORKER1")

echo "" >&2
echo "Generating zone files..." >&2

# --- Generate the Forward Zone File Content ---
# Print content directly to stdout or redirect stdout to file
if [ -n "$FORWARD_OUTPUT_FILE" ]; then
    { # Use a subshell to group the heredoc and redirection
    cat << EOF
\$TTL $DEFAULT_TTL
@	IN	SOA	ns1.$BASE_DOMAIN.	root (
			$DEFAULT_SERIAL	; serial
			$DEFAULT_REFRESH		; refresh ($DEFAULT_REFRESH)
			$DEFAULT_RETRY		; retry ($DEFAULT_RETRY)
			$DEFAULT_EXPIRY		; expiry ($DEFAULT_EXPIRY)
			$DEFAULT_MINIMUM )		; minimum ($DEFAULT_MINIMUM)
	IN	NS	ns1.$BASE_DOMAIN.
;
;
ns1.$BASE_DOMAIN.		IN	A	$IP_NS1
;
api.$FQDN.		IN	A	$IP_API
api-int.$FQDN.	IN	A	$IP_API_INT
;
*.apps.$FQDN.	IN	A	$IP_APPS
;
bootstrap.$FQDN.	IN	A	$IP_BOOTSTRAP
;
master0.$FQDN.	IN	A	$IP_MASTER0
master1.$FQDN.	IN	A	$IP_MASTER1
master2.$FQDN.	IN	A	$IP_MASTER2
;
worker0.$FQDN.	IN	A	$IP_WORKER0
worker1.$FQDN.	IN	A	$IP_WORKER1
;
;
EOF
    } > "$FORWARD_OUTPUT_FILE" # Redirect the grouped output
    echo "Forward zone file '$FORWARD_OUTPUT_FILE' created successfully." >&2 # Log message to stderr
else
    echo "### Forward Zone Content for $FQDN ###" >&2 # Output header to stderr for clarity
    echo "----------------------------------------------------" >&2
    cat << EOF
\$TTL $DEFAULT_TTL
@	IN	SOA	ns1.$BASE_DOMAIN.	root (
			$DEFAULT_SERIAL	; serial
			$DEFAULT_REFRESH		; refresh ($DEFAULT_REFRESH)
			$DEFAULT_RETRY		; retry ($DEFAULT_RETRY)
			$DEFAULT_EXPIRY		; expiry ($DEFAULT_EXPIRY)
			$DEFAULT_MINIMUM )		; minimum ($DEFAULT_MINIMUM)
	IN	NS	ns1.$BASE_DOMAIN.
;
api.$FQDN.		IN	A	$IP_API
api-int.$FQDN.	IN	A	$IP_API_INT
;
bootstrap.$FQDN.	IN	A	$IP_BOOTSTRAP
;
master0.$FQDN.	IN	A	$IP_MASTER0
master1.$FQDN.	IN	A	$IP_MASTER1
master2.$FQDN.	IN	A	$IP_MASTER2
;
worker0.$FQDN.	IN	A	$IP_WORKER0
worker1.$FQDN.	IN	A	$IP_WORKER1
;
;
EOF
fi

# --- Generate the Reverse Zone File Content (if requested) ---
if [ -n "$REVERSE_OUTPUT_FILE" ]; then
    # Ensure IP_NS1 is valid before proceeding for reverse zone name
    if ! is_valid_ip "$IP_NS1"; then
        echo "Error: IP_NS1 ($IP_NS1) is invalid. Cannot generate reverse zone." >&2
        exit 1
    fi
    REVERSE_ZONE_NETWORK=$(get_reverse_zone_network "$IP_NS1")
    if [ -z "$REVERSE_ZONE_NETWORK" ]; then
        echo "Error: Could not determine reverse zone network from IP_NS1 ($IP_NS1)." >&2
        exit 1
    fi

    { # Use a subshell for reverse zone output
    cat << EOF
\$TTL $DEFAULT_TTL
@	IN	SOA	ns1.$BASE_DOMAIN.	root (
			$DEFAULT_SERIAL	; serial
			$DEFAULT_REFRESH		; refresh ($DEFAULT_REFRESH)
			30M		; retry (30 minutes)
			$DEFAULT_EXPIRY		; expiry ($DEFAULT_EXPIRY)
			$DEFAULT_MINIMUM )		; minimum ($DEFAULT_MINIMUM)
	IN	NS	ns1.$BASE_DOMAIN.
;
$(get_ptr_name "$IP_API")	IN	PTR	api.$FQDN.
$(get_ptr_name "$IP_API_INT")	IN	PTR	api-int.$FQDN.
;
$(get_ptr_name "$IP_BOOTSTRAP")	IN	PTR	bootstrap.$FQDN.
;
$(get_ptr_name "$IP_MASTER0")	IN	PTR	master0.$FQDN.
$(get_ptr_name "$IP_MASTER1")	IN	PTR	master1.$FQDN.
$(get_ptr_name "$IP_MASTER2")	IN	PTR	master2.$FQDN.
;
$(get_ptr_name "$IP_WORKER0")	IN	PTR	worker0.$FQDN.
$(get_ptr_name "$IP_WORKER1")	IN	PTR	worker1.$FQDN.
;
;
EOF
    } > "$REVERSE_OUTPUT_FILE" # Redirect the grouped output
    echo "Reverse zone file '$REVERSE_OUTPUT_FILE' created successfully." >&2 # Log message to stderr
fi

# Final message to stderr, as stdout might be redirected to a forward zone file.
echo "" >&2
echo "DNS zone generation complete." >&2
