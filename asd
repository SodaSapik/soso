#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Variables
DOMAIN="aclc.ru"
IP="10.10.16.128"
HOSTS_FILE="/etc/hosts"
BIND_CONF="/etc/bind/named.conf.local"
BIND_ZONE="/etc/bind/db.${DOMAIN}.local"

print_status "Starting automatic DNS configuration for ${DOMAIN}..."

# 1. Check root privileges
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# 2. Check if BIND is running
print_status "Checking DNS servers..."
if systemctl is-active --quiet named; then
    print_success "BIND9 is running (named)"
    USE_BIND=true
elif systemctl is-active --quiet dnsmasq; then
    print_success "dnsmasq is running"
    USE_DNSMASQ=true
else
    print_warning "No DNS server found"
    USE_BIND=false
    USE_DNSMASQ=false
fi

# 3. Check if port 53 is occupied
print_status "Checking port 53..."
if lsof -i :53 | grep -q LISTEN; then
    DNS_SERVICE=$(lsof -i :53 | grep LISTEN | head -1 | awk '{print $1}')
    print_success "Port 53 is used by: ${DNS_SERVICE}"
else
    print_warning "Port 53 is free"
fi

# 4. Configure BIND if it exists
if [[ "$USE_BIND" == true ]]; then
    print_status "Configuring BIND9..."
    
    # Create zone file
    cat > ${BIND_ZONE} <<EOF
\$TTL 3600
@       IN SOA  ns.${DOMAIN}. root.${DOMAIN}. (
            2026040301
            3600
            1800
            604800
            3600
)
        IN NS   ns.${DOMAIN}.
@       IN A    ${IP}
ns      IN A    ${IP}
moodle  IN A    ${IP}
mail    IN A    ${IP}
EOF
    
    # Check if zone already exists in config
    if ! grep -q "zone \"${DOMAIN}\"" ${BIND_CONF} 2>/dev/null; then
        cat >> ${BIND_CONF} <<EOF

zone "${DOMAIN}" {
    type master;
    file "${BIND_ZONE}";
};
EOF
        print_success "Added zone to BIND config"
    else
        print_status "Zone already exists in BIND config"
    fi
    
    # Check configuration
    if named-checkzone ${DOMAIN} ${BIND_ZONE} 2>/dev/null; then
        print_success "Zone file syntax OK"
    else
        print_error "Zone file has errors"
        cat ${BIND_ZONE}
        exit 1
    fi
    
    if named-checkconf; then
        print_success "BIND configuration OK"
    else
        print_error "BIND configuration has errors"
        exit 1
    fi
    
    # Restart BIND
    systemctl restart named
    if systemctl is-active --quiet named; then
        print_success "BIND9 restarted successfully"
    else
        print_error "Failed to restart BIND9"
        exit 1
    fi
fi

# 5. Configure dnsmasq if no BIND
if [[ "$USE_DNSMASQ" == true ]]; then
    print_status "Configuring dnsmasq..."
    
    # Stop systemd-resolved if running
    if systemctl is-active --quiet systemd-resolved; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        print_status "Stopped systemd-resolved"
    fi
    
    # Create dnsmasq config
    cat > /etc/dnsmasq.d/aclc.conf <<EOF
listen-address=127.0.0.1
listen-address=${IP}
bind-interfaces
local=/${DOMAIN}/
domain=${DOMAIN}
address=/moodle.${DOMAIN}/${IP}
address=/mail.${DOMAIN}/${IP}
log-queries
EOF
    
    # Restart dnsmasq
    systemctl restart dnsmasq
    if systemctl is-active --quiet dnsmasq; then
        print_success "dnsmasq restarted successfully"
    else
        print_error "Failed to restart dnsmasq"
        journalctl -u dnsmasq -n 10 --no-pager
        exit 1
    fi
fi

# 6. Always add entries to /etc/hosts as fallback
print_status "Updating /etc/hosts..."
if ! grep -q "moodle.${DOMAIN}" ${HOSTS_FILE}; then
    echo "127.0.0.1 moodle.${DOMAIN} mail.${DOMAIN}" >> ${HOSTS_FILE}
    echo "${IP} moodle.${DOMAIN} mail.${DOMAIN}" >> ${HOSTS_FILE}
    print_success "Added entries to ${HOSTS_FILE}"
else
    print_status "Entries already exist in ${HOSTS_FILE}"
fi

# 7. Configure system resolver
print_status "Configuring system resolver..."

# Backup original resolv.conf
cp ${HOSTS_FILE} ${HOSTS_FILE}.backup.$(date +%Y%m%d_%H%M%S)

# Configure resolv.conf for local DNS
if [[ "$USE_BIND" == true ]] || [[ "$USE_DNSMASQ" == true ]]; then
    cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
nameserver 8.8.8.8
search ${DOMAIN}
EOF
    print_success "Configured /etc/resolv.conf to use local DNS"
else
    print_status "Using /etc/hosts only (no local DNS server)"
fi

# 8. Test DNS resolution
print_status "Testing DNS resolution..."

sleep 2

# Test with dig if available
if command -v dig &> /dev/null; then
    print_status "Testing with dig..."
    
    if dig +short moodle.${DOMAIN} @127.0.0.1 | grep -q "${IP}"; then
        print_success "moodle.${DOMAIN} resolves to ${IP}"
    else
        print_warning "moodle.${DOMAIN} test failed, checking fallback..."
        if grep -q "moodle.${DOMAIN}" ${HOSTS_FILE}; then
            print_success "moodle.${DOMAIN} found in /etc/hosts"
        else
            print_error "moodle.${DOMAIN} resolution failed"
        fi
    fi
    
    if dig +short mail.${DOMAIN} @127.0.0.1 | grep -q "${IP}"; then
        print_success "mail.${DOMAIN} resolves to ${IP}"
    else
        print_warning "mail.${DOMAIN} test failed, checking fallback..."
        if grep -q "mail.${DOMAIN}" ${HOSTS_FILE}; then
            print_success "mail.${DOMAIN} found in /etc/hosts"
        else
            print_error "mail.${DOMAIN} resolution failed"
        fi
    fi
else
    # Test with nslookup or ping
    if nslookup moodle.${DOMAIN} 127.0.0.1 2>/dev/null | grep -q "${IP}"; then
        print_success "moodle.${DOMAIN} resolves to ${IP}"
    else
        print_warning "moodle.${DOMAIN} test failed"
    fi
    
    if nslookup mail.${DOMAIN} 127.0.0.1 2>/dev/null | grep -q "${IP}"; then
        print_success "mail.${DOMAIN} resolves to ${IP}"
    else
        print_warning "mail.${DOMAIN} test failed"
    fi
fi

# 9. Final check
print_status "==================================="
print_success "DNS configuration completed"
print_status "==================================="
echo ""
print_status "Current DNS resolution:"
echo "moodle.${DOMAIN} -> $(dig +short moodle.${DOMAIN} @127.0.0.1 2>/dev/null || grep moodle.${DOMAIN} ${HOSTS_FILE} | head -1 | awk '{print $1}')"
echo "mail.${DOMAIN}   -> $(dig +short mail.${DOMAIN} @127.0.0.1 2>/dev/null || grep mail.${DOMAIN} ${HOSTS_FILE} | head -1 | awk '{print $1}')"
echo ""
print_status "To test:"
echo "  ping moodle.${DOMAIN}"
echo "  ping mail.${DOMAIN}"
echo "  nslookup moodle.${DOMAIN} 127.0.0.1"
echo ""
print_status "Backup files saved in /etc/hosts.backup.*"
